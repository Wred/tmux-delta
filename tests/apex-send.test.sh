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
# $PANE_FILE is the rendered pane. $KEYS_LOG records send-keys calls. If
# $DRAIN_ON_ENTER is set, an Enter empties the box the way a real TUI would.
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
	capture-pane) cat "$PANE_FILE" ;;
	send-keys)
		shift
		printf '%s\n' "$*" >> "$KEYS_LOG"
		case "$*" in
			*"-l -- "*)
				# A literal send lands in the input box, unsubmitted.
				printf '\xe2\x94\x82 > %s   \xe2\x94\x82\n' "${*#*-l -- }" > "$PANE_FILE" ;;
			*Enter*) [ -n "${DRAIN_ON_ENTER:-}" ] && printf '%s\n' "$EMPTY_BOX" > "$PANE_FILE" ;;
			*C-u*)   printf '%s\n' "$EMPTY_BOX" > "$PANE_FILE" ;;
		esac
		;;
esac
exit 0
STUB
chmod +x "$BIN/tmux"
export PATH="$BIN:$PATH"
export PANE_FILE="$TMPROOT/pane" KEYS_LOG="$TMPROOT/keys"
export EMPTY_BOX='│ >                                    │'

# Source the script under test. Its dispatch prints usage when called with no
# arguments and does not exit, so suppressing stdout is enough.
source "$SCRIPTS/tmux-apex.sh" >/dev/null 2>&1

pane() { print -r -- "$*" > "$PANE_FILE"; : > "$KEYS_LOG" }
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

print -r -- 'no prompt on this line at all' > "$PANE_FILE"
eq "no prompt line reads as empty" "" "$(_pane_input_line %1)"

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
contains "occupied box: clears first, types second" "C-u" "$(keys | head -1)"
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

print "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
