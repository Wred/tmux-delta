#!/usr/bin/env bash
# Pull-based delivery of apex pings into the manager's own context.
#
# Wired from ~/.claude/settings.json hooks:
#   UserPromptSubmit -> runs before every human message reaches the manager
#   SessionStart      -> runs on startup/resume, so a killed-and-reopened
#                         manager (e.g. `claude --continue` in the same
#                         directory) catches up on what it missed
#
# For both events, Claude Code adds this script's stdout to Claude's context
# as plain text when it exits 0 — it never touches the visible prompt or the
# pane's input line. That's the point: the old mechanism (`_ping_manager` in
# tmux-apex.sh) wrote status lines directly into the manager's own tmux pane
# via send-keys, which could splice into a human's in-flight input (or, as
# observed, ghost text from a shell/TUI autosuggestion that was never human
# input at all). A pane has no reliable way to tell those apart from the
# outside, so the fix is to stop writing to it, not to guard the write more
# carefully. See github issue #5.
#
# No-op, fast, for the overwhelming majority of invocations: every Claude
# Code session on the machine fires UserPromptSubmit, so this exits before
# doing any work unless the current session is actually an apex manager.

[ -z "$TMUX" ] && exit 0
session=$(tmux display-message -p '#S' 2>/dev/null) || exit 0

self_dir=$(dirname "$(readlink -f "$0")")

# Re-derive @apex_role (and, for a worker, @apex_session/@apex_task) if this
# session's tmux options didn't survive a kill-and-recreate — e.g. this same
# `claude --continue` after the session died and got reopened under the same
# name. See `relink` in tmux-apex.sh: it never resurrects a manager the
# human explicitly took out of apex mode with `stop`. Runs for every
# session (this hook fires globally), not just managers — determining
# whether this session even is one is the point of calling it here, before
# the role check below.
"$self_dir/tmux-apex.sh" relink 2>/dev/null

[ "$(tmux show-option -t "$session" -qv @apex_role 2>/dev/null)" = manager ] || exit 0

pending=$("$self_dir/tmux-apex.sh" pending --mark-delivered 2>/dev/null)
[ -z "$pending" ] && exit 0

printf '%s\n%s\n' "[apex] pending events since you last checked:" "$pending"
