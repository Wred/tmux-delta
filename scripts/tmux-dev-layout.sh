#!/usr/bin/env zsh

# Set up a dev split: nvim (left) + coding agent (right, 50%).
# Picks up CODING_AGENT_ISSUE / CODING_AGENT_PR and CODING_AGENT_MODE
# from tmux session env vars to drive the agent.
#
# Idempotent — does nothing if the window already has multiple panes.
# Called via send-keys from the picker after session creation.
#
# Requires: direnv, nvim
# Optional: CODING_AGENT env var to override the agent command (default: claude).
#           Flag spelling per agent lives in lib/agents/<command>.sh.
# Optional: DEV_EDITOR env var to override the left-pane editor command (default: nvim)

SELF=${0:A}

# Must be in tmux
[[ -z $TMUX ]] && exit 0

# Idempotency: skip if window already has >1 pane
(( $(tmux list-panes 2>/dev/null | wc -l) > 1 )) && exit 0

# Read session context from tmux env
session=$(tmux display-message -p '#S')
issue=$(tmux show-environment -t "$session" CODING_AGENT_ISSUE 2>/dev/null | cut -d= -f2-)
pr=$(tmux show-environment -t "$session" CODING_AGENT_PR 2>/dev/null | cut -d= -f2-)
mode=$(tmux show-environment -t "$session" CODING_AGENT_MODE 2>/dev/null | cut -d= -f2-)
# Apex mode: per-spawn agent configuration set by tmux-apex.sh.
agent_model=$(tmux show-environment -t "$session" CODING_AGENT_MODEL 2>/dev/null | cut -d= -f2-)
agent_perm=$(tmux show-environment -t "$session" CODING_AGENT_PERMISSION_MODE 2>/dev/null | cut -d= -f2-)
agent_role=$(tmux show-environment -t "$session" CODING_AGENT_ROLE 2>/dev/null | cut -d= -f2-)
apex_session=$(tmux show-environment -t "$session" CODING_AGENT_APEX_SESSION 2>/dev/null | cut -d= -f2-)

# Managed-worker instructions, when this session was spawned by an apex manager.
local managed_prompt=""
if [[ -n $agent_role && -n $apex_session ]]; then
	managed_prompt="You are a managed ${agent_role} agent under tmux-delta apex mode. \
A manager agent in tmux session '${apex_session}' spawned you and tracks your progress. \
Work autonomously to completion. Do not wait on the human: if you hit a blocking decision or \
an ambiguous acceptance criterion, state the blocker plainly in your final message and stop — \
your manager is notified when you go idle and will send follow-up instructions into this pane. \
Never merge a pull request and never close an issue; that is the human's call. \
Push your work and open a draft PR so the manager can see it."
fi

# The initial prompt. Empty means "resume the last session in this directory".
local prompt=""
if [[ -n $issue ]]; then
	if [[ $mode == "autonomous" ]]; then
		prompt="GitHub issue #${issue}. Read it with: gh issue view ${issue} --json title,body,labels,url,comments. Assign the issue to yourself with gh issue edit ${issue} --add-assignee @me and comment that you have started working on it. Then work it end-to-end: implement, test, commit on the current branch, push, and open a draft PR with gh pr create --draft. If acceptance criteria are ambiguous or you hit a blocking decision, stop and ask rather than guessing."
	else
		prompt="GitHub issue #${issue}. Read it with: gh issue view ${issue} --json title,body,labels,url,comments. Summarize it back to me, then ask if I want to assign the issue to myself and start working on it."
	fi
elif [[ -n $pr ]]; then
	prompt="/my-pr-review ${pr}"
fi

# Split: agent on the right (50% width)
# Capture PWD now so the split pane uses the correct dir regardless of how
# tmux resolves pane_current_path (changed in 3.5+, unreliable without OSC 7).
# direnv exec loads .envrc before running the inner command, so CODING_AGENT
# from the worktree's .envrc is the source of truth.
local project_dir=$PWD

# ${CODING_AGENT:-claude} is left UNEXPANDED here so the spawned zsh resolves it
# AFTER direnv exec loads the worktree's .envrc — otherwise we'd race the parent
# shell's direnv precmd hook. That means the agent's identity is only known
# inside the pane, so adapter selection has to happen there too.
local adapter="${SELF:h}/lib/agent-adapter.sh"
local -a agent_env=(
	"DELTA_AGENT_MODEL=${(q)agent_model}"
	"DELTA_AGENT_FLAGS=${(q)agent_perm}"
	"DELTA_AGENT_SYSTEM=${(q)managed_prompt}"
	"DELTA_AGENT_PROMPT=${(q)prompt}"
	"DELTA_AGENT_DIR=${(q)project_dir}"
)
inner='agent=${CODING_AGENT:-claude}; '${(j:; :)agent_env}'; source '${(q)adapter}'; delta_agent_exec "$agent"'

# -P -F publishes the agent pane id so other sessions (and tmux-apex.sh) can
# address this agent with send-keys.
local agent_pane
agent_pane=$(tmux split-window -h -p 50 -c "$project_dir" -P -F '#{pane_id}' \
	"direnv exec ${(q)project_dir} zsh -ic ${(q)inner}")
[[ -n $agent_pane ]] && tmux set-option -t "$session" @agent_pane "$agent_pane"

# Start the editor in this pane (the left/original pane where the script is running).
# This pane's own shell already ran direnv's precmd hook, so DEV_EDITOR from the
# worktree's .envrc is already resolved in the environment — no deferred expansion needed.
editor=${DEV_EDITOR:-nvim}
eval "$editor"
