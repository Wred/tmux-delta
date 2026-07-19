#!/usr/bin/env bash
# Updates @git_branch_cache, @git_icon_cache, and @git_repo_cache on the tmux
# server based on the active pane's current directory and its git remote.
#
# Service detection (fast path, by hostname pattern):
#   github.com                        → GitHub public
#   *gitlab* / *bitbucket* / *gitea*  → respective service
#
# For any hostname not caught by the fast path, probes the service API and
# caches the result in ~/.cache/tmux-git-service/<hostname> so the network
# is only hit once per host. This covers enterprise GitHub/GitLab/Gitea
# instances with non-obvious hostnames.

set -u

ICON_GITHUB=$'\xef\x82\x9b'   # U+F09B  nf-fa-github
ICON_GITLAB=$'\xef\x8a\x96'   # U+F296  nf-fa-gitlab
ICON_BITBUCKET=$'\xef\x85\xb1' # U+F171  nf-fa-bitbucket
ICON_GITEA=$'\xef\x8c\xb9'    # U+F339  nf-md-tea
ICON_GENERIC=$'\xee\x82\xa0'  # U+E0A0  nf-pl-branch

pane_path=$(tmux display-message -p -F '#{pane_current_path}' 2>/dev/null || true)
[[ -n "${pane_path:-}" && -d "$pane_path" ]] || pane_path="$HOME"

branch=$(cd "$pane_path" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

if [[ -n "$branch" ]]; then
  remote_url=$(cd "$pane_path" && git remote get-url origin 2>/dev/null || true)
  # Extract scheme and hostname (preserving port) from SSH or HTTP(S) remote URLs.
  # SSH:   git@host:path  → scheme=https, host=host  (port unknown, assume standard)
  # HTTP:  http://host:port/path → scheme=http, host=host:port
  # HTTPS: https://host/path    → scheme=https, host=host
  if [[ "$remote_url" == git@* ]]; then
    scheme="https"
    hostname="${remote_url#git@}"; hostname="${hostname%%:*}"
  elif [[ "$remote_url" == http://* ]]; then
    scheme="http"
    hostname="${remote_url#http://}"; hostname="${hostname%%/*}"
  elif [[ "$remote_url" == https://* ]]; then
    scheme="https"
    hostname="${remote_url#https://}"; hostname="${hostname%%/*}"
  else
    scheme="https"; hostname=""
  fi

  # Fast path: well-known hostnames and explicit env var lists
  icon=""
  if [[ "$hostname" == "github.com" ]]; then
    icon="$ICON_GITHUB"
  fi

  if [[ -z "$icon" ]]; then
    case "$hostname" in
      *gitlab*)    icon="$ICON_GITLAB" ;;
      *bitbucket*) icon="$ICON_BITBUCKET" ;;
      *gitea*)     icon="$ICON_GITEA" ;;
    esac
  fi

  # Slow path: probe service API for unknown hostnames, cache result per host
  if [[ -z "$icon" && -n "$hostname" ]]; then
    cache_dir="${HOME}/.cache/tmux-git-service"
    cache_file="${cache_dir}/${hostname//:/_}"
    mkdir -p "$cache_dir"

    if [[ -f "$cache_file" ]]; then
      cached_service=$(cat "$cache_file")
    else
      cached_service="generic"
      base="${scheme}://${hostname}"
      if curl -sf --max-time 3 "${base}/api/v3/meta" 2>/dev/null \
          | grep -qE '"github_services_sha"|"installed_version"'; then
        cached_service="github"
      elif curl -sf --max-time 3 "${base}/api/v4/version" 2>/dev/null \
          | grep -q '"version"'; then
        cached_service="gitlab"
      elif curl -sf --max-time 3 "${base}/api/v1/version" 2>/dev/null \
          | grep -q '"version"'; then
        cached_service="gitea"
      fi
      printf '%s' "$cached_service" > "$cache_file"
    fi

    case "$cached_service" in
      github)    icon="$ICON_GITHUB" ;;
      gitlab)    icon="$ICON_GITLAB" ;;
      gitea)     icon="$ICON_GITEA" ;;
      *)         icon="$ICON_GENERIC" ;;
    esac
  fi

  [[ -z "$icon" ]] && icon="$ICON_GENERIC"
else
  icon=""
fi

# Derive main worktree (repo root) name for the @git_repo_cache pill.
# git worktree list always prints the main tree first; its basename is
# the repo name regardless of which worktree the pane is currently in.
if [[ -n "$branch" ]]; then
  main_wt_path=$(cd "$pane_path" && git worktree list 2>/dev/null | awk 'NR==1{print $1}')
  repo="${main_wt_path##*/}"
else
  repo=""
fi

# Fetch the current branch's PR title (if any) for the repo pill's second
# segment. Falls back to the raw branch name when there's no open PR, since
# a real title is far more readable than a dash-separated branch slug.
pr_title=""
if [[ -n "$branch" ]] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  cache_dir="${HOME}/.cache/tmux-pr-title"
  mkdir -p "$cache_dir"
  key=$(printf '%s_%s' "$pane_path" "$branch" | tr -cs 'A-Za-z0-9_-' '_' | cut -c1-120)
  cache_file="${cache_dir}/${key}"

  age=999999
  if [[ -f "$cache_file" ]]; then
    now=$(date +%s)
    mtime=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
  fi

  if [[ $age -lt 60 ]]; then
    pr_title=$(cat "$cache_file")
  else
    pr_title=$(cd "$pane_path" && gh pr view --json title -q .title 2>/dev/null || true)
    printf '%s' "$pr_title" > "$cache_file"
  fi
fi

if [[ -n "$pr_title" ]]; then
  repo_label="${repo}: ${pr_title}"
elif [[ -n "$branch" ]]; then
  repo_label="${repo}: ${branch}"
else
  repo_label="$repo"
fi

# Determine session type: folder (no git), git-main (main worktree), or worktree (linked).
if [[ -z "$branch" ]]; then
  session_type="folder"
else
  actual_wt=$(cd "$pane_path" && git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ "$actual_wt" == "$main_wt_path" ]]; then
    session_type="git-main"
  else
    session_type="worktree"
  fi
fi

current_session=$(tmux display-message -p '#S' 2>/dev/null || true)
prev_session_type=""
[[ -n "$current_session" ]] && prev_session_type=$(tmux show-option -t "$current_session" -qv @session_type 2>/dev/null || true)

prev_branch=$(tmux show-option -gqv @git_branch_cache)
prev_icon=$(tmux show-option -gqv @git_icon_cache)
prev_repo=$(tmux show-option -gqv @git_repo_cache)
prev_repo_label=$(tmux show-option -gqv @git_repo_label_cache)

if [[ "$branch" != "$prev_branch" || "$icon" != "$prev_icon" || "$repo" != "$prev_repo" || "$repo_label" != "$prev_repo_label" || "$session_type" != "$prev_session_type" ]]; then
  tmux set-option -g @git_branch_cache "$branch"
  tmux set-option -g @git_icon_cache   "$icon"
  tmux set-option -g @git_repo_cache   "$repo"
  tmux set-option -g @git_repo_label_cache "$repo_label"
  [[ -n "$current_session" ]] && tmux set-option -t "$current_session" @session_type "$session_type" 2>/dev/null || true
  tmux refresh-client -S 2>/dev/null || true
fi
