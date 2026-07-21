#!/usr/bin/env zsh

# Unified tmux session picker with tabbed fzf interface.
# Tabs: Directories | Worktrees | Issues | PRs
# Non-git directories show only the Directories tab.
#
# Bound to @tmux_delta_picker_key (default: C-g) in tmux-delta.tmux.

SELF="${0:A}"
SCRIPTS="${SELF:h}"
export TMUX_PICKER="$SELF"

source "${SCRIPTS}/gwt.zsh"
source "${SCRIPTS}/lib/pr-cache.sh"

# ─── Directory history ───────────────────────────────────────────────

_HIST_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/tmux/sessionizer-history"
mkdir -p "${_HIST_FILE:h}"

_record_dir_history() {
	local path="$1"
	local -a lines=("$path")
	if [[ -f $_HIST_FILE ]]; then
		while IFS= read -r line; do
			[[ $line == $path ]] && continue
			[[ -d $line ]] || continue
			lines+=("$line")
			(( ${#lines} >= 50 )) && break
		done < "$_HIST_FILE"
	fi
	printf '%s\n' "${lines[@]}" >| "$_HIST_FILE"
}

# ─── GitHub auth helpers ─────────────────────────────────────────────

_gh_repo_host() {
	local remote_url
	remote_url=$(git remote get-url origin 2>/dev/null) || return 1
	# Extract hostname from SSH (git@host:...) or HTTPS (https://host/...) remotes
	if [[ $remote_url =~ '^git@([^:]+):' ]]; then
		echo "${match[1]}"
	elif [[ $remote_url =~ '^https?://([^/]+)/' ]]; then
		echo "${match[1]}"
	fi
}

_gh_check_auth() {
	local host
	host=$(_gh_repo_host 2>/dev/null)
	if [[ -n $host ]]; then
		if ! gh auth status --hostname "$host" >/dev/null 2>&1; then
			printf '\t\033[31mgh not authenticated for %s — run: gh auth login --hostname %s\033[0m\n' "$host" "$host"
			return 1
		fi
	elif ! gh auth status >/dev/null 2>&1; then
		printf '\t\033[31mgh not authenticated — run: gh auth login\033[0m\n'
		return 1
	fi
	return 0
}

# ─── List generators (called by fzf reload) ─────────────────────────

_list_sessions() {
	local active_paths=$(tmux list-sessions -F '#{session_path}' 2>/dev/null || true)
	tmux list-sessions -F '#{session_name}:#{session_path}' 2>/dev/null \
		| while IFS=: read -r session_name session_path; do
			printf 'session:%s:%s\t\033[33m%s\033[0m\n' "$session_name" "$session_path" "$session_name"
		done
	if [[ -f $_HIST_FILE ]]; then
		while IFS= read -r dir; do
			[[ -d $dir ]] || continue
			echo "$active_paths" | grep -qxF "$dir" && continue
			local label="${dir:h:t}/${dir:t}"
			printf 'dir:%s\t%s\n' "$dir" "$label"
		done < "$_HIST_FILE"
	fi
}

_list_dirs() {
	local directories=${TMUX_SESSIONIZER_SEARCH_DIRS:-"$HOME/work"}
	local extra_dirs=${TMUX_SESSIONIZER_EXTRA_DIRS:-""}
	local active_paths=$(tmux list-sessions -F '#{session_path}' 2>/dev/null || true)
	{ find $directories -mindepth 2 -maxdepth 2 -type d; printf '%s\n' ${=extra_dirs}; } \
		| while IFS= read -r dir; do
			local label="${dir:h:t}/${dir:t}"
			if echo "$active_paths" | grep -qxF "$dir" 2>/dev/null; then
				printf 'dir:%s\t\033[33m%s\033[0m\n' "$dir" "$label"
			else
				printf 'dir:%s\t%s\n' "$dir" "$label"
			fi
		done
}

_list_worktrees() {
	local active_paths=$(tmux list-sessions -F '#{session_path}' 2>/dev/null || true)
	git worktree list | while read -r line; do
		[[ $line == *prunable\] ]] && continue
		local wt_path=${line%% *}
		local folder=${wt_path:t}
		local branch_field=${line##* }
		local branch=${branch_field//[\[\]]/}
		if echo "$active_paths" | grep -qxF "$wt_path" 2>/dev/null; then
			printf 'wt:%s\t\033[33m%s  \033[2m%s\033[0m\n' "$wt_path" "$branch" "$folder"
		else
			printf 'wt:%s\t%s  \033[2m%s\033[0m\n' "$wt_path" "$branch" "$folder"
		fi
	done

	local checked_out=$(git worktree list --porcelain \
		| awk '/^branch refs\/heads\// { sub("^branch refs/heads/", ""); print }')
	git branch -r --no-color 2>/dev/null | sed 's/^[* ]*//' | grep -v 'HEAD' \
		| while read -r ref; do
			local local_name=${ref#origin/}
			echo "$checked_out" | grep -qxF "$local_name" && continue
			printf 'remote:%s\t\033[36m%s\033[0m\n' "$local_name" "$ref"
		done
}

_list_issues() {
	_gh_check_auth || return
	local issues_json
	issues_json=$(gh issue list --state open --limit 1000 \
		--json number,title,labels,assignees 2>/dev/null)
	if [[ -z $issues_json || $issues_json == "[]" ]]; then
		printf '\t\033[2mNo open issues\033[0m\n'
		return
	fi

	local active_paths=$(tmux list-sessions -F '#{session_path}' 2>/dev/null || true)
	local -a active_issue_nums=()
	while IFS= read -r wt_line; do
		local wt_path=${wt_line%% *}
		local branch_raw=${wt_line##* }
		local branch=${branch_raw//[\[\]]/}
		if [[ $branch =~ -issue-([0-9]+)$ ]]; then
			local num=$match[1]
			echo "$active_paths" | grep -qxF "$wt_path" 2>/dev/null && active_issue_nums+=($num)
		fi
	done < <(git worktree list)

	echo "$issues_json" | jq -r '
		.[] |
		(.labels | map(.name) | join(",")) as $labels |
		(.assignees | map("@" + .login) | join(",")) as $assignees |
		(if $labels == "" then "" else "  [2m[\($labels)][0m" end) as $labels_col |
		(if $assignees == "" then "" else "  [2m\($assignees)[0m" end) as $assignees_col |
		"issue:\(.number)\t#\(.number)  \(.title)\($labels_col)\($assignees_col)"
	' | while IFS= read -r line; do
		local num=${line#issue:}
		num=${num%%$'\t'*}
		if (( ${active_issue_nums[(Ie)$num]} )); then
			local key=${line%%$'\t'*}
			local display=${line#*$'\t'}
			printf '%s\t\033[33m%s\033[0m\n' "$key" "$display"
		else
			printf '%s\n' "$line"
		fi
	done
}

_list_prs_closed() {
	_gh_check_auth || return
	local prs_json
	prs_json=$(gh pr list --state closed --limit 1000 \
		--json number,title,headRefName,author,mergedAt 2>/dev/null)
	if [[ -z $prs_json || $prs_json == "[]" ]]; then
		printf '\t\033[2mNo closed PRs\033[0m\n'
		return
	fi

	echo "$prs_json" | jq -r '
		.[] |
		(.author.login) as $author |
		(if .mergedAt != null then "  [32m⎇ merged[0m"
		 else "  [31m✗ closed[0m" end) as $status |
		"pr:\(.headRefName)\t#\(.number)  \(.title)  [2m@\($author)[0m\($status)"
	'
}

_list_prs_ready() {
	_gh_check_auth || return
	local prs_json
	prs_json=$(gh pr list --state open --limit 1000 \
		--json number,title,headRefName,author,isDraft,reviewDecision,statusCheckRollup 2>/dev/null)
	if [[ -z $prs_json || $prs_json == "[]" ]]; then
		printf '\t\033[2mNo open PRs\033[0m\n'
		return
	fi

	local filtered
	filtered=$(echo "$prs_json" | jq -r '
		.[] |
		select(
			.isDraft == false and
			.reviewDecision != "APPROVED" and
			(.statusCheckRollup | length > 0) and
			(.statusCheckRollup | all(
				if .__typename == "CheckRun" then
					.conclusion != null and
					(.conclusion | IN("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE") | not)
				elif .__typename == "StatusContext" then .state == "SUCCESS"
				else true end
			))
		) |
		(.author.login) as $author |
		(if .reviewDecision == "CHANGES_REQUESTED" then "  [31m✗[0m"
		 else "" end) as $review |
		"pr:\(.headRefName)\t#\(.number)  \(.title)  [2m@\($author)[0m\($review)"
	')

	if [[ -z $filtered ]]; then
		printf '\t\033[2mNo PRs ready for review\033[0m\n'
		return
	fi

	# Highlight branches with active tmux sessions
	local active_paths=$(tmux list-sessions -F '#{session_path}' 2>/dev/null || true)
	local -A active_branches=()
	while IFS= read -r wt_line; do
		local wt_path=${wt_line%% *}
		local branch_raw=${wt_line##* }
		local branch=${branch_raw//[\[\]]/}
		echo "$active_paths" | grep -qxF "$wt_path" 2>/dev/null && active_branches[$branch]=1
	done < <(git worktree list)

	echo "$filtered" | while IFS= read -r line; do
		local branch=${line#pr:}
		branch=${branch%%$'\t'*}
		if (( ${+active_branches[$branch]} )); then
			local key=${line%%$'\t'*}
			local display=${line#*$'\t'}
			printf '%s\t\033[33m%s\033[0m\n' "$key" "$display"
		else
			printf '%s\n' "$line"
		fi
	done
}

_list_prs() {
	_gh_check_auth || return
	local prs_json
	prs_json=$(gh pr list --state open --limit 1000 \
		--json number,title,headRefName,author,isDraft,reviewDecision 2>/dev/null)
	if [[ -z $prs_json || $prs_json == "[]" ]]; then
		printf '\t\033[2mNo open PRs\033[0m\n'
		return
	fi

	# Build set of branches with active tmux sessions (via worktree paths)
	local active_paths=$(tmux list-sessions -F '#{session_path}' 2>/dev/null || true)
	local -A active_branches=()
	while IFS= read -r wt_line; do
		local wt_path=${wt_line%% *}
		local branch_raw=${wt_line##* }
		local branch=${branch_raw//[\[\]]/}
		echo "$active_paths" | grep -qxF "$wt_path" 2>/dev/null && active_branches[$branch]=1
	done < <(git worktree list)

	echo "$prs_json" | jq -r '
		.[] |
		(.author.login) as $author |
		(if .isDraft then "[2m[draft][0m " else "" end) as $draft |
		(if .reviewDecision == "APPROVED" then "  [32m✓[0m"
		 elif .reviewDecision == "CHANGES_REQUESTED" then "  [31m✗[0m"
		 else "" end) as $review |
		"pr:\(.headRefName)\t#\(.number)  \($draft)\(.title)  [2m@\($author)[0m\($review)"
	' | while IFS= read -r line; do
		local branch=${line#pr:}
		branch=${branch%%$'\t'*}
		if (( ${+active_branches[$branch]} )); then
			local key=${line%%$'\t'*}
			local display=${line#*$'\t'}
			printf '%s\t\033[33m%s\033[0m\n' "$key" "$display"
		else
			printf '%s\n' "$line"
		fi
	done
}

# ─── Tab header ──────────────────────────────────────────────────────

_tab_header() {
	local active=$1
	local reset=$'\033[0m'
	local on=$'\033[1;7m'
	local off=$'\033[2m'
	local s d w i p c r
	[[ $active == sessions ]]  && s=$on || s=$off
	[[ $active == dirs ]]      && d=$on || d=$off
	[[ $active == worktrees ]] && w=$on || w=$off
	[[ $active == issues ]]    && i=$on || i=$off
	[[ $active == prs ]]       && p=$on || p=$off
	[[ $active == closed ]]    && c=$on || c=$off
	[[ $active == ready ]]     && r=$on || r=$off
	local tabs repo_name=""
	if git rev-parse --git-dir &>/dev/null; then
		tabs="${s} s:Sessions ${reset}  ${d} f:Dirs ${reset}  ${i} i:Issues ${reset}  ${w} w:Worktrees ${reset}  ${p} p:PRs ${reset}  ${c} Closed PRs ${reset}  ${r} r:Ready ${reset}"
		repo_name=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}' | xargs basename)
	else
		tabs="${s} s:Sessions ${reset}  ${d} f:Dirs ${reset}"
	fi
	local hints
	case $active in
		sessions)  hints="ctrl-x: delete · ctrl-e: open explorer · ctrl-o: open browser (git repos) · ctrl-h/l: switch" ;;
		worktrees) hints="ctrl-x: delete · ctrl-e: open explorer · ctrl-o: open browser · ctrl-h/l: switch" ;;
		issues)    hints="ctrl-a: autonomous · ctrl-o: open browser · ctrl-h/l: switch" ;;
		prs)       hints="ctrl-o: open browser · ctrl-h/l: switch" ;;
		closed)    hints="ctrl-o: open browser · ctrl-h/l: switch" ;;
		ready)     hints="ctrl-a: review all · ctrl-o: open browser · ctrl-h/l: switch" ;;

		dirs)      hints="ctrl-e: open explorer · ctrl-h/l: switch" ;;
		*)         hints="ctrl-h/l: switch" ;;
	esac
	if [[ -n $repo_name ]]; then
		printf '%s\n%s\n\033[33m%s\033[0m' "$tabs" "$hints" "$repo_name"
	else
		printf '%s\n%s' "$tabs" "$hints"
	fi
}

# ─── fzf transform subcommands ──────────────────────────────────────

_switch_tab() {
	local tab=$1
	case $tab in
		sessions)  echo "change-prompt(Sessions> )+reload($TMUX_PICKER --list-sessions)+transform-header($TMUX_PICKER --tab-header sessions)+clear-query" ;;
		dirs)      echo "change-prompt(Directories> )+reload($TMUX_PICKER --list-dirs)+transform-header($TMUX_PICKER --tab-header dirs)+clear-query" ;;
		worktrees)
			local current_wt pos=1
			current_wt=$(git rev-parse --show-toplevel 2>/dev/null)
			if [[ -n $current_wt ]]; then
				local i=0
				while IFS= read -r line; do
					(( i++ ))
					[[ ${line%%$'\t'*} == "wt:${current_wt}" ]] && pos=$i && break
				done < <("$TMUX_PICKER" --list-worktrees 2>/dev/null)
			fi
			echo "change-prompt(Worktrees> )+reload-sync($TMUX_PICKER --list-worktrees)+transform-header($TMUX_PICKER --tab-header worktrees)+clear-query+pos($pos)"
			;;
		issues)    echo "change-prompt(Issues> )+reload-sync($TMUX_PICKER --list-issues)+transform-header($TMUX_PICKER --tab-header issues)+clear-query" ;;
		prs)       echo "change-prompt(PRs> )+reload-sync($TMUX_PICKER --list-prs)+transform-header($TMUX_PICKER --tab-header prs)+clear-query" ;;
		closed)    echo "change-prompt(Closed PRs> )+reload-sync($TMUX_PICKER --list-prs-closed)+transform-header($TMUX_PICKER --tab-header closed)+clear-query" ;;
		ready)     echo "change-prompt(Ready> )+reload-sync($TMUX_PICKER --list-prs-ready)+transform-header($TMUX_PICKER --tab-header ready)+clear-query" ;;
	esac
}

_cycle_left() {
	if git rev-parse --git-dir &>/dev/null; then
		case "$1" in
			"Sessions> ")    _switch_tab prs ;;
			"Directories> ") _switch_tab sessions ;;
			"Issues> ")      _switch_tab dirs ;;
			"Worktrees> ")   _switch_tab issues ;;
			"PRs> ")         _switch_tab worktrees ;;
			"Closed PRs> ")  _switch_tab prs ;;
			"Ready> ")       _switch_tab closed ;;
		esac
	else
		case "$1" in
			"Sessions> ")    _switch_tab dirs ;;
			"Directories> ") _switch_tab sessions ;;
		esac
	fi
}

_cycle_right() {
	if git rev-parse --git-dir &>/dev/null; then
		case "$1" in
			"Sessions> ")    _switch_tab dirs ;;
			"Directories> ") _switch_tab issues ;;
			"Issues> ")      _switch_tab worktrees ;;
			"Worktrees> ")   _switch_tab prs ;;
			"PRs> ")         _switch_tab closed ;;
			"Closed PRs> ")  _switch_tab ready ;;
			"Ready> ")       _switch_tab dirs ;;
		esac
	else
		case "$1" in
			"Sessions> ")    _switch_tab dirs ;;
			"Directories> ") _switch_tab sessions ;;
		esac
	fi
}

_on_enter() {
	case "$1" in
		"Sessions> ")    echo "become(printf '%s\n%s' select {1})" ;;
		"Directories> ") echo "become(printf '%s\n%s' select {1})" ;;
		"Worktrees> ")   echo "become(printf '%s\n%s\n%s' select {1} {q})" ;;
		"Issues> ")      echo "become(printf '%s\n%s' interactive {1})" ;;
		"PRs> ")         echo "become(printf '%s\n%s' select {1})" ;;
		"Closed PRs> ")  echo "become(printf '%s\n%s' select {1})" ;;
		"Ready> ")       echo "become(printf '%s\n%s' select {1})" ;;
	esac
}

_on_ctrl_a() {
	case "$1" in
	"Issues> ") echo "become(printf '%s\n%s' autonomous {1})" ;;
	"Ready> ")  echo "become(printf 'review-all\n')" ;;
esac
}

_on_ctrl_x() {
	case "$1" in
		"Sessions> ")  echo "execute($TMUX_PICKER --delete-session {1})+abort" ;;
		"Worktrees> ") echo "execute($TMUX_PICKER --delete-wt {1})+abort" ;;
	esac
}

_on_ctrl_e() {
	case "$1" in
		"Sessions> ")    echo "execute($TMUX_PICKER --open-finder {1})+abort" ;;
		"Directories> ") echo "execute($TMUX_PICKER --open-finder {1})+abort" ;;
		"Worktrees> ")   echo "execute($TMUX_PICKER --open-finder {1})+abort" ;;
	esac
}

_open_finder() {
	local selected="$1"
	local path
	case "$selected" in
		session:*)
			local rest="${selected#session:}"
			path="${rest#*:}"
			;;
		dir:*)
			path="${selected#dir:}"
			;;
		wt:*)
			path="${selected#wt:}"
			;;
		*)
			return 0
			;;
	esac
	if [[ -d $path ]]; then
		local opener
		[[ -x /usr/bin/open ]] && opener=/usr/bin/open || opener=xdg-open
		"$opener" "$path"
	fi
}

_on_ctrl_o() {
	case "$1" in
		"Sessions> ")  echo "execute($TMUX_PICKER --open-browser {1})+abort" ;;
		"Issues> ")    echo "execute($TMUX_PICKER --open-browser {1})+abort" ;;
		"PRs> ")         echo "execute($TMUX_PICKER --open-browser {1})+abort" ;;
		"Closed PRs> ")  echo "execute($TMUX_PICKER --open-browser {1})+abort" ;;
		"Ready> ")       echo "execute($TMUX_PICKER --open-browser {1})+abort" ;;
		"Worktrees> ")   echo "execute($TMUX_PICKER --open-browser {1})+abort" ;;
	esac
}

_open_url() {
	local url="$1"
	[[ -z $url ]] && return 1
	if [[ "$(uname)" == "Darwin" ]]; then
		open "$url"
	else
		xdg-open "$url" &>/dev/null &
	fi
}

_browse_repo() {
	# Open PR if branch has one, otherwise open branch in browser
	local repo_path="$1"
	local branch="$2"
	local session_name="${3:-}"
	local url
	local pr_number
	# A cached PR number+url is safe to reuse even if stale — a PR's number
	# and url never change once assigned. Only fall back to a live `gh pr
	# view` when the cache has no PR on record yet (e.g. just opened, no
	# refresh cycle has run).
	local cached
	cached=$(pr_cache_read "$repo_path" "$branch")
	if [[ -n $cached ]]; then
		pr_number=$(printf '%s' "$cached" | jq -r '.pr_number // empty')
		[[ -n $pr_number ]] && url=$(printf '%s' "$cached" | jq -r '.url // empty')
	fi
	if [[ -z $pr_number ]]; then
		pr_number=$(cd "$repo_path" && gh pr view --json number --jq '.number' 2>/dev/null)
		[[ -n $pr_number ]] && url=$(cd "$repo_path" && gh pr view --json url --jq '.url' 2>/dev/null)
	fi
	if [[ -z $pr_number && -n $session_name ]]; then
		local issue_number
		issue_number=$(tmux show-environment -t "$session_name" CODING_AGENT_ISSUE 2>/dev/null | sed 's/CODING_AGENT_ISSUE=//')
		if [[ -n $issue_number && $issue_number != -* ]]; then
			url=$(cd "$repo_path" && gh issue view "$issue_number" --json url --jq '.url' 2>/dev/null)
		fi
	fi
	[[ -z $url ]] && url=$(cd "$repo_path" && gh browse --branch "$branch" --no-browser 2>/dev/null)
	_open_url "$url"
}

_open_browser() {
	local selected="$1"
	case "$selected" in
		issue:*) _open_url "$(gh issue view "${selected#issue:}" --json url --jq '.url' 2>/dev/null)" ;;
		pr:*)    _open_url "$(gh pr view "${selected#pr:}" --json url --jq '.url' 2>/dev/null)" ;;
		session:*)
			local rest="${selected#session:}"
			local session_name="${rest%%:*}"
			local repo_path="${rest#*:}"
			local branch=$(git -C "$repo_path" branch --show-current 2>/dev/null)
			[[ -n $branch ]] && _browse_repo "$repo_path" "$branch" "$session_name"
			;;
		dir:*)
			local repo_path="${selected#dir:}"
			local branch=$(git -C "$repo_path" branch --show-current 2>/dev/null)
			[[ -n $branch ]] && _browse_repo "$repo_path" "$branch"
			;;
		wt:*)
			local wt_path="${selected#wt:}"
			local branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
			[[ -n $branch ]] && _browse_repo "$wt_path" "$branch"
			;;
		remote:*)
			local branch="${selected#remote:}"
			local pr_number url
			pr_number=$(gh pr view "$branch" --json number --jq '.number' 2>/dev/null)
			if [[ -n $pr_number ]]; then
				url=$(gh pr view "$branch" --json url --jq '.url' 2>/dev/null)
			else
				url=$(gh browse --branch "$branch" --no-browser 2>/dev/null)
			fi
			_open_url "$url"
			;;
	esac
}

# ─── Shared confirm helper ──────────────────────────────────────────

_confirm() {
	local prompt="$1"
	read -q "reply?${prompt} [y/N] "
	echo
	[[ $reply == "y" ]]
}

# ─── Session / history delete (runs inside fzf execute) ────────────

_delete_session() {
	local raw="$1"
	case "$raw" in
		session:*)
			local rest="${raw#session:}"
			local session_name="${rest%%:*}"
			local session_path="${rest#*:}"
			# If the session is rooted in a linked git worktree, do the full
			# worktree delete (removes folder, branch, and session).
			# Resolve to the actual worktree root — session_path may be a
			# subdirectory if the active pane navigated away from the root.
			local wt_root main_tree
			wt_root=$(git -C "$session_path" rev-parse --show-toplevel 2>/dev/null)
			local check_path=${wt_root:-$session_path}
			main_tree=$(git -C "$check_path" worktree list 2>/dev/null | head -1 | awk '{print $1}')
			if [[ -n $main_tree && $check_path != $main_tree ]]; then
				_delete_wt "wt:$check_path"
			else
				if ! _confirm "Kill session '$session_name'?"; then
					echo "Aborted."
					sleep 0.5
					return 0
				fi
				tmux kill-session -t "$session_name" 2>/dev/null \
					&& echo "Session '$session_name' killed." \
					|| echo "Session '$session_name' not found."
				sleep 0.5
			fi
			;;
		dir:*)
			local dir="${raw#dir:}"
			if ! _confirm "Remove '$dir:t' from history?"; then
				echo "Aborted."
				sleep 0.3
				return 0
			fi
			if [[ -f $_HIST_FILE ]]; then
				local -a lines=()
				while IFS= read -r line; do
					[[ $line == $dir ]] && continue
					lines+=("$line")
				done < "$_HIST_FILE"
				printf '%s\n' "${lines[@]}" >| "$_HIST_FILE"
				echo "Removed '$dir:t' from history."
			fi
			sleep 0.3
			;;
		*)
			echo "Nothing to delete for '$raw'."
			sleep 0.5
			;;
	esac
}

# ─── Worktree delete (runs inside fzf execute) ──────────────────────

_delete_wt() {
	local raw="$1"
	if [[ $raw == remote:* ]]; then
		echo "Cannot delete a remote branch reference."
		sleep 1
		return
	fi
	local wt_path="${raw#wt:}"
	local branch=$(git -C "$wt_path" symbolic-ref --short HEAD 2>/dev/null)
	if ! _confirm "Remove worktree '${wt_path:t}' and delete branch '$branch'?"; then
		echo "Aborted."
		sleep 0.5
		return 0
	fi
	local session_name=$(basename "$wt_path" | tr . _)
	gwtrm -f "$wt_path"
	if [[ -f $_HIST_FILE ]]; then
		local -a lines=()
		while IFS= read -r line; do
			[[ $line == $wt_path ]] && continue
			lines+=("$line")
		done < "$_HIST_FILE"
		printf '%s\n' "${lines[@]}" >| "$_HIST_FILE"
	fi
	if [[ ! -d $wt_path ]] && tmux has-session -t="$session_name" 2>/dev/null; then
		tmux kill-session -t "$session_name"
		echo "Session '$session_name' killed."
		sleep 0.5
	fi
}

# ─── Session handlers ───────────────────────────────────────────────

# Set @session_label on a tmux session to the branch-only portion of its name
# (strips the repo-root prefix that gwta prepends to worktree folder names).
# Falls back gracefully: non-git sessions or the main worktree keep their
# full name so the status-format conditional stays correct.
_set_session_label() {
	local session_name="$1" session_path="$2" pr_number="${3:-}"
	local main_tree
	main_tree=$(git -C "$session_path" worktree list 2>/dev/null | awk 'NR==1{print $1}')
	[[ -z $main_tree ]] && return
	local repo_prefix short_label
	repo_prefix=$(basename "$main_tree" | tr . _)
	short_label=${session_name#${repo_prefix}-}
	if [[ -n $pr_number ]]; then
		local max_len=20
		if (( ${#short_label} > max_len )); then
			short_label="${short_label:0:$max_len}…"
		fi
		short_label="${pr_number}: ${short_label}"
	fi
	tmux set-option -t "$session_name" @session_label "$short_label"
}

_switch_session() {
	local name="$1"
	[[ -z $name ]] && exit 0
	local tmux_running=$(pgrep tmux)
	if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
		tmux attach-session -t "$name"
	else
		tmux switch-client -t "$name"
	fi
}

_open_session() {
	local selected="$1"
	[[ -z $selected ]] && exit 0
	_record_dir_history "$selected"
	local selected_name=$(basename "$selected" | tr . _)
	local tmux_running=$(pgrep tmux)
	local is_git=false
	git -C "$selected" rev-parse --git-dir &>/dev/null && is_git=true
	local newly_created=false
	if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
		tmux new-session -ds "$selected_name" -c "$selected"
		newly_created=true
		_set_session_label "$selected_name" "$selected"
		tmux attach-session -t "$selected_name"
		if $newly_created && $is_git; then
			sleep 0.5
			tmux send-keys -t "$selected_name" "${SCRIPTS}/tmux-dev-layout.sh" Enter
		fi
		exit 0
	fi
	if ! tmux has-session -t="$selected_name" 2>/dev/null; then
		tmux new-session -ds "$selected_name" -c "$selected"
		newly_created=true
	fi
	tmux switch-client -t "$selected_name"
	_set_session_label "$selected_name" "$selected"
	# The picker runs inside display-popup, so the client-session-changed hook
	# resolves pane_current_path against the popup's originating pane rather
	# than the new session. Re-run the refresh scripts targeted at the new
	# session so the pills reflect the worktree's directory.
	tmux run-shell -b -t "$selected_name" "$SCRIPTS/tmux-kube-status-refresh.sh"
	tmux run-shell -b -t "$selected_name" "$SCRIPTS/tmux-git-status-refresh.sh"
	if $newly_created && $is_git; then
		sleep 0.5
		tmux send-keys -t "$selected_name" "${SCRIPTS}/tmux-dev-layout.sh" Enter
	fi
}

_open_remote() {
	local remote_branch="$1"
	gwta "$remote_branch"
	local sanitized=${${${remote_branch// /-}//\//-}:l}
	local selected=$(git worktree list | grep -F "$sanitized" | awk '{print $1}')
	if [[ -z $selected ]]; then
		echo "Error: Failed to find newly created worktree"
		exit 1
	fi
	_open_session "$selected"
}

_create_branch() {
	local query="$1"
	while true; do
		read "reply?Branch '$query' not found. Create a new worktree? (Y/n) "
		[[ -z $reply || $reply == [yY] ]] && break
		[[ $reply == [nN] ]] && exit 0
		echo "Invalid input. Please enter y or n."
	done
	echo
	gwta "$query"
	local sanitized=${${${query// /-}//\//-}:l}
	local selected=$(git worktree list | grep -F "$sanitized" | awk '{print $1}')
	if [[ -z $selected ]]; then
		echo "Error: Failed to find newly created worktree"
		exit 1
	fi
	_open_session "$selected"
}

_open_pr() {
	local branch="$1"
	[[ -z $branch ]] && exit 0

	# Check if a worktree already exists for this branch
	local existing=$(git worktree list | while read -r line; do
		local wt_path=${line%% *}
		local branch_field=${line##* }
		local b=${branch_field//[\[\]]/}
		[[ $b == "$branch" ]] && echo "$wt_path" && break
	done)

	if [[ -n $existing ]]; then
		_open_session "$existing"
	else
		gwta "$branch"
		local sanitized=${${${branch// /-}//\//-}:l}
		local selected=$(git worktree list | grep -F "$sanitized" | awk '{print $1}')
		if [[ -z $selected ]]; then
			echo "Error: Failed to find newly created worktree"
			exit 1
		fi
		_open_session "$selected"
	fi
}

_open_pr_review() {
	local branch="$1"
	local do_switch="${2:-yes}"
	[[ -z $branch ]] && exit 0

	# Look up the PR number for the skill invocation
	local pr_number
	pr_number=$(gh pr view "$branch" --json number --jq '.number' 2>/dev/null)
	if [[ -z $pr_number ]]; then
		echo "Error: Could not find PR for branch '$branch'"
		sleep 1
		exit 1
	fi

	# Find or create worktree
	local existing=$(git worktree list | while read -r line; do
		local wt_path=${line%% *}
		local branch_field=${line##* }
		local b=${branch_field//[\[\]]/}
		[[ $b == "$branch" ]] && echo "$wt_path" && break
	done)

	local selected
	if [[ -n $existing ]]; then
		selected="$existing"
	else
		gwta "$branch"
		local sanitized=${${${branch// /-}//\//-}:l}
		selected=$(git worktree list | grep -F "$sanitized" | awk '{print $1}')
		if [[ -z $selected ]]; then
			echo "Error: Failed to find newly created worktree"
			exit 1
		fi
	fi

	local selected_name=$(basename "$selected" | tr . _)
	local tmux_running=$(pgrep tmux)

	_set_pr_env() {
		tmux set-environment -t "$selected_name" CODING_AGENT_PR "$pr_number"
		tmux set-environment -t "$selected_name" CODING_AGENT_MODE "review"
	}

	if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
		tmux new-session -ds "$selected_name" -c "$selected"
		_set_pr_env
		_set_session_label "$selected_name" "$selected" "$pr_number"
		tmux attach-session -t "$selected_name"
		tmux send-keys -t "$selected_name" "${SCRIPTS}/tmux-dev-layout.sh" Enter
		exit 0
	fi

	local newly_created=false
	if ! tmux has-session -t="$selected_name" 2>/dev/null; then
		tmux new-session -ds "$selected_name" -c "$selected"
		newly_created=true
	fi
	_set_session_label "$selected_name" "$selected" "$pr_number"
	[[ $do_switch == yes ]] && tmux switch-client -t "$selected_name"
	[[ $do_switch == yes ]] && tmux run-shell -b -t "$selected_name" "$SCRIPTS/tmux-kube-status-refresh.sh"
	[[ $do_switch == yes ]] && tmux run-shell -b -t "$selected_name" "$SCRIPTS/tmux-git-status-refresh.sh"
	_set_pr_env
	if $newly_created; then
		sleep 0.5
		tmux send-keys -t "$selected_name" "${SCRIPTS}/tmux-dev-layout.sh" Enter
	fi
}

_open_all_pr_reviews() {
	local -a branches=()
	while IFS=$'\t' read -r key _; do
		[[ $key == pr:* ]] || continue
		branches+=("${key#pr:}")
	done < <(_list_prs_ready)

	[[ ${#branches} -eq 0 ]] && return

	# Create all sessions in the background first
	for branch in "${branches[@]}"; do
		_open_pr_review "$branch" no-switch
	done
	# Then switch to the first one
	_open_pr_review "${branches[1]}" yes
}

_open_issue() {
	local issue_number="$1" mode="$2"
	[[ ! $issue_number =~ ^[0-9]+$ ]] && exit 0

	local issue_json=$(gh issue view "$issue_number" --json title 2>/dev/null)
	if [[ -z $issue_json ]]; then
		echo "Error: Failed to fetch issue #$issue_number"
		exit 1
	fi
	local issue_title=$(echo "$issue_json" | jq -r '.title')

	# Derive branch slug
	local lower_title=${issue_title:l}
	local slug=${lower_title//[^a-z0-9]/-}
	while [[ $slug == *--* ]]; do slug=${slug//--/-}; done
	slug=${slug#-}; slug=${slug%-}
	slug=${slug:0:40}; slug=${slug%-}
	[[ -z $slug ]] && slug="work"
	local branch="${slug}-issue-${issue_number}"

	# Idempotency: find existing worktree for this issue
	local existing=$(git worktree list --porcelain | awk -v n="$issue_number" '
		/^worktree / { p=$2 }
		/^branch refs\/heads\// {
			b=$2; sub("refs/heads/", "", b)
			if (b ~ "-issue-"n"$") { print p; exit }
		}
	')

	local selected is_new_worktree
	if [[ -n $existing ]]; then
		selected="$existing"
		is_new_worktree=0
		echo "Reusing existing worktree: $selected"
	else
		# Before creating a new branch, check if this issue already has an open PR
		local linked_pr_data
		linked_pr_data=$(gh issue view "$issue_number" --json linkedPullRequests 2>/dev/null | \
			jq -r '.linkedPullRequests[] | select(.state == "OPEN") | "\(.number)\t\(.title)\t\(.headRefName)"' | \
			head -1)
		if [[ -n $linked_pr_data ]]; then
			local pr_num=${linked_pr_data%%$'\t'*}
			local pr_rest=${linked_pr_data#*$'\t'}
			local pr_title=${pr_rest%%$'\t'*}
			local pr_branch=${pr_rest#*$'\t'}
			echo "⚠  Issue #$issue_number already has an open PR: #$pr_num  $pr_title"
			if _confirm "Open the existing PR branch ($pr_branch) instead?"; then
				_open_pr "$pr_branch"
				return
			fi
		fi
		gwta "$branch"
		local sanitized=${${${branch// /-}//\//-}:l}
		selected=$(git worktree list | grep -F "$sanitized" | awk '{print $1}')
		if [[ -z $selected ]]; then
			echo "Error: Failed to find newly created worktree"
			exit 1
		fi
		is_new_worktree=1
	fi

	local selected_name=$(basename "$selected" | tr . _)
	local tmux_running=$(pgrep tmux)

	_set_issue_env() {
		tmux set-environment -t "$selected_name" CODING_AGENT_ISSUE "$issue_number"
		tmux set-environment -t "$selected_name" CODING_AGENT_MODE "$mode"
	}

	if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
		tmux new-session -ds "$selected_name" -c "$selected"
		_set_issue_env
		_set_session_label "$selected_name" "$selected"
		tmux attach-session -t "$selected_name"
		tmux send-keys -t "$selected_name" "${SCRIPTS}/tmux-dev-layout.sh" Enter
		exit 0
	fi

	local newly_created=false
	if ! tmux has-session -t="$selected_name" 2>/dev/null; then
		tmux new-session -ds "$selected_name" -c "$selected"
		newly_created=true
	fi
	tmux switch-client -t "$selected_name"
	_set_session_label "$selected_name" "$selected"
	tmux run-shell -b -t "$selected_name" "$SCRIPTS/tmux-kube-status-refresh.sh"
	tmux run-shell -b -t "$selected_name" "$SCRIPTS/tmux-git-status-refresh.sh"
	if $newly_created; then
		_set_issue_env
		sleep 0.5
		tmux send-keys -t "$selected_name" "${SCRIPTS}/tmux-dev-layout.sh" Enter
	fi
}

# ─── Subcommand dispatch ────────────────────────────────────────────

case "${1:-}" in
	--list-sessions)  _list_sessions;              exit ;;
	--list-dirs)      _list_dirs;                  exit ;;
	--list-worktrees) _list_worktrees;             exit ;;
	--list-issues)    _list_issues;                exit ;;
	--list-prs)        _list_prs;                  exit ;;
	--list-prs-closed) _list_prs_closed;           exit ;;
	--list-prs-ready)  _list_prs_ready;            exit ;;
	--tab-header)     _tab_header "$2";            exit ;;
	--delete-session) _delete_session "$2";        exit ;;
	--delete-wt)      _delete_wt "$2";             exit ;;
	--switch-tab)     _switch_tab "$2";            exit ;;
	--cycle-left)     _cycle_left "$2";            exit ;;
	--cycle-right)    _cycle_right "$2";           exit ;;
	--on-enter)       _on_enter "$2";              exit ;;
	--on-ctrl-a)      _on_ctrl_a "$2";             exit ;;
	--on-ctrl-x)      _on_ctrl_x "$2";             exit ;;
	--on-ctrl-e)      _on_ctrl_e "$2";             exit ;;
	--open-finder)    _open_finder "$2";           exit ;;
	--on-ctrl-o)      _on_ctrl_o "$2";             exit ;;
	--open-browser)   _open_browser "$2";          exit ;;
esac

# ─── Main ───────────────────────────────────────────────────────────

_common_binds=(
	--bind 'ctrl-s:transform:$TMUX_PICKER --switch-tab sessions'
	--bind 'ctrl-f:transform:$TMUX_PICKER --switch-tab dirs'
	--bind 'ctrl-h:transform:$TMUX_PICKER --cycle-left "$FZF_PROMPT"'
	--bind 'ctrl-l:transform:$TMUX_PICKER --cycle-right "$FZF_PROMPT"'
	--bind 'enter:transform:$TMUX_PICKER --on-enter "$FZF_PROMPT"'
	--bind 'ctrl-x:transform:$TMUX_PICKER --on-ctrl-x "$FZF_PROMPT"'
)

# Pre-generate sessions list and header in parallel to reduce fzf startup latency.
# _tab_header is called as a function (not a subprocess) in the background to avoid
# re-forking the whole script; _list_sessions runs concurrently in the foreground.
_header_file=$(mktemp)
_tab_header sessions >| "$_header_file" &
_header_pid=$!
_sessions_list=$("$SELF" --list-sessions)
wait $_header_pid
_header=$(cat "$_header_file")
rm -f "$_header_file"

_current_session_pos=1
if [[ -n $TMUX ]]; then
	_current=$(tmux display-message -p '#S' 2>/dev/null)
	_pos=0
	while IFS= read -r _line; do
		(( _pos++ ))
		[[ $_line == "session:${_current}:"* ]] && _current_session_pos=$_pos && break
	done <<< "$_sessions_list"
fi

if git rev-parse --git-dir &>/dev/null; then
	output=$(echo "$_sessions_list" | fzf --ansi \
		--delimiter=$'\t' --with-nth=2 \
		--prompt 'Sessions> ' \
		--header "$_header" \
		"${_common_binds[@]}" \
		--bind "load:pos($_current_session_pos)+unbind(load)" \
		--bind 'ctrl-w:transform:$TMUX_PICKER --switch-tab worktrees' \
		--bind 'ctrl-i:transform:$TMUX_PICKER --switch-tab issues' \
		--bind 'ctrl-p:transform:$TMUX_PICKER --switch-tab prs' \
		--bind 'ctrl-r:transform:$TMUX_PICKER --switch-tab ready' \
		--bind 'ctrl-a:transform:$TMUX_PICKER --on-ctrl-a "$FZF_PROMPT"' \
		--bind 'ctrl-e:transform:$TMUX_PICKER --on-ctrl-e "$FZF_PROMPT"' \
		--bind 'ctrl-o:transform:$TMUX_PICKER --on-ctrl-o "$FZF_PROMPT"' \
	)
else
	output=$(echo "$_sessions_list" | fzf --ansi \
		--delimiter=$'\t' --with-nth=2 \
		--prompt 'Sessions> ' \
		--header "$_header" \
		"${_common_binds[@]}" \
		--bind "load:pos($_current_session_pos)+unbind(load)" \
	)
fi

[[ -z $output ]] && exit 0

# Parse structured output from become()
# Line 1: mode (select | interactive | autonomous | review)
# Line 2: prefixed item (dir:… | wt:… | remote:… | issue:…)
# Line 3: fzf query (worktrees tab only)
mode=$(echo "$output" | sed -n '1p')
selected=$(echo "$output" | sed -n '2p')
query=$(echo "$output" | sed -n '3p')

if [[ $mode == review-all ]]; then
	_open_all_pr_reviews
	exit 0
fi

case "$selected" in
	session:*) _switch_session "${${selected#session:}%%:*}" ;;
	dir:*)     _open_session "${selected#dir:}" ;;
	wt:*)      _open_session "${selected#wt:}" ;;
	remote:*)  _open_remote "${selected#remote:}" ;;
	issue:*)   _open_issue "${selected#issue:}" "$mode" ;;
	pr:*)
		if [[ $mode == review ]]; then
			_open_pr_review "${selected#pr:}"
		else
			_open_pr "${selected#pr:}"
		fi
		;;
	"")        [[ -n $query ]] && _create_branch "$query" ;;
esac
