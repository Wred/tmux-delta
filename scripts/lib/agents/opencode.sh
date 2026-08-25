#!/usr/bin/env zsh
# Adapter: opencode (sst/opencode). See ../agent-adapter.sh for the contract.
#
# opencode has no --append-system-prompt either, but unlike codex it does not
# need the prompt-prepending compromise: OPENCODE_CONFIG_CONTENT is merged into
# the resolved config rather than replacing it (verified with
# `opencode debug config`), so the managed-worker instructions go in as real
# `instructions`. The file lives in the cache dir, never in the worktree — an
# AGENTS.md there would end up in the diff the worker commits.
#
# The initial prompt is the --prompt flag, not a positional.
# Permissions: --auto auto-approves, passed through DELTA_AGENT_FLAGS.

delta_agent_argv() {
	agent_argv=()
	# opencode wants "provider/model".
	[[ -n $DELTA_AGENT_MODEL ]] && agent_argv+=(--model "$DELTA_AGENT_MODEL")
	[[ -n $DELTA_AGENT_FLAGS ]] && agent_argv+=(${=DELTA_AGENT_FLAGS})

	if [[ -n $DELTA_AGENT_SYSTEM ]]; then
		local dir="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-delta/agent-prompts"
		local file="${dir}/$(tmux display-message -p '#S' 2>/dev/null || print opencode).md"
		mkdir -p "$dir" && print -r -- "$DELTA_AGENT_SYSTEM" > "$file" || file=""

		if [[ -n $file ]]; then
			# Merge into whatever the user already had in the env var.
			export OPENCODE_CONFIG_CONTENT=$(
				jq -nc --arg f "$file" --argjson base "${OPENCODE_CONFIG_CONTENT:-{\}}" \
					'$base * {instructions: (($base.instructions // []) + [$f])}'
			)
		fi
	fi

	if [[ -n $DELTA_AGENT_PROMPT ]]; then
		agent_argv+=(--prompt "$DELTA_AGENT_PROMPT")
	else
		agent_argv_fresh=("${agent_argv[@]}")
		agent_argv_fresh_set=1
		agent_argv+=(--continue)
	fi
}
