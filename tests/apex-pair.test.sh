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
# that exist live in $STUB_PANES, one id per line — every one of them in the
# member session $STUB_PANE_SESSION (STUB_SESSION is the *caller's* session, and
# the caller is often the manager). Only the subset of tmux
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

# The input box's live contents. Seeded from $STUB_PANE_TEXT and re-seeded
# whenever that changes, so a fixture set between two `settle` runs takes
# effect rather than inheriting the box the previous test left behind.
box_read() {
	if [[ -e "$STUB_SENT.box" ]] &&
		[[ "$(cat "$STUB_SENT.boxseed" 2>/dev/null)" == "${STUB_PANE_TEXT:-}" ]]; then
		cat "$STUB_SENT.box"
	else
		print -r -- "${STUB_PANE_TEXT:-}"
	fi
}
box_write() {
	print -r -- "$1" > "$STUB_SENT.box"
	print -r -- "${STUB_PANE_TEXT:-}" > "$STUB_SENT.boxseed"
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
		# Liveness is checked session-scoped ("#{session_name}:#{pane_id}"),
		# because tmux recycles pane ids across servers and a bare id can
		# belong to a different session than the member's.
		if [[ ${@[-1]} == *'#{session_name}'* ]]; then
			sed "s|^|${STUB_PANE_SESSION}:|" "$STUB_PANES"
		else
			cat "$STUB_PANES"
		fi
		;;
	send-keys)
		local target=""
		while (( $# )); do
			case "$1" in
				-t) target="$2"; shift 2 ;;
				-l|--) shift ;;
				# Submitting empties the box, unless the test is modelling a
				# swallowed Enter.
				Enter) [[ -n ${STUB_PANE_NO_DRAIN:-} ]] || box_write ""; shift ;;
				# Key names, not text: cursor/kill keys from _clear_pane_input.
				C-e) shift ;;
				C-u) [[ -n ${STUB_PANE_NO_CLEAR:-} ]] || box_write ""; shift ;;
				# Literal text lands in the box, appended to whatever survived
				# clearing — the splice.
				*) print -r -- "$target	$1" >> "$STUB_SENT"
				   box_write "$(box_read)$1"; shift ;;
			esac
		done
		;;
	# The input box is real state, not a canned pair of reads: $STUB_SENT.box
	# holds its current contents, C-u empties it, a literal send appends to
	# whatever is there, and Enter empties it. That is what lets one fixture
	# distinguish the shapes the delivery code cares about — a box that drains,
	# one that will not (STUB_PANE_NO_DRAIN), and a draft that will not clear
	# so our text is spliced onto it (STUB_PANE_NO_CLEAR). Canned reads could
	# not: the residue the splice check strips is read *before* we type, and a
	# stub that cannot tell before from after has to answer both with one
	# string (issue #22).
	#
	# STUB_PANE_TEXT is the box's initial contents, bare text — the stub draws
	# the frame. File-backed because the stub is a fresh process per call.
	#
	# STUB_PANE_BUSY adds an orthogonal shape: a trailing line that differs on
	# every read, i.e. an agent mid-turn repainting a spinner while the box
	# keeps our text. A frozen box alone is a byte-frozen pane, which the send
	# path reads as a genuine stall (issue #24), so a test that wants the busy
	# reading has to say so.
	capture-pane)
		# STUB_PANE_DRAIN_AFTER models the shape the relay's longer confirmation
		# window exists for: the Enter *did* land, but the box only visibly
		# drains after N reads because the pane was busy redrawing in between.
		# Read with a ceiling below N it looks unconfirmed; with a ceiling above
		# N, delivered. That difference is the whole of the issue #29 fix, so it
		# needs a fixture that can be read both ways rather than one that is
		# permanently undrainable.
		if [[ -n ${STUB_PANE_DRAIN_AFTER:-} ]]; then
			local reads
			reads=$(( $(cat "$STUB_SENT.reads" 2>/dev/null || print 0) + 1 ))
			print -n -- "$reads" > "$STUB_SENT.reads"
			(( reads > STUB_PANE_DRAIN_AFTER )) && box_write ""
		fi
		busy_line() {
			[[ -n ${STUB_PANE_BUSY:-} ]] || return 0
			local n
			n=$(( $(cat "$STUB_SENT.busy" 2>/dev/null || print 0) + 1 ))
			print -n -- "$n" > "$STUB_SENT.busy"
			print -r -- "esc to interrupt · $n tokens"
		}
		local box
		box=$(box_read)
		[[ -n $box ]] && print -r -- "│ > ${box}   │"
		busy_line
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
case "$*" in
	*"pr view"*"--jq"*) printf '%s\n' "${STUB_GH_COMMENTS:-1}" ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux" "$BIN/gh"
export PATH="$BIN:$PATH"

export XDG_CACHE_HOME="$TMPROOT/cache"
export STUB_OPTS="$TMPROOT/opts.tsv"
export STUB_PANES="$TMPROOT/panes"
export STUB_PANE_SESSION=wt
export STUB_SENT="$TMPROOT/sent.tsv"
export STUB_GH="$TMPROOT/gh.log"
export STUB_SESSION=mgr
export TMUX=fake-socket

MGR=mgr
WORKER='wt:%1'
REVIEWER='wt:%2'
MEMBERS="$XDG_CACHE_HOME/tmux-delta/apex/$MGR/members"
EVENTS="$XDG_CACHE_HOME/tmux-delta/apex/$MGR/events.jsonl"

# `_die` exits non-zero; every failure here is asserted on its message, so
# swallow the status rather than tripping err_return.
apex() { "$APEX" "$@" 2>&1 || true }
# Last event of a given type, as compact JSON ("" if none).
ev() { jq -c --arg e "$1" 'select(.event == $e)' "$EVENTS" 2>/dev/null | tail -1 }

mget() { jq -r --arg k "$2" '.[$k] // "" | tostring' "$MEMBERS/$1.json" }

# reset [--no-link] [--max N] — rebuild a clean two-member world.
reset() {
	local nolink=false max=5 a
	for a in "$@"; do
		case "$a" in --no-link) nolink=true ;; --max=*) max="${a#--max=}" ;; esac
	done
	rm -rf "$XDG_CACHE_HOME" "$STUB_OPTS" "$STUB_PANES" "$STUB_SENT" "$STUB_GH" "$STUB_SENT.box" "$STUB_SENT.boxseed" "$STUB_SENT.busy" "$STUB_SENT.reads"
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
contains "worker is told how the finding was recorded" "noted inline" "$relayed"
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
lacks "the PR is left as a draft" "pr ready" "$(cat "$STUB_GH")"

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
# ── pair-resume refuses to resume onto live work (issue #29) ─────────
# `pair-resume` re-invokes the reviewer immediately, against whatever is on the
# branch at that moment. Every escalation message names it as the remedy, but
# the unconfirmed-relay escalation can fire while the worker is provably still
# working on the relay it did receive — and resuming there re-reviews unchanged
# code, spends a round, and re-posts the same findings. So the remedy refuses
# the state it is most often reached from.
print "\npair-resume refuses to resume onto live work"
reset --max=3
jq -c '.status = "working"' "$MEMBERS/$WORKER.json" > "$TMPROOT/w" \
	&& mv "$TMPROOT/w" "$MEMBERS/$WORKER.json"
: > "$STUB_SENT"
out=$(apex pair-resume "$WORKER")
contains "an active worker pane blocks the resume" "still mid-change" "$out"
contains "and the refusal says which signal fired" "pane is still active" "$out"
contains "and names the override"                  "--force"            "$out"
eq "the reviewer is not woken for nothing" "" "$(sent_to %2)"
eq "and the verdict is left alone" 1 "$(mget "$REVIEWER" pair_round)"

# --force exists because the signals are heuristics, not proof: a worker can sit
# at status=working with a pane nobody is going to touch again. The human keeps
# the last word, they just have to say so.
out=$(apex pair-resume "$WORKER" --force)
contains "--force resumes anyway" "Resumed the loop" "$out"
contains "and the reviewer is re-invoked" "Re-review" "$(sent_to %2)"

# The other half of the guard: an idle worker with uncommitted changes. Same
# hazard — the reviewer would read a tree the worker has not finished with.
print "\n…and equally on a dirty worktree"
reset --max=3
mkdir -p "$TMPROOT/dirtywt"
git -C "$TMPROOT/dirtywt" init -q 2>/dev/null
: > "$TMPROOT/dirtywt/untracked"
jq -c --arg wt "$TMPROOT/dirtywt" '.worktree = $wt' "$MEMBERS/$WORKER.json" > "$TMPROOT/w" \
	&& mv "$TMPROOT/w" "$MEMBERS/$WORKER.json"
: > "$STUB_SENT"
out=$(apex pair-resume "$WORKER")
contains "a dirty worktree blocks the resume"    "still mid-change"      "$out"
contains "and the refusal says which signal fired" "worktree is dirty"   "$out"
eq "the reviewer is not woken" "" "$(sent_to %2)"

# A clean, idle worker is the case the resume was designed for: no obstacle.
print "\npair-resume still resumes a settled worker"
reset --max=3
: > "$STUB_SENT"
out=$(apex pair-resume "$WORKER")
contains "an idle worker with a clean tree resumes" "Resumed the loop" "$out"

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
export STUB_PANE_TEXT='[apex from:apex-pair] PAIRED REVIEW'
export STUB_PANE_NO_DRAIN=1                     # Enter is swallowed
settle "$REVIEWER" >/dev/null
unset STUB_PANE_TEXT STUB_PANE_NO_DRAIN
eq "loop is marked stuck" stuck "$(mget "$REVIEWER" pair_state)"
contains "the stuck ping names the unsent text, not a dead pane" \
	"sitting unsent in the input box" "$(apex pending)"
eq "the round is rolled back" 1 "$(mget "$WORKER" pair_round)"
eq "and so is the turn" reviewer "$(mget "$WORKER" pair_turn)"
# The failure path logs too: the pane-clearing already ran, so whatever it
# discarded is gone whether or not the delivery that displaced it landed.
contains "the failed relay is logged" '"event":"pair-relay-failed"' \
	"$(ev pair-relay-failed)"
contains "with the _deliver return code" '"rc":5' "$(ev pair-relay-failed)"
# NOT a discarded human draft: the box here holds our own relay text, which is
# what makes _box_pending see it as unsubmitted in the first place. What this
# asserts is only that the pre-send box read is carried onto the failure event.
# The draft-plus-rc-5 cross-product is asserted separately below, where the box
# starts foreign and then holds ours.
contains "the pre-send box read is carried onto the event" "PAIRED REVIEW" \
	"$(ev pair-relay-failed)"

# ── a relay the send path could not confirm (issue #24) ──────────────
# The send path no longer retypes into a pane that is visibly working, because
# that is how the same instruction got delivered twice for real. It reports
# delivered-by-inference instead, with APEX_SEND_UNCONFIRMED set. For a human
# at a terminal that is fine — `send` prints a NOTE they can act on. Here there
# is nobody to read it, and advancing pair_turn on an inference risks a loop
# waiting forever on a partner that was never woken, with the rollback
# machinery built for that case unreachable. So the relay demotes it to
# undelivered and escalates, accepting a false alarm to avoid a silent
# deadlock.
print "\nan unconfirmed relay escalates rather than advancing the turn"
reset --max=3
verdict --findings 2 >/dev/null
export STUB_PANE_TEXT='[apex from:apex-pair] PAIRED REVIEW'
export STUB_PANE_NO_DRAIN=1                     # box never drains…
export STUB_PANE_BUSY=1                         # …but the pane keeps repainting
export APEX_SEND_SETTLE_TICKS=6
settle "$REVIEWER" >/dev/null
unset STUB_PANE_TEXT STUB_PANE_NO_DRAIN STUB_PANE_BUSY APEX_SEND_SETTLE_TICKS
eq "the loop is marked stuck" stuck "$(mget "$REVIEWER" pair_state)"
contains "the stuck ping says the delivery was unconfirmed" \
	"could not be confirmed" "$(apex pending)"
eq "the round is rolled back" 1 "$(mget "$WORKER" pair_round)"
eq "and the turn is not advanced" reviewer "$(mget "$WORKER" pair_turn)"
# The event is the only surviving record on this path, and the whole
# justification for reporting delivered-by-inference at all — so it is pinned,
# jq program included: a typo there loses the entire event, not just the field.
eq "the event marks it unconfirmed" true \
	"$(print -r -- "$(ev pair-relay-failed)" | jq -r '.unconfirmed // false')"
contains "and reports it as an unsubmitted-class failure" '"rc":5' \
	"$(ev pair-relay-failed)"
# The escalation is a fail-safe, not a diagnosis: a pane that kept repainting is
# weak evidence *for* delivery. Saying "unconfirmed" and stopping there sent an
# operator straight to `pair-resume`, which is the one thing that must not
# happen while the partner is mid-turn on the relay it did receive (issue #29).
contains "the ping says the partner may have it after all" \
	"may well have the message" "$(apex pending)"
contains "and gives the recovery order, not just the symptom" \
	"finish and push first" "$(apex pending)"

# ── the same pane, watched for longer (issue #29) ─────────────────────
# The give-up above is a ceiling, not a fact about the pane, and the ceiling it
# used was `send`'s: 5s, tuned for a human who can just look at the pane. On the
# relay path nobody looks, so the loop was disarming itself over redraw lag. The
# relay now watches far longer, which costs only observation — the retype is
# still gated on the pane going quiet, so no extra ceiling can produce a
# duplicate turn (issue #24).
print "\na busy pane whose box drains late is delivered, not escalated"
reset --max=3
verdict --findings 2 >/dev/null
export STUB_PANE_TEXT='[apex from:apex-pair] PAIRED REVIEW'
export STUB_PANE_NO_DRAIN=1                     # Enter does not visibly drain it…
export STUB_PANE_BUSY=1                         # …the pane repaints throughout…
export STUB_PANE_DRAIN_AFTER=10                 # …and the box drains on read 11
settle "$REVIEWER" >/dev/null
unset STUB_PANE_TEXT STUB_PANE_NO_DRAIN STUB_PANE_BUSY STUB_PANE_DRAIN_AFTER
eq "the loop stays active" active "$(mget "$REVIEWER" pair_state)"
eq "the turn advances to the worker" worker "$(mget "$WORKER" pair_turn)"
eq "the round is consumed, because a round happened" 2 "$(mget "$WORKER" pair_round)"
contains "the findings reach the worker" "PAIRED REVIEW" "$(sent_to %1)"
contains "and it is logged as an ordinary relay" '"event":"pair-relay"' \
	"$(ev pair-relay)"
eq "with no unconfirmed flag" false \
	"$(print -r -- "$(ev pair-relay)" | jq -r '.unconfirmed // false')"
eq "and no escalation was written" "" "$(mget "$WORKER" pair_message)"

# Same pane, same drain, ceiling put back to `send`'s: escalates again. This is
# the pair that shows the behaviour turns on the ceiling and nothing else — and
# that an explicitly-set APEX_SEND_SETTLE_TICKS still wins, so an operator who
# tuned it does not silently get the relay's default instead.
print "\n…and the explicit ceiling still wins over the relay default"
reset --max=3
verdict --findings 2 >/dev/null
export STUB_PANE_TEXT='[apex from:apex-pair] PAIRED REVIEW'
export STUB_PANE_NO_DRAIN=1
export STUB_PANE_BUSY=1
export STUB_PANE_DRAIN_AFTER=10
export APEX_SEND_SETTLE_TICKS=3                 # gives up before read 11
settle "$REVIEWER" >/dev/null
unset STUB_PANE_TEXT STUB_PANE_NO_DRAIN STUB_PANE_BUSY STUB_PANE_DRAIN_AFTER APEX_SEND_SETTLE_TICKS
eq "the loop is marked stuck" stuck "$(mget "$REVIEWER" pair_state)"
eq "the round is rolled back" 1 "$(mget "$WORKER" pair_round)"
eq "the event marks it unconfirmed" true \
	"$(print -r -- "$(ev pair-relay-failed)" | jq -r '.unconfirmed // false')"

# The same pane, read by a human's `send`: delivered, with the NOTE and the
# flag on the `send` event rather than an escalation.
print "\nsend reports the same pane as delivered-but-unconfirmed"
reset --max=3
export STUB_PANE_TEXT='[apex from:mgr] check the build'
export STUB_PANE_NO_DRAIN=1
export STUB_PANE_BUSY=1
export APEX_SEND_SETTLE_TICKS=6
out=$(apex send "$WORKER" "check the build")
unset STUB_PANE_TEXT STUB_PANE_NO_DRAIN STUB_PANE_BUSY APEX_SEND_SETTLE_TICKS
contains "send reports delivery" "Delivered to" "$out"
contains "and notes that it was never observed" "never drained" "$out"
eq "the send event marks it unconfirmed" true \
	"$(print -r -- "$(ev send)" | jq -r '.unconfirmed // false')"
# The ordinary case must not carry the field at all — an always-present
# "unconfirmed" would be worthless to grep for.
reset --max=3
apex send "$WORKER" "check the build" >/dev/null
eq "a confirmed send has no unconfirmed field" false \
	"$(print -r -- "$(ev send)" | jq -r '.unconfirmed // false')"

# ── the relay records what its pane-clearing discarded ───────────────
# `_send_to_pane` fires C-e/C-u before typing (#12), and the contract for
# that is that nothing vanishes silently: whatever was in the box is
# reported on stderr and stored as cleared_input on the event. A relay is
# the one delivery path where the stderr half is worthless — it runs from
# _cmd_settle under `tmux run-shell -b -d`, with no operator attached — so
# the event is the only record, on the success *and* failure paths: a draft
# destroyed by a relay that then failed is exactly as destroyed.
print "\ndiscarded pane input is recorded on the relay event"
reset --max=3
verdict --findings 2 >/dev/null
# The box drains after the first read, so _send_to_pane confirms submission —
# a successful relay that still discarded a draft to make room for itself.
export STUB_PANE_TEXT='half-written note'
settle "$REVIEWER" >/dev/null
unset STUB_PANE_TEXT
eq "the relay succeeded" 2 "$(mget "$WORKER" pair_round)"
contains "and still recorded the discarded draft" "half-written note" \
	"$(ev pair-relay)"

# A box that will not drain is a *splice*, not a clear: the relay is appended
# to the draft and the partner receives `<draft><relay>` as one garbled
# instruction. cleared_input alone reported that identically to a clean
# discard — the worse outcome reading as the benign one, on the path where the
# stderr line that distinguishes them is unread by design. (PR #13 round 4.)
#
# Note what this case does *not* do: it does not fail. The Enter landed — the
# message went in, garbled onto the draft — and a splice that submits is not a
# delivery failure. Escalating on the splice itself would let unsent text in
# any worker pane halt an autonomous loop, so the splice stays record-only and
# the event is the only place it is visible. A splice whose Enter is *swallowed*
# is a different case, and does escalate — see below (issue #22).
print "\na relay that spliced says so instead of claiming a clear"
reset --max=3
verdict --findings 2 >/dev/null
# A foreign draft that will not clear, so our own text is appended to it. The
# Enter still lands, so the garbled line is genuinely submitted.
export STUB_PANE_TEXT='half-written human note'
export STUB_PANE_NO_CLEAR=1                     # …and it will not clear
settle "$REVIEWER" >/dev/null
unset STUB_PANE_TEXT STUB_PANE_NO_CLEAR
# The relay *succeeds*: the box drained, so the submit check is satisfied and
# rightly so. The round advances, the loop stays healthy, and the worker is now
# acting on a garbled line. Nothing about the delivery's return code can say
# so — which is the whole argument for the event key.
eq "the relay is reported as delivered" 2 "$(mget "$WORKER" pair_round)"
eq "and the loop stays active" active "$(mget "$WORKER" pair_state)"
contains "the event names what it spliced onto" "spliced_onto" \
	"$(ev pair-relay)"
contains "and quotes the draft it garbled" "half-written human note" \
	"$(print -r -- "$(ev pair-relay)" | jq -r '.spliced_onto')"
contains "with the pre-send read recorded too" "half-written human note" \
	"$(print -r -- "$(ev pair-relay)" | jq -r '.cleared_input')"

# A splice whose Enter is swallowed is an unsubmitted relay, and escalates like
# any other. It used to report success: the box read `<draft><relay>`, the
# prefix check saw text that was not ours, concluded ours had been submitted,
# and the round advanced on a message the worker never received (issue #22).
# The residue recorded before typing is stripped before that check, so the
# stall is visible again — and the escalation comes through the existing
# unsubmitted path, not a new splice-specific one.
print "\na spliced relay that never submits escalates like any other"
reset --max=3
verdict --findings 2 >/dev/null
export STUB_PANE_TEXT='half-written human note'
export STUB_PANE_NO_CLEAR=1                     # …will not clear…
export STUB_PANE_NO_DRAIN=1                     # …and the Enter is swallowed
settle "$REVIEWER" >/dev/null
unset STUB_PANE_TEXT STUB_PANE_NO_CLEAR STUB_PANE_NO_DRAIN
eq "the loop is marked stuck" stuck "$(mget "$REVIEWER" pair_state)"
contains "the stuck ping names the unsent text" \
	"sitting unsent in the input box" "$(apex pending)"
eq "the round is rolled back" 1 "$(mget "$WORKER" pair_round)"
contains "the failure is logged" '"event":"pair-relay-failed"' \
	"$(ev pair-relay-failed)"
contains "and still names what it spliced onto" "half-written human note" \
	"$(print -r -- "$(ev pair-relay-failed)" | jq -r '.spliced_onto // ""')"

print "\na drained box reports cleared, never spliced"
reset --max=3
verdict --findings 2 >/dev/null
export STUB_PANE_TEXT='a draft that does drain'
settle "$REVIEWER" >/dev/null
unset STUB_PANE_TEXT
eq "no spliced_onto when the clear took" "" \
	"$(print -r -- "$(ev pair-relay)" | jq -r '.spliced_onto // ""')"

print "\nan uneventful relay records no cleared_input"
reset --max=3
verdict --findings 2 >/dev/null
settle "$REVIEWER" >/dev/null
eq "no cleared_input key when the box was empty" "" \
	"$(print -r -- "$(ev pair-relay)" | jq -r '.cleared_input // ""')"
eq "and no spliced_onto either" "" \
	"$(print -r -- "$(ev pair-relay)" | jq -r '.spliced_onto // ""')"

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

# ── verdict refuses to trust findings nobody can read (issue #47) ────
# A reviewer could run `verdict --findings N` having only thought about the
# findings, without ever posting them anywhere outside its own pane — the
# relay would then send the fixer to read comments that don't exist.
print "\nverdict refuses findings with nothing published to back them"
reset
export STUB_GH_COMMENTS=0
out=$(verdict --findings 2 2>&1)
contains "the die names the PR" "PR #42" "$out"
contains "the die says nothing was published" "zero published comments" "$out"
contains "the die offers --note" "--note" "$out"
contains "the die offers --override" "--override" "$out"
eq "no verdict was recorded" "" "$(mget "$REVIEWER" verdict_findings)"
unset STUB_GH_COMMENTS

print "\n...but a --note is accepted as the evidence instead"
reset
export STUB_GH_COMMENTS=0
out=$(verdict --findings 2 --note 'no network, recording inline' 2>&1)
eq "verdict is recorded" 2 "$(mget "$REVIEWER" verdict_findings)"
contains "the reviewer sees it went through" "recorded for round" "$out"
unset STUB_GH_COMMENTS

print "\n...and --override records it anyway without a note"
reset
export STUB_GH_COMMENTS=0
out=$(verdict --findings 2 --override 2>&1)
eq "verdict is recorded despite no published comments" 2 "$(mget "$REVIEWER" verdict_findings)"
contains "the reviewer sees it went through" "recorded for round" "$out"
unset STUB_GH_COMMENTS

print "\n...and a real published comment satisfies the guard"
reset
export STUB_GH_COMMENTS=1
out=$(verdict --findings 3 2>&1)
eq "verdict is recorded" 3 "$(mget "$REVIEWER" verdict_findings)"
unset STUB_GH_COMMENTS

print "\n...and --none never needs published comments"
reset
export STUB_GH_COMMENTS=0
out=$(verdict --none 2>&1)
eq "an empty verdict is recorded" 0 "$(mget "$REVIEWER" verdict_findings)"
unset STUB_GH_COMMENTS

print "\n...and a GitHub query failure refuses rather than assumes"
reset
export STUB_GH_FAIL=1
out=$(verdict --findings 1 2>&1)
contains "the die says it could not confirm" "could not confirm" "$out"
eq "no verdict was recorded" "" "$(mget "$REVIEWER" verdict_findings)"
unset STUB_GH_FAIL

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
