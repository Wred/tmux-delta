#!/usr/bin/env zsh
# Tests for the send path's collision handling: scripts/tmux-apex.sh's
# _pane_input_line and _send_to_pane (issue #10).
#
# Both are pure functions of what `tmux capture-pane` reports, so a fake tmux on
# PATH is enough — no live agent, no real pane. The fake logs every send-keys it
# receives and renders its "pane" from a fixture file the test rewrites, which
# lets a test model a box that drains on Enter as well as one that never does.
#
# Run: tests/apex-send.test.sh

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-send-test.XXXXXX")
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
# $PANE_FILE is the rendered pane. $KEYS_LOG records send-keys calls. The
# knobs let a test pick which TUI misbehaviour to model:
#
#   DRAIN_ON_ENTER  every Enter empties the box, i.e. a well-behaved TUI
#   DRAIN_AT_ENTER  only the Nth Enter empties it — a swallowed Enter that
#                   the retry loop eventually gets through
#   DRAIN_DELAY     the box empties this many seconds *after* the Enter, so a
#                   verify that reads the pane without waiting sees stale text
#   NO_CLEAR        C-u does not empty the box (a cursor or multi-line draft
#                   that a single kill-to-start cannot deal with)
#   SPLICE_RESIDUE  text a literal send gets appended to, so the box renders
#                   `<residue><message>` — the splice NO_CLEAR produces
#   BOX_WIDTH       the box renders only this many characters, i.e. a message
#                   wider than the box, whose tail soft-wraps out of the one
#                   line a pane read can see
#   PASTE_WINDOW    an Enter arriving within this many seconds of the literal
#                   send is dropped mid-paste — the codex behaviour the
#                   settle sleep exists for
#   DROP_FIRST_ENTER  the first Enter is swallowed outright, forcing the retry
#                   loop to be the thing that delivers
#   BUSY            every capture-pane renders a different trailing line, i.e.
#                   an agent mid-turn repainting a spinner/token counter. The
#                   input box is untouched by it, so this models the issue #24
#                   case: pane demonstrably active, box still showing our text
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env zsh
zmodload zsh/datetime 2>/dev/null
drain() {
	if [ -n "${DRAIN_DELAY:-}" ]; then
		( sleep "$DRAIN_DELAY"; printf '%s\n' "$EMPTY_BOX" > "$PANE_FILE" ) &
	else
		printf '%s\n' "$EMPTY_BOX" > "$PANE_FILE"
	fi
}
case "$1" in
	capture-pane)
		cat "$PANE_FILE"
		if [ -n "${BUSY:-}" ]; then
			n=$(( $(cat "$BUSY_COUNT" 2>/dev/null || echo 0) + 1 ))
			printf '%s' "$n" > "$BUSY_COUNT"
			printf 'esc to interrupt - %s tokens\n' "$n"
		fi ;;
	send-keys)
		shift
		# Join first: ${*#pat} applies the pattern to each positional
		# separately, so stripping off "$*" directly leaves tmux's own flags
		# in the fixture.
		args="$*"
		printf '%s\n' "$args" >> "$KEYS_LOG"
		case "$args" in
			*"-l -- "*)
				# A literal send lands in the input box, unsubmitted. With
				# SPLICE_RESIDUE set it lands *on top of* that text, which is
				# what a box that would not clear really does to a send.
				# BOX_WIDTH clips what the box renders, i.e. a message wider
				# than the box: it soft-wraps and only the caret line is
				# readable, so a pane read of a long message ends mid-message.
				line="${SPLICE_RESIDUE:-}${args#*-l -- }"
				[ -n "${BOX_WIDTH:-}" ] && line=${line[1,$BOX_WIDTH]}
				printf '\xe2\x94\x82 > %s   \xe2\x94\x82\n' "$line" > "$PANE_FILE"
				printf '%s' "${EPOCHREALTIME:-0}" > "$PASTE_AT" ;;
			*Enter*)
				n=$(( $(cat "$ENTER_COUNT" 2>/dev/null || echo 0) + 1 ))
				printf '%s' "$n" > "$ENTER_COUNT"
				if [ -n "${PASTE_WINDOW:-}" ]; then
					# Dropped if it landed inside the paste window.
					since=$(( ${EPOCHREALTIME:-0} - $(cat "$PASTE_AT" 2>/dev/null || echo 0) ))
					(( since < PASTE_WINDOW )) && exit 0
				fi
				[ -n "${DROP_FIRST_ENTER:-}" ] && [ "$n" -eq 1 ] && exit 0
				if [ -n "${DRAIN_ON_ENTER:-}" ]; then
					drain
				elif [ -n "${DRAIN_AT_ENTER:-}" ] && [ "$n" -ge "$DRAIN_AT_ENTER" ]; then
					drain
				fi ;;
			*C-u*)
				[ -z "${NO_CLEAR:-}" ] && printf '%s\n' "$EMPTY_BOX" > "$PANE_FILE" ;;
		esac
		;;
esac
exit 0
STUB
chmod +x "$BIN/tmux"
export PATH="$BIN:$PATH"
export PANE_FILE="$TMPROOT/pane" KEYS_LOG="$TMPROOT/keys"
export ENTER_COUNT="$TMPROOT/enters" PASTE_AT="$TMPROOT/paste-at"
export BUSY_COUNT="$TMPROOT/busy"
export EMPTY_BOX='│ >                                    │'

# Source the script under test. Its dispatch prints usage when called with no
# arguments and does not exit, so suppressing stdout is enough.
source "$SCRIPTS/tmux-apex.sh" >/dev/null 2>&1

pane() { print -r -- "$*" > "$PANE_FILE"; : > "$KEYS_LOG"; : > "$ENTER_COUNT" }
panel() { print -l -- "$@" > "$PANE_FILE"; : > "$KEYS_LOG"; : > "$ENTER_COUNT" }
keys() { cat "$KEYS_LOG" 2>/dev/null }

# ── reading the input box ────────────────────────────────────────────
print "_pane_input_line"

pane '│ > mark ready for review              │'
eq "reads text out of a box-drawn prompt" "mark ready for review" "$(_pane_input_line %1)"

pane "$EMPTY_BOX"
eq "empty box reads as empty" "" "$(_pane_input_line %1)"

print -l '╭──────────────╮' '│ > first      │' '│              │' '╰──────────────╯' > "$PANE_FILE"
eq "ignores frame lines" "first" "$(_pane_input_line %1)"

# Scrollback holds old submitted prompts; only the live box matters.
print -l '│ > an older submitted line │' 'some agent output' '│ > the live one │' > "$PANE_FILE"
eq "takes the last prompt line, not an earlier one" "the live one" "$(_pane_input_line %1)"

print -r -- '❯ half-typed' > "$PANE_FILE"
eq "handles a bare caret with no box" "half-typed" "$(_pane_input_line %1)"

# Agent output is full of lines that open with a caret. A framed box beats an
# unframed caret line, so a shell transcript scrolling past an idle box does
# not read as pending input (finding: "$" matched ordinary output).
panel '$ npm test' '  3 passed' "$EMPTY_BOX"
eq "shell transcript above an empty box reads as empty" "" "$(_pane_input_line %1)"

panel '> a markdown blockquote' "$EMPTY_BOX"
eq "blockquote above an empty box reads as empty" "" "$(_pane_input_line %1)"

panel '$ npm test' '  3 passed'
eq "\$ is not a prompt caret" "" "$(_pane_input_line %1)"

panel '│ > real pending text                  │' '$ npm test'
eq "framed box beats an unframed caret below it" "real pending text" "$(_pane_input_line %1)"

# Only the bottom of the visible pane is read; anything higher is history.
panel '│ > scrolled off the window            │' \
	'l1' 'l2' 'l3' 'l4' 'l5' 'l6' 'l7' 'l8' 'l9' 'l10' 'l11' 'l12'
eq "prompt line above the 12-line window is ignored" "" "$(_pane_input_line %1)"

print -r -- 'no prompt on this line at all' > "$PANE_FILE"
eq "no prompt line reads as empty" "" "$(_pane_input_line %1)"

# The parsing half, against a capture the caller already holds — this is what
# the send verify loop calls, so that one capture answers both of its questions
# instead of forking tmux twice per tick.
eq "_box_line_of parses a capture the caller already has" "from a held capture" \
	"$(_box_line_of "$(print -l -- 'some output' '│ > from a held capture   │')")"
eq "_box_line_of on an empty capture reads as empty" "" "$(_box_line_of "")"

# ── is our own line still pending? ───────────────────────────────────
# Prefix, not suffix: a message wider than the box wraps and only its leading
# part is readable, so a tail match would pass without checking anything.
print "\n_box_pending"

_box_pending "run the tests and rep" "run the tests and report back when done" \
	&& ok "wrapped message: leading part counts as still pending" \
	|| bad "wrapped message: leading part counts as still pending" "returned false"
_box_pending "run tests first" "run tests first" \
	&& ok "whole line present counts as still pending" \
	|| bad "whole line present counts as still pending" "returned false"
_box_pending "mark ready for review" "run tests first" \
	&& bad "someone else's text means ours is gone" "returned true" \
	|| ok "someone else's text means ours is gone"
_box_pending "run tests first and then some" "run tests first" \
	&& bad "text beyond ours means ours is gone" "returned true" \
	|| ok "text beyond ours means ours is gone"
_box_pending "" "run tests first" \
	&& bad "empty box is not pending" "returned true" \
	|| ok "empty box is not pending"

# A box that would not clear holds `<residue><message>`, so the prefix test
# has to be told about the residue or every spliced send reads as submitted
# and rc 2 becomes unreachable (issue #22).
_box_pending "half-written draftrun tests first" "run tests first" "half-written draft" \
	&& ok "spliced box: known residue is stripped before the prefix test" \
	|| bad "spliced box: known residue is stripped before the prefix test" "returned false"

_box_pending "half-written draftrun tests fi" "run tests first" "half-written draft" \
	&& ok "spliced box: still prefix, so a wrapped spliced line counts" \
	|| bad "spliced box: still prefix, so a wrapped spliced line counts" "returned false"

# _pane_input_line trims, so a draft ending in a space is recorded without it
# while the box still shows the gap before our text.
_box_pending "half-written draft run tests first" "run tests first" "half-written draft" \
	&& ok "spliced box: a trimmed trailing space in the residue is tolerated" \
	|| bad "spliced box: a trimmed trailing space in the residue is tolerated" "returned false"

# A retype into a box that will not clear appends, so the box holds our text
# twice over by the second attempt — still a stall, not "our text is gone".
_box_pending "half-written draftrun tests firstrun tests first" "run tests first" \
	"half-written draft" \
	&& ok "spliced box: repeated retypes still read as pending" \
	|| bad "spliced box: repeated retypes still read as pending" "returned false"

# Stripping an empty sent-text never shortens the line, so the collapse above
# must not be entered for one — it would spin forever. _send_to_pane refuses an
# empty message before it gets here; this pins the function itself.
_box_pending "half-written draftrun tests first" "" "half-written draft" \
	&& bad "spliced box: an empty sent-text is not pending" "returned true" \
	|| ok "spliced box: an empty sent-text is not pending"

_box_pending "half-written draft" "run tests first" "half-written draft" \
	&& bad "spliced box: residue alone means ours is gone" "returned true" \
	|| ok "spliced box: residue alone means ours is gone"

# Residue is a known, recorded prefix — not licence to match anywhere. An
# autosuggestion quoting our text back under some *other* prefix must still
# read as gone, which is what rules substring matching out.
_box_pending "something elserun tests first" "run tests first" "half-written draft" \
	&& bad "unknown prefix is not our text pending" "returned true" \
	|| ok "unknown prefix is not our text pending"

# ── delivery ─────────────────────────────────────────────────────────
print "\ndelivery"

export DRAIN_ON_ENTER=1
pane "$EMPTY_BOX"
out=$(_send_to_pane %1 "do the thing" 2>&1; print "rc=$?")
contains "empty box: succeeds" "rc=0" "$out"
contains "empty box: types the text" "do the thing" "$(keys)"
contains "empty box: submits" "Enter" "$(keys)"
lacks "empty box: does not clear what isn't there" "C-u" "$(keys)"
eq "empty box: reports nothing cleared" "" "$APEX_SEND_CLEARED"

# The issue's actual failure: ghost autosuggestion text in an idle box. Left
# alone, the delivered instruction is appended to it and the worker gets one
# spliced line.
pane '│ > mark ready for review              │'
out=$(_send_to_pane %1 "run the tests first" 2>&1; print "rc=$?")
contains "occupied box: succeeds" "rc=0" "$out"
contains "occupied box: clears before typing" "C-u" "$(keys)"
eq "occupied box: clears first, types second" "clear-first" \
	"$(keys | awk '/ -l -- /{print (c?"clear-first":"typed-first"); exit} /C-u/{c=1}')"
contains "occupied box: warns on stderr" "had unsent input" "$out"
contains "occupied box: names the autosuggestion explanation" "autosuggestion" "$out"

# APEX_SEND_CLEARED is what _cmd_send puts in the event log, so it has to
# survive the call — check it outside a subshell.
pane '│ > mark ready for review              │'
_send_to_pane %1 "run the tests first" 2>/dev/null
eq "occupied box: exports what it cleared" "mark ready for review" "$APEX_SEND_CLEARED"
pane "$EMPTY_BOX"
_send_to_pane %1 "run the tests first" 2>/dev/null
eq "empty box: clears the export from a previous send" "" "$APEX_SEND_CLEARED"

# Opting out must still report, and must not silently look like the clearing path.
pane '│ > mark ready for review              │'
out=$(APEX_SEND_CLEAR=0 _send_to_pane %1 "run the tests first" 2>&1; print "rc=$?")
contains "APEX_SEND_CLEAR=0: still delivers" "rc=0" "$out"
lacks "APEX_SEND_CLEAR=0: does not clear" "C-u" "$(keys)"
contains "APEX_SEND_CLEAR=0: says it will splice" "appended to" "$out"

rc=0
_send_to_pane %1 "" >/dev/null 2>&1 || rc=$?
eq "empty message is refused" 1 "$rc"

# C-u kills to the start of the line, so it leaves anything right of the
# cursor and clears one line of a multi-line draft. Saying "cleared" when the
# box did not drain is worse than the old honest append, so say what happened.
export NO_CLEAR=1 SPLICE_RESIDUE='mark ready for review '
pane '│ > mark ready for review               │'
out=$(_send_to_pane %1 "run tests first" 2>&1; print "rc=$?")
contains "box refuses to clear: still delivers" "rc=0" "$out"
contains "box refuses to clear: says so" "did not clear" "$out"
contains "box refuses to clear: names what it will splice onto" "mark ready for review" "$out"

# Splice plus a submit that lands is not a delivery failure: the message did
# go in, garbled onto the draft, and the event log is where that is recorded.
# Only APEX_SEND_SPLICED says so — the return code must stay 0.
pane '│ > mark ready for review               │'
_send_to_pane %1 "run tests first" >/dev/null 2>&1
eq "spliced but submitted: exports what it spliced onto" "mark ready for review" \
	"$APEX_SEND_SPLICED"
unset NO_CLEAR SPLICE_RESIDUE

# ── retries must not submit whatever the box happens to hold ─────────
# A bare Enter as a retry submits the box's current contents. After a
# successful send that is often a *fresh* autosuggestion, so a bare retry can
# deliver the agent's own guess as an instruction — the issue #10 failure mode
# caused by the fix for it. Retries clear and retype instead.
print "\nretries"

unset DRAIN_ON_ENTER
pane '│ > stuck message here                 │'
_send_to_pane %1 "stuck message here" >/dev/null 2>&1 || true
eq "retry re-types rather than firing a bare Enter" 4 "$(keys | grep -c ' -l -- ')"
eq "retry clears the box before each re-type" 4 "$(keys | grep -c 'C-u')"

# The verdict must not race the last retry's Enter: a send that lands on the
# third retry is a success, not a "send-unsubmitted".
export DRAIN_AT_ENTER=4 DRAIN_DELAY=0.05
pane '│ > slow to drain                      │'
rc=0
_send_to_pane %1 "slow to drain" >/dev/null 2>&1 || rc=$?
eq "drains on the last retry: reported as delivered" 0 "$rc"
unset DRAIN_AT_ENTER DRAIN_DELAY

# ── unconfirmed submission ───────────────────────────────────────────
# A TUI that swallows Enter leaves the text sitting in the box. Retrying is
# worth it, but claiming delivery is not.
print "\nunsubmitted text"

unset DRAIN_ON_ENTER
pane '│ > stuck message here                 │'
rc=0
_send_to_pane %1 "stuck message here" >/dev/null 2>&1 || rc=$?
eq "box never drains: reports failure, not success" 2 "$rc"
eq "box never drains: re-sends Enter three times" 4 "$(keys | grep -c Enter)"

# The same swallowed Enter, but onto a box that would not clear, so the box
# reads `<draft><message>`. The prefix check used to fail on that at the very
# first read and conclude our text was gone, i.e. submitted — which made rc 2
# unreachable on every spliced path and reported a garbled, unsent message as
# delivered (issue #22). The residue recorded before typing is stripped before
# the check, so a stalled splice now fails like a stalled clean send does.
export NO_CLEAR=1 SPLICE_RESIDUE='half-written human note '
pane '│ > half-written human note             │'
rc=0
_send_to_pane %1 "PAIRED REVIEW round 2" >/dev/null 2>&1 || rc=$?
eq "spliced and never submitted: reports failure, not success" 2 "$rc"
eq "spliced and never submitted: still retries" 4 "$(keys | grep -c Enter)"
eq "spliced and never submitted: reports what it spliced onto" \
	"half-written human note" "$APEX_SEND_SPLICED"
unset NO_CLEAR SPLICE_RESIDUE

# Same again, but with a message wider than the box, which is the shape every
# pair-relay message has. A pane read only ever returns the caret line, so the
# box reads `<draft><start-of-message>` — and a retry that re-derived the
# residue from that read would take our own half-typed message as residue,
# strip it out of every later read, and report the send delivered (the round-2
# review finding on PR #28). The residue recorded before typing is the only
# one that survives soft-wrapping.
export NO_CLEAR=1 SPLICE_RESIDUE='half-written human note' BOX_WIDTH=40
pane '│ > half-written human note             │'
rc=0
_send_to_pane %1 "PAIRED REVIEW round 2: the reviewer on PR #28 recorded 2 finding(s) worth addressing." \
	>/dev/null 2>&1 || rc=$?
eq "wrapped and spliced, never submitted: reports failure" 2 "$rc"
eq "wrapped and spliced, never submitted: retries all three times" 4 \
	"$(keys | grep -c Enter)"
unset NO_CLEAR SPLICE_RESIDUE BOX_WIDTH

# ── pane active vs. pane idle (issue #24) ────────────────────────────
# "Our text is still in the box after N seconds" does not mean the Enter was
# swallowed — under a loaded turn the TUI can lag the repaint well past any
# fixed timeout, and retyping there delivers the instruction twice for real.
# The retry is therefore gated on the *whole pane* being static, not on the
# clock: a pane that keeps repainting is an agent working on what we sent.
print "\npane activity gate"

unset DRAIN_ON_ENTER DRAIN_AT_ENTER DRAIN_DELAY
export BUSY=1 APEX_SEND_SETTLE_TICKS=8
: > "$BUSY_COUNT"
pane '│ > busy agent message                 │'
rc=0
out=$(_send_to_pane %1 "busy agent message" 2>&1; print "rc=$?")
contains "pane busy, box stale: reported as delivered" "rc=0" "$out"
eq "pane busy, box stale: does not retype" 1 "$(keys | grep -c ' -l -- ')"
eq "pane busy, box stale: fires exactly one Enter" 1 "$(keys | grep -c Enter)"
contains "pane busy, box stale: says why it stopped" "issue #24" "$out"

# The flag has to survive the call: it is what _cmd_send logs and prints.
: > "$BUSY_COUNT"
pane '│ > busy agent message                 │'
_send_to_pane %1 "busy agent message" >/dev/null 2>&1 || true
eq "pane busy, box stale: exports the unconfirmed flag" 1 "$APEX_SEND_UNCONFIRMED"

# A busy pane whose box does drain mid-turn is an ordinary success, and must
# not be reported as unconfirmed.
export DRAIN_ON_ENTER=1 DRAIN_DELAY=0.5
: > "$BUSY_COUNT"
pane "$EMPTY_BOX"
rc=0
_send_to_pane %1 "slow repaint but it lands" >/dev/null 2>&1 || rc=$?
eq "pane busy, box drains late: delivered" 0 "$rc"
eq "pane busy, box drains late: not flagged unconfirmed" "" "$APEX_SEND_UNCONFIRMED"
eq "pane busy, box drains late: does not retype" 1 "$(keys | grep -c ' -l -- ')"
unset DRAIN_ON_ENTER DRAIN_DELAY

# The genuine unsubmitted case is unchanged: nothing in the pane moves at all,
# so the retry loop still runs and still refuses to claim delivery.
unset BUSY
pane '│ > truly stuck                        │'
rc=0
_send_to_pane %1 "truly stuck" >/dev/null 2>&1 || rc=$?
eq "pane idle, box stale: still retries" 4 "$(keys | grep -c ' -l -- ')"
eq "pane idle, box stale: still reports failure" 2 "$rc"
unset APEX_SEND_SETTLE_TICKS

# The knobs are clamped, not trusted. `local -i x=abc` is 0 in zsh with no
# error, and a settle of 0 skips the poll loop entirely: nothing is read back,
# no retry can fire, and every send reports delivered-but-unconfirmed forever.
# A knob that silently disables the verification it exists to tune is the
# failure this repo already guards against at the door for `watch`.
#
# Assert on APEX_SEND_UNCONFIRMED, not on stderr text: the flag is what
# callers branch on, and it is the thing a broken clamp actually sets. Stderr
# here belongs to _send_to_pane, whose wording ("still shows the sent text")
# differs from the NOTE _cmd_send prints ("never drained") — matching the
# wrong one gives an assertion that cannot fail. That means running the call
# outside a subshell, so the flag survives, with stderr diverted to a file.
export DRAIN_ON_ENTER=1
ERRFILE="$TMPROOT/err"
for bad_val in abc 0 -3; do
	pane "$EMPTY_BOX"
	rc=0
	APEX_SEND_SETTLE_TICKS=$bad_val _send_to_pane %1 "do the thing" 2>"$ERRFILE" || rc=$?
	eq "APEX_SEND_SETTLE_TICKS=$bad_val: still verifies and delivers" 0 "$rc"
	contains "APEX_SEND_SETTLE_TICKS=$bad_val: says it fell back" "using 25" "$(cat "$ERRFILE")"
	eq "APEX_SEND_SETTLE_TICKS=$bad_val: not reported as unconfirmed" \
		"" "$APEX_SEND_UNCONFIRMED"
	lacks "APEX_SEND_SETTLE_TICKS=$bad_val: does not claim a busy pane" \
		"still shows the sent text" "$(cat "$ERRFILE")"
	# The other half of "verification is off": with settle=0 the poll loop
	# never runs, so a clamp on idle alone would fall straight through to
	# three blind retypes of an already-delivered message — the duplicate
	# this whole change exists to prevent. One literal send means the box was
	# actually read back.
	eq "APEX_SEND_SETTLE_TICKS=$bad_val: does not blind-retype" 1 \
		"$(keys | grep -c ' -l -- ')"
done
pane "$EMPTY_BOX"
rc=0
APEX_SEND_IDLE_TICKS=abc _send_to_pane %1 "do the thing" 2>"$ERRFILE" || rc=$?
contains "APEX_SEND_IDLE_TICKS=abc: falls back" "using 5" "$(cat "$ERRFILE")"
eq "APEX_SEND_IDLE_TICKS=abc: still delivers" 0 "$rc"
eq "APEX_SEND_IDLE_TICKS=abc: not reported as unconfirmed" "" "$APEX_SEND_UNCONFIRMED"

# An idle threshold above the ceiling is unreachable, which disables the retry
# by another route: clamp it to the ceiling instead.
unset DRAIN_ON_ENTER
pane '│ > stuck message here                 │'
rc=0
APEX_SEND_SETTLE_TICKS=3 APEX_SEND_IDLE_TICKS=99 \
	_send_to_pane %1 "stuck message here" >/dev/null 2>&1 || rc=$?
eq "idle above the ceiling still retries" 4 "$(keys | grep -c ' -l -- ')"
eq "idle above the ceiling still reports failure" 2 "$rc"

# ── the paste/Enter race, in the retry path too ──────────────────────
# tmux wraps a literal send in bracketed paste and codex drops an Enter that
# lands inside it. The first send sleeps for that; the retries have to as well,
# or every retry is less likely to land than the attempt it is retrying and a
# recoverable swallowed Enter turns into a hard `send: delivery unconfirmed`.
print "\nmid-paste Enter"

unset DRAIN_ON_ENTER DRAIN_AT_ENTER DRAIN_DELAY
export DRAIN_ON_ENTER=1 PASTE_WINDOW=0.15 DROP_FIRST_ENTER=1
pane "$EMPTY_BOX"
rc=0
_send_to_pane %1 "run the tests and report back" >/dev/null 2>&1 || rc=$?
eq "retry survives a mid-paste-dropped Enter" 0 "$rc"
unset PASTE_WINDOW DROP_FIRST_ENTER

# ── locale ───────────────────────────────────────────────────────────
# The box edges are multibyte. Under a single-byte locale a bracket expression
# matches their individual bytes instead, the caret check then fails, and every
# box reads as empty — so `send` silently stops clearing before it types. Hooks
# and cron hand us LC_ALL=C often enough that this has to be pinned, not
# inherited.
print "\nlocale"

unset DRAIN_AT_ENTER DRAIN_DELAY NO_CLEAR PASTE_WINDOW DROP_FIRST_ENTER
export DRAIN_ON_ENTER=1

pane '│ > mark ready for review              │'
unset APEX_UTF8_LOCALE   # cold cache: the pick must happen under C too
eq "reads the box under LC_ALL=C" "mark ready for review" \
	"$(LC_ALL=C _pane_input_line %1)"

pane '│ > mark ready for review              │'
unset APEX_UTF8_LOCALE
out=$(LC_ALL=C _send_to_pane %1 "run the tests first" 2>&1; print "rc=$?")
contains "clears the box under LC_ALL=C" "C-u" "$(keys)"
contains "still delivers under LC_ALL=C" "rc=0" "$out"

# Pinning is scoped to the call: nothing else in the process gets re-localed.
eq "leaves the caller's locale alone" "C" \
	"$(LC_ALL=C; _pane_input_line %1 >/dev/null; print -r -- "$LC_ALL")"

# A machine with no UTF-8 locale at all must degrade to inheriting, not break.
pane '│ > mark ready for review              │'
eq "no UTF-8 locale available: still runs" "mark ready for review" \
	"$(APEX_UTF8_LOCALE= _pane_input_line %1)"

print "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
