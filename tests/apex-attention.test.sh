#!/usr/bin/env zsh
# Tests why-does-this-member-want-attention classification and how it is
# reported: scripts/tmux-apex.sh's _attention_reason_of, the attention_reason /
# attention_detail facts, and the `status` / `pending` lines that carry them
# (issue #63).
#
# `@agent_needs_attention` is a boolean, and three situations set it — blocked
# at a permission/safety dialog, a turn killed mid-response, and an ordinary
# end-of-turn. Only the first two need a decision, and neither produces any
# further transition, so neither produces any further ping. From the ping line
# alone all three used to read identically; one cost seven hours.
#
# The classifier is a pure function of a `tmux capture-pane` capture, so a
# fake tmux on PATH is enough — no live agent, no real pane.
#
# Run: tests/apex-attention.test.sh

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-attention-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq() {
	if [[ $2 == $3 ]]; then ok "$1"
	else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}
contains() {
	if [[ $3 == *$2* ]]; then ok "$1"
	else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi
}
lacks() {
	if [[ $3 != *$2* ]]; then ok "$1"
	else bad "$1" "expected NOT to contain: ${(qqq)2}
       actual                 : ${(qqq)3}"; fi
}

# ── fake tmux ────────────────────────────────────────────────────────
# $PANE_FILE is the rendered pane; @agent_needs_attention comes from
# $ATTENTION so a test can put the member in and out of the state.
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"
export TMUX=fake-socket
export XDG_CACHE_HOME="$TMPROOT/cache"
export PANE_FILE="$TMPROOT/pane"
export ATTENTION=""
: > "$PANE_FILE"

cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env zsh
case "$1" in
capture-pane) cat "$PANE_FILE" ;;
display-message) print -r -- "${STUB_SESSION:-manager}" ;;
list-panes)
	# The member below is w:%1; -a is the liveness probe.
	if [[ " $* " == *" -a "* ]]; then print -r -- 'w:%1'
	else print -r -- '%1'; fi
	;;
show-option)
	# -p is pane-scoped (a member), otherwise session-scoped (the manager);
	# `_sopt` picks between them off the id shape and `_resolve_manager`
	# needs the session-scoped answer to be "manager".
	case "$*" in
		*@agent_needs_attention*) print -r -- "${ATTENTION:-}" ;;
		*@agent_working*)         : ;;
		*@apex_role*)
			if [[ " $* " == *" -p "* ]]; then print -r -- worker
			else print -r -- manager; fi ;;
		*@apex_task*)             : ;;
		*) : ;;
	esac
	;;
*) : ;;
esac
exit 0
STUB
chmod +x "$BIN/tmux"

MGR=manager
export STUB_SESSION="$MGR"
source "$SCRIPTS/tmux-apex.sh" >/dev/null 2>&1
APEX_SESSION="$MGR"

# ── fixtures ─────────────────────────────────────────────────────────
# Claude Code draws the permission dialog in the same box as the prompt, so
# the shape — a numbered choice list, with or without the selection caret —
# is what the classifier keys on, not any wording we picked.
DIALOG=$(print -l -- \
	'  ⎿  Running…' \
	'╭───────────────────────────────────────────────╮' \
	'│ Bash command                                  │' \
	'│                                               │' \
	'│   rm -f $TMPDIR/*                             │' \
	'│   Clean the test scaffold                     │' \
	'│                                               │' \
	'│ Do you want to proceed?                       │' \
	'│ ❯ 1. Yes                                      │' \
	'│   2. Yes, and do not ask again                │' \
	'│   3. No, and tell Claude what to do (esc)     │' \
	'╰───────────────────────────────────────────────╯')

IDLE=$(print -l -- \
	'  ⎿  Pushed to origin' \
	'· Done (14 tool uses)' \
	'╭───────────────────────────────────────────────╮' \
	'│ >                                             │' \
	'╰───────────────────────────────────────────────╯')

SLEPT=$(print -l -- \
	'  ⎿  Wrote scripts/thing.sh' \
	'Your computer went to sleep mid-response. The response above may be incomplete.' \
	'╭───────────────────────────────────────────────╮' \
	'│ >                                             │' \
	'╰───────────────────────────────────────────────╯')

APIERR=$(print -l -- \
	'API Error: 500 {"type":"error","error":{"type":"api_error"}}' \
	'╭───────────────────────────────────────────────╮' \
	'│ >                                             │' \
	'╰───────────────────────────────────────────────╯')

# The classifier answers "<reason>\t<detail>" on one line; split it the way
# every caller does.
reason_of() { local r; r=$(_attention_reason_of "$1"); print -r -- "${r%%$'\t'*}" }
detail_of() { local r; r=$(_attention_reason_of "$1"); print -r -- "${r#*$'\t'}" }

# ── classification ───────────────────────────────────────────────────
print "classification"
eq "a permission dialog classifies as permission-prompt" permission-prompt "$(reason_of "$DIALOG")"
eq "an empty input box classifies as idle"               idle              "$(reason_of "$IDLE")"
eq "a sleep-interrupted turn classifies as interrupted"  interrupted       "$(reason_of "$SLEPT")"
eq "an API error classifies as interrupted"              interrupted       "$(reason_of "$APIERR")"

# `unknown` is deliberately its own answer. The reassuring case is the one
# that gets ignored, and the defect was a state that could not tell "fine"
# from "stuck" apart.
eq "an unreadable pane classifies as unknown" unknown "$(reason_of "")"
eq "a pane with neither dialog nor box is unknown" unknown \
	"$(reason_of "$(print -l -- 'Select a login method:' 'nothing here looks like a box')")"
eq "a missing pane id is unknown, not idle" unknown \
	"$(r=$(_pane_attention_reason ""); print -r -- "${r%%$'\t'*}")"

print "not false-positived by ordinary output"
# Agent output is full of lines that begin with a number, so one numbered
# line is never enough on its own.
eq "a single numbered line in output is not a dialog" idle \
	"$(reason_of "$(print -l -- 'Plan:' '1. read the file' '│ > │')")"
# The notice has to have been *printed*, not typed: a member whose own input
# box quotes the phrase has not been interrupted by anything.
eq "the interrupt phrase inside the input box is not an interrupt" idle \
	"$(reason_of "$(print -l -- '│ > next up: better api error handling │')")"
# A live dialog outranks an error notice above it — the dialog is what is
# blocking now, and answering it unblocks the pane either way.
eq "a dialog outranks an earlier API error" permission-prompt \
	"$(reason_of "$(print -l -- 'API Error: 500' "$DIALOG")")"

print "detail"
# The reason says which situation; the dialog's own text says what the answer
# should be. In the case this was written for the right answer was *decline*,
# and only the command text could have said so.
d=$(detail_of "$DIALOG")
contains "the detail names the tool"        "Bash command"     "$d"
contains "…and the command itself"          'rm -f $TMPDIR/*'  "$d"
contains "…and the question being asked"    "Do you want to proceed?" "$d"
lacks    "…and not the choice list"         "1. Yes"           "$d"
contains "an interrupt detail carries the notice" "went to sleep mid-response" \
	"$(detail_of "$SLEPT")"
eq "a clean idle pane has no detail" "" "$(detail_of "$IDLE")"

# A ping line has to stay a line.
LONG=$(print -l -- '╭──╮' "│ $(printf 'x%.0s' {1..400}) │" '│ Do you want to proceed? │' '│ ❯ 1. Yes │' '│ 2. No │' '╰──╯')
if (( ${#$(detail_of "$LONG")} <= 240 )); then
	ok "a huge dialog is truncated"
else
	bad "a huge dialog is truncated" "detail was ${#$(detail_of "$LONG")} chars"
fi

# ── facts ────────────────────────────────────────────────────────────
print "member facts"
member() {
	apex_init_dirs "$MGR"
	jq -nc --arg st "$1" --argjson seq "$2" --argjson p "$3" \
		--argjson t "$(( $(date +%s) - ${4:-5} ))" \
		'{role:"worker", worktree:"", issue:"9", review_pr:"", agent:"claude",
		  status:$st, seq:$seq, pinged_seq:$p, pair_message:"",
		  spawned_at:$t, updated_at:$t}' \
		> "$(apex_member_file "$MGR" 'w:%1')"
}

member attention 5 5
print -r -- "$DIALOG" > "$PANE_FILE"
ATTENTION=1
facts=$(_member_facts 'w:%1')
eq "facts report the reason"  permission-prompt "$(printf '%s' "$facts" | jq -r .attention_reason)"
contains "facts carry the detail" 'rm -f $TMPDIR/*' "$(printf '%s' "$facts" | jq -r .attention_detail)"
eq "…and still report the boolean state" needs-attention "$(printf '%s' "$facts" | jq -r .agent)"

# Computed only for members actually in the state: a working team must not
# pay a capture-pane per member per `status`.
ATTENTION=""
facts=$(_member_facts 'w:%1')
eq "a member not wanting attention has no reason" "" \
	"$(printf '%s' "$facts" | jq -r .attention_reason)"

# ── reporting ────────────────────────────────────────────────────────
print "status"
ATTENTION=1
member attention 5 5
out=$(_cmd_status 2>&1)
contains "the AGENT column carries the reason" "needs-attention(permission-prompt)" "$out"
contains "…and the dialog text is printed"     'rm -f $TMPDIR/*' "$out"
contains "…and says answering it is the unblock" "answer in its pane" "$out"
# The dialog is drawn in the prompt's own box, so the unsent-input heuristic
# reads its selected choice as typed text. Reporting that invites submitting
# it, which is answering a safety prompt by accident.
lacks "…and does not report the choice list as unsent input" \
	"Unsent text" "$out"
eq "--json carries the reason" permission-prompt \
	"$(_cmd_status --json 2>/dev/null | jq -r '.members[0].attention_reason')"

print "pending"
member attention 5 -1
out=$(_cmd_pending 2>/dev/null)
contains "the ping line names the reason"  "status=attention(permission-prompt)" "$out"
contains "…and quotes the dialog"          "Do you want to proceed?" "$out"
contains "…and says it will not ping again" "will not move or report again" "$out"

print -r -- "$SLEPT" > "$PANE_FILE"
member attention 5 -1
out=$(_cmd_pending 2>/dev/null)
contains "an interrupted member reads differently" "status=attention(interrupted)" "$out"
contains "…and is told to carry on"                "send w:%1" "$out"

print -r -- "$IDLE" > "$PANE_FILE"
member attention 5 -1
out=$(_cmd_pending 2>/dev/null)
contains "a clean idle member says so" "status=attention(idle)" "$out"
lacks "…and is not dressed up as blocked" "permission" "$out"

print ""
print "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
