#!/usr/bin/env bash
# tmux-pr-status-refresh.sh
#
# Updates @pr_icons per tmux session, showing GitHub PR status for the branch
# checked out in each session's active pane.
#
# Triggered by tmux hooks on session/pane/window switch and by the hidden #()
# in status-right that runs on every status-interval tick. Results are cached
# in ~/.cache/tmux-pr-status/ (TTL: 60 s) to avoid hammering the GitHub API.
#
# Per-session @pr_icons is set via `set-option -t <session>` (not -g), so it
# resolves correctly per-session inside the #{S/n:...} format iterator.
#
# CI status is derived from the check-suites REST endpoint for the PR's HEAD
# commit — this captures queued/in-progress suites that haven't started
# individual runs yet (what GitHub UI shows as "Expected" / orange).
#
# Icon key (Nerd Font FontAwesome range, 3-byte UTF-8):
#   pencil       U+F040  — draft PR (muted grey)
#   eye          U+F06E  — ready for review, no decision yet (sky blue)
#   check        U+F00C  — PR approved (green)
#   refresh      U+F021  — changes requested (orange)
#   check-circle U+F058  — CI passing (green, distinct from plain check)
#   times-circle U+F057  — CI failing (red)
#   clock-o      U+F017  — CI checks pending / in progress (yellow)

set -u

# Nerd Font FontAwesome icons (BMP U+F000–U+F2FF, 3-byte UTF-8)
ICON_DRAFT=$'\xef\x81\x80'     # U+F040  nf-fa-pencil
ICON_READY=$'\xef\x81\xae'     # U+F06E  nf-fa-eye
ICON_APPROVED=$'\xef\x80\x8c'  # U+F00C  nf-fa-check
ICON_CHANGES=$'\xef\x80\xa1'   # U+F021  nf-fa-refresh
ICON_CI_PASS=$'\xef\x81\x98'   # U+F058  nf-fa-check-circle
ICON_CI_FAIL=$'\xef\x81\x97'   # U+F057  nf-fa-times-circle
ICON_CI_PEND=$'\xef\x80\x97'   # U+F017  nf-fa-clock-o

# Catppuccin Mocha palette (must match @catppuccin_flavor 'mocha' in tmux.conf)
COLOR_GREEN="#a6e3a1"
COLOR_RED="#f38ba8"
COLOR_PEACH="#fab387"
COLOR_MUTED="#6c7086"   # overlay0 — visually muted for draft
COLOR_SKY="#89dceb"     # sky — ready for review, awaiting decision

CACHE_DIR="${HOME}/.cache/tmux-pr-status"
CACHE_TTL=60   # seconds between GitHub API re-fetches per session+branch
mkdir -p "$CACHE_DIR"

# Bail early if required tools are absent
command -v gh  >/dev/null 2>&1 || exit 0
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# compute_pr_icons <pane_path> <branch>
# Prints a tmux-format icon string (may be empty). Writes result to cache.
compute_pr_icons() {
  local pane_path="$1" branch="$2"

  # Cache key: sanitise path+branch into a safe filename (max 120 chars)
  local key
  key=$(printf '%s_%s' "$pane_path" "$branch" \
    | tr -cs 'A-Za-z0-9_-' '_' \
    | cut -c1-120)
  local cache_file="${CACHE_DIR}/${key}"

  # Return cached value if still fresh
  if [[ -f "$cache_file" ]]; then
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -f %m "$cache_file" 2>/dev/null \
         || stat -c %Y "$cache_file" 2>/dev/null \
         || echo 0)
    age=$(( now - mtime ))
    if [[ $age -lt $CACHE_TTL ]]; then
      cat "$cache_file"
      return
    fi
  fi

  # ── Fetch PR state from gh CLI (auto-detects the correct GitHub host) ──────
  local pr_json
  pr_json=$(cd "$pane_path" \
    && gh pr view --json isDraft,reviewDecision,number 2>/dev/null \
    || true)

  if [[ -z "$pr_json" ]]; then
    printf '' > "$cache_file"
    return
  fi

  local is_draft review_decision pr_number
  is_draft=$(printf '%s' "$pr_json"        | jq -r '.isDraft       // false')
  review_decision=$(printf '%s' "$pr_json" | jq -r '.reviewDecision // ""')
  pr_number=$(printf '%s' "$pr_json"       | jq -r '.number        // ""')

  # ── CI status via gh pr checks ─────────────────────────────────────────────
  # gh pr checks covers both GitHub Actions check runs AND commit-status
  # checks (e.g. Argo ci/* jobs). The `bucket` field is gh's own rollup:
  # pass | fail | pending | skipping
  local ci_status="none"
  local checks_json
  checks_json=$(cd "$pane_path" && gh pr checks --json bucket 2>/dev/null || true)

  if [[ -n "$checks_json" ]]; then
    ci_status=$(printf '%s' "$checks_json" | jq -r '
      if length == 0 then "none"
      elif (map(select(.bucket == "fail"))    | length) > 0 then "failing"
      elif (map(select(.bucket == "pending")) | length) > 0 then "pending"
      elif (map(select(.bucket == "pass" or .bucket == "skipping")) | length) == length
        then "passing"
      else "unknown"
      end
    ')
  fi

  # ── Build icon string ───────────────────────────────────────────────────────
  local icons=""

  if [[ "$is_draft" == "true" ]]; then
    icons+="#[fg=${COLOR_MUTED}]${ICON_DRAFT}#[fg=default] "
  else
    case "$review_decision" in
      ""|REVIEW_REQUIRED)
        icons+="#[fg=${COLOR_SKY}]${ICON_READY}#[fg=default] " ;;
      APPROVED)
        icons+="#[fg=${COLOR_GREEN}]${ICON_APPROVED}#[fg=default] " ;;
      CHANGES_REQUESTED)
        icons+="#[fg=${COLOR_PEACH}]${ICON_CHANGES}#[fg=default] " ;;
    esac
  fi

  case "$ci_status" in
    passing) icons+="#[fg=${COLOR_GREEN}]${ICON_CI_PASS}#[fg=default]" ;;
    failing) icons+="#[fg=${COLOR_RED}]${ICON_CI_FAIL}#[fg=default]" ;;
    pending) icons+="#[fg=${COLOR_PEACH}]${ICON_CI_PEND}#[fg=default]" ;;
  esac

  # Trim trailing space (when a review icon was added but CI is none/unknown)
  icons="${icons% }"

  printf '%s|%s' "$pr_number" "$icons" > "$cache_file"
  printf '%s|%s' "$pr_number" "$icons"
}

# ── Main ────────────────────────────────────────────────────────────────────
# With --current: only refresh the session owning the active pane (for hooks).
# Without flag:   iterate all sessions (for the background daemon).

if [[ "${1:-}" == "--current" ]]; then
  sessions=$(tmux display-message -p -F '#{session_name}' 2>/dev/null || true)
else
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
fi

needs_refresh=0

while IFS= read -r session; do
  [[ -z "$session" ]] && continue

  pane_path=$(tmux display-message -t "${session}:" -p -F '#{pane_current_path}' \
    2>/dev/null || true)
  [[ -n "${pane_path:-}" && -d "$pane_path" ]] || continue

  branch=$(cd "$pane_path" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    prev=$(tmux show-option -t "$session" -qv @pr_icons 2>/dev/null || true)
    if [[ -n "$prev" ]]; then
      tmux set-option -t "$session" @pr_icons "" 2>/dev/null || true
      needs_refresh=1
    fi
    continue
  fi

  result=$(compute_pr_icons "$pane_path" "$branch")
  pr_number="${result%%|*}"
  icons="${result#*|}"
  # Handle old cache format (no pipe) or non-numeric prefix
  [[ "$pr_number" =~ ^[0-9]+$ ]] || pr_number=""

  prev=$(tmux show-option -t "$session" -qv @pr_icons 2>/dev/null || true)
  if [[ "$icons" != "$prev" ]]; then
    tmux set-option -t "$session" @pr_icons "$icons" 2>/dev/null || true
    needs_refresh=1
  fi

  if [[ -n "$pr_number" ]]; then
    expected_prefix="#${pr_number}: "
    current_label=$(tmux show-option -t "$session" -qv @session_label 2>/dev/null || true)
    if [[ "$current_label" != "${expected_prefix}"* ]]; then
      base_label="$current_label"
      [[ "$base_label" =~ ^#[0-9]+:\ (.*)$ ]] && base_label="${BASH_REMATCH[1]}"
      [[ -z "$base_label" ]] && base_label="$session"
      (( ${#base_label} > 20 )) && base_label="${base_label:0:20}…"
      tmux set-option -t "$session" @session_label "${expected_prefix}${base_label}" 2>/dev/null || true
      needs_refresh=1
    fi
  fi
done <<< "$sessions"

[[ $needs_refresh -eq 1 ]] && tmux refresh-client -S 2>/dev/null || true
