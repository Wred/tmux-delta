#!/usr/bin/env zsh

# Set up a dev split: nvim (left) + claude (right, 50%).
# Picks up CODING_AGENT_ISSUE / CODING_AGENT_PR and CODING_AGENT_MODE
# from tmux session env vars to drive the agent.
#
# Idempotent — does nothing if the window already has multiple panes.
# Called via send-keys from the picker after session creation.
#
# Requires: direnv, nvim
# Optional: CODING_AGENT env var to override the agent command (default: claude)
# Optional: DEV_EDITOR env var to override the left-pane editor command (default: nvim)

# Must be in tmux
[[ -z $TMUX ]] && exit 0

# Idempotency: skip if window already has >1 pane
(( $(tmux list-panes 2>/dev/null | wc -l) > 1 )) && exit 0

# Read session context from tmux env
session=$(tmux display-message -p '#S')
issue=$(tmux show-environment -t "$session" CODING_AGENT_ISSUE 2>/dev/null | cut -d= -f2-)
pr=$(tmux show-environment -t "$session" CODING_AGENT_PR 2>/dev/null | cut -d= -f2-)
mode=$(tmux show-environment -t "$session" CODING_AGENT_MODE 2>/dev/null | cut -d= -f2-)

# Build the inner command. ${CODING_AGENT:-claude} is left UNEXPANDED here so
# the spawned zsh resolves it AFTER direnv exec loads the worktree's .envrc —
# otherwise we'd race the parent shell's direnv precmd hook.
if [[ -n $issue ]]; then
	if [[ $mode == "autonomous" ]]; then
		prompt="GitHub issue #${issue}. Read it with: gh issue view ${issue} --json title,body,labels,url,comments. Assign the issue to yourself with gh issue edit ${issue} --add-assignee @me and comment that you have started working on it. Then work it end-to-end: implement, test, commit on the current branch, push, and open a draft PR with gh pr create --draft. If acceptance criteria are ambiguous or you hit a blocking decision, stop and ask rather than guessing."
	else
		prompt="GitHub issue #${issue}. Read it with: gh issue view ${issue} --json title,body,labels,url,comments. Summarize it back to me, then ask if I want to assign the issue to myself and start working on it."
	fi
	inner='agent=${CODING_AGENT:-claude}; "$agent" '${(q)prompt}
elif [[ -n $pr ]]; then
	local skill_prompt="/my-pr-review ${pr}"
	inner='agent=${CODING_AGENT:-claude}; "$agent" '${(q)skill_prompt}
else
	inner='agent=${CODING_AGENT:-claude}; "$agent" --continue || "$agent"'
fi

# Split: agent on the right (50% width)
# Capture PWD now so the split pane uses the correct dir regardless of how
# tmux resolves pane_current_path (changed in 3.5+, unreliable without OSC 7).
# direnv exec loads .envrc before running the inner command, so CODING_AGENT
# from the worktree's .envrc is the source of truth.
local project_dir=$PWD
tmux split-window -h -p 50 -c "$project_dir" "direnv exec ${(q)project_dir} zsh -ic ${(q)inner}"

# Start the editor in this pane (the left/original pane where the script is running).
# This pane's own shell already ran direnv's precmd hook, so DEV_EDITOR from the
# worktree's .envrc is already resolved in the environment — no deferred expansion needed.
editor=${DEV_EDITOR:-nvim}
eval "$editor"
