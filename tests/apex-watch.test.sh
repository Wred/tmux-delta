#!/usr/bin/env zsh
# Tests for the fast automatic ping poller: scripts/tmux-apex.sh's
# _apex_pending_sig and _apex_watch_tick (issue #14).
#
# A tick is a pure function of three things — the member state files, what
# `tmux capture-pane` reports for the manager's input box, and the watcher's
# own saved state — so a fake tmux on PATH and a temp $APEX_ROOT are enough.
# No live agent, no real pane, no daemon: the loop is one `sleep` around
# _apex_watch_tick, and the tick is what all the decisions live in.
#
# Run: tests/apex-watch.test.sh

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-watch-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq()  { if [[ $2 == $3 ]]; then ok "$1"; else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi }
contains() { if [[ $3 == *$2* ]]; then ok "$1"; else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi }
lacks() { if [[ $3 != *$2* ]]; then ok "$1"; else bad "$1" "expected NOT to contain: ${(qqq)2}
       actual                 : ${(qqq)3}"; fi }

# ── fake tmux ────────────────────────────────────────────────────────
# Renders the manager's pane from $PANE_FILE and logs send-keys. The box
# drains on Enter (a well-behaved TUI); the send path's misbehaving-TUI cases
# are already covered by tests/apex-send.test.sh and are not re-tested here.
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env zsh
case "$1" in
	capture-pane) cat "$PANE_FILE" ;;
	list-panes)   printf '%s\n' "$MGR_PANE" ;;
	list-clients) [ -n "${CLIENT_ACTIVITY:-}" ] && printf '%s\n' "$CLIENT_ACTIVITY" ;;
	has-session)  exit 0 ;;
	display-message) printf '%s\n' "${PANE_CMD:-node}" ;;
	show-option)  printf '%s\n' "" ;;
	send-keys)
		shift; args="$*"
		printf '%s\n' "$args" >> "$KEYS_LOG"
		case "$args" in
			*"-l -- "*) printf '\xe2\x94\x82 > %s   \xe2\x94\x82\n' "${args#*-l -- }" > "$PANE_FILE" ;;
			*Enter*)    printf '%s\n' "$EMPTY_BOX" > "$PANE_FILE" ;;
			*C-u*)      printf '%s\n' "$EMPTY_BOX" > "$PANE_FILE" ;;
		esac ;;
esac
exit 0
STUB
chmod +x "$BIN/tmux"
export PATH="$BIN:$PATH"
export PANE_FILE="$TMPROOT/pane" KEYS_LOG="$TMPROOT/keys" MGR_PANE='%1'
export PANE_CMD=node
export EMPTY_BOX='│ >                                    │'
export XDG_CACHE_HOME="$TMPROOT/cache"

source "$SCRIPTS/tmux-apex.sh" >/dev/null 2>&1

MGR=fake-manager
# The manager is a bare session name, so _agent_pane reads @agent_pane off it;
# the stub answers every show-option with "", so point it at the pane directly.
_agent_pane() { print -r -- "$MGR_PANE" }

member() {  # member <id> <status> <seq> <pinged_seq>
	apex_init_dirs "$MGR"
	jq -nc --arg st "$2" --argjson seq "$3" --argjson p "$4" \
		'{status:$st, seq:$seq, pinged_seq:$p}' > "$(apex_member_file "$MGR" "$1")"
}
reset() {
	rm -rf "$(apex_dir "$MGR")"; apex_init_dirs "$MGR"
	print -r -- "$EMPTY_BOX" > "$PANE_FILE"; : > "$KEYS_LOG"
}
keys() { cat "$KEYS_LOG" 2>/dev/null }
tick() { _apex_watch_tick "$MGR" 2>/dev/null }

# ── the cheap gate ───────────────────────────────────────────────────
# The whole reason a 1s cadence is affordable is that this predicate touches
# nothing but the state files. If it ever grows a git or gh call the tick cost
# stops being negligible, so it is tested directly and separately.
print "_apex_pending_sig"

reset
eq "no members reports nothing" "" "$(_apex_pending_sig "$MGR")"

member 'w:%7' idle 3 -1
eq "an undelivered idle member is reported" "w:%7#3" "$(_apex_pending_sig "$MGR")"

member 'w:%7' idle 3 3
eq "already-delivered member is not reported" "" "$(_apex_pending_sig "$MGR")"

member 'w:%7' working 4 3
eq "a member mid-turn is not reported" "" "$(_apex_pending_sig "$MGR")"

member 'w:%7' starting 4 3
eq "a starting member is not reported" "" "$(_apex_pending_sig "$MGR")"

member 'w:%7' attention 5 3
eq "attention is reported like idle" "w:%7#5" "$(_apex_pending_sig "$MGR")"

# Keyed on seq, not session: settle → ping → wake → settle again is a second
# event to deliver, and keying on the session alone would eat it.
member 'w:%7' idle 6 5
eq "the sequence number is part of the fingerprint" "w:%7#6" "$(_apex_pending_sig "$MGR")"

reset
member 'b:%9' attention 1 -1
member 'a:%8' idle 2 -1
eq "several members are reported in a stable order" "a:%8#2,b:%9#1" "$(_apex_pending_sig "$MGR")"

# ── nudging ──────────────────────────────────────────────────────────
print "_apex_watch_tick"

reset
tick >/dev/null
eq "nothing pending sends nothing" "" "$(keys)"

reset
member 'w:%7' idle 3 -1
out=$(tick)
contains "a pending member nudges the manager" "nudged $MGR for: w:%7#3" "$out"
contains "the nudge is typed into the pane" "[apex] a member just changed state" "$(keys)"
contains "and submitted" "Enter" "$(keys)"

# The nudge deliberately carries no event detail — the manager's own
# UserPromptSubmit hook attaches the real `pending` output as context, so
# duplicating it here would only risk the two disagreeing.
lacks "the nudge does not restate the event itself" "status=idle" "$(keys)"

# ── not nudging twice for one event ───────────────────────────────────
# A nudge can sit queued behind a long manager turn. Re-sending every second
# until it lands would bury the manager in duplicates, so the same fingerprint
# is only re-sent after APEX_WATCH_RENUDGE.
print "debounce"

reset
member 'w:%7' idle 3 -1
tick >/dev/null
: > "$KEYS_LOG"
tick >/dev/null
eq "the same pending set is not re-sent immediately" "" "$(keys)"

APEX_WATCH_RENUDGE=0
tick >/dev/null
contains "but is re-sent once the re-nudge window passes" "-l -- " "$(keys)"
APEX_WATCH_RENUDGE=60

# A genuinely new event must get through the debounce.
reset
member 'w:%7' idle 3 -1
tick >/dev/null
: > "$KEYS_LOG"
member 'w:%7' idle 4 3
tick >/dev/null
contains "a new event nudges again straight away" "-l -- " "$(keys)"

# ── never clobbering live typing ──────────────────────────────────────
# This is the guard that makes writing into the manager's pane acceptable at
# all (issue #5). A human mid-draft moves the box; the agent's own ghost
# autosuggestion does not (issue #10) — so an unchanged box eventually loses
# its protection, otherwise ghost text would block delivery forever, which is
# the exact failure this command exists to fix.
print "input-box protection"

reset
member 'w:%7' idle 3 -1
print -r -- '│ > half a thought                     │' > "$PANE_FILE"
: > "$KEYS_LOG"
out=$(tick)
contains "unsent input defers the nudge" "deferring" "$out"
eq "and sends nothing" "" "$(keys)"

# Still typing: the box changed, so the grace window restarts.
print -r -- '│ > half a thought and more            │' > "$PANE_FILE"
: > "$KEYS_LOG"
tick >/dev/null
eq "a changing box keeps deferring" "" "$(keys)"

# Unchanged past the grace window: treat it as stale and deliver, clearing it.
APEX_WATCH_BOX_GRACE=0
: > "$KEYS_LOG"
tick >/dev/null
contains "a box unchanged past the grace window is cleared" "C-u" "$(keys)"
contains "and the nudge is delivered" "[apex] a member just changed state" "$(keys)"
APEX_WATCH_BOX_GRACE=15

# A resolved event must not leave its grace clock ticking — otherwise the next
# real event finds an "already waited long enough" box and clears a draft that
# has only just been typed.
reset
member 'w:%7' idle 3 -1
print -r -- '│ > a draft                            │' > "$PANE_FILE"
tick >/dev/null
member 'w:%7' idle 3 3          # delivered; nothing pending
tick >/dev/null
eq "settling clears the deferred-box clock" "0" "$(_apex_watch_state "$MGR" box_since)"

# ── only ever into an agent pane ──────────────────────────────────────
# Sending into a shell would execute the nudge as a command.
print "pane safety"

reset
member 'w:%7' idle 3 -1
PANE_CMD=zsh
: > "$KEYS_LOG"
out=$(tick)
contains "a non-agent pane is refused" "no agent pane" "$out"
eq "and nothing is typed into it" "" "$(keys)"
PANE_CMD=node

# ── surviving a damaged state file ───────────────────────────────────
# Every "" the state reader can return has to fail *closed*. Read as
# "never nudged" and "box first seen at the epoch", an unreadable state file
# turns the 1s daemon into a nudge per second, each one running
# _clear_pane_input over whatever the human is typing — the exact hazard the
# guards above exist to prevent. The old code did precisely that, and the
# suite missed it because it only ever exercised a healthy file.
print "damaged state file"

reset
member 'w:%7' idle 3 -1
tick >/dev/null                          # one legitimate nudge
: > "$KEYS_LOG"
print -r -- 'not json at all' > "$(_apex_watch_statefile "$MGR")"
repeat 5 { tick >/dev/null }
# The file is reset and that tick skipped, so the worst case is one duplicate
# nudge for an event already delivered — not one per tick, which is what an
# unguarded "" default produced (five ticks, five nudges).
n=$(grep -c -- '-l -- \[apex\]' "$KEYS_LOG" 2>/dev/null) || n=0
if (( n <= 1 )); then ok "garbage state costs at most one duplicate nudge, not one per tick"
else bad "garbage state costs at most one duplicate nudge, not one per tick" "nudges: $n"; fi

# ...and a save must repair the file rather than leaving it wedged: the old
# `cat` base meant one bad merge emptied it and every later save failed
# identically, with no recovery short of deleting it by hand.
_apex_watch_save "$MGR" '{"box":"","box_since":0}'
eq "a save over garbage restores parseable state" "0" "$(_apex_watch_state "$MGR" box_since)"

# A draft in the box must still be safe when the state file is unreadable.
reset
member 'w:%7' idle 3 -1
print -r -- '│ > a draft I am still writing         │' > "$PANE_FILE"
print -r -- 'not json at all' > "$(_apex_watch_statefile "$MGR")"
: > "$KEYS_LOG"
repeat 5 { tick >/dev/null }
lacks "an unreadable state file never clears a draft" "C-u" "$(keys)"

# ── one bad member file must not blind the rest ───────────────────────
# The cheap gate slurps every member file in one jq, and a slurp aborts on the
# first unparseable document. Returning "" for the whole set would leave a
# poller that reports itself healthy in `doctor` and `watch --status` and will
# never fire again, while `pending` keeps answering correctly.
print "malformed member file"

reset
member 'good:%8' idle 4 -1
print -r -- '{ truncated' > "$(apex_member_file "$MGR" 'bad:%9')"
eq "a corrupt member only loses itself" "good:%8#4" "$(_apex_pending_sig "$MGR" 2>/dev/null)"
contains "and the degradation is recorded" "watch-degraded" \
	"$(cat "$(apex_events_file "$MGR")" 2>/dev/null)"

# ── a comma in a session name ────────────────────────────────────────
# tmux allows it (`tmux new-session -s a,b` succeeds), so the names cannot ride
# alongside the slurped documents on a comma — one name would split into two
# and misalign every name after it, attaching the wrong seq to the wrong
# member.
reset
member 'has,comma:%3' idle 9 -1
member 'plain:%4' idle 1 -1
eq "a comma in a session name does not misalign names" \
	"has,comma:%3#9,plain:%4#1" "$(_apex_pending_sig "$MGR")"

# ── client activity, not just a timer ────────────────────────────────
# The grace window is really asking "is a human present?". tmux answers it
# directly: client_activity moves only on client *input*, and ghost text is
# painted with none at all. So a present human keeps their draft while an
# unattended pane still expires on schedule.
print "client activity"

reset
member 'w:%7' idle 3 -1
print -r -- '│ > mid-sentence                       │' > "$PANE_FILE"
tick >/dev/null                          # records the box
export CLIENT_ACTIVITY=$(date +%s)
APEX_WATCH_BOX_GRACE=0
: > "$KEYS_LOG"
# GRACE=0 would otherwise deliver immediately; recent client input must not.
APEX_WATCH_BOX_GRACE=5
out=$(tick)
contains "recent client input keeps deferring" "deferring" "$out"
eq "and clears nothing" "" "$(keys)"

# Nobody attached: the timer is all there is, and it still fires.
export CLIENT_ACTIVITY=""
APEX_WATCH_BOX_GRACE=0
: > "$KEYS_LOG"
tick >/dev/null
contains "an unattended stale box still gets delivery" "[apex] a member just changed state" "$(keys)"
APEX_WATCH_BOX_GRACE=60

# ── pidfile ownership ────────────────────────────────────────────────
# The pidfile outlives reboots under $XDG_CACHE_HOME, after which the pid has
# very likely been reassigned. Trusting `kill -0` alone both blocks `init` from
# starting a real poller and points `watch --stop` at somebody else's process.
print "pidfile ownership"

reset
print -r -- "$$" > "$(_apex_watch_pidfile "$MGR")"
if _apex_watch_running "$MGR" >/dev/null 2>&1; then
	bad "a live pid that is not a watcher reads as not running" "reported running"
else
	ok "a live pid that is not a watcher reads as not running"
fi
[[ -f $(_apex_watch_pidfile "$MGR") ]] \
	&& bad "and the stale pidfile is unlinked" "still present" \
	|| ok "and the stale pidfile is unlinked"

reset
print -r -- 'not-a-pid' > "$(_apex_watch_pidfile "$MGR")"
if _apex_watch_running "$MGR" >/dev/null 2>&1; then
	bad "a garbage pidfile reads as not running" "reported running"
else
	ok "a garbage pidfile reads as not running"
fi

# ── knob validation ──────────────────────────────────────────────────
# A non-numeric interval makes `sleep` fail instantly, which the loop cannot
# tell from a slept second — it would spin a core running full ticks forever.
print "knob validation"

_die() { print -u2 -- "die: $*"; return 1 }
out=$(APEX_WATCH_INTERVAL=1s _apex_watch_check_knobs 2>&1) || true
contains "a non-numeric interval is refused" "APEX_WATCH_INTERVAL must be a number" "$out"
out=$(APEX_WATCH_INTERVAL=0.5 _apex_watch_check_knobs 2>&1) || true
eq "a fractional interval is accepted" "" "$out"

# ── summary ──────────────────────────────────────────────────────────
print ""
print "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
