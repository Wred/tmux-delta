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
	local n="${2#-t}"; n="${n#=}"
	grep -qxF "$n" "$STUB/sessions" 2>/dev/null
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
	if [[ $2 == -a ]]; then
		cut -f1 "$STUB/panes" 2>/dev/null
	else
		local s="$3"
		awk -F'\t' -v s="$s" '$2==s{print $1}' "$STUB/panes" 2>/dev/null
	fi
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
transcript "$REVIEW_ID" "$WT" "$(delta_task_prompt '' 43 review)"     >/dev/null

# A transcript in the same project dir but a different cwd — must never match.
transcript 33333333-3333-3333-3333-333333333333 "$TMPROOT/elsewhere" \
	"$(delta_task_prompt 42 '' autonomous)" >/dev/null

# ─── 1. conversation identity ────────────────────────────────────────

print "conversation identity"

# Load just the discovery helpers out of tmux-apex.sh.
eval "$(sed -n '/^_claude_project_dirs()/,/^}/p; /^_claude_session_for()/,/^}/p' \
	"$SCRIPTS/tmux-apex.sh")"

eq "worker's own conversation, not the newer reviewer's" \
	"$WORKER_ID" "$(_claude_session_for "$WT" "$(delta_task_marker 42 '')")"
eq "reviewer's own conversation" \
	"$REVIEW_ID" "$(_claude_session_for "$WT" "$(delta_task_marker '' 43)")"
eq "unknown task matches nothing" \
	"" "$(_claude_session_for "$WT" "$(delta_task_marker 99 '')" || true)"
eq "a transcript for another cwd is never used" \
	"" "$(_claude_session_for "$TMPROOT/no-such-tree" '' || true)"

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

# ─── 2. resume argv ──────────────────────────────────────────────────

print "\nresume argv"

argv_for() {
	DELTA_AGENT_LIBDIR="$SCRIPTS/lib"
	typeset -ga agent_argv=() agent_argv_fresh=(); unset agent_argv_fresh_set
	DELTA_AGENT_MODEL="" DELTA_AGENT_FLAGS="" DELTA_AGENT_SYSTEM="" \
	DELTA_AGENT_PROMPT="$1" DELTA_AGENT_RESUME="$2" \
		source "$SCRIPTS/lib/agents/claude.sh"
	DELTA_AGENT_MODEL="" DELTA_AGENT_FLAGS="" DELTA_AGENT_SYSTEM="" \
	DELTA_AGENT_PROMPT="$1" DELTA_AGENT_RESUME="$2" delta_agent_argv
}

argv_for "the task" "$WORKER_ID"
eq "resume wins over the prompt" "--resume $WORKER_ID" "${(j: :)agent_argv}"
eq "fresh fallback keeps the task prompt" "the task" "${(j: :)agent_argv_fresh}"
eq "fallback is armed, so an unresumable id degrades to a fresh start" \
	1 "${+agent_argv_fresh_set}"

argv_for "the task" ""
eq "no resume id: plain prompt, no --resume" "the task" "${(j: :)agent_argv}"

source "$SCRIPTS/lib/agent-launch.sh"
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

# Re-registering the SAME task is still a merge, not a wipe: that is the
# ordinary idempotent path and it must keep accumulated fields.
apex _register-member '%1' "$MANAGER" monitor pr:43 "$WT" '' '' review claude '' '' 43 >/dev/null 2>&1
apex_root_file="$APEX_ROOT/$MANAGER/members/recycled:%1.json"
jq '. + {agent_session_id:"kept-id"}' "$apex_root_file" > "$apex_root_file.t" && mv "$apex_root_file.t" "$apex_root_file"
apex _register-member '%1' "$MANAGER" monitor pr:43 "$WT" '' '' review claude '' '' 43 >/dev/null 2>&1
eq "an unchanged re-registration preserves the conversation id" "kept-id" \
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

# Re-spawning the same review reuses the pane rather than stacking another.
before=$(grep -c '' "$STUB/panes")
"$SCRIPTS/tmux-picker.sh" --spawn-pr-review fix-issue-42 no-switch \
	CODING_AGENT_ROLE=monitor "CODING_AGENT_APEX_SESSION=$MANAGER" >/dev/null 2>&1
eq "re-spawning the same review adds no pane" "$before" "$(grep -c '' "$STUB/panes")"

# ─── summary ─────────────────────────────────────────────────────────

print ""
print "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
