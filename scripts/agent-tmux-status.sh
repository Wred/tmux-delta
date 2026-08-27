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

# Session-scoped write, unconditionally, exactly as before this pane may or
# may not be an apex member: this is what the status-bar pill reads, and
# with more than one agent pane per session "session-level = any pane busy"
# is a reasonable aggregate — it's the only thing keeping that indicator
# working for apex-managed sessions at all.
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

# Apex member (pane-scoped) reporting — no-op for panes that aren't a
# registered apex member. This pane's own @apex_role is what tells apex
# apart from the plain session-scoped write above; a pane with no
# pane-scoped @apex_role at all is either a non-apex session or the
# session's non-agent pane (editor), and gets no further treatment.
pane="$TMUX_PANE"
if [ -n "$pane" ] && [ -n "$(tmux show-option -p -t "$pane" -qv @apex_role 2>/dev/null)" ]; then
  case "$1" in
    set)
      tmux set-option -p -t "$pane" @agent_working 1
      tmux set-option -u -p -t "$pane" @agent_needs_attention 2>/dev/null || true
      ;;
    notify)
      tmux set-option -u -p -t "$pane" @agent_working 2>/dev/null || true
      tmux set-option -p -t "$pane" @agent_needs_attention 1
      ;;
    clear)
      tmux set-option -u -p -t "$pane" @agent_working 2>/dev/null || true
      tmux set-option -u -p -t "$pane" @agent_needs_attention 2>/dev/null || true
      ;;
  esac
  "$(dirname "$(readlink -f "$0")")/tmux-apex.sh" event "$1" >/dev/null 2>&1 || true
fi
