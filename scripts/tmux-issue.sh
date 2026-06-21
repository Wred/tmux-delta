#!/usr/bin/env zsh

# Pick an open GitHub issue and spin up a worktree-backed tmux session for it.
# Layout is driven by .envrc in the worktree directory.
#
# Superseded by the Issues tab in tmux-picker.sh. Kept for direct CLI use.

# Fail if not in a git repo
if ! git rev-parse --git-dir &>/dev/null; then
	echo "Error: Not inside a git repository"
	exit 1
fi

# Fail if gh is not authenticated
if ! gh auth status &>/dev/null; then
	echo "Error: gh is not authenticated. Run 'gh auth login'."
	exit 1
fi

# Source gwt.zsh for worktree creation
source "$(dirname "$0")/gwt.zsh"

# Fetch open issues. No label filter — source-agnostic.
issues_json=$(gh issue list --state open --limit 1000 \
	--json number,title,labels,assignees 2>/dev/null)

if [[ -z $issues_json || $issues_json == "[]" ]]; then
	echo "No open issues found."
	exit 0
fi

formatted=$(echo "$issues_json" | jq -r '
  .[] |
  (.labels | map(.name) | join(",")) as $labels |
  (.assignees | map("@" + .login) | join(",")) as $assignees |
  (if $labels == "" then "" else "  [2m[\($labels)][0m" end) as $labels_col |
  (if $assignees == "" then "" else "  [2m\($assignees)[0m" end) as $assignees_col |
  "\(.number)\t#\(.number)  \(.title)\($labels_col)\($assignees_col)"
')

# Highlight issues that already have an active tmux session (via their worktree)
active_issue_nums=()
while IFS= read -r wt_line; do
	wt_path=${wt_line%% *}
	branch_raw=${wt_line##* }
	branch=${branch_raw//[\[\]]/}
	if [[ $branch =~ -issue-([0-9]+)$ ]]; then
		num=$match[1]
		session=$(basename "$wt_path" | tr . _)
		tmux has-session -t="$session" 2>/dev/null && active_issue_nums+=($num)
	fi
done < <(git worktree list)

if (( ${#active_issue_nums} > 0 )); then
	formatted=$(echo "$formatted" | while IFS= read -r line; do
		num=${line%%$'\t'*}
		if (( ${active_issue_nums[(Ie)$num]} )); then
			display=${line#*$'\t'}
			printf '%s\t\033[33m%s\033[0m\n' "$num" "$display"
		else
			printf '%s\n' "$line"
		fi
	done)
fi

result=$(echo "$formatted" | fzf --ansi --delimiter=$'\t' --with-nth=2 \
	--header "enter: interactive · ctrl-a: autonomous" \
	--expect "ctrl-a")
key=$(echo "$result" | sed -n '1p')
selected_line=$(echo "$result" | sed -n '2p')
issue_number=${selected_line%%$'\t'*}

if [[ -z $issue_number ]]; then
	exit 0
fi

if [[ $key == "ctrl-a" ]]; then
	mode="autonomous"
else
	mode="interactive"
fi

issue_json=$(gh issue view "$issue_number" --json title 2>/dev/null)
if [[ -z $issue_json ]]; then
	echo "Error: Failed to fetch issue #$issue_number"
	exit 1
fi

issue_title=$(echo "$issue_json" | jq -r '.title')

lower_title=${issue_title:l}
slug=${lower_title//[^a-z0-9]/-}
while [[ $slug == *--* ]]; do
	slug=${slug//--/-}
done
slug=${slug#-}
slug=${slug%-}
slug=${slug:0:40}
slug=${slug%-}
[[ -z $slug ]] && slug="work"

branch="${slug}-issue-${issue_number}"

existing=$(git worktree list --porcelain | awk -v n="$issue_number" '
	/^worktree / { path=$2 }
	/^branch refs\/heads\// {
		b=$2
		sub("refs/heads/", "", b)
		if (b ~ "-issue-"n"$") { print path; exit }
	}
')

if [[ -n $existing ]]; then
	selected="$existing"
	is_new_worktree=0
	echo "Reusing existing worktree: $selected"
else
	gwta "$branch"

	sanitized=${${${branch// /-}//\//-}:l}
	selected=$(git worktree list | grep -F "$sanitized" | awk '{print $1}')
	if [[ -z $selected ]]; then
		echo "Error: Failed to find newly created worktree"
		exit 1
	fi
	is_new_worktree=1
fi

if [[ $is_new_worktree == 1 ]]; then
	if ! gh issue edit "$issue_number" --add-assignee @me >/dev/null 2>&1; then
		echo "Warning: failed to assign issue #$issue_number to @me (continuing)"
	fi
	if ! gh issue comment "$issue_number" \
		--body "Started work on this in branch \`${branch}\`." >/dev/null 2>&1; then
		echo "Warning: failed to post branch comment on issue #$issue_number (continuing)"
	fi
fi

selected_name=$(basename "$selected" | tr . _)
tmux_running=$(pgrep tmux)

set_issue_env() {
	tmux set-environment -t "$selected_name" CODING_AGENT_ISSUE "$issue_number"
	tmux set-environment -t "$selected_name" CODING_AGENT_MODE "$mode"
}

if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
	tmux new-session -ds "$selected_name" -c "$selected"
	set_issue_env
	tmux attach-session -t "$selected_name"
	exit 0
fi

newly_created=false
if ! tmux has-session -t="$selected_name" 2>/dev/null; then
	tmux new-session -ds "$selected_name" -c "$selected"
	newly_created=true
fi

tmux switch-client -t "$selected_name"

if $newly_created; then
	set_issue_env
fi
