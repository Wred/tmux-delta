#!/usr/bin/env bash
# agent-icons-refresh.sh
#
# Updates @agent_icons per tmux session: one icon per coding agent present in
# the session, each coloured by that agent's own state.
#
# Why a cache option instead of a format expression: tmux's format engine can
# iterate sessions (#{S/n:...}) but not the panes inside one, so "one icon per
# agent pane" cannot be expressed in status-format. This script does the
# per-pane walk and writes the finished icon string to a per-session option,
# exactly like tmux-pr-status-refresh.sh does for @pr_icons.
#
# Agent presence is pane-scoped and outlives a single turn:
#   @agent_present  — set by agent-tmux-status.sh on the first hook event from
#                     that pane; an agent lives here (idle or not).
#   @apex_role      — set by tmux-apex.sh when the pane is a registered apex
#                     member; also counts as presence.
# Both are pane options, so they disappear with the pane — no stale icons.
#
# Per-agent state, most urgent first:
#   @agent_needs_attention  blocked, wants input   U+F169F (peach)
#   @agent_working          mid-turn               U+F16A3 (green)
#   neither                 idle but present       U+F06A9 (muted)
#
# Usage:
#   agent-icons-refresh.sh                 refresh the current session
#   agent-icons-refresh.sh <session>       refresh one session by name
#   agent-icons-refresh.sh --all           refresh every session
#   agent-icons-refresh.sh --ack [session] clear attention flags, then refresh

set -u

[ -z "${TMUX:-}" ] && exit 0

# Nerd Font Material Design icons (supplementary PUA, 4-byte UTF-8)
ICON_IDLE='󰚩'       # U+F06A9 nf-md-robot
ICON_WORKING='󱚣'    # U+F16A3 nf-md-robot_excited
ICON_ATTENTION='󱚟'  # U+F169F nf-md-robot_confused

# Colors — overridable via @tmux_delta_color_agent_*; tmux-delta.tmux seeds
# them from catppuccin's active flavor when catppuccin/tmux is loaded.
COLOR_IDLE=$(tmux show-option -gqv @tmux_delta_color_agent_idle 2>/dev/null)
COLOR_WORKING=$(tmux show-option -gqv @tmux_delta_color_agent_working 2>/dev/null)
COLOR_ATTENTION=$(tmux show-option -gqv @tmux_delta_color_agent_attention 2>/dev/null)
: "${COLOR_IDLE:=#6c7086}"       # overlay0
: "${COLOR_WORKING:=#a6e3a1}"    # green
: "${COLOR_ATTENTION:=#fab387}"  # peach

# More agents than this in one session and the rest collapse into a +N counter,
# so a busy apex session can't push the pills off the status line.
MAX_ICONS=4

# icons_for <session> — prints the icon string for one session (may be empty).
icons_for() {
	local session="$1" line pane role present working attention
	local icons="" shown=0 extra=0

	while IFS='|' read -r pane role present working attention; do
		[ -n "$pane" ] || continue
		# Not an agent pane: no apex role and no hook has ever fired here.
		[ -n "$role" ] || [ -n "$present" ] || continue
		if [ "$shown" -ge "$MAX_ICONS" ]; then
			extra=$((extra + 1))
			continue
		fi
		[ "$shown" -gt 0 ] && icons+=" "
		if [ -n "$attention" ]; then
			icons+="#[fg=${COLOR_ATTENTION}]${ICON_ATTENTION}"
		elif [ -n "$working" ]; then
			icons+="#[fg=${COLOR_WORKING}]${ICON_WORKING}"
		else
			icons+="#[fg=${COLOR_IDLE}]${ICON_IDLE}"
		fi
		shown=$((shown + 1))
	done <<-EOF
		$(tmux list-panes -s -t "$session" -F \
			'#{pane_id}|#{@apex_role}|#{@agent_present}|#{@agent_working}|#{@agent_needs_attention}' \
			2>/dev/null)
	EOF

	# Fallback for agents that report session-scoped state without ever having
	# been seen as a pane (a hook wired to a different tmux pane, an older
	# agent-tmux-status.sh still in ~/.claude/settings.json). One icon, from
	# the session aggregate — the pre-per-agent behaviour.
	if [ "$shown" -eq 0 ]; then
		attention=$(tmux show-option -t "$session" -qv @agent_needs_attention 2>/dev/null || true)
		working=$(tmux show-option -t "$session" -qv @agent_working 2>/dev/null || true)
		if [ -n "$attention" ]; then
			icons="#[fg=${COLOR_ATTENTION}]${ICON_ATTENTION}"
		elif [ -n "$working" ]; then
			icons="#[fg=${COLOR_WORKING}]${ICON_WORKING}"
		fi
	fi

	[ "$extra" -gt 0 ] && icons+=" #[fg=${COLOR_IDLE}]+${extra}"
	printf '%s' "$icons"
}

# refresh <session> — recompute and store, writing only on change so tmux
# doesn't repaint the whole status line on every hook tick.
refresh() {
	local session="$1" icons prev
	[ -n "$session" ] || return 0
	icons=$(icons_for "$session")
	prev=$(tmux show-option -t "$session" -qv @agent_icons 2>/dev/null || true)
	[ "$icons" = "$prev" ] && return 0
	tmux set-option -t "$session" @agent_icons "$icons" 2>/dev/null || true
	tmux refresh-client -S 2>/dev/null || true
}

# ack <session> — the user switched into this session, so the "wants input"
# signal has been seen: clear it session-wide and on every pane in it.
ack() {
	local session="$1" pane
	[ -n "$session" ] || return 0
	tmux set-option -u -t "$session" @agent_needs_attention 2>/dev/null || true
	while read -r pane; do
		[ -n "$pane" ] || continue
		tmux set-option -u -p -t "$pane" @agent_needs_attention 2>/dev/null || true
	done <<-EOF
		$(tmux list-panes -s -t "$session" -F '#{pane_id}' 2>/dev/null)
	EOF
}

current_session() { tmux display-message -p '#S' 2>/dev/null || true; }

case "${1:-}" in
	--all)
		while read -r s; do
			[ -n "$s" ] && refresh "$s"
		done <<-EOF
			$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
		EOF
		;;
	--ack)
		session="${2:-$(current_session)}"
		ack "$session"
		refresh "$session"
		;;
	"")
		refresh "$(current_session)"
		;;
	*)
		refresh "$1"
		;;
esac
