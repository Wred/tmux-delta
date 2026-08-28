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

# ── summary ──────────────────────────────────────────────────────────
print ""
print "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
