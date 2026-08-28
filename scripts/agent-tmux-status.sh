#!/usr/bin/env bash
# Coding-agent activity signalling for the session pills.
#
# Wired from ~/.claude/settings.json hooks:
#   PreToolUse   -> set     (agent is doing work)
#   Notification -> notify  (agent is blocked, wants input)
#   Stop         -> clear   (agent finished its turn)
#
# State is recorded twice: pane-scoped (per agent — this is what the session
# pill's per-agent icons are built from) and session-scoped (an "any agent
# busy" aggregate, kept for the fallback path in agent-icons-refresh.sh).
#
# @agent_present         this pane hosts an agent; drives the idle robot icon
# @agent_working         mid-turn; drives the "excited" robot icon
# @agent_needs_attention blocked; drives the "confused" robot icon, cleared by
#                        the client-session-changed hook in tmux-delta.tmux
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

# Pane-scoped reporting, for every agent pane — not just apex members: the
# session pill now draws one icon per agent pane, so a plain (non-apex) agent
# needs its own pane state too. Forwarding to the manager stays apex-only, and
# is still keyed off this pane's own @apex_role.
pane="$TMUX_PANE"
if [ -n "$pane" ]; then
  # Presence is sticky for the life of the pane: an agent that has finished its
  # turn is still an agent, and the pill shows it as idle rather than vanishing.
  tmux set-option -p -t "$pane" @agent_present 1 2>/dev/null || true
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
  if [ -n "$(tmux show-option -p -t "$pane" -qv @apex_role 2>/dev/null)" ]; then
    "$(dirname "$(readlink -f "$0")")/tmux-apex.sh" event "$1" >/dev/null 2>&1 || true
  fi
fi

# Rebuild the session's per-agent icon string from the pane state written above.
"$(dirname "$(readlink -f "$0")")/agent-icons-refresh.sh" "$session" >/dev/null 2>&1 || true
