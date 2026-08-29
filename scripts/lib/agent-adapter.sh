#!/usr/bin/env zsh

# Agent adapter dispatch.
#
# Coding agents spell the same concepts differently — claude has
# --permission-mode, pi has a --tools allowlist, codex has --sandbox; codex has
# no --append-system-prompt at all and resumes with a subcommand rather than a
# flag. So tmux-dev-layout.sh never emits agent flags itself. It exports the
# neutral inputs below and calls delta_agent_exec, which loads the adapter for
# whichever agent actually resolved after direnv.
#
# Inputs (environment, all optional):
#   DELTA_AGENT_MODEL   model name, passed through to the agent's model flag
#   DELTA_AGENT_FLAGS   agent-native argv, word-split and passed verbatim
#   DELTA_AGENT_SYSTEM  extra system-prompt text (managed-worker instructions)
#   DELTA_AGENT_PROMPT  initial user prompt; empty means "resume last session"
#   DELTA_AGENT_DIR     project directory
#   DELTA_AGENT_RESUME  resume THIS specific recorded session id, rather than
#                       "whatever was last in this directory" — used by
#                       `tmux-apex.sh recover` after a tmux-server crash, where
#                       the pane is gone but the conversation is not
#
# An adapter is scripts/lib/agents/<command-basename>.sh defining
# delta_agent_argv(), which sets the array `agent_argv` to everything that
# follows the command name. Adding an agent is one file.
#
# When DELTA_AGENT_PROMPT is empty the adapter is resuming, and resuming fails
# on a worktree the agent has never seen. Adapters therefore also set
# `agent_argv_fresh` in that case: the same invocation without the resume flags,
# used if the resume attempt exits non-zero.

DELTA_AGENT_LIBDIR="${0:A:h}"

# delta_agent_exec <agent-command>
delta_agent_exec() {
	local agent="$1"
	local lib="${DELTA_AGENT_LIBDIR}/agents/${agent:t}.sh"

	# Unknown agents fall back to the claude adapter: its flag spellings are the
	# most widely copied, and a wrong flag is a visible startup error rather
	# than a silently mis-configured agent.
	[[ -r $lib ]] || lib="${DELTA_AGENT_LIBDIR}/agents/claude.sh"

	typeset -ga agent_argv=() agent_argv_fresh=()
	unset agent_argv_fresh_set
	source "$lib"
	delta_agent_argv

	# Resume, falling back to a fresh session when there is nothing to resume.
	if (( ${+agent_argv_fresh_set} )); then
		"$agent" "${agent_argv[@]}" && return 0
		agent_argv=("${agent_argv_fresh[@]}")
	fi

	exec "$agent" "${agent_argv[@]}"
}
