#!/usr/bin/env zsh
# Tests for the paired worker↔reviewer fix/re-review loop (issue #9): the
# state machine in scripts/tmux-apex.sh that relays a reviewer's verdict to
# the worker, re-invokes the reviewer after the worker pushes, and escalates
# to the manager exactly once — when the loop terminates, not per round.
#
# No live agents: tmux is stubbed by a file-backed option store, `gh` records
# its argv, and member state is the real thing under a temp XDG_CACHE_HOME.
#
# Run: tests/apex-pair.test.sh

set -u
emulate -L zsh
setopt err_return

ROOT="${0:A:h:h}"
APEX="$ROOT/scripts/tmux-apex.sh"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-pair-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0 rc=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq() {
	if [[ $2 == $3 ]]; then ok "$1"; else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}
contains() {
	if [[ $3 == *$2* ]]; then ok "$1"; else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi
}
lacks() {
	if [[ $3 != *$2* ]]; then ok "$1"; else bad "$1" "expected NOT to contain: ${(qqq)2}
       actual                 : ${(qqq)3}"; fi
}

# ── stub environment ─────────────────────────────────────────────────
BIN="$TMPROOT/bin"
mkdir -p "$BIN"

# tmux stub. Options live in $STUB_OPTS as "scope<TAB>key<TAB>value"; panes
# that exist live in $STUB_PANES, one id per line. Only the subset of tmux
# that tmux-apex.sh actually calls is implemented — anything else is a
# silent no-op, which is what a missing tmux feature looks like anyway.
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env zsh
emulate -L zsh
set -u

_get() {  # _get <scope> <key>
	local line
	while IFS=$'\t' read -r sc k v; do
		[[ $sc == "$1" && $k == "$2" ]] && line="$v"
	done < "$STUB_OPTS"
	print -r -- "${line:-}"
}
_set() {  # _set <scope> <key> <value>
	print -r -- "$1	$2	$3" >> "$STUB_OPTS"
}

cmd="$1"; shift
case "$cmd" in
	display-message)
		# -p '#S'  |  -p -t <pane> '#{pane_current_command}'
		local target="" fmt=""
		while (( $# )); do
			case "$1" in
				-p) shift ;;
				-t) target="$2"; shift 2 ;;
				*)  fmt="$1"; shift ;;
			esac
		done
		case "$fmt" in
			'#S')                     print -r -- "$STUB_SESSION" ;;
			'#{pane_current_command}') print -r -- "${STUB_PANE_CMD:-node}" ;;
		esac
		;;
	show-option)
		local pane_scoped=false target="" key="" global=false
		while (( $# )); do
			case "$1" in
				-p)    pane_scoped=true; shift ;;
				-g)    global=true; shift ;;
				-t)    target="$2"; shift 2 ;;
				-qv|-v|-q) shift ;;
				-gqv)  global=true; shift ;;
				-*)    shift ;;
				*)     key="$1"; shift ;;
			esac
		done
		if $global; then print -r -- ""; else _get "$target" "$key"; fi
		;;
	set-option)
		local target="" key="" val="" unset=false
		while (( $# )); do
			case "$1" in
				-p) shift ;;
				-u) unset=true; shift ;;
				-t) target="$2"; shift 2 ;;
				-*) shift ;;
				*)  if [[ -z $key ]]; then key="$1"; else val="$1"; fi; shift ;;
			esac
		done
		$unset && val=""
		_set "$target" "$key" "$val"
		;;
	list-panes)
		cat "$STUB_PANES"
		;;
	send-keys)
		local target=""
		while (( $# )); do
			case "$1" in
				-t) target="$2"; shift 2 ;;
				-l|--) shift ;;
				Enter) shift ;;
				# Key names, not text: cursor/kill keys from _clear_pane_input.
				C-e|C-u) shift ;;
				*) print -r -- "$target	$1" >> "$STUB_SENT"; shift ;;
			esac
		done
		;;
	# Empty unless a test opts in, so `send` sees a drained input box and
	# _send_to_pane confirms submission (the ordinary case here).
	capture-pane)
		[[ -n ${STUB_PANE_TEXT:-} ]] && print -r -- "$STUB_PANE_TEXT"
		exit 0
		;;
	has-session)  exit 0 ;;
	run-shell)    exit 0 ;;   # settle callbacks are driven explicitly here
	*)            exit 0 ;;
esac
EOF

# gh stub: record argv so a `gh pr ready` (a real, outward-facing state
# change on the PR) can be asserted on, and fail on demand.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH"
[ -n "${STUB_GH_FAIL:-}" ] && exit 1
exit 0
EOF
chmod +x "$BIN/tmux" "$BIN/gh"
export PATH="$BIN:$PATH"

export XDG_CACHE_HOME="$TMPROOT/cache"
export STUB_OPTS="$TMPROOT/opts.tsv"
export STUB_PANES="$TMPROOT/panes"
export STUB_SENT="$TMPROOT/sent.tsv"
export STUB_GH="$TMPROOT/gh.log"
export STUB_SESSION=mgr
export TMUX=fake-socket

MGR=mgr
WORKER='wt:%1'
REVIEWER='wt:%2'
MEMBERS="$XDG_CACHE_HOME/tmux-delta/apex/$MGR/members"

# `_die` exits non-zero; every failure here is asserted on its message, so
# swallow the status rather than tripping err_return.
apex() { "$APEX" "$@" 2>&1 || true }
mget() { jq -r --arg k "$2" '.[$k] // "" | tostring' "$MEMBERS/$1.json" }

# reset [--no-link] [--max N] — rebuild a clean two-member world.
reset() {
	local nolink=false max=5 a
	for a in "$@"; do
		case "$a" in --no-link) nolink=true ;; --max=*) max="${a#--max=}" ;; esac
	done
	rm -rf "$XDG_CACHE_HOME" "$STUB_OPTS" "$STUB_PANES" "$STUB_SENT" "$STUB_GH"
	mkdir -p "$MEMBERS"
	: > "$STUB_OPTS"; : > "$STUB_SENT"; : > "$STUB_GH"
	printf '%%1\n%%2\n' > "$STUB_PANES"
	unset STUB_GH_FAIL

	print -r -- "mgr	@apex_role	manager"   >> "$STUB_OPTS"
	print -r -- "mgr	@apex_repo	$ROOT"     >> "$STUB_OPTS"
	print -r -- "%1	@apex_role	worker"    >> "$STUB_OPTS"
	print -r -- "%1	@apex_session	$MGR"      >> "$STUB_OPTS"
	print -r -- "%1	@apex_task	issue:9"   >> "$STUB_OPTS"
	print -r -- "%2	@apex_role	monitor"   >> "$STUB_OPTS"
	print -r -- "%2	@apex_session	$MGR"      >> "$STUB_OPTS"
	print -r -- "%2	@apex_task	pr:42"     >> "$STUB_OPTS"

	local m
	mkdir -p "$TMPROOT/wt"
	for m in "$WORKER" "$REVIEWER"; do
		jq -nc --arg wt "$TMPROOT/wt" --argjson t 1 '{agent:"claude", worktree:$wt, status:"idle",
			seq:1, pinged_seq:1, spawned_at:$t, updated_at:$t}' > "$MEMBERS/$m.json"
	done
	jq -c '.role="worker"'  "$MEMBERS/$WORKER.json"   > "$TMPROOT/w" && mv "$TMPROOT/w" "$MEMBERS/$WORKER.json"
	jq -c '.role="monitor" | .review_pr="42"' "$MEMBERS/$REVIEWER.json" > "$TMPROOT/r" && mv "$TMPROOT/r" "$MEMBERS/$REVIEWER.json"

	$nolink && return 0
	apex link --worker "$WORKER" --reviewer "$REVIEWER" --pr 42 --max-rounds "$max" >/dev/null
	: > "$STUB_SENT"   # drop the initial reviewer briefing
}

# verdict / worker_verdict — `verdict` reads the *calling* pane, so it has to
# run as the member recording it, not as the manager.
verdict()        { STUB_SESSION=wt TMUX_PANE=%2 "$APEX" verdict "$@" 2>&1 || true }
worker_verdict() { STUB_SESSION=wt TMUX_PANE=%1 "$APEX" verdict "$@" 2>&1 || true }

# settle <member> — one working→idle cycle: bump the member's seq the way the
# Stop hook would, then fire the deferred callback tmux would have run.
# _settle dedupes on settled_seq, so re-settling the same seq is a no-op.
settle() {
	local seq; seq=$(( $(mget "$1" seq) + 1 ))
	jq -c --argjson s "$seq" '.seq = $s' "$MEMBERS/$1.json" > "$TMPROOT/s" \
		&& mv "$TMPROOT/s" "$MEMBERS/$1.json"
	apex _settle "$1" "$MGR" "$seq"
}
sent_to() { awk -F'\t' -v p="$1" '$1==p{print $2}' "$STUB_SENT" }

# ── link ─────────────────────────────────────────────────────────────
print "link"
reset --no-link
out=$(apex link --worker "$WORKER" --reviewer "$REVIEWER" --pr 42)
contains "link reports the PR"        "PR #42"      "$out"
eq       "worker records its role"    worker        "$(mget "$WORKER" pair_role)"
eq       "reviewer records its role"  reviewer      "$(mget "$REVIEWER" pair_role)"
eq       "worker points at reviewer"  "$REVIEWER"   "$(mget "$WORKER" pair)"
eq       "reviewer points at worker"  "$WORKER"     "$(mget "$REVIEWER" pair)"
eq       "loop starts active"         active        "$(mget "$WORKER" pair_state)"
eq       "reviewer moves first"       reviewer      "$(mget "$WORKER" pair_turn)"
eq       "default round cap applied"  5             "$(mget "$WORKER" pair_max_rounds)"
# The reviewer is already running its own prompt and cannot know about the
# verdict protocol unless linking tells it.
contains "link briefs the reviewer"   "tmux-apex.sh verdict" "$(sent_to %2)"
lacks    "link does not nudge the worker" "verdict"          "$(sent_to %1)"

out=$(apex link --worker "$WORKER" --reviewer "$WORKER" --pr 42)
contains "linking a member to itself is refused" "must be different" "$out"
out=$(apex link --worker "$WORKER" --reviewer 'wt:%9' --pr 42)
contains "linking a non-member is refused" "not a member" "$out"

# ── reviewer found findings → relay to worker ────────────────────────
print "\nreviewer with findings relays to the worker"
reset
verdict --findings 3 --note 'unquoted vars' >/dev/null
eq "verdict is stamped with the round" 1 "$(mget "$REVIEWER" verdict_round)"
eq "verdict count is stored"           3 "$(mget "$REVIEWER" verdict_findings)"

settle "$REVIEWER" >/dev/null
relayed=$(sent_to %1)
contains "worker is told the finding count" "3 finding(s)"      "$relayed"
contains "worker is told how to read them"  "gh pr view 42"     "$relayed"
contains "the reviewer's note is passed on" "unquoted vars"     "$relayed"
contains "worker is told not to wait"       "Do NOT message the manager" "$relayed"
eq "round advances on both halves (worker)"   2 "$(mget "$WORKER" pair_round)"
eq "round advances on both halves (reviewer)" 2 "$(mget "$REVIEWER" pair_round)"
eq "the turn passes to the worker"       worker "$(mget "$WORKER" pair_turn)"
lacks "nothing is sent to the reviewer yet" "re-review" "$(sent_to %2)"
# The whole point: no manager ping for an intermediate round.
eq "manager is not pinged mid-loop" "" "$(apex pending)"

# ── worker pushed → re-invoke reviewer ───────────────────────────────
print "\nworker idle re-invokes the reviewer"
settle "$WORKER" >/dev/null
relayed=$(sent_to %2)
contains "reviewer is asked to re-review"  "Re-review"           "$relayed"
contains "re-review names the PR"          "/my-pr-review 42"    "$relayed"
contains "re-review re-states the verdict duty" "verdict --none" "$relayed"
eq "the turn passes back to the reviewer" reviewer "$(mget "$WORKER" pair_turn)"
eq "manager still not pinged" "" "$(apex pending)"

# ── termination: no findings left ────────────────────────────────────
print "\nempty verdict terminates the loop"
reset
verdict --none >/dev/null
settle "$REVIEWER" >/dev/null
contains "the PR is flipped out of draft" "pr ready 42" "$(cat "$STUB_GH")"
eq "loop is marked complete (worker)"   complete "$(mget "$WORKER" pair_state)"
eq "loop is marked complete (reviewer)" complete "$(mget "$REVIEWER" pair_state)"
lacks "no further relay to the worker" "finding(s)" "$(sent_to %1)"

out=$(apex pending)
contains "manager is finally pinged"          "READY FOR HUMAN REVIEW" "$out"
contains "the ping is framed as a merge call" "merge decision"         "$out"
contains "the ping says the draft was lifted" "ready-for-review"       "$out"
eq "and only about the PR, once" 1 "$(print -r -- "$out" | grep -c 'READY FOR HUMAN')"
# Escalating twice — once per pane — is exactly the noise this replaces.
eq "the reviewer pane is not reported separately" 1 "$(print -r -- "$out" | wc -l | tr -d ' ')"

# A failed `gh pr ready` must still reach the human, and say so, rather than
# silently reporting a PR as ready when it is still a draft.
print "\ngh pr ready failure still escalates"
reset
export STUB_GH_FAIL=1
verdict --none >/dev/null
settle "$REVIEWER" >/dev/null
unset STUB_GH_FAIL
out=$(apex pending)
contains "failure is surfaced"        "Could not flip PR #42" "$out"
contains "failure names the manual fix" "gh pr ready 42"      "$out"
eq "loop still terminates" complete "$(mget "$WORKER" pair_state)"

# ── termination: no verdict recorded ─────────────────────────────────
# "no verdict" and "no findings" are different states; guessing between them
# silently flips a PR to ready-for-review.
print "\nreviewer idle without a verdict escalates instead of guessing"
reset
settle "$REVIEWER" >/dev/null
out=$(apex pending)
contains "stuck ping explains why"   "without recording a verdict" "$out"
contains "stuck ping offers a resume" "pair-resume"                "$out"
eq "loop is marked stuck"  stuck "$(mget "$WORKER" pair_state)"
eq "the PR is left as a draft" "" "$(cat "$STUB_GH")"
lacks "the worker is not asked to fix anything" "finding(s)" "$(sent_to %1)"

# ── loop cap ─────────────────────────────────────────────────────────
print "\nthe round cap escalates rather than ping-ponging forever"
reset --max=2
verdict --findings 1 >/dev/null
settle "$REVIEWER" >/dev/null
eq "round 1 relays normally" 2 "$(mget "$WORKER" pair_round)"
settle "$WORKER" >/dev/null
: > "$STUB_SENT"
verdict --findings 1 >/dev/null
settle "$REVIEWER" >/dev/null
out=$(apex pending)
contains "cap ping names the cap"        "round 2 of 2" "$out"
contains "cap ping says they diverged"   "not converging" "$out"
eq "loop is marked stuck" stuck "$(mget "$WORKER" pair_state)"
eq "no third round is relayed" "" "$(sent_to %1)"
eq "the PR is left as a draft" "" "$(cat "$STUB_GH")"

# Resuming at the cap without raising it would re-invoke the reviewer for a
# full turn, collect duplicate PR comments, and land back in `stuck` on its
# first finding. Refuse instead of pretending to resume. (PR #13 review.)
out=$(apex pair-resume "$WORKER")
contains "resume at the cap is refused"  "already at the cap" "$out"
contains "refusal names the way out"     "--max-rounds"       "$out"
eq "loop is left stuck" stuck "$(mget "$WORKER" pair_state)"
eq "and the reviewer is not woken for nothing" "" "$(sent_to %2)"

out=$(apex pair-resume "$WORKER" --max-rounds 2)
contains "a cap that is not actually higher is refused" "not above the current cap" "$out"

out=$(apex pair-resume "$WORKER" --max-rounds 4)
contains "pair-resume restarts the round" "Resumed the loop" "$out"
contains "and reports the new cap"        "round 2 of 4"     "$out"
eq "loop is active again" active "$(mget "$WORKER" pair_state)"
eq "the raised cap lands on both halves (worker)"   4 "$(mget "$WORKER" pair_max_rounds)"
eq "the raised cap lands on both halves (reviewer)" 4 "$(mget "$REVIEWER" pair_max_rounds)"
contains "and the reviewer is re-invoked" "Re-review" "$(sent_to %2)"

# A resume re-invokes the reviewer for the *same* round, and the freshness check
# only compares verdict_round to pair_round — so without clearing it, the
# verdict recorded before the loop got stuck passes for the resumed round's.
# That relays stale findings and skips the no-verdict escalation, in the one
# property the whole design rests on. (PR #13 re-review.)
eq "resume clears the stale verdict round"    "" "$(mget "$REVIEWER" verdict_round)"
eq "resume clears the stale verdict findings" "" "$(mget "$REVIEWER" verdict_findings)"
: > "$STUB_SENT"
settle "$REVIEWER" >/dev/null
contains "a resumed reviewer that records nothing is escalated, not believed" \
	"without recording a verdict" "$(apex pending)"
eq "and no stale findings are relayed" "" "$(sent_to %1)"
eq "loop is stuck again, honestly" stuck "$(mget "$WORKER" pair_state)"

# The point of raising the cap: with a *fresh* verdict, the next round must
# actually make progress rather than re-escalating immediately.
apex pair-resume "$WORKER" --max-rounds 5 >/dev/null
: > "$STUB_SENT"
verdict --findings 1 >/dev/null
settle "$REVIEWER" >/dev/null
eq "the resumed round relays instead of re-escalating" active "$(mget "$WORKER" pair_state)"
contains "and the worker gets the findings" "1 finding(s)" "$(sent_to %1)"
eq "round advances past the old cap" 3 "$(mget "$WORKER" pair_round)"

# A reaped partner must not be resurrected as a phantom member.
print "\npair-resume does not recreate a reaped partner"
reset --max=3
rm -f "$MEMBERS/$REVIEWER.json"
apex pair-resume "$WORKER" >/dev/null
eq "the reaped member file stays gone" "" "$(print -r -- "$MEMBERS/$REVIEWER.json"(N))"

# ── an undeliverable relay must not spend a round ────────────────────
# The pair state is written ahead of the relay on purpose (it must not race the
# wake-up it causes), so the undelivered case has to roll it back — otherwise a
# round nobody performed eats one of the cap's attempts, which now costs a
# mandatory --max-rounds bump to recover from. (PR #13 re-review.)
print "\nan undeliverable relay does not consume a round"
reset --max=3
verdict --findings 2 >/dev/null
export STUB_PANE_CMD=zsh          # the worker's pane is no longer an agent
settle "$REVIEWER" >/dev/null
unset STUB_PANE_CMD
contains "the stuck ping names the delivery failure" "no reachable coding agent" "$(apex pending)"
eq "the round is rolled back (worker)"   1 "$(mget "$WORKER" pair_round)"
eq "the round is rolled back (reviewer)" 1 "$(mget "$REVIEWER" pair_round)"
eq "and so is the turn" reviewer "$(mget "$WORKER" pair_turn)"
# With the round rolled back, resuming does not need the cap raised.
out=$(apex pair-resume "$WORKER")
contains "resume works without raising the cap" "Resumed the loop" "$out"
contains "and resumes the round that never ran" "round 1 of 3" "$out"

# ── a relay that is typed but never submitted ────────────────────────
# PR #12 taught `_send_to_pane` to distinguish "tmux refused" from "typed
# into the box, Enter never took". `send` reports the second as a distinct
# unconfirmed state because a human can act on it; the loop cannot — an
# unsubmitted relay never wakes the partner — so it must escalate exactly
# like an undeliverable one, round rollback included.
print "\nan unsubmitted relay escalates and does not consume a round"
reset --max=3
verdict --findings 2 >/dev/null
# A static box still showing our own text: the submit check never clears.
export STUB_PANE_TEXT='│ > [apex from:apex-pair] PAIRED REVIEW              │'
settle "$REVIEWER" >/dev/null
unset STUB_PANE_TEXT
eq "loop is marked stuck" stuck "$(mget "$REVIEWER" pair_state)"
contains "the stuck ping names the unsent text, not a dead pane" \
	"sitting unsent in the input box" "$(apex pending)"
eq "the round is rolled back" 1 "$(mget "$WORKER" pair_round)"
eq "and so is the turn" reviewer "$(mget "$WORKER" pair_turn)"

# ── dead partner ─────────────────────────────────────────────────────
print "\na dead partner escalates"
reset
verdict --findings 2 >/dev/null
printf '%%2\n' > "$STUB_PANES"          # worker's pane is gone
settle "$REVIEWER" >/dev/null
contains "stuck ping names the missing partner" "partner session" "$(apex pending)"
eq "loop is marked stuck" stuck "$(mget "$REVIEWER" pair_state)"

# ── turn discipline / fall-through ───────────────────────────────────
# A worker that idles before the first review has nothing to relay — that
# idle transition belongs to the manager, exactly as before this feature.
print "\nout-of-turn and unlinked idles fall through to the manager"
reset
settle "$WORKER" >/dev/null
out=$(apex pending)
contains "out-of-turn worker idle reaches the manager" "status=idle" "$out"
eq "and relays nothing" "" "$(sent_to %2)"
eq "loop stays active" active "$(mget "$WORKER" pair_state)"

reset --no-link
settle "$WORKER" >/dev/null
contains "an unlinked member reports as before" "status=idle" "$(apex pending)"
eq "and relays nothing" "" "$(cat "$STUB_SENT")"

# ── verdict guard rails ──────────────────────────────────────────────
print "\nverdict guard rails"
reset
out=$(verdict)
contains "verdict needs an argument" "usage: verdict" "$out"
out=$(verdict --findings nope)
contains "verdict rejects a non-integer" "non-negative integer" "$out"

# The worker must not be able to close out its own review.
out=$(worker_verdict --none)
contains "only the reviewer may record a verdict" "only the reviewer" "$out"

# ── two-argument option guards ───────────────────────────────────────
# zsh's `shift 2` with one positional left fails *and leaves $# unchanged*, so
# an unguarded `while (( $# ))` parser spins forever. `verdict` is run by the
# reviewer agent unattended, and a wedged pane never reaches its Stop hook — so
# the loop's own "idle without a verdict" escalation never fires either, and the
# pair hangs with nobody notified. (PR #13 review.)
print "\nmissing option values fail fast instead of spinning"

for cmd in \
	'verdict --findings' 'verdict --note' \
	'link --worker' 'link --reviewer' 'link --pr' 'link --max-rounds' \
	'pair-resume --max-rounds' \
	'spawn --issue' 'spawn --review-pr' 'spawn --role' 'spawn --agent' \
	'spawn --model' 'spawn --profile' 'spawn --mode' 'spawn --agent-flags'
do
	# Capture the status outside a command substitution: err_return aborts the
	# subshell on the failure itself, before a trailing `print $?` can run.
	timeout 5 zsh "$APEX" ${=cmd} > "$TMPROOT/out" 2>&1 && rc=0 || rc=$?
	eq "'${cmd}' with no value exits, not 124/timeout" 1 "$rc"
	contains "'${cmd}' says which flag needs a value" \
		"${cmd##* } needs a value" "$(cat "$TMPROOT/out")"
done

# An intentionally empty value is still a value.
reset
verdict --findings 2 --note '' >/dev/null
eq "an empty --note is accepted" 2 "$(mget "$REVIEWER" verdict_findings)"

# ── escalations are not gated on the status field ────────────────────
# A relay wakes the partner, whose own `event set` overwrites status to
# `working` and bumps seq. Gating `pending` on status would defer a terminal
# ping by a whole agent turn — likeliest in exactly the cases that need it
# soonest. (PR #13 review.)
print "\na terminal escalation reaches the manager even mid-turn"
reset
verdict --none >/dev/null
settle "$REVIEWER" >/dev/null
jq -c '.status = "working" | .seq = 99' "$MEMBERS/$WORKER.json" > "$TMPROOT/w" \
	&& mv "$TMPROOT/w" "$MEMBERS/$WORKER.json"
out=$(apex pending)
contains "the ready ping is not withheld while the worker is busy" \
	"READY FOR HUMAN REVIEW" "$out"

# ── unlink ───────────────────────────────────────────────────────────
print "\nunlink"
reset
apex unlink "$WORKER" >/dev/null
eq "worker pairing cleared"   "" "$(mget "$WORKER" pair)"
eq "reviewer pairing cleared" "" "$(mget "$REVIEWER" pair)"
settle "$REVIEWER" >/dev/null
contains "an unlinked reviewer reports to the manager" "status=idle" "$(apex pending)"

print "\n${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
