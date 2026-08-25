#!/usr/bin/env zsh
# Adapter: codex (OpenAI Codex CLI). See ../agent-adapter.sh for the contract.
#
# Two things codex does not have:
#   * No --append-system-prompt. Writing the managed-worker instructions into
#     the worktree's AGENTS.md would pollute the diff the worker then commits,
#     so they are prepended to the initial prompt instead. Weaker than a real
#     system prompt — the model can be talked out of them — but non-invasive.
#   * No --continue. Resuming is the `resume --last` subcommand, which must come
#     before any flags.
#
# Sandbox/approval flags (--full-auto, --sandbox, -a) go through
# DELTA_AGENT_FLAGS verbatim.

delta_agent_argv() {
	agent_argv=()

	# `resume --last` is a subcommand, so it has to precede every flag.
	if [[ -z $DELTA_AGENT_PROMPT ]]; then
		agent_argv+=(resume --last)
		agent_argv_fresh_set=1
	fi

	[[ -n $DELTA_AGENT_MODEL ]] && agent_argv+=(--model "$DELTA_AGENT_MODEL")
	[[ -n $DELTA_AGENT_FLAGS ]] && agent_argv+=(${=DELTA_AGENT_FLAGS})

	if (( ${+agent_argv_fresh_set} )); then
		agent_argv_fresh=("${(@)agent_argv[3,-1]}")
	fi

	if [[ -n $DELTA_AGENT_PROMPT ]]; then
		local prompt="$DELTA_AGENT_PROMPT"
		[[ -n $DELTA_AGENT_SYSTEM ]] && prompt="${DELTA_AGENT_SYSTEM}"$'\n\n'"${prompt}"
		agent_argv+=("$prompt")
	fi
}
