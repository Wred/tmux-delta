#!/usr/bin/env zsh
# Adapter: Claude Code. See ../agent-adapter.sh for the contract.

delta_agent_argv() {
	agent_argv=()
	[[ -n $DELTA_AGENT_MODEL ]] && agent_argv+=(--model "$DELTA_AGENT_MODEL")

	# Historically this slot held a bare --permission-mode value, and the README
	# documents it that way. Keep accepting that; anything starting with a dash
	# is agent-native argv and goes through untouched.
	if [[ -n $DELTA_AGENT_FLAGS ]]; then
		if [[ $DELTA_AGENT_FLAGS == -* ]]; then
			agent_argv+=(${=DELTA_AGENT_FLAGS})
		else
			agent_argv+=(--permission-mode "$DELTA_AGENT_FLAGS")
		fi
	fi

	[[ -n $DELTA_AGENT_SYSTEM ]] && agent_argv+=(--append-system-prompt "$DELTA_AGENT_SYSTEM")

	# DELTA_AGENT_RESUME names one specific conversation, so it wins over both
	# the prompt and --continue: `recover` uses it to put a crashed worker back
	# into the *same* conversation rather than the newest one that happens to
	# live in this worktree (a worker and its reviewer share a worktree, so
	# "newest here" is a coin flip between the two).
	#
	# The fresh fallback keeps the prompt: if the transcript for that id is gone
	# (pruned, or the worktree was recreated), the pane starts a normal fresh
	# session on the same task rather than dying with a resume error.
	if [[ -n $DELTA_AGENT_RESUME ]]; then
		agent_argv_fresh=("${agent_argv[@]}")
		[[ -n $DELTA_AGENT_PROMPT ]] && agent_argv_fresh+=("$DELTA_AGENT_PROMPT")
		agent_argv_fresh_set=1
		agent_argv+=(--resume "$DELTA_AGENT_RESUME")
	elif [[ -n $DELTA_AGENT_PROMPT ]]; then
		agent_argv+=("$DELTA_AGENT_PROMPT")
	else
		agent_argv_fresh=("${agent_argv[@]}")
		agent_argv_fresh_set=1
		agent_argv+=(--continue)
	fi
}
