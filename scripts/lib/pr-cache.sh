#!/usr/bin/env bash
# Shared helpers for the consolidated PR cache (~/.cache/tmux-pr/<key>.json).
# Sourced by tmux-pr-status-refresh.sh, tmux-git-status-refresh.sh, and
# tmux-picker.sh so all three agree on cache key derivation, file location,
# and read/write semantics. One JSON blob per session+branch replaces the
# old ~/.cache/tmux-pr-status/ and ~/.cache/tmux-pr-title/ flat-file caches.

PR_CACHE_DIR="${HOME}/.cache/tmux-pr"

pr_cache_key() {
	local pane_path="$1" branch="$2"
	printf '%s_%s' "$pane_path" "$branch" \
		| tr -cs 'A-Za-z0-9_-' '_' \
		| cut -c1-120
}

pr_cache_file() {
	local pane_path="$1" branch="$2"
	printf '%s/%s.json' "$PR_CACHE_DIR" "$(pr_cache_key "$pane_path" "$branch")"
}

pr_cache_read() {
	local pane_path="$1" branch="$2" file
	file=$(pr_cache_file "$pane_path" "$branch")
	[[ -f "$file" ]] && cat "$file"
}

# Seconds since the cache entry was last written, or a large number if absent.
pr_cache_age() {
	local pane_path="$1" branch="$2" file now mtime
	file=$(pr_cache_file "$pane_path" "$branch")
	if [[ ! -f "$file" ]]; then
		printf '%s' 999999
		return
	fi
	now=$(date +%s)
	mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo 0)
	printf '%s' $(( now - mtime ))
}

# Atomic write: temp file in the same dir, then mv, so concurrent readers
# never see a partially-written cache entry.
pr_cache_write() {
	local pane_path="$1" branch="$2" json="$3" file tmp
	file=$(pr_cache_file "$pane_path" "$branch")
	mkdir -p "$PR_CACHE_DIR"
	tmp=$(mktemp "${PR_CACHE_DIR}/.tmp.XXXXXX") || return 1
	printf '%s' "$json" > "$tmp"
	mv "$tmp" "$file"
}
