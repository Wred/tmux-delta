#!/usr/bin/env zsh

# Crash recovery for apex members (github issue #18).
#
# Three things are under test, all of them things that were silently wrong
# before and that no live tmux server is needed to pin down:
#
#   1. Conversation identity. A worker and its reviewer share a worktree, so
#      "newest Claude Code transcript for this directory" is a coin flip between
#      them. _claude_session_for must pick by the opening prompt instead, and
#      lib/agent-prompts.sh is the single copy of the text both the launcher and
#      the matcher use — a drift between the two is a wrong resume that looks
#      like a right one.
#   2. `recover` itself: which dead members it offers, which it refuses, and
#      what it actually does on --yes (new pane, resumed conversation, member
#      record moved to the new pane key, old key retired).
#   3. The pane collision. An apex spawn into a session that already exists must
#      land in its own new pane and must NOT rewrite that session's
#      CODING_AGENT_* env, which is what made one pane register as two members
#      with a concatenated "issue:Npr:M" task.
#
# tmux, git, gh and the agent binary are all stubbed; nothing here attaches to a
# server or starts an agent.

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-recover-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq() {
	if [[ $2 == $3 ]]; then ok "$1"
	else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}
neq() {
	if [[ $2 != $3 ]]; then ok "$1"
	else bad "$1" "expected anything but: ${(qqq)2}"; fi
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

# ─── shared fake environment ─────────────────────────────────────────

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"
export TMUX=fake-socket
# `recover` waits for a resumed pane's agent to come up before nudging it. The
# stub pane never execs anything, so every recover of a resumable member would
# otherwise pay the full real-world ceiling before giving up.
export APEX_RECOVER_NUDGE_WAIT=1
# Likewise for the confirmation wait: no stub pane ever starts a turn, so every
# nudge here is delivered-but-unconfirmed and would pay the full ceiling.
export APEX_RECOVER_NUDGE_CONFIRM=1
export STUB_PANE_CMD=""
export XDG_CACHE_HOME="$TMPROOT/cache"
APEX_ROOT="$XDG_CACHE_HOME/tmux-delta/apex"

# tmux stub. State lives in files under $STUB so it survives the many separate
# processes one tmux-apex.sh run forks, and every invocation is logged so a test
# can assert on what was NOT called (the env-rewrite collision is an absence).
STUB="$TMPROOT/stub"; mkdir -p "$STUB"
export STUB
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env zsh
emulate -L zsh
print -r -- "$*" >> "$STUB/log"
_key() { print -r -- "${1//[^a-zA-Z0-9]/_}" }
case "$1" in
display-message)
	# display-message -p [-t TARGET] FORMAT
	local target="" fmt="${@[-1]}"
	[[ $3 == -t ]] && target="$4"
	if [[ $target == %* ]]; then
		# pane target: resolve the pane's session (or echo the pane id back)
		case "$fmt" in
			'#S') awk -F'\t' -v p="$target" '$1==p{print $2}' "$STUB/panes" 2>/dev/null ;;
			# What `_pane_is_agent` asks. Empty by default, so a freshly split
			# pane reads as the shell it actually is for the first second or
			# two — which is the case `recover` has to refuse to type into.
			'#{pane_current_command}') print -r -- "${STUB_PANE_CMD:-}" ;;
			*)    print -r -- "$target" ;;
		esac
	elif [[ -n $target ]]; then
		# session target: its most recent pane
		awk -F'\t' -v s="$target" '$2==s{p=$1} END{if (p != "") print p}' "$STUB/panes" 2>/dev/null
	else
		print -r -- "${STUB_SESSION:-manager}"
	fi
	;;
show-option)
	local scope=session target key
	if [[ $2 == -p ]]; then scope=pane; target="$4"; key="$6"
	else target="$3"; key="$5"; fi
	[[ $2 == -p ]] || { [[ $2 == -t ]] && target="$3" && key="$5" }
	cat "$STUB/opt.${scope}.$(_key "$target").$(_key "$key")" 2>/dev/null
	;;
set-option)
	local -a a=("$@"); shift
	local scope=session unset=no target="" key="" val=""
	while (( $# )); do
		case "$1" in
			-p) scope=pane; shift ;;
			-g) shift ;;
			-u) unset=yes; shift ;;
			-t) target="$2"; shift 2 ;;
			*)  if [[ -z $key ]]; then key="$1"; else val="$1"; fi; shift ;;
		esac
	done
	local f="$STUB/opt.${scope}.$(_key "$target").$(_key "$key")"
	if [[ $unset == yes ]]; then rm -f "$f"; else print -r -- "$val" > "$f"; fi
	;;
set-environment)
	local -a a=("$@"); shift
	local unset=no session="" name="" val=""
	while (( $# )); do
		case "$1" in
			-u) unset=yes; shift ;;
			-t) session="$2"; shift 2 ;;
			*)  if [[ -z $name ]]; then name="$1"; else val="$1"; fi; shift ;;
		esac
	done
	local f="$STUB/env.$(_key "$session").$(_key "$name")"
	if [[ $unset == yes ]]; then rm -f "$f"; else print -r -- "$val" > "$f"; fi
	;;
has-session)
	# Exits here rather than falling through: the stub ends in `exit 0`, and a
	# has-session that always succeeds makes every dead session look alive.
	local n="${2#-t}"; n="${n#=}"
	grep -qxF "$n" "$STUB/sessions" 2>/dev/null
	exit $?
	;;
new-session)
	# new-session -ds NAME -c DIR
	local n=""; local -a a=("$@")
	local i
	for (( i = 1; i <= ${#a}; i++ )); do
		[[ ${a[i]} == -ds ]] && n="${a[i+1]}"
		[[ ${a[i]} == -s  ]] && n="${a[i+1]}"
	done
	[[ -n $n ]] || exit 1
	print -r -- "$n" >> "$STUB/sessions"
	local p="%$(( $(grep -c '' "$STUB/panes" 2>/dev/null) + 90 ))"
	printf '%s\t%s\t\n' "$p" "$n" >> "$STUB/panes"
	;;
split-window)
	local s="" i; local -a a=("$@")
	for (( i = 1; i <= ${#a}; i++ )); do [[ ${a[i]} == -t ]] && s="${a[i+1]}"; done
	local p="%$(( $(grep -c '' "$STUB/panes" 2>/dev/null) + 90 ))"
	printf '%s\t%s\t%s\n' "$p" "$s" "${a[-1]}" >> "$STUB/panes"
	print -r -- "$p"
	;;
list-panes)
	# Honours the two formats the scripts actually ask for: bare "#{pane_id}"
	# and the member key "#{session_name}:#{pane_id}".
	local fmt="${@[-1]}"
	if [[ $2 == -a ]]; then
		if [[ $fmt == *'#{session_name}'* ]]; then
			awk -F'\t' '{print $2 ":" $1}' "$STUB/panes" 2>/dev/null
		else
			cut -f1 "$STUB/panes" 2>/dev/null
		fi
	else
		local s="$3"
		awk -F'\t' -v s="$s" '$2==s{print $1}' "$STUB/panes" 2>/dev/null
	fi
	;;
show-environment)
	# show-environment [-t SESSION] NAME -> "NAME=value", or exit 1 when unset,
	# which is how tmux-dev-layout.sh reads its per-spawn configuration.
	local session="" name=""
	shift
	while (( $# )); do
		case "$1" in
			-t) session="$2"; shift 2 ;;
			*)  name="$1"; shift ;;
		esac
	done
	local f="$STUB/env.$(_key "$session").$(_key "$name")"
	[[ -r $f ]] || exit 1
	print -r -- "${name}=$(cat "$f")"
	;;
list-sessions) cat "$STUB/sessions" 2>/dev/null ;;
kill-pane|kill-session|refresh-client|switch-client|run-shell|list-clients) : ;;
*) : ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"

: > "$STUB/log"; : > "$STUB/panes"; : > "$STUB/sessions"

stub_reset_log() { : > "$STUB/log" }
pane_cmd()       { awk -F'\t' -v p="$1" '$1==p{print $3}' "$STUB/panes" }
# The launch command reaches tmux ${(q)}-quoted, so every space in a prompt is a
# backslash-space. Assertions want the human-readable text.
pane_cmd_plain() { local c; c=$(pane_cmd "$1"); print -r -- "${c//\\/}" }
# Both read state that may legitimately be unset; a missing file is an empty
# value, not a test crash (err_return is on).
session_env()    { cat "$STUB/env.$(print -r -- "${1//[^a-zA-Z0-9]/_}").$(print -r -- "${2//[^a-zA-Z0-9]/_}")" 2>/dev/null || true }
pane_opt()       { cat "$STUB/opt.pane.$(print -r -- "${1//[^a-zA-Z0-9]/_}").$(print -r -- "${2//[^a-zA-Z0-9]/_}")" 2>/dev/null || true }

MANAGER=manager
export STUB_SESSION="$MANAGER"
print -r -- manager > "$STUB/opt.session.manager._apex_role"
print -r -- "$MANAGER" >> "$STUB/sessions"

# ─── fake Claude Code transcripts ────────────────────────────────────

# Two conversations in ONE worktree — a worker on issue 42 and a reviewer on
# PR 43 — which is the case that makes "newest transcript wins" wrong.
export HOME="$TMPROOT/home"
WT="$TMPROOT/wt/repo-fix-issue-42"
mkdir -p "$WT"
PROJ="$HOME/.claude/projects/${WT//[^a-zA-Z0-9]/-}"
mkdir -p "$PROJ"

transcript() {
	# Separate statements on purpose: zsh expands every word of a `local` before
	# the builtin runs, so `local id="$1" f="$PROJ/${id}.jsonl"` would use the
	# OUTER id and silently write to "$PROJ/.jsonl".
	local id="$1" cwd="$2" text="$3"
	local f="$PROJ/${id}.jsonl"
	jq -nc --arg c "$cwd" --arg s "$id" '{type:"mode", sessionId:$s, cwd:null}'  > "$f"
	jq -nc --arg c "$cwd" --arg t "$text" \
		'{type:"user", cwd:$c, message:{role:"user", content:$t}}'              >> "$f"
	print -r -- "$f"
}

source "$SCRIPTS/lib/agent-prompts.sh"

WORKER_ID=11111111-1111-1111-1111-111111111111
REVIEW_ID=22222222-2222-2222-2222-222222222222
transcript "$WORKER_ID" "$WT" "$(delta_task_prompt 42 '' autonomous)" >/dev/null
sleep 0.05
# The reviewer's is NEWER, so any newest-wins matcher returns it for both.
# Claude Code never stores a slash command verbatim — it records the expanded
# form. A reviewer transcript that begins with the literal "/my-pr-review 43"
# does not exist, so the fixture must not pretend otherwise.
transcript "$REVIEW_ID" "$WT" \
	'<command-message>my-pr-review</command-message>
<command-name>/my-pr-review</command-name>
<command-args>43</command-args>' >/dev/null

# A transcript in the same project dir but a different cwd — must never match.
transcript 33333333-3333-3333-3333-333333333333 "$TMPROOT/elsewhere" \
	"$(delta_task_prompt 42 '' autonomous)" >/dev/null

# ─── 1. conversation identity ────────────────────────────────────────

print "conversation identity"

# Load just the discovery helpers out of tmux-apex.sh.
eval "$(sed -n '/^_claude_project_dirs()/,/^}/p; /^_claude_normalize_prompt()/,/^}/p;
	/^_claude_session_for()/,/^}/p' "$SCRIPTS/tmux-apex.sh")"
# The extraction is line-anchored, so a rename, an indent, `name () {`, or a
# nested `}` at column zero makes sed emit nothing or half a function. Without
# this check the section below would "pass" against functions that do not exist.
for fn in _claude_project_dirs _claude_normalize_prompt _claude_session_for; do
	(( ${+functions[$fn]} )) || {
		print -u2 "apex-recover.test.sh: could not extract $fn from tmux-apex.sh"
		exit 1
	}
done

eq "worker's own conversation, not the newer reviewer's" \
	"$WORKER_ID" "$(_claude_session_for "$WT" "$(delta_task_marker 42 '')")"
eq "reviewer's own conversation" \
	"$REVIEW_ID" "$(_claude_session_for "$WT" "$(delta_task_marker '' 43)")"
eq "unknown task matches nothing" \
	"" "$(_claude_session_for "$WT" "$(delta_task_marker 99 '')" || true)"
eq "a transcript for another cwd is never used" \
	"" "$(_claude_session_for "$TMPROOT/no-such-tree" '' || true)"

# The normalizer is what makes the reviewer case work; pin its shapes directly.
eq "an expanded slash command folds back to what was typed" "/my-pr-review 43" \
	"$(_claude_normalize_prompt '<command-name>/my-pr-review</command-name>
<command-args>43</command-args>')"
eq "an argument-less slash command keeps no trailing space" "/compact" \
	"$(_claude_normalize_prompt '<command-name>/compact</command-name>')"
eq "an ordinary prompt passes through untouched" "GitHub issue #42. Read it" \
	"$(_claude_normalize_prompt 'GitHub issue #42. Read it')"

# A marker is matched as a prefix, so a low-numbered task must not match a
# higher-numbered one that starts with the same digits. The issue marker is
# terminated by its own "."; the PR marker is not, and "/my-pr-review 4" does
# prefix "/my-pr-review 43" — which had recover on PR #4 resume PR #43's review.
# Only the PR-43 and issue-42 transcripts exist in this worktree, so anything
# these two return is a wrong match.
eq "a low-numbered PR does not match a higher one" "" \
	"$(_claude_session_for "$WT" "$(delta_task_marker '' 4)" || true)"
eq "a low-numbered issue does not match a higher one" "" \
	"$(_claude_session_for "$WT" "$(delta_task_marker 4 '')" || true)"
eq "the exact PR still matches" "$REVIEW_ID" \
	"$(_claude_session_for "$WT" "$(delta_task_marker '' 43)")"
eq "the exact issue still matches" "$WORKER_ID" \
	"$(_claude_session_for "$WT" "$(delta_task_marker 42 '')")"

# The marker must be a prefix of every prompt variant for the same task, or
# matching silently fails for whichever mode wasn't tested.
m=$(delta_task_marker 42 '')
for mode in autonomous interactive; do
	p=$(delta_task_prompt 42 '' $mode)
	if [[ $p == "$m"* ]]; then ok "marker is a prefix of the $mode issue prompt"
	else bad "marker is a prefix of the $mode issue prompt" "prompt: ${(qqq)p}"; fi
done
p=$(delta_task_prompt '' 43 review)
eq "marker is the whole review prompt" "$p" "$(delta_task_marker '' 43)"

# An issue's stated diagnosis is often wrong (#35/#45, #60, #43), and the agent
# in the worktree is the cheapest place to catch that. The instruction belongs
# in the *managed* prompt: the task prompt doubles as the transcript-matching
# key above, so growing it would break recovery matching (#18).
# The wording is role-specific, so each role is pinned to the tail only its own
# branch produces — asserting on the shared opening would pass even if the
# reviewing-role override were deleted. `monitor` is the reviewing role apex
# spawns (`--role worker|monitor`); `reviewer` is the pair vocabulary's name for
# it, covered so a rename cannot hand a reviewer the implementer's wording.
for r in worker monitor reviewer; do
	mp=$(delta_managed_prompt $r tmux-delta)
	contains "the $r managed prompt tells it not to trust the diagnosis" \
		"Do not trust a task's stated diagnosis" "$mp"
	contains "…and to verify the claim first" "verify that claim yourself" "$mp"
	if [[ $r == worker ]]; then
		contains "…and tells a $r to fix the real cause" \
			"fix the real cause" "$mp"
		lacks "…not to write a review it does not write" \
			"say so in your review" "$mp"
	else
		contains "…and tells a $r to report it in the review" \
			"say so in your review" "$mp"
		lacks "…not to fix it itself" "fix the real cause" "$mp"
	fi
done
lacks "the verify gate is not in the task prompt" \
	"Do not trust a task's stated diagnosis" "$(delta_task_prompt 42 '' autonomous)"
eq "…and an unmanaged session gets no prompt at all" "" \
	"$(delta_managed_prompt '' tmux-delta)"

# ─── 2. resume argv ──────────────────────────────────────────────────

print "\nresume argv"

argv_for() {
	DELTA_AGENT_LIBDIR="$SCRIPTS/lib"
	typeset -ga agent_argv=() agent_argv_fresh=(); unset agent_argv_fresh_set
	DELTA_AGENT_MODEL="" DELTA_AGENT_FLAGS="" DELTA_AGENT_SYSTEM="" \
	DELTA_AGENT_PROMPT="$1" DELTA_AGENT_RESUME="$2" DELTA_AGENT_MANAGED="$3" \
		source "$SCRIPTS/lib/agents/claude.sh"
	DELTA_AGENT_MODEL="" DELTA_AGENT_FLAGS="" DELTA_AGENT_SYSTEM="" \
	DELTA_AGENT_PROMPT="$1" DELTA_AGENT_RESUME="$2" DELTA_AGENT_MANAGED="$3" delta_agent_argv
}

argv_for "the task" "$WORKER_ID"
eq "resume wins over the prompt" "--resume $WORKER_ID" "${(j: :)agent_argv}"
# agent-adapter.sh fires the fresh fallback on ANY non-zero exit, not only on
# "nothing to resume". Arming it on a prompt-carrying invocation means an
# interrupted or crashed agent silently redoes an autonomous task — duplicate
# commits, duplicate draft PR. recover only ever passes an id whose transcript
# it just found, so there is nothing for a fallback to rescue here.
eq "a resumed agent never re-runs its task on a bad exit" 0 "${+agent_argv_fresh_set}"

argv_for "the task" ""
eq "no resume id: plain prompt, no --resume" "the task" "${(j: :)agent_argv}"

# The promptless --continue path keeps its fallback: resuming fails on a
# worktree the agent has never seen, and the fallback there is a bare
# interactive session, which is harmless to enter twice.
argv_for "" ""
eq "a promptless launch still falls back" 1 "${+agent_argv_fresh_set}"
eq "…from --continue" "--continue" "${(j: :)agent_argv}"

# A managed pane is read back with capture-pane, where a grayed-out prompt
# suggestion is byte-identical to real unsubmitted input (#20). Every apex
# read of an input box — splice detection, box-drained confirmation, the
# stuck-pane heuristics — trusts that box, so the suggestion has to be off.
argv_for "the task" "" 1
eq "a managed launch disables prompt suggestions" \
	"--prompt-suggestions false the task" "${(j: :)agent_argv}"
# The CLI flag alone is a no-op for the interactive TUI — it only governs the
# print/SDK prompt_suggestion message, which is why #35 shipped it and the
# workers kept painting ghost text. The env var is the half that actually
# suppresses the suggestion, so pin it separately (#45).
eq "…via the env var the interactive TUI actually reads" false \
	"$CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"

argv_for "the task" "$WORKER_ID" 1
eq "…on the resume path too" \
	"--prompt-suggestions false --resume $WORKER_ID" "${(j: :)agent_argv}"

# The picker and dev-layout launch panes a human types into, and they pass no
# managed flag. Suggestions are a typing convenience: leave them alone there.
argv_for "the task" "" ""
eq "an unmanaged launch leaves prompt suggestions alone" \
	"the task" "${(j: :)agent_argv}"
# In a subshell with the var explicitly cleared first, because delta_agent_argv
# exports into its caller: asserting on the ambient shell would silently become
# a tautology the moment a managed argv_for is inserted above this line.
eq "…and plants no suppression env var" 0 \
	"$( unset CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION
	    argv_for "the task" "" ""
	    print -r -- "${+CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION}" )"

source "$SCRIPTS/lib/agent-launch.sh"
contains "launch command exports the managed flag" "DELTA_AGENT_MANAGED=1" \
	"$(delta_agent_launch_cmd claude '' '' '' p /tmp/w /a/adapter.sh sid-9 1)"
contains "launch command exports an empty managed flag when omitted" \
	"DELTA_AGENT_MANAGED=''" \
	"$(delta_agent_launch_cmd claude '' '' '' p /tmp/w /a/adapter.sh)"
contains "launch command exports the resume id" "DELTA_AGENT_RESUME=sid-9" \
	"$(delta_agent_launch_cmd claude '' '' '' p /tmp/w /a/adapter.sh sid-9)"
contains "launch command exports an empty resume id when omitted" \
	"DELTA_AGENT_RESUME=''" \
	"$(delta_agent_launch_cmd claude '' '' '' p /tmp/w /a/adapter.sh)"

# ─── 3. recover ──────────────────────────────────────────────────────

print "\nrecover"

member() {
	# member <key> <json-patch>
	local f="$APEX_ROOT/$MANAGER/members/$1.json"
	mkdir -p "${f:h}"
	print -r -- "$2" | jq . > "$f"
}

DEAD_WT="$WT"
GONE_WT="$TMPROOT/wt/deleted-worktree"
member "repo-fix-issue-42:%7" "$(jq -nc --arg wt "$DEAD_WT" \
	'{role:"worker", worktree:$wt, issue:"42", review_pr:"", agent:"claude",
	  mode:"autonomous", model:"opus", permission_mode:"bypassPermissions",
	  profile:"", status:"idle", seq:1}')"
member "repo-gone-issue-9:%8" "$(jq -nc --arg wt "$GONE_WT" \
	'{role:"worker", worktree:$wt, issue:"9", review_pr:"", agent:"claude"}')"

apex() { "$SCRIPTS/tmux-apex.sh" "$@" }

out=$(apex recover 2>&1)
contains "dry run offers the dead member"        "repo-fix-issue-42:%7" "$out"
contains "dry run names the resumable id"        "resume $WORKER_ID"    "$out"
contains "dry run keeps role and task visible"   "role=worker task=issue:42" "$out"
contains "dry run skips a member whose worktree is gone" \
	"repo-gone-issue-9:%8  — SKIP: worktree gone" "$out"
contains "dry run says how to act"               "Re-run with --yes"    "$out"
eq "dry run creates no session" "" "$(grep -v "^$MANAGER\$" "$STUB/sessions" || true)"

# A member whose pane is alive is not a recovery candidate.
printf '%%7\t%s\t\n' repo-fix-issue-42 >> "$STUB/panes"
print -r -- repo-fix-issue-42 >> "$STUB/sessions"
out=$(apex recover 2>&1)
lacks "a live member is never offered" "repo-fix-issue-42:%7  — role" "$out"
# Put it back to dead for the real run.
# grep exits 1 when nothing survives the filter, which err_return would treat
# as a test crash — these are edits, not assertions.
{ grep -v '^%7	' "$STUB/panes" > "$STUB/panes.new" || true; }
mv "$STUB/panes.new" "$STUB/panes"
{ grep -v '^repo-fix-issue-42$' "$STUB/sessions" > "$STUB/sessions.new" || true; }
mv "$STUB/sessions.new" "$STUB/sessions"

# ...but "alive" has to mean the pane is alive *in that member's session*. A
# restarted tmux server hands out %0, %1, … again, so pane %7 almost certainly
# exists somewhere — and a bare pane-id check would call every crashed member
# healthy, making recover skip exactly the members it exists to recover.
printf '%%7\t%s\t\n' some-unrelated-session >> "$STUB/panes"
print -r -- some-unrelated-session >> "$STUB/sessions"
out=$(apex recover 2>&1)
contains "a recycled pane id elsewhere does not fake a live member" \
	"repo-fix-issue-42:%7" "$out"
{ grep -v '^%7\t' "$STUB/panes" > "$STUB/panes.new" || true; }
mv "$STUB/panes.new" "$STUB/panes"
{ grep -v '^some-unrelated-session$' "$STUB/sessions" > "$STUB/sessions.new" || true; }
mv "$STUB/sessions.new" "$STUB/sessions"

stub_reset_log
out=$(apex recover --yes 2>&1)
contains "recover reports the resumed conversation" "resumed conversation $WORKER_ID" "$out"

new_pane=$(awk -F'\t' '$2=="repo-fix-issue-42"{p=$1} END{print p}' "$STUB/panes")
if [[ -n $new_pane ]]; then ok "recover created an agent pane"
else bad "recover created an agent pane" "$(cat "$STUB/panes")"; fi

cmd=$(pane_cmd "$new_pane")
contains "the pane resumes that exact conversation" "DELTA_AGENT_RESUME=$WORKER_ID" "$cmd"
contains "the pane runs in the surviving worktree" "direnv exec $DEAD_WT" "$cmd"
contains "a recovered worker is still told it is managed" \
	"managed worker agent under tmux-delta apex mode" "$(pane_cmd_plain "$new_pane")"

eq "the member record moved to the new pane key" 1 \
	"$(print -n $(ls "$APEX_ROOT/$MANAGER/members/repo-fix-issue-42:${new_pane}.json" 2>/dev/null | grep -c ''))"
eq "the stale pane key is retired" 0 \
	"$(ls "$APEX_ROOT/$MANAGER/members/repo-fix-issue-42:%7.json" 2>/dev/null | grep -c '' || true)"

rec=$(cat "$APEX_ROOT/$MANAGER/members/repo-fix-issue-42:${new_pane}.json")
eq "the recovered record keeps the conversation id" "$WORKER_ID" \
	"$(print -r -- "$rec" | jq -r '.agent_session_id')"
eq "the recovered record keeps role"  worker "$(print -r -- "$rec" | jq -r '.role')"
eq "the recovered record keeps issue" 42     "$(print -r -- "$rec" | jq -r '.issue')"
eq "the recovered record carries no PR"  ""  "$(print -r -- "$rec" | jq -r '.review_pr')"
eq "the recovered pane is tagged with one task" "issue:42" "$(pane_opt "$new_pane" @apex_task)"

# The pane exists but is still a shell, so the continuation cannot be
# delivered. The one thing recover must not do here is stay quiet about it:
# "the pane is back" and "the worker is working" are different claims, and
# reporting the first as the second is how two members sat at an empty prompt
# for ~24h (issue #42).
contains "recover says when it could not nudge a resumed member" "NOT nudged" "$out"
contains "…and says the member will not start on its own" "waiting at an empty prompt" "$out"
contains "…and hands over the send to run by hand" "send repo-fix-issue-42:" "$out"
cev=$(grep -F '"event":"recover-continue"' "$APEX_ROOT/$MANAGER/events.jsonl" | tail -1)
eq "…and records the undelivered nudge" false "$(print -r -- "$cev" | jq -r '.delivered')"

ev=$(grep -F '"event":"recover"' "$APEX_ROOT/$MANAGER/events.jsonl" | tail -1)
eq "the recover event records that it resumed" true "$(print -r -- "$ev" | jq -r '.resumed')"
eq "the recover event names the pane it replaced" "repo-fix-issue-42:%7" \
	"$(print -r -- "$ev" | jq -r '.previous_session')"

# Running it again must not stack a second pane on the same task.
before=$(grep -c '' "$STUB/panes")
out=$(apex recover --yes 2>&1)
lacks "a second recover leaves the member alone" "repo-fix-issue-42" "$out"
eq "…and adds no pane" "$before" "$(grep -c '' "$STUB/panes")"

# ─── 4. no conversation to resume ────────────────────────────────────

print "\nno conversation to resume"

NOWT="$TMPROOT/wt/never-ran-issue-77"; mkdir -p "$NOWT"
member "never-ran-issue-77:%3" "$(jq -nc --arg wt "$NOWT" \
	'{role:"worker", worktree:$wt, issue:"77", review_pr:"", agent:"claude",
	  mode:"autonomous"}')"
out=$(apex recover --yes never-ran-issue-77:%3 2>&1)
contains "says plainly that nothing was resumable" "fresh conversation" "$out"
pane=$(awk -F'\t' '$2=="never-ran-issue-77"{p=$1} END{print p}' "$STUB/panes")
cmd=$(pane_cmd "$pane")
plain=$(pane_cmd_plain "$pane")
contains "starts a fresh session on the same task instead" \
	"DELTA_AGENT_RESUME=''" "$plain"
contains "…with the task prompt" "GitHub issue #77." "$plain"
ev=$(grep -F '"event":"recover"' "$APEX_ROOT/$MANAGER/events.jsonl" | tail -1)
eq "the event does not claim a resume" false "$(print -r -- "$ev" | jq -r '.resumed')"

# Selecting one member must leave the others alone.
lacks "a named member is recovered alone" "repo-gone-issue-9" "$out"

# ─── 4b. a resumed member is told to continue (issue #42) ────────────

print "\na resumed member is nudged to continue"

# DELTA_AGENT_RESUME takes precedence over DELTA_AGENT_PROMPT (section 2), so a
# recovered agent restores its context and then waits at an empty prompt: it
# resumes *waiting*, not *working*. `starting` was not reportable, no hook ever
# fired, and nothing in the system could say so — two workers sat like that for
# ~24h. `recover` now delivers the continuation a human otherwise has to type.
#
# Reusing $WT keeps the worker transcript resolvable: `recover` reads the id off
# disk and refuses to trust the record alone, so a member with no transcript
# takes the fresh path instead and is never nudged.
member "resumed:%21" "$(jq -nc --arg wt "$WT" \
	'{role:"worker", worktree:$wt, issue:"42", review_pr:"", agent:"claude",
	  mode:"autonomous", status:"idle", seq:6}')"

stub_reset_log
out=$(STUB_PANE_CMD=node apex recover --yes resumed:%21 2>&1)
# The stub pane runs no agent, so nothing ever writes a turn to the new
# member's record: the nudge is delivered and *not* confirmed. That is the
# honest reading here, and the line has to say so — see section 4c.
contains "the resumed member is nudged" "Nudged it" "$out"
contains "…and the unconfirmed nudge is not claimed as a start" \
	"has NOT started a turn" "$out"
lacks "…so it never says the member started" "started a turn." \
	"${out%%has NOT started*}"
contains "…and it hands over the send to re-deliver it" "send resumed:" "$out"
contains "…and points at the stale-start report as the backstop" \
	"status=starting" "$out"
lacks "…and does not also claim nothing was delivered" "NOT nudged" "$out"

keys=$(grep -F 'send-keys' "$STUB/log")
contains "the continuation is typed into the new pane" "[apex from:recover]" "$keys"
contains "…and tells it to pick up where it left off" "Pick up where you left off" "$keys"
contains "…and is submitted" "Enter" "$keys"

# The whole point of the resume path is that a recovered agent cannot re-run its
# task and duplicate the commits, the comment and the PR. A continuation is not
# a task prompt, and this is the assertion that keeps it that way.
lacks "the nudge is not the task prompt" \
	"$(delta_task_prompt 42 '' autonomous)" "$keys"
lacks "…so it cannot re-assign the issue to itself" "--add-assignee" "$keys"

cev=$(grep -F '"event":"recover-continue"' "$APEX_ROOT/$MANAGER/events.jsonl" | tail -1)
eq "the delivery is recorded" true "$(print -r -- "$cev" | jq -r '.delivered')"
eq "…separately from whether it was acted on" false \
	"$(print -r -- "$cev" | jq -r '.confirmed')"
contains "…against the new member key" "resumed:%" \
	"$(print -r -- "$cev" | jq -r '.session')"

# A member recovered onto a *fresh* conversation was launched with the task
# prompt and is already working; nudging it would be a second instruction on
# top of the first, and the two would race.
FRESHWT="$TMPROOT/wt/no-transcript-issue-78"; mkdir -p "$FRESHWT"
member "no-transcript-issue-78:%23" "$(jq -nc --arg wt "$FRESHWT" \
	'{role:"worker", worktree:$wt, issue:"78", review_pr:"", agent:"claude",
	  mode:"autonomous"}')"
out=$(STUB_PANE_CMD=node apex recover --yes no-transcript-issue-78:%23 2>&1)
contains "a fresh recover says so"     "fresh conversation" "$out"
lacks "…and is not nudged"             "Nudged it to continue" "$out"
lacks "…nor reported as needing one"   "NOT nudged" "$out"

# The knob exists for an operator who wants the old behaviour. Turning the
# nudge off must not turn the reporting off with it — a silently unnudged
# member is the bug, not the nudge.
member "optout:%22" "$(jq -nc --arg wt "$WT" \
	'{role:"worker", worktree:$wt, issue:"42", review_pr:"", agent:"claude",
	  mode:"autonomous", status:"idle", seq:6}')"
out=$(STUB_PANE_CMD=node APEX_RECOVER_NUDGE=0 apex recover --yes optout:%22 2>&1)
contains "the nudge can be turned off"      "NOT nudged (APEX_RECOVER_NUDGE=0)" "$out"
contains "…and it still says who needs one" "send optout:" "$out"

# ─── 4c. the nudge is confirmed, not assumed (issue #42, review) ─────

print "\na delivered nudge is confirmed against member state"

# `_pane_is_agent` is the strongest precondition available before typing, and it
# proves the agent *execed* — not that its TUI accepts input. On the --resume
# path claude then spends time restoring the conversation, and the longer the
# transcript the wider that window; keystrokes typed into it are dropped and
# `_send_to_pane` cannot tell, because an undrawn input box reads exactly like a
# ready empty one. Asserting "Nudged it to continue" off a successful delivery
# would relocate the false claim this whole change exists to delete one step
# later, so the outcome is read back off the member's own state instead.
confirmed() {  # confirmed <key> — "yes" if the member is judged to have started
	zsh -c 'source "'"$SCRIPTS"'/tmux-apex.sh" >/dev/null 2>&1
		if _apex_nudge_confirmed "'"$MANAGER"'" "'"$1"'" 0; then
			print yes
		else
			print no
		fi'
}

member "confirm-working:%40" '{"status":"working","seq":1}'
eq "a member that took a turn counts as started" yes \
	"$(confirmed confirm-working:%40)"

member "confirm-idle:%41" '{"status":"idle","seq":2}'
eq "…and so does one that already finished one" yes \
	"$(confirmed confirm-idle:%41)"

member "confirm-attention:%42" '{"status":"attention","seq":3}'
eq "…and one that stopped to ask something" yes \
	"$(confirmed confirm-attention:%42)"

member "confirm-stuck:%43" '{"status":"starting","seq":0}'
eq "a member still at seq 0 has not started" no \
	"$(confirmed confirm-stuck:%43)"

# seq is what the hooks bump, and a bump can land before the status write is
# read back; either half is enough, so neither can strand a working member.
member "confirm-raced:%44" '{"status":"starting","seq":1}'
eq "…but a bumped seq alone is enough" yes \
	"$(confirmed confirm-raced:%44)"

# Fail towards "not confirmed": an unreadable record must not license the
# claim. The stale-start report picks the member up either way.
eq "an absent record is never confirmation" no \
	"$(confirmed confirm-missing:%45)"

# ─── 5. recycled pane ids ────────────────────────────────────────────

print "\nrecycled pane ids"

# A restarted tmux server hands out %0, %1, … again, so a durable member file
# can be a *different* member's record from before the restart. Registration
# used to merge onto it, producing one pane that was both members at once
# (role from the new spawn, issue from the old) — the corruption in issue #18.
member "recycled:%1" "$(jq -nc --arg wt "$WT" \
	'{role:"worker", worktree:$wt, issue:"42", review_pr:"", agent:"claude",
	  status:"idle", seq:9}')"
printf '%%1\trecycled\t\n' >> "$STUB/panes"
print -r -- recycled >> "$STUB/sessions"

out=$(apex _register-member '%1' "$MANAGER" monitor pr:43 "$WT" '' '' review claude '' '' 43 2>&1)
rec=$(cat "$APEX_ROOT/$MANAGER/members/recycled:%1.json")
contains "registration warns that it replaced a stale record" "replacing a stale record" "$out"
eq "the new member's role stands"      monitor "$(print -r -- "$rec" | jq -r '.role')"
eq "the new member's PR stands"        43      "$(print -r -- "$rec" | jq -r '.review_pr')"
eq "the old member's issue is gone"    ""      "$(print -r -- "$rec" | jq -r '.issue')"
eq "no stale sequence number survives" 0       "$(print -r -- "$rec" | jq -r '.seq')"

contains "the replacement is recorded where stderr cannot be swallowed" \
	'"event":"stale-record-replaced"' "$(cat "$APEX_ROOT/$MANAGER/events.jsonl")"

# Registration is the birth of a member, so it never inherits a conversation id
# — not even from a record on the same key with the same task. Pane ids get
# recycled, and a new agent pointed at a dead agent's conversation is the same
# bug as the stale record above, just harder to see.
apex_root_file="$APEX_ROOT/$MANAGER/members/recycled:%1.json"
jq '. + {agent_session_id:"stale-id"}' "$apex_root_file" > "$apex_root_file.t"
mv "$apex_root_file.t" "$apex_root_file"
apex _register-member '%1' "$MANAGER" monitor pr:43 "$WT" '' '' review claude '' '' 43 >/dev/null 2>&1
eq "registration never inherits a conversation id" "" \
	"$(jq -r '.agent_session_id' "$apex_root_file")"
apex _register-member '%1' "$MANAGER" monitor pr:43 "$WT" '' '' review claude '' '' 43 fresh-id >/dev/null 2>&1
eq "…and takes the one it is given" "fresh-id" \
	"$(jq -r '.agent_session_id' "$apex_root_file")"

# ─── 6. one task per member ──────────────────────────────────────────

print "\none task per member"

# @apex_task must never read "issue:42pr:43". relink builds it from the durable
# record, so a record that is already corrupt must still produce one legible
# task rather than propagating the concatenation onto a live pane.
member "both:%2" "$(jq -nc --arg wt "$WT" \
	'{role:"worker", worktree:$wt, issue:"42", review_pr:"43", agent:"claude"}')"
printf '%%2\tboth\t\n' >> "$STUB/panes"
print -r -- both >> "$STUB/sessions"
rm -f "$STUB/opt.pane."*
# relink matches a durable record by the *real* cwd, so actually be there —
# a `PWD=...` assignment prefix is reset by the child shell.
( cd "$WT" && STUB_SESSION=both TMUX_PANE='%2' apex relink ) >/dev/null 2>&1 || true
task=$(pane_opt '%2' @apex_task)
lacks "relink never concatenates two tasks" "issue:42pr:43" "$task"
eq "relink picks the PR when a record has both" "pr:43" "$task"

# Re-keying moves the record to the live pane, so the old key's write lock has
# to go with it — nothing will ever take that lock again, and a leftover file
# per crashed pane accumulates for the life of the cache directory.
rm -f "$APEX_ROOT/$MANAGER/members/both:"*.json
member "both:%9" "$(jq -nc --arg wt "$WT" \
	'{role:"worker", worktree:$wt, review_pr:"43", agent:"claude"}')"
LOCK9="$APEX_ROOT/$MANAGER/members/.both:%9.lock"
: > "$LOCK9"
rm -f "$STUB/opt.pane."*   # else the pane reads as already linked
( cd "$WT" && STUB_SESSION=both TMUX_PANE='%2' apex relink ) >/dev/null 2>&1 || true
eq "relink re-keys the record to the live pane" yes \
	"$([[ -f "$APEX_ROOT/$MANAGER/members/both:%2.json" ]] && print yes)"
eq "…and takes the dead key's lock with it" "" \
	"$(print -r -- "$LOCK9"(N))"

# ─── 7. no session env rewrite on an apex spawn ──────────────────────

print "\napex spawn into an existing session"

# The collision itself: spawning a reviewer for a PR whose worker session is
# already up must add a pane and must NOT touch that session's CODING_AGENT_*
# env. Rewriting it is what let the next dev-layout run re-register the
# worker's own pane under the reviewer's task.
cat > "$BIN/gh" <<'EOF'
#!/bin/sh
case "$*" in
	*"pr view"*number*) echo 43 ;;
	*) echo "" ;;
esac
EOF
cat > "$BIN/git" <<EOF
#!/bin/sh
case "\$*" in
	*"worktree list"*) printf '%s [%s]\n' "$WT" fix-issue-42 ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$BIN/gh" "$BIN/git"

SESSION_NAME=$(basename "$WT" | tr . _)
print -r -- "$SESSION_NAME" >> "$STUB/sessions"
printf '%%50\t%s\t\n' "$SESSION_NAME" >> "$STUB/panes"
print -r -- 42 > "$STUB/env.$(print -r -- "${SESSION_NAME//[^a-zA-Z0-9]/_}").CODING_AGENT_ISSUE"

before=$(grep -c '' "$STUB/panes")
out=$("$SCRIPTS/tmux-picker.sh" --spawn-pr-review fix-issue-42 no-switch \
	CODING_AGENT_ROLE=monitor "CODING_AGENT_APEX_SESSION=$MANAGER" 2>&1)
eq "the reviewer gets its own new pane" $(( before + 1 )) "$(grep -c '' "$STUB/panes")"
contains "…and the spawn reports it as a pane-scoped member" "$SESSION_NAME:%" "$out"
eq "the worker's session env is left alone" 42 \
	"$(session_env "$SESSION_NAME" CODING_AGENT_ISSUE)"
eq "no CODING_AGENT_PR is planted on the shared session" "" \
	"$(session_env "$SESSION_NAME" CODING_AGENT_PR)"

review_pane=$(awk -F'\t' -v s="$SESSION_NAME" '$2==s{p=$1} END{print p}' "$STUB/panes")
cmd=$(pane_cmd_plain "$review_pane")
contains "the new pane runs the review"        "/my-pr-review 43" "$cmd"
contains "the new pane is told it is managed"  "managed monitor agent" "$cmd"
# The gap #35 left: its tests asserted the adapter's argv given the managed
# flag, and that delta_agent_launch_cmd exports the flag it is handed — but
# nothing asserted that the *spawn* path hands one over, and it did not. Every
# spawned worker and monitor launched with suggestions on. Assert here, on the
# argv the spawn actually put in the pane (#45).
contains "the new pane is launched with the managed marker" \
	"DELTA_AGENT_MANAGED=1" "$cmd"

# Re-spawning the same review reuses the pane rather than stacking another.
before=$(grep -c '' "$STUB/panes")
"$SCRIPTS/tmux-picker.sh" --spawn-pr-review fix-issue-42 no-switch \
	CODING_AGENT_ROLE=monitor "CODING_AGENT_APEX_SESSION=$MANAGER" >/dev/null 2>&1
eq "re-spawning the same review adds no pane" "$before" "$(grep -c '' "$STUB/panes")"

# ─── 7b. the fresh-session spawn path ────────────────────────────────

print "\nfresh-session spawn (tmux-dev-layout.sh)"

# The path above covers a spawn into an ALREADY-EXISTING session. The common
# case is the other one: the picker creates a session and send-keys
# tmux-dev-layout.sh into it, and that script builds its own launch command.
# #35 patched neither, so both spawned panes with prompt suggestions on (#45).
# Pin the argv here too, and pin that a human's own open is left alone —
# dev-layout derives "managed" from CODING_AGENT_APEX_SESSION, so the two cases
# differ only by that one session env var.
DL_WT="$TMPROOT/dl-worktree"; mkdir -p "$DL_WT"
dl_launch_cmd() {
	# dl_launch_cmd <session-name> — run dev-layout in a fresh fake session
	# carrying whatever env the caller planted, and return the pane's command.
	local sess="$1"
	print -r -- "$sess" >> "$STUB/sessions"
	( cd "$DL_WT" && STUB_SESSION="$sess" TMUX=fake-socket DEV_EDITOR=true \
		"$SCRIPTS/tmux-dev-layout.sh" ) >/dev/null 2>&1 || true
	# dev-layout splits the current window with no -t, so the stub records the
	# new pane with an empty session field — it is just the newest row.
	pane_cmd_plain "$(awk -F'\t' 'END{print $1}' "$STUB/panes")"
}

APEX_SPAWNED=dl-apex-session
print -r -- 42 > "$STUB/env.$(print -r -- "${APEX_SPAWNED//[^a-zA-Z0-9]/_}").CODING_AGENT_ISSUE"
print -r -- "$MANAGER" > "$STUB/env.$(print -r -- "${APEX_SPAWNED//[^a-zA-Z0-9]/_}").CODING_AGENT_APEX_SESSION"
print -r -- worker > "$STUB/env.$(print -r -- "${APEX_SPAWNED//[^a-zA-Z0-9]/_}").CODING_AGENT_ROLE"
dl_cmd=$(dl_launch_cmd "$APEX_SPAWNED")
contains "an apex-spawned session launches its agent as managed" \
	"DELTA_AGENT_MANAGED=1" "$dl_cmd"
contains "…and still gets its task prompt" "GitHub issue #42" "$dl_cmd"

HUMAN_OPENED=dl-human-session
print -r -- 42 > "$STUB/env.$(print -r -- "${HUMAN_OPENED//[^a-zA-Z0-9]/_}").CODING_AGENT_ISSUE"
dl_cmd=$(dl_launch_cmd "$HUMAN_OPENED")
contains "a human's own open is not marked managed" \
	"DELTA_AGENT_MANAGED=''" "$dl_cmd"

# ─── summary ─────────────────────────────────────────────────────────

# ─── 8. recovered layout and stale recorded ids ──────────────────────

print "\nrecovered layout"

# A reviewer whose whole session died, carrying a recorded conversation id that
# no longer resolves. Recovery has to (a) rebuild the label the picker would
# have given it — PR number included, or the pill reads as a different session
# than the one that died — (b) use the fresh-session pane width, and (c) notice
# that the recorded id is not the one the transcript actually has.
REVIEW_SESSION=repo-fix-issue-42-review
member "$REVIEW_SESSION:%4" "$(jq -nc --arg wt "$WT" \
	'{role:"monitor", worktree:$wt, issue:"", review_pr:"43", agent:"claude",
	  mode:"review", model:"opus", permission_mode:"", profile:"",
	  agent_session_id:"id-from-before-the-crash", status:"idle", seq:3}')"

stub_reset_log
out=$(apex recover --yes "$REVIEW_SESSION:%4" 2>&1)
contains "a resumed reviewer gets its own conversation" \
	"resumed conversation $REVIEW_ID" "$out"
contains "a recorded id that no longer resolves is called out" \
	"recorded id id-from-before-the-crash no longer resolves" "$out"
rec=$(cat "$APEX_ROOT/$MANAGER/members/$REVIEW_SESSION":*.json)
eq "…and the record is corrected, not left stale" "$REVIEW_ID" \
	"$(print -r -- "$rec" | jq -r '.agent_session_id')"

eq "a recovered review session keeps its PR number in the label" "43: review" \
	"$(cat "$STUB/opt.session.$(print -r -- "${REVIEW_SESSION//[^a-zA-Z0-9]/_}")._session_label" 2>/dev/null || true)"
contains "a session recover just built gets the dev-layout pane width" \
	"-p $DELTA_AGENT_PANE_PCT_NEW" \
	"$(grep -F "split-window -t $REVIEW_SESSION" "$STUB/log" | tail -1)"

# A member with no task at all still must not get a second pane: the duplicate
# guard used to be gated on a non-empty task, so a record written before the
# task was known was recovered on every run.
TASKLESS=taskless-session
member "$TASKLESS:%5" "$(jq -nc --arg wt "$WT" \
	'{role:"worker", worktree:$wt, issue:"", review_pr:"", agent:"claude"}')"
print -r -- "$TASKLESS" >> "$STUB/sessions"
printf '%%55\t%s\t\n' "$TASKLESS" >> "$STUB/panes"
print -r -- "$MANAGER" > "$STUB/opt.pane._55._apex_session"
before=$(grep -c '' "$STUB/panes")
out=$(apex recover --yes "$TASKLESS:%5" 2>&1)
contains "a taskless member already in a pane is left alone" \
	"already live on this session" "$out"
eq "…and gains no second pane" "$before" "$(grep -c '' "$STUB/panes")"

# ─── 9. reap must not destroy what recover needs ─────────────────────

print "\nreap guard"

eval "$(sed -n '/^_reap_risk()/,/^}/p' "$SCRIPTS/tmux-apex.sh")"
(( ${+functions[_reap_risk]} )) || {
	print -u2 "apex-recover.test.sh: could not extract _reap_risk from tmux-apex.sh"
	exit 1
}

# Real repos here, not a git stub: the whole point of the guard is what git
# actually reports about unpushed work, and a stub would only assert that the
# test author and the implementation agree on the same wrong model.
GBIN="$TMPROOT/realbin"; mkdir -p "$GBIN"
REAL_GIT=$(PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" whence -p git)
ln -sf "$REAL_GIT" "$GBIN/git"

facts_for() {  # facts_for <worktree> <dirty-bool> [pr-state] [pr-number]
	jq -nc --arg wt "$1" --argjson d "$2" --arg ps "${3:-}" --arg pn "${4:-}" \
		'{worktree:$wt, dirty:$d, commits_ahead:0, pr_state:$ps, pr_number:$pn}'
}

risk() { PATH="$GBIN:$PATH" _reap_risk "$(facts_for "$1" "$2" "${3:-}" "${4:-}")" }

# A `gh` that answers only what the guard asks it. GH_BASE_REF empty means "gh
# cannot answer", which is the case the fallback chain has to cover.
cat > "$GBIN/gh" <<'EOF'
#!/bin/sh
[ -n "$GH_BASE_REF" ] || exit 1
printf '%s\n' "$GH_BASE_REF"
EOF
chmod +x "$GBIN/gh"

# A bare "remote" plus a clone whose one commit is pushed: nothing to lose.
REMOTE="$TMPROOT/remote.git"
PATH="$GBIN:$PATH" git init -q --bare "$REMOTE"
CLEAN="$TMPROOT/wt/clean"
PATH="$GBIN:$PATH" git clone -q "$REMOTE" "$CLEAN" 2>/dev/null
(
	cd "$CLEAN" || exit
	export PATH="$GBIN:$PATH"
	git config user.email t@t; git config user.name t
	print pushed > f; git add f; git commit -qm pushed; git push -q origin HEAD:main
) >/dev/null 2>&1
# `git init --bare` points HEAD at init.defaultBranch, which is not the same
# everywhere — main on this author's machine, master on the CI runner. Cloning a
# bare repo whose HEAD names a ref that does not exist leaves an *unborn* branch
# and no checkout, so the fixtures below quietly built root commits unrelated to
# main and `merge --squash` died on unrelated histories. Say which branch is the
# remote's default instead of inheriting an opinion from the environment.
PATH="$GBIN:$PATH" git -C "$REMOTE" symbolic-ref HEAD refs/heads/main

eq "a clean, fully pushed member is safe to reap" "" "$(risk "$CLEAN" false)"

contains "uncommitted changes hold it back" "uncommitted changes" \
	"$(risk "$CLEAN" true)"

# A commit no remote has. commits_ahead stays 0 in the facts on purpose: this
# is the never-pushed branch whose @{upstream} does not exist, which is the case
# the old field reports as "0 ahead" and reap would have destroyed.
(
	cd "$CLEAN" || exit
	export PATH="$GBIN:$PATH"
	git checkout -qb side; print local > g; git add g; git commit -qm unpushed
) >/dev/null 2>&1
contains "a commit no remote has holds it back" "1 unpushed commit(s)" \
	"$(risk "$CLEAN" false)"
# Pins the premise the guard rests on rather than the guard's own output: if
# @{upstream} ever did resolve on a never-pushed branch, the reason for not
# reading commits_ahead would be stale and this is what would say so.
eq "…and @{upstream} really does report 0 for that same branch" "0" \
	"$(PATH="$GBIN:$PATH" git -C "$CLEAN" rev-list --count '@{upstream}..HEAD' 2>/dev/null || print 0)"

# A worktree that is already gone is exactly what reap is for.
eq "a missing worktree is not held back" "" "$(risk "$TMPROOT/wt/vanished" false)"

# Unreadable git state must fail closed, not read as "nothing unpushed".
NOTREPO="$TMPROOT/wt/notrepo"; mkdir -p "$NOTREPO"
contains "an unreadable worktree fails closed" "could not read git state" \
	"$(risk "$NOTREPO" false)"

# ── the narrow-refspec case (issue #31) ──────────────────────────────
# `HEAD --not --remotes` reads local remote-tracking refs, not the remote. With
# remote.origin.fetch narrowed to one branch — the configuration this was found
# under — no origin/<worker-branch> ref is ever created, so a fully pushed
# branch still counts every one of its commits as unpushed. The guard then holds
# every worker forever, which is indistinguishable from having no guard, because
# the operator learns to pass --force.
print "\nreap guard under a narrow fetch refspec"
NARROW="$TMPROOT/wt/narrow"
PATH="$GBIN:$PATH" git clone -q "$REMOTE" "$NARROW" 2>/dev/null
(
	cd "$NARROW" || exit
	export PATH="$GBIN:$PATH"
	git config user.email t@t; git config user.name t
	# The whole point: only main is ever fetched into a tracking ref.
	git config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
	git checkout -qb narrowbranch origin/main
	print work > n; git add n; git commit -qm "pushed on a narrow refspec"
	git push -q origin narrowbranch
	git fetch -q origin
) >/dev/null 2>&1

# A fixture built on a root commit would make every count below an artefact of
# the setup rather than a fact about the code, and it fails silently — so assert
# the branch descends from the base before reading anything off it.
eq "the narrow fixture's branch descends from main" 0 \
	"$(PATH="$GBIN:$PATH" git -C "$NARROW" rev-list --count refs/remotes/origin/main --not HEAD 2>/dev/null)"

# Premise first: the old signal really is wrong here, not merely unhelpful.
# Without this the test below could pass because nothing was pushed at all.
eq "the local view really does call the pushed branch unpushed" 1 \
	"$(PATH="$GBIN:$PATH" git -C "$NARROW" rev-list --count HEAD --not --remotes 2>/dev/null)"
eq "…and no tracking ref for it was ever created" "" \
	"$(PATH="$GBIN:$PATH" git -C "$NARROW" rev-parse --verify --quiet refs/remotes/origin/narrowbranch 2>/dev/null)"
eq "a pushed branch with no tracking ref is safe to reap" "" "$(risk "$NARROW" false)"
# The dirty signal is independent and must still fire — it is the check doing
# most of the real protecting, and the one reap cannot recover from.
contains "…but uncommitted changes there still hold it back" \
	"uncommitted changes" "$(risk "$NARROW" true)"

# ── the squash-merged case (issue #31) ───────────────────────────────
# A squash merge rewrites the commits, so the branch's own commits are
# unreachable from any remote ref *by construction* — permanently, no matter how
# the refspec is configured. Only content survives the rewrite, so a merged PR
# whose tree matches the base has nothing left to lose.
print "\nreap guard after a squash merge"
MERGED_WT="$TMPROOT/wt/merged"
PATH="$GBIN:$PATH" git clone -q "$REMOTE" "$MERGED_WT" 2>/dev/null
(
	cd "$MERGED_WT" || exit
	export PATH="$GBIN:$PATH"
	git config user.email t@t; git config user.name t
	git config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
	git checkout -qb mergedbranch origin/main
	print feature > m; git add m; git commit -qm "the work"
	git push -q origin mergedbranch
) >/dev/null 2>&1
eq "the merged fixture's branch descends from main before the squash" 0 \
	"$(PATH="$GBIN:$PATH" git -C "$MERGED_WT" rev-list --count refs/remotes/origin/main --not HEAD 2>/dev/null)"

# Squash it into main the way GitHub would, from a separate clone, then drop the
# branch on the remote — so the worktree keeps commits nothing can reach.
SQUASHER="$TMPROOT/squasher"
PATH="$GBIN:$PATH" git clone -q "$REMOTE" "$SQUASHER" 2>/dev/null
(
	cd "$SQUASHER" || exit
	export PATH="$GBIN:$PATH"
	git config user.email t@t; git config user.name t
	git checkout -q main
	git merge -q --squash origin/mergedbranch
	git commit -qm "the work (#1)"
	git push -q origin main
	git push -q origin --delete mergedbranch
) >/dev/null 2>&1
PATH="$GBIN:$PATH" git -C "$MERGED_WT" fetch -q origin 2>/dev/null

# Premises: the commits really are unreachable, and the content really is in.
eq "the merged branch's commits are unreachable from any remote ref" 1 \
	"$(PATH="$GBIN:$PATH" git -C "$MERGED_WT" rev-list --count HEAD --not --remotes 2>/dev/null)"
eq "…and its tree is identical to the base" "" \
	"$(PATH="$GBIN:$PATH" git -C "$MERGED_WT" diff --name-only refs/remotes/origin/main HEAD 2>/dev/null)"

eq "a merged PR whose content is in the base is safe to reap" "" \
	"$(risk "$MERGED_WT" false MERGED)"

# The content check is gated on the PR being merged, and that gate carries
# weight: tree-equals-base on an open PR means the worker has not started, which
# is not the same thing as its work being preserved. Fail closed.
contains "the same tree on an open PR still holds" "1 unpushed commit(s)" \
	"$(risk "$MERGED_WT" false OPEN)"
contains "…and so does an unknown PR state" "1 unpushed commit(s)" \
	"$(risk "$MERGED_WT" false)"

# A merged PR the worker then kept working on is not safe: the extra commit is
# content the base has never seen, which is the case this whole guard exists for.
(
	cd "$MERGED_WT" || exit
	export PATH="$GBIN:$PATH"
	print more > extra; git add extra; git commit -qm "kept going after the merge"
) >/dev/null 2>&1
contains "work added after the merge still holds it back" "unpushed commit(s)" \
	"$(risk "$MERGED_WT" false MERGED)"

# ── a PR that does not target the default branch (issue #40) ─────────
# The base was resolved by trying origin/HEAD, then origin/main, then
# origin/master — a fallback chain with no input from the PR. For a PR merged
# into a release branch that answers about main, and the tree comparison then
# says "still differs" for work that is fully merged. Where the PR number is
# known, its baseRefName is the real answer.
print "\nreap guard for a PR merged into a non-default base"
RELREMOTE="$TMPROOT/relremote.git"
PATH="$GBIN:$PATH" git init -q --bare "$RELREMOTE"
RELSEED="$TMPROOT/relseed"
(
	export PATH="$GBIN:$PATH"
	git clone -q "$RELREMOTE" "$RELSEED"
	cd "$RELSEED" || exit
	git config user.email t@t; git config user.name t
	print seed > s; git add s; git commit -qm seed; git push -q origin HEAD:main
	git fetch -q origin
	git checkout -qB release origin/main
	print rel > r; git add r; git commit -qm "release line"; git push -q origin release
	# main moves on independently, so tree-vs-main can never match the branch.
	git checkout -qB main origin/main
	print drift > d; git add d; git commit -qm "main drifts"; git push -q origin main
) >/dev/null 2>&1
PATH="$GBIN:$PATH" git -C "$RELREMOTE" symbolic-ref HEAD refs/heads/main

RELWT="$TMPROOT/wt/release"
PATH="$GBIN:$PATH" git clone -q "$RELREMOTE" "$RELWT" 2>/dev/null
(
	cd "$RELWT" || exit
	export PATH="$GBIN:$PATH"
	git config user.email t@t; git config user.name t
	git checkout -qb relbranch origin/release
	print fix > hotfix; git add hotfix; git commit -qm "the hotfix"
	git push -q origin relbranch
) >/dev/null 2>&1

# Squash it into release, GitHub-style, from elsewhere, then drop the branch.
RELSQ="$TMPROOT/relsquasher"
(
	export PATH="$GBIN:$PATH"
	git clone -q "$RELREMOTE" "$RELSQ"
	cd "$RELSQ" || exit
	git config user.email t@t; git config user.name t
	git checkout -qB release origin/release
	git merge -q --squash origin/relbranch
	git commit -qm "the hotfix (#7)"
	git push -q origin release
	git push -q origin --delete relbranch
) >/dev/null 2>&1
PATH="$GBIN:$PATH" git -C "$RELWT" fetch -q --prune origin 2>/dev/null

# Premises: the commits are unreachable, the content is in release, and main —
# the branch the old chain would have picked — genuinely disagrees.
eq "the release fixture's commits are unreachable from any remote ref" 1 \
	"$(PATH="$GBIN:$PATH" git -C "$RELWT" rev-list --count HEAD --not --remotes 2>/dev/null)"
eq "…and its tree matches the release base it merged into" "" \
	"$(PATH="$GBIN:$PATH" git -C "$RELWT" diff --name-only refs/remotes/origin/release HEAD 2>/dev/null)"
neq "…but not origin/main, so the old fallback chain answers wrongly" "" \
	"$(PATH="$GBIN:$PATH" git -C "$RELWT" diff --name-only refs/remotes/origin/main HEAD 2>/dev/null)"

export GH_BASE_REF=release
eq "a PR merged into a non-default base is safe to reap" "" \
	"$(risk "$RELWT" false MERGED 7)"

# With no PR number there is nothing to ask, and with no answer from gh the
# chain is all there is — both must fail closed rather than clear on the wrong
# base. This is the pre-fix behaviour, kept deliberately as the floor.
contains "…while with no PR number to ask about it holds" "unpushed commit(s)" \
	"$(risk "$RELWT" false MERGED)"
export GH_BASE_REF=""
contains "…and it holds when gh cannot answer" "unpushed commit(s)" \
	"$(risk "$RELWT" false MERGED 7)"

# ── the same PR in a narrow-refspec repo ────────────────────────────
# Knowing the base by name is not having a ref for it. Where
# remote.origin.fetch covers only main (issue #31), origin/release never
# exists, so asking the PR and then rev-parsing it falls through to the chain
# and lands back on origin/main — the exact wrong base, reached the long way
# round. The guard has to fetch the ref it was told to compare against.
NARROWREL="$TMPROOT/wt/release-narrow"
cp -R "$RELWT" "$NARROWREL"
(
	cd "$NARROWREL" || exit
	export PATH="$GBIN:$PATH"
	git config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
	git update-ref -d refs/remotes/origin/release
) >/dev/null 2>&1
eq "the narrow release fixture has no tracking ref for its base" "" \
	"$(PATH="$GBIN:$PATH" git -C "$NARROWREL" rev-parse --verify --quiet refs/remotes/origin/release 2>/dev/null)"
neq "…and origin/main is there to be wrongly picked" "" \
	"$(PATH="$GBIN:$PATH" git -C "$NARROWREL" rev-parse --verify --quiet refs/remotes/origin/main 2>/dev/null)"

export GH_BASE_REF=release
eq "a non-default base is fetched rather than assumed to be present" "" \
	"$(risk "$NARROWREL" false MERGED 7)"
eq "…which leaves the base's own tip behind as the tracking ref" \
	"$(PATH="$GBIN:$PATH" git -C "$NARROWREL" ls-remote origin refs/heads/release 2>/dev/null | cut -f1)" \
	"$(PATH="$GBIN:$PATH" git -C "$NARROWREL" rev-parse --verify --quiet refs/remotes/origin/release 2>/dev/null)"
unset GH_BASE_REF

# ── and when that fetch cannot succeed ───────────────────────────────
# The fetch closes the common case; it does not make the base ref certain.
# Offline, expired auth, a deleted base branch — any of those leave the derived
# base unresolvable, and the question the guard should then answer is *unknown*,
# not "here is a different branch's answer". Two ways that used to go wrong at
# once, so one fixture pins both:
#
#   - the fallback chain was appended even when the PR had answered, so a failed
#     fetch fell through to origin/main — the pre-fix bug by a narrower door;
#   - the fetch was unguarded, and this function is eval'd into this file's
#     shell under `err_return`, where a failing bare command returns before the
#     guard can print anything. _cmd_reap reads that empty string as "safe to
#     reap" and force-removes the worktree (the shape of issue #37).
#
# Both fail *open*, so the fixture has to be one where falling through would
# clear rather than hold: main is moved to the same tree as the branch, which is
# what makes the difference between the two answers observable at all.
(
	export PATH="$GBIN:$PATH"
	cd "$RELSQ" || exit
	git push -q -f origin release:main
) >/dev/null 2>&1
GONEREL="$TMPROOT/wt/release-gone"
cp -R "$RELWT" "$GONEREL"
(
	cd "$GONEREL" || exit
	export PATH="$GBIN:$PATH"
	git fetch -q origin '+refs/heads/main:refs/remotes/origin/main'
	git update-ref -d refs/remotes/origin/release
	git remote set-url origin "$TMPROOT/gone.git"
) >/dev/null 2>&1
eq "the unreachable fixture has no tracking ref for its base" "" \
	"$(PATH="$GBIN:$PATH" git -C "$GONEREL" rev-parse --verify --quiet refs/remotes/origin/release 2>/dev/null)"
eq "…and origin/main now agrees with HEAD, so falling through would clear" "" \
	"$(PATH="$GBIN:$PATH" git -C "$GONEREL" diff --name-only refs/remotes/origin/main HEAD 2>/dev/null)"
neq "…and its origin really is unreachable" 0 \
	"$(PATH="$GBIN:$PATH" git -C "$GONEREL" fetch -q origin '+refs/heads/release:refs/remotes/origin/release' >/dev/null 2>&1; print $?)"

export GH_BASE_REF=release
contains "a known base that will not resolve holds rather than clearing" \
	"unpushed commit(s)" "$(risk "$GONEREL" false MERGED 7)"
unset GH_BASE_REF

# ─── 10. the guard where it actually matters: inside `reap` ──────────
#
# _reap_risk returning the right string is only half of it. The value is in
# _cmd_reap's wiring: a held member must keep its record and its worktree, or
# `recover` has nothing left to work with. So run the real command.
#
# Two accommodations. The other sections' members are parked out of the way so
# only these are in play — reap walks every member, and a stray one pointing at
# a clean worktree would take the destructive branch through the real picker.
# And real git is on PATH for these invocations, because the shared git stub
# cannot answer "is any of this on a remote".

print "\nreap holds the line"

mv "$APEX_ROOT/$MANAGER/members" "$TMPROOT/members.parked"
mkdir -p "$APEX_ROOT/$MANAGER/members"

HOLD_WT="$TMPROOT/wt/held-issue-99"
PATH="$GBIN:$PATH" git clone -q "$REMOTE" "$HOLD_WT" 2>/dev/null
(
	cd "$HOLD_WT" || exit
	export PATH="$GBIN:$PATH"
	git config user.email t@t; git config user.name t
	git checkout -qb held; print work > w; git add w; git commit -qm unpushed
) >/dev/null 2>&1

HELD_KEY="held-issue-99:%20"
member "$HELD_KEY" "$(jq -nc --arg wt "$HOLD_WT" \
	'{role:"worker", worktree:$wt, issue:"99", review_pr:"", agent:"claude"}')"

# A live sibling in the same session, so that if the guard is ever broken this
# test fails at an assertion rather than by handing a worktree to the real
# picker: _cmd_reap skips worktree cleanup while any member still owns a pane
# there. gwtrm has no rm -rf fallback, but a test should not be one bug away
# from calling it at all.
member "held-issue-99:%21" "$(jq -nc --arg wt "$HOLD_WT" \
	'{role:"reviewer", worktree:$wt, issue:"", review_pr:"99", agent:"claude"}')"
printf '%%21\t%s\t\n' held-issue-99 >> "$STUB/panes"
print -r -- held-issue-99 >> "$STUB/sessions"

# %20 is in no pane, which after a server crash is every member's state.
out=$(PATH="$GBIN:$PATH" apex reap --yes 2>&1)
contains "reap holds back a member with unpushed work" \
	"HOLD: 1 unpushed commit(s)" "$out"
contains "…and names the member it held" "$HELD_KEY" "$out"
contains "…and reaps nothing" "Nothing reaped." "$out"
contains "…and says how to override" "--force" "$out"

eq "…and leaves the record on disk for recover" yes \
	"$([[ -f "$APEX_ROOT/$MANAGER/members/${HELD_KEY}.json" ]] && print yes)"
eq "…and leaves the worktree on disk for recover" yes \
	"$([[ -d "$HOLD_WT" ]] && print yes)"
eq "…and leaves the unpushed commit reachable" unpushed \
	"$(PATH="$GBIN:$PATH" git -C "$HOLD_WT" log -1 --format=%s 2>/dev/null)"
lacks "…and never killed its pane" "kill-pane -t %20" "$(cat "$STUB/log")"

# --force reclassifies it. Checked on the dry run: --yes here would hand the
# worktree to the real picker, and a test has no business calling gwtrm -f.
out=$(PATH="$GBIN:$PATH" apex reap --force 2>&1)
contains "--force offers the held member instead" "$HELD_KEY" "$out"
lacks "…and drops the HOLD" "HOLD:" "$out"
contains "…but still will not act without --yes" "Re-run with --yes" "$out"

mv "$TMPROOT/members.parked" "$APEX_ROOT/$MANAGER/members"

# ─── 10. reap keeps the record when cleanup does not happen ──────────

print "\nreap cleanup"

# `gwtrm -f` once prompted a second time for a dirty worktree and, with no tty,
# fell through to "Aborted." returning 0 — so reap deleted the member record for
# a worktree that was still on disk, and `recover` could no longer reach it.
# _reap_cleanup answers the only question that settles it: is the directory gone?
eval "$(sed -n '/^_reap_cleanup()/,/^}/p' "$SCRIPTS/tmux-apex.sh")"
(( ${+functions[_reap_cleanup]} )) || {
	print -u2 "fatal: could not extract _reap_cleanup from tmux-apex.sh"
	exit 1
}

# A stub picker stands in for the real --delete-wt, so the test decides whether
# cleanup succeeds instead of handing a worktree to gwtrm.
FAKE_SCRIPTS="$TMPROOT/fakescripts"
mkdir -p "$FAKE_SCRIPTS"
cleanup() { SCRIPTS="$FAKE_SCRIPTS" _reap_cleanup "$1" "$2" }

CLEAN_WT="$TMPROOT/cleanup-wt"

# The honest case: the picker removes the worktree.
mkdir -p "$CLEAN_WT"
print -r -- '#!/usr/bin/env zsh
rm -rf "${2#wt:}"' > "$FAKE_SCRIPTS/tmux-picker.sh"
chmod +x "$FAKE_SCRIPTS/tmux-picker.sh"
out=$(cleanup dead-session "$CLEAN_WT" 2>&1)
ok "cleanup succeeds when the worktree is actually removed" $?
eq "…and says nothing" "" "$out"

# The regression: exit 0, worktree untouched.
mkdir -p "$CLEAN_WT"
print -r -- '#!/usr/bin/env zsh
print "Warning: worktree has uncommitted changes:"
print "Aborted."
exit 0' > "$FAKE_SCRIPTS/tmux-picker.sh"
rc=0
out=$(cleanup dead-session "$CLEAN_WT" 2>&1) || rc=$?
eq "a surviving worktree fails cleanup even on exit 0" 1 $rc
contains "…and names the worktree" "worktree survived cleanup: $CLEAN_WT" "$out"
contains "…and keeps the output reap used to discard" "Aborted." "$out"

# Nothing to remove is not a failure — it is reap's whole purpose.
print -r -- '#!/usr/bin/env zsh
print "picker must not be called for a missing worktree"
exit 1' > "$FAKE_SCRIPTS/tmux-picker.sh"
out=$(cleanup dead-session "$TMPROOT/never-existed" 2>&1)
ok "a worktree that is already gone counts as clean" $?
lacks "…without invoking the picker" "must not be called" "$out"
contains "…and kills the orphaned session instead" "kill-session -t dead-session" \
	"$(cat "$STUB/log")"

print ""
print "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
