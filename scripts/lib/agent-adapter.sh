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
#
# DELTA_AGENT_MANAGED marks a launch made by the apex manager rather than by a
# human. Such a launch must carry a task (DELTA_AGENT_PROMPT) or a conversation
# to resume (DELTA_AGENT_RESUME); delta_agent_exec refuses it otherwise instead
# of falling back to a bare agent that would wait forever (#68).

DELTA_AGENT_LIBDIR="${0:A:h}"

# _delta_agent_missing <var>... — names of the listed variables that are empty,
# joined for an error message.
_delta_agent_missing() {
	local -a empty=()
	local v
	for v in "$@"; do
		[[ -z ${(P)v} ]] && empty+=("$v")
	done
	print -r -- "${(j:, :)empty}"
}

# delta_agent_exec <agent-command>
delta_agent_exec() {
	local agent="$1"
	local lib="${DELTA_AGENT_LIBDIR}/agents/${agent:t}.sh"

	# Unknown agents fall back to the claude adapter: its flag spellings are the
	# most widely copied, and a wrong flag is a visible startup error rather
	# than a silently mis-configured agent.
	[[ -r $lib ]] || lib="${DELTA_AGENT_LIBDIR}/agents/claude.sh"

	# A managed launch must carry a task or a conversation to resume. Every
	# other input is optional and every adapter appends it conditionally, so
	# with all of them empty the argv collapses to nothing and the agent comes
	# up at an interactive prompt with no idea it is managed and no job to do —
	# present, healthy from outside, waiting forever (#68, same shape as #42).
	# That is a configuration failure, not a degraded success: nothing
	# downstream can recover a worker that was never told what to do, so refuse
	# here and name what was missing rather than burning a pane and tokens on
	# it. Unmanaged launches are exempt on purpose — a human pressing `o` on a
	# plain session wants exactly a bare interactive agent in this directory.
	if [[ -n $DELTA_AGENT_MANAGED && -z $DELTA_AGENT_PROMPT && -z $DELTA_AGENT_RESUME ]]; then
		print -u2 "delta_agent_exec: refusing to launch managed agent '${agent}' with no task."
		print -u2 "  empty: $(_delta_agent_missing DELTA_AGENT_PROMPT DELTA_AGENT_RESUME DELTA_AGENT_MODEL DELTA_AGENT_SYSTEM)"
		print -u2 "  a managed launch needs DELTA_AGENT_PROMPT (a task) or DELTA_AGENT_RESUME (a"
		print -u2 "  conversation id); the caller derived neither, so this pane would sit idle."
		return 78
	fi

	typeset -ga agent_argv=() agent_argv_fresh=()
	unset agent_argv_fresh_set
	source "$lib"
	delta_agent_argv

	# Resume, falling back to a fresh session when there is nothing to resume.
	if (( ${+agent_argv_fresh_set} )); then
		"$agent" "${agent_argv[@]}" && return 0

		# An empty fresh argv means the adapter dropped every input it was
		# given. That is fine only when there was nothing to drop (the bare
		# human open above); with any input set it is an adapter bug, and
		# exec'ing it would launch an agent stripped of its model, flags and
		# system prompt instead of reporting the bug.
		if (( ${#agent_argv_fresh} == 0 )) \
			&& [[ -n $DELTA_AGENT_MODEL$DELTA_AGENT_FLAGS$DELTA_AGENT_SYSTEM$DELTA_AGENT_PROMPT$DELTA_AGENT_MANAGED ]]; then
			print -u2 "delta_agent_exec: adapter ${lib:t} built an empty fresh-session argv for '${agent}'"
			print -u2 "  while configured inputs were set; refusing to exec an unconfigured agent."
			return 78
		fi

		agent_argv=("${agent_argv_fresh[@]}")
	fi

	exec "$agent" "${agent_argv[@]}"
}
