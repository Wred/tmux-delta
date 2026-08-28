#!/usr/bin/env zsh

# Shared coding-agent launch-command builder.
#
# Builds the quoted shell command line a split pane runs to start a coding
# agent, then hands off to agent-adapter.sh's delta_agent_exec. Extracted so
# both the initial dev-layout split (tmux-dev-layout.sh) and any later pane
# added to an already-running session (tmux-picker.sh's _add_agent_pane)
# build the exact same command.
#
# <agent_expr> decides how the pane's shell picks its agent binary:
#   - tmux-dev-layout.sh passes the literal, single-quoted string
#     '${CODING_AGENT:-claude}' so it's resolved INSIDE the pane, after
#     direnv exec loads the worktree's .envrc (the pane doesn't exist yet
#     when the caller runs, so the agent can't be known any earlier).
#   - _add_agent_pane already has a concrete, already-resolved agent name
#     (from the apex spawn's own --agent/profile), so it passes that
#     value pre-quoted (e.g. "${(q)agent}") to bake it in directly instead.
#
# Usage:
#   inner=$(delta_agent_launch_cmd "$agent_expr" "$model" "$flags" "$system" "$prompt" "$dir" "$adapter_path" [resume_session_id])
#   tmux split-window ... "direnv exec ${(q)dir} zsh -ic ${(q)inner}"
#
# The optional trailing <resume_session_id> is only passed by
# `tmux-apex.sh recover`: it resumes that exact recorded conversation instead of
# starting a fresh one. Every other caller omits it.

# Width of the agent pane, as a percentage, for the two shapes of split that
# exist. Named because three call sites have to agree: a recovered session must
# not be visibly laid out differently from the one it replaces.
#   NEW   — the agent is the second pane of a fresh session (editor | agent),
#           as tmux-dev-layout.sh builds it.
#   EXTRA — the agent is an additional pane in a session that is already
#           populated (tmux-picker.sh's _add_agent_pane).
typeset -g DELTA_AGENT_PANE_PCT_NEW=50
typeset -g DELTA_AGENT_PANE_PCT_EXTRA=33

delta_agent_launch_cmd() {
	local agent_expr="$1" model="$2" flags="$3" system="$4" prompt="$5" dir="$6" adapter="$7"
	local resume="${8:-}"
	local -a agent_env=(
		"DELTA_AGENT_MODEL=${(q)model}"
		"DELTA_AGENT_FLAGS=${(q)flags}"
		"DELTA_AGENT_SYSTEM=${(q)system}"
		"DELTA_AGENT_PROMPT=${(q)prompt}"
		"DELTA_AGENT_DIR=${(q)dir}"
		"DELTA_AGENT_RESUME=${(q)resume}"
	)
	print -r -- 'agent='${agent_expr}'; '${(j:; :)agent_env}'; source '${(q)adapter}'; delta_agent_exec "$agent"'
}
