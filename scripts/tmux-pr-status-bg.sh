#!/usr/bin/env bash
# tmux-pr-status-bg.sh
#
# Persistent background daemon that refreshes PR status icons for all tmux
# sessions every 60 seconds. Ensures only one instance runs at a time via a
# PID file. Started by tmux-delta.tmux after TPM loads; safe to call on every
# config reload since a live daemon causes the new attempt to exit.

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="${HOME}/.cache/tmux-pr-status/.daemon.pid"
REFRESH="${SCRIPTS}/tmux-pr-status-refresh.sh"

mkdir -p "$(dirname "$PIDFILE")"

# Exit if a daemon is already running
if [[ -f "$PIDFILE" ]]; then
  old_pid=$(cat "$PIDFILE" 2>/dev/null)
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0
  fi
fi

printf '%d' "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

while true; do
  sleep 60
  # Stop if tmux server has gone away
  tmux list-sessions >/dev/null 2>&1 || exit 0
  "$REFRESH" 2>/dev/null
done
