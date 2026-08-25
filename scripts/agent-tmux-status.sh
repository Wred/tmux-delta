#!/usr/bin/env bash
# Coding-agent activity signalling for the session pills.
#
# Wired from ~/.claude/settings.json hooks:
#   PreToolUse   -> set     (agent is doing work)
#   Notification -> notify  (agent is blocked, wants input)
#   Stop         -> clear   (agent finished its turn)
#
# @agent_working         renders the peach robot in the session pill
# @agent_needs_attention paints the whole pill orange; cleared by the
#                        client-session-changed hook in tmux-delta.tmux
#
# When the session is an apex-mode member (see tmux-apex.sh), the same transitions
# are forwarded so the manager agent learns about them.

[ -z "$TMUX" ] && exit 0
session=$(tmux display-message -p '#S' 2>/dev/null) || exit 0
case "$1" in
  set)
    tmux set-option -t "$session" @agent_working 1
    tmux set-option -u -t "$session" @agent_needs_attention 2>/dev/null || true
    ;;
  notify)
    tmux set-option -u -t "$session" @agent_working 2>/dev/null || true
    tmux set-option -t "$session" @agent_needs_attention 1
    ;;
  clear)
    tmux set-option -u -t "$session" @agent_working 2>/dev/null || true
    tmux set-option -u -t "$session" @agent_needs_attention 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac
tmux list-clients -F '#{client_name}' | xargs -n1 tmux refresh-client -S -t

# Apex reporting — no-op for sessions that are not apex-mode members.
if [ -n "$(tmux show-option -t "$session" -qv @apex_session 2>/dev/null)" ]; then
  "$(dirname "$(readlink -f "$0")")/tmux-apex.sh" event "$1" >/dev/null 2>&1 || true
fi
