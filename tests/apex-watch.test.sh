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
	list-clients) [ -n "${CLIENT_ACTIVITY:-}" ] && printf '%s\n' "client-0" ;;
	has-session)  exit 0 ;;
	display-message)
		case "$*" in
			*client_activity*) printf '%s\n' "$CLIENT_ACTIVITY" ;;
			# Which pane the client is looking at — $CLIENT_PANE lets a test put
			# it on a sibling pane rather than the manager's.
			*pane_id*)         printf '%s\n' "${CLIENT_PANE:-$MGR_PANE}" ;;
			*)                 printf '%s\n' "${PANE_CMD:-node}" ;;
		esac ;;
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
export PANE_CMD=node CLIENT_ACTIVITY="" CLIENT_PANE=""
export EMPTY_BOX='│ >                                    │'
export XDG_CACHE_HOME="$TMPROOT/cache"

source "$SCRIPTS/tmux-apex.sh" >/dev/null 2>&1

MGR=fake-manager
# The manager is a bare session name, so _agent_pane reads @agent_pane off it;
# the stub answers every show-option with "", so point it at the pane directly.
_agent_pane() { print -r -- "$MGR_PANE" }

member() {  # member <id> <status> <seq> <pinged_seq> [pair_message]
	apex_init_dirs "$MGR"
	jq -nc --arg st "$2" --argjson seq "$3" --argjson p "$4" --arg pm "${5-}" \
		'{status:$st, seq:$seq, pinged_seq:$p, pair_message:$pm}' \
		> "$(apex_member_file "$MGR" "$1")"
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

# `pending` reports a pair escalation on its own merit rather than through the
# `status` it forces, so a terminal "READY FOR HUMAN REVIEW" can arrive while
# the member reads as working. The gate has to agree, or the poller stays quiet
# through exactly the handoff that most wants a human.
reset
member 'w:%7' working 4 3 'READY FOR HUMAN REVIEW'
eq "a pair escalation is reported even mid-turn" "w:%7#4!" "$(_apex_pending_sig "$MGR")"

# The `!` is not decoration: without it a pair message landing on a member that
# was already reported idle at the same seq would fingerprint identically, and
# the debounce would swallow the escalation as a duplicate.
member 'w:%7' idle 4 3
eq "the escalation marker distinguishes the fingerprint" "w:%7#4" "$(_apex_pending_sig "$MGR")"

# ── the gate and `pending` must agree, exhaustively ──────────────────
# The invariant the watcher rests on: it nudges exactly when `pending` has
# something to say. Nothing used to assert that. The decision was written twice
# — here in jq, and in `_cmd_pending` in shell — and the two drifted, so the
# gate returned empty while `pending` reported READY FOR HUMAN REVIEW and the
# handoff was suppressed for as long as nobody looked (issue #23).
#
# `_cmd_pending` now shares this file's `reportable` definition, so the two
# cannot disagree about the predicate by construction. They still *enumerate*
# members differently — one jq over all files vs. one read per member — which
# is exactly the kind of difference a shared definition does not cover, so the
# agreement is asserted directly over every state either one distinguishes.
print "\npending and the gate agree"

# _cmd_pending reaches for the manager and for per-member git/PR facts; neither
# is what is under test here, and the stub tmux answers show-option with "".
_require_manager() { print -r -- "$MGR" }

pending_reports() {  # 1 if `pending` emits a line for w:%7, else 0
	[[ $(_cmd_pending 2>/dev/null) == *'session=w:%7'* ]] && print 1 || print 0
}
gate_reports() {     # 1 if the cheap gate fingerprints w:%7, else 0
	[[ $(_apex_pending_sig "$MGR" 2>/dev/null) == *'w:%7'* ]] && print 1 || print 0
}

typeset -a DISAGREE=()
typeset -i REPORTED=0 CHECKED=0
for st in idle attention working starting; do
	for seqs in '4 3' '4 4'; do
		for pm in '' 'READY FOR HUMAN REVIEW'; do
			reset
			member 'w:%7' "$st" ${=seqs} "$pm"
			p=$(pending_reports); g=$(gate_reports)
			(( CHECKED += 1 ))
			(( REPORTED += p ))
			[[ $p == "$g" ]] || DISAGREE+=("status=$st seq/pinged='$seqs' pair_message='${pm:-<none>}': pending=$p gate=$g")
		done
	done
done

eq "every member state agrees between pending and the gate" "" "${(j:; :)DISAGREE}"
# Both answering "no" everywhere would satisfy the agreement check while
# asserting nothing, so pin that the matrix actually exercises both answers.
eq "…over all 16 states"          16 "$CHECKED"
eq "…and some of them do report"   6 "$REPORTED"

# Still one-shot. seq is the delivery ledger for escalations too, so a message
# left in the record after delivery must not re-report forever.
member 'w:%7' working 4 4 'READY FOR HUMAN REVIEW'
eq "a delivered escalation is not re-reported" "" "$(_apex_pending_sig "$MGR")"

member 'w:%7' working 4 3 ''
eq "an empty pair message is not an escalation" "" "$(_apex_pending_sig "$MGR")"

# ── a member that never took its first turn (issue #42) ──────────────
# `starting` is written at registration and only ever moved off by the
# member's own hooks, so an agent whose launch failed — or that came back
# from `recover` and is sitting at an empty prompt — holds `starting` with
# seq 0 for the life of the pane. Every reporting path agreed it had nothing
# to say, and two workers sat like that for ~24h. Past APEX_STARTING_STALE
# that is a failure, not a state.
print "\nstale starting"

# member_started <id> <status> <seq> <pinged_seq> <age-seconds>
member_started() {
	apex_init_dirs "$MGR"
	jq -nc --arg st "$2" --argjson seq "$3" --argjson p "$4" \
		--argjson t "$(( $(date +%s) - $5 ))" \
		'{status:$st, seq:$seq, pinged_seq:$p, pair_message:"", spawned_at:$t}' \
		> "$(apex_member_file "$MGR" "$1")"
}

reset
member_started 'w:%7' starting 0 -1 5
eq "a member that just started is not reported" "" "$(_apex_pending_sig "$MGR")"

member_started 'w:%7' starting 0 -1 60
eq "…and is reported once it is stale" "w:%7#0" \
	"$(APEX_STARTING_STALE=30 _apex_pending_sig "$MGR")"

# The default is what an unconfigured manager actually gets, so pin the
# threshold itself rather than only the knob-overridden path.
member_started 'w:%7' starting 0 -1 899
eq "the default threshold has not been reached at 899s" "" "$(_apex_pending_sig "$MGR")"
member_started 'w:%7' starting 0 -1 901
eq "…and has at 901s" "w:%7#0" "$(_apex_pending_sig "$MGR")"

# Gated on seq, not on status alone: a member that has run turns has a live
# agent, and whatever put it back at `starting` is a different problem than
# "it never started".
member_started 'w:%7' starting 4 3 5000
eq "a member that has taken turns is never a stalled start" "" \
	"$(_apex_pending_sig "$MGR")"

# Records predating spawned_at must read as healthy, not as stalled: the
# false positive sends the manager to poke a working member, and there is no
# way to tell a missing timestamp from an ancient one.
reset
member 'w:%7' starting 0 -1
eq "a record with no spawned_at is never stale" "" "$(_apex_pending_sig "$MGR")"

# One-shot, like every other reportable state — the manager is told, and then
# left to decide, not re-interrupted every second by a condition that by
# definition will not change on its own.
reset
member_started 'w:%7' starting 0 0 5000
eq "a delivered stalled start is not re-reported" "" "$(_apex_pending_sig "$MGR")"

# `pending` has to say something a manager can act on, and its usual line —
# read the facts, decide what to tell it — is the wrong reflex here: nothing
# has happened yet and the real question is whether the agent is running.
reset
member_started 'w:%7' starting 0 -1 5000
out=$(_cmd_pending 2>/dev/null)
contains "pending names the member"        "session=w:%7" "$out"
contains "…says it never took a turn"     "never taken a turn" "$out"
contains "…names the recover/empty-prompt cause" "waiting at an empty prompt" "$out"
contains "…and hands over the send to run" "send w:%7" "$out"
lacks "…and does not claim it is idle"    "status=idle" "$out"

# Same invariant as above, over the states this clause introduces: the cheap
# 1s gate and `pending` must not disagree, or the watcher stays quiet through
# exactly the stall it was added to surface.
typeset -a SDISAGREE=()
typeset -i SREPORTED=0 SCHECKED=0
for st in starting idle; do
	for seq in 0 4; do
		for age in 5 5000; do
			reset
			member_started 'w:%7' "$st" "$seq" -1 "$age"
			p=$(pending_reports); g=$(gate_reports)
			(( SCHECKED += 1 )) || true; (( SREPORTED += p )) || true
			[[ $p == "$g" ]] || SDISAGREE+=("status=$st seq=$seq age=${age}s: pending=$p gate=$g")
		done
	done
done
eq "pending and the gate agree on stalled starts" "" "${(j:; :)SDISAGREE}"
eq "…over all 8 states"           8 "$SCHECKED"
eq "…and some of them do report"  5 "$SREPORTED"

# A garbage threshold must not silently disable every reporting path at once.
# `--argjson` would fail, which makes every jq in the file exit non-zero,
# which reads as "nothing to report" everywhere — the exact silence this
# clause exists to end. So it is clamped, loudly, not trusted.
reset
member 'w:%7' idle 3 -1
err=$(APEX_STARTING_STALE=soon _apex_pending_sig "$MGR" 2>&1 >/dev/null)
contains "a non-numeric threshold is reported" "APEX_STARTING_STALE" "$err"
eq "…and does not take the rest of reportability down with it" "w:%7#3" \
	"$(APEX_STARTING_STALE=soon _apex_pending_sig "$MGR" 2>/dev/null)"

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

# The fallback reads each file with a second copy of the predicate. It is the
# same jq definition spliced into a different call site, so it gets the same
# escalation case to keep the two from drifting apart unnoticed.
reset
member 'good:%8' working 4 3 'READY FOR HUMAN REVIEW'
print -r -- '{ truncated' > "$(apex_member_file "$MGR" 'bad:%9')"
eq "the fallback honours escalations too" "good:%8#4!" \
	"$(_apex_pending_sig "$MGR" 2>/dev/null)"

# The two paths are two serializations of the same answer, and the poller
# compares sigs as opaque strings — so a difference in *shape* alone is a
# changed fingerprint, i.e. a nudge typed into the manager's pane for a pending
# set that did not change. Pin them byte-identical over a multi-member set,
# which is the only case where joining can disagree.
reset
member 'a:%1' idle 2 -1
member 'b:%2' attention 1 -1
slurped=$(_apex_pending_sig "$MGR")
print -r -- '{ truncated' > "$(apex_member_file "$MGR" 'bad:%9')"
fallback=$(_apex_pending_sig "$MGR" 2>/dev/null)
eq "the slurped path joins on comma, sorted" "a:%1#2,b:%2#1" "$slurped"
eq "and the fallback serializes identically" "$slurped" "$fallback"

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

# client_activity is a *client* attribute, so an unscoped read counts typing in
# a sibling shell pane, a window switch or a scroll as "mid-draft in the
# manager's box" — which defers delivery for as long as someone works next door.
reset
member 'w:%7' idle 3 -1
print -r -- '│ > ghost text the agent painted       │' > "$PANE_FILE"
tick >/dev/null
export CLIENT_ACTIVITY=$(date +%s) CLIENT_PANE='%99'   # busy, but next door
APEX_WATCH_BOX_GRACE=0
: > "$KEYS_LOG"
tick >/dev/null
contains "activity in a sibling pane does not defer" "[apex] a member just changed state" "$(keys)"
export CLIENT_PANE=""
APEX_WATCH_BOX_GRACE=60

# And the extension is capped from box_since, so "ghost text delays delivery,
# never blocks it" holds unconditionally rather than only once the human stops.
reset
member 'w:%7' idle 3 -1
print -r -- '│ > ghost text the agent painted       │' > "$PANE_FILE"
now=$(date +%s)
tick >/dev/null
# Backdate the box well past 2 x grace while a client keeps reporting activity.
_apex_watch_save "$MGR" "$(jq -nc --argjson t "$(( now - 500 ))" '{box_since:$t}')"
export CLIENT_ACTIVITY=$now
APEX_WATCH_BOX_GRACE=60
: > "$KEYS_LOG"
tick >/dev/null
contains "continuous client activity cannot defer past the cap" "[apex] a member just changed state" "$(keys)"
export CLIENT_ACTIVITY=""

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
