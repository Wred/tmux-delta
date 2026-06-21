#!/usr/bin/env bash
# tmux-kube-status-refresh
#
# Updates @kube_context_cache and @kube_namespace_cache on the tmux server
# based on the active pane's current directory, respecting direnv. Triggered
# both by tmux hooks (on pane/window/session switch) and by a hidden #() in
# status-right that runs on every status-interval tick.
#
# Idempotent and safe to invoke repeatedly.

set -u

pane_path=$(tmux display-message -p -F '#{pane_current_path}' 2>/dev/null || true)
[[ -n "${pane_path:-}" && -d "$pane_path" ]] || pane_path="$HOME"

# Run the given command inside the pane's directory. If direnv is available we
# use `direnv exec`, which loads any .envrc under $pane_path before executing
# the command — that's how per-directory KUBECONFIG overrides reach kubectl.
#
# IMPORTANT: `direnv exec <DIR> CMD` loads <DIR>/.envrc but does NOT chdir into
# <DIR> before running CMD. If the .envrc uses a relative path (e.g.
# `export KUBECONFIG=k3d-kubeconfig`), the path will be resolved against the
# *caller's* cwd — which for tmux `#()` and `run-shell -b` is typically /tmp
# or $HOME, where the file doesn't exist. kubectl then reports
# "current-context is not set" and the pill flashes off.
#
# Wrap in a subshell that cd's into $pane_path first so relative paths from
# .envrc resolve relative to the pane's directory, matching what the user
# sees from an interactive shell. stderr is preserved so we can classify
# failures below.
if command -v direnv >/dev/null 2>&1; then
  run_in_dir() { (cd "$pane_path" && direnv exec "$pane_path" "$@"); }
else
  run_in_dir() { (cd "$pane_path" && "$@"); }
fi

prev_context=$(tmux show-option -gqv @kube_context_cache)
prev_namespace=$(tmux show-option -gqv @kube_namespace_cache)

# Read context+namespace and classify the outcome into one of three states:
#   ok    : exit 0 from `kubectl config current-context`; context populated
#   empty : exit 1 with "current-context is not set" — note this also fires
#           when KUBECONFIG points at a missing or 0-byte file, which is
#           exactly what happens during the brief window where k3d (or any
#           other tool) truncates-then-rewrites the kubeconfig
#   error : any other failure (YAML parse error mid-write, permission denied,
#           direnv barfing, etc.)
read_state() {
  local ctx_err
  ctx_err=$(mktemp -t tmux-kube-ctx-err.XXXXXX 2>/dev/null) || ctx_err=""
  context=$(run_in_dir kubectl config current-context 2>"${ctx_err:-/dev/null}")
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    namespace=$(run_in_dir kubectl config view --minify \
      -o jsonpath='{.contexts[0].context.namespace}' 2>/dev/null)
    [[ -z "$namespace" ]] && namespace="default"
    state="ok"
  elif [[ -n "$ctx_err" ]] && grep -qi 'current-context is not set' "$ctx_err"; then
    context=""
    namespace=""
    state="empty"
  else
    context=""
    namespace=""
    state="error"
  fi
  [[ -n "$ctx_err" ]] && rm -f "$ctx_err"
}

read_state

# If the new read looks like a degradation from the previous cached state
# (we had a context, and now we don't or kubectl errored), retry once after a
# short pause. The vast majority of these are k3d / `kubectl config use-context`
# briefly truncating the kubeconfig file; by the time we re-read, the write
# has finished and we get the real value back. A genuine context removal will
# still be reflected, just delayed by ~250ms.
if [[ -n "$prev_context" && "$state" != "ok" ]]; then
  sleep 0.25
  read_state
fi

# After the retry: if we're still in a hard error state, leave the caches
# alone so the pill doesn't flash off.
if [[ "$state" == "error" ]]; then
  exit 0
fi

# Only update the cache (and trigger a redraw) when something actually changed.
if [[ "$context" != "$prev_context" || "$namespace" != "$prev_namespace" ]]; then
  tmux set-option -g @kube_context_cache   "$context"
  tmux set-option -g @kube_namespace_cache "$namespace"
  tmux refresh-client -S 2>/dev/null || true
fi
