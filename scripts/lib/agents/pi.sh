#!/usr/bin/env zsh
# Adapter: pi (@earendil-works/pi-coding-agent).
# --model and --append-system-prompt are spelled exactly as claude's.
# There is no --permission-mode: pi gates with a --tools allowlist, --approve,
# and whatever extensions are installed, so DELTA_AGENT_FLAGS is passed
# verbatim. See ../agent-adapter.sh for the contract.

delta_agent_argv() {
	agent_argv=()
	# pi accepts "provider/id" and a ":<thinking>" suffix here.
	[[ -n $DELTA_AGENT_MODEL  ]] && agent_argv+=(--model "$DELTA_AGENT_MODEL")
	[[ -n $DELTA_AGENT_FLAGS  ]] && agent_argv+=(${=DELTA_AGENT_FLAGS})
	[[ -n $DELTA_AGENT_SYSTEM ]] && agent_argv+=(--append-system-prompt "$DELTA_AGENT_SYSTEM")

	if [[ -n $DELTA_AGENT_PROMPT ]]; then
		agent_argv+=("$DELTA_AGENT_PROMPT")
	else
		agent_argv_fresh=("${agent_argv[@]}")
		agent_argv_fresh_set=1
		agent_argv+=(--continue)
	fi
}
