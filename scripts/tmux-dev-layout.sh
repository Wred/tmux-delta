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
coding_agent=$(tmux show-environment -t "$session" CODING_AGENT 2>/dev/null | cut -d= -f2-)

# A session should only ever carry one of these. It can end up carrying both
# when a session name is reused for a second task (the picker sets its own env
# var but used not to clear the other one) — and then this script builds a
# nonsense task like "issue:12pr:34" and registers one pane as both, which is
# exactly the corruption reported in issue #18. The picker now clears the other
# var; refuse to trust a session that still has both rather than concatenating.
if [[ -n $issue && -n $pr ]]; then
	print -u2 "tmux-dev-layout: session '$session' has both CODING_AGENT_ISSUE=$issue and"
	print -u2 "  CODING_AGENT_PR=$pr set; using the PR and ignoring the issue. One of them is"
	print -u2 "  stale — a reused session name (see issue #18)."
	issue=""
fi

# Prompt text is shared with `tmux-apex.sh recover`, which has to be able to
# rebuild this exact launch — see lib/agent-prompts.sh.
source "${SELF:h}/lib/agent-prompts.sh"

# Managed-worker instructions, when this session was spawned by an apex manager.
local managed_prompt
managed_prompt=$(delta_managed_prompt "$agent_role" "$apex_session")

# The initial prompt. Empty means "resume the last session in this directory".
local prompt
prompt=$(delta_task_prompt "$issue" "$pr" "$mode")

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
source "${SELF:h}/lib/agent-launch.sh"
local inner
inner=$(delta_agent_launch_cmd '${CODING_AGENT:-claude}' "$agent_model" "$agent_perm" "$managed_prompt" "$prompt" "$project_dir" "$adapter")

# -P -F publishes the agent pane id so other sessions (and tmux-apex.sh) can
# address this agent with send-keys.
local agent_pane
agent_pane=$(tmux split-window -h -p $DELTA_AGENT_PANE_PCT_NEW \
	-c "$project_dir" -P -F '#{pane_id}' \
	"direnv exec ${(q)project_dir} zsh -ic ${(q)inner}")
[[ -n $agent_pane ]] && tmux set-option -t "$session" @agent_pane "$agent_pane"

# Register this pane with apex (member identity is session:pane_id) if this
# spawn came from tmux-apex.sh, not a plain human `o`pen. A member's own task
# is issue:N or pr:N depending on which env var apex populated.
if [[ -n $agent_pane && -n $apex_session ]]; then
	task="${issue:+issue:$issue}${pr:+pr:$pr}"
	"${SELF:h}/tmux-apex.sh" _register-member "$agent_pane" "$apex_session" "$agent_role" \
		"$task" "$project_dir" "$agent_model" "$agent_perm" "$mode" "${coding_agent:-claude}" \
		"" "$issue" "$pr" \
		>/dev/null 2>&1
fi

# Start the editor in this pane (the left/original pane where the script is running).
# This pane's own shell already ran direnv's precmd hook, so DEV_EDITOR from the
# worktree's .envrc is already resolved in the environment — no deferred expansion needed.
editor=${DEV_EDITOR:-nvim}
eval "$editor"
