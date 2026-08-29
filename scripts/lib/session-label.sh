#!/usr/bin/env zsh

# The short "pill" label a session shows in the status line.
#
# Shared because two callers must agree on it exactly: the picker sets it when
# it creates a session, and `tmux-apex.sh recover` sets it when it recreates one
# after a crash. A recovered session whose label differs from the one that died
# reads as a *different* session to the human, which is the whole thing recovery
# is trying to avoid. This used to be a hand-kept copy in tmux-apex.sh whose own
# comment said "kept in step with" — the standing invitation to drift.

# delta_session_label <session-name> <session-path> [pr-number] — set
# @session_label on <session-name>. No-op outside a git worktree.
delta_session_label() {
	local session_name="$1" session_path="$2" pr_number="${3:-}"
	local main_tree
	main_tree=$(git -C "$session_path" worktree list 2>/dev/null | awk 'NR==1{print $1}')
	[[ -z $main_tree ]] && return 0

	local repo_prefix short_label
	repo_prefix=$(basename "$main_tree" | tr . _)
	short_label=${session_name#${repo_prefix}-}

	# A PR label carries the number, so the branch part gets a budget.
	if [[ -n $pr_number ]]; then
		local max_len=20
		(( ${#short_label} > max_len )) && short_label="${short_label:0:$max_len}…"
		short_label="${pr_number}: ${short_label}"
	fi

	tmux set-option -t "$session_name" @session_label "$short_label" 2>/dev/null
}
