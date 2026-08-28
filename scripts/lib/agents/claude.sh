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
	# No fresh fallback on this path, deliberately. agent-adapter.sh fires the
	# fallback on ANY non-zero exit, not just "there was nothing to resume", and
	# the fallback argv here would carry DELTA_AGENT_PROMPT — so an agent that
	# was interrupted, crashed mid-turn, or hit a transient API error would
	# immediately relaunch with the full autonomous prompt and redo the task:
	# duplicate commits, duplicate draft PR. `recover` is the only caller that
	# sets DELTA_AGENT_RESUME and it only passes an id it just located a
	# transcript for, so "nothing to resume" is already ruled out before we get
	# here; a resume that still fails should surface as an error, not as a
	# second run of the task.
	if [[ -n $DELTA_AGENT_RESUME ]]; then
		agent_argv+=(--resume "$DELTA_AGENT_RESUME")
	elif [[ -n $DELTA_AGENT_PROMPT ]]; then
		agent_argv+=("$DELTA_AGENT_PROMPT")
	else
		agent_argv_fresh=("${agent_argv[@]}")
		agent_argv_fresh_set=1
		agent_argv+=(--continue)
	fi
}
