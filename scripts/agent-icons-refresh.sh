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
# Two strings are written per session, because the pill for the *selected*
# session is drawn from a different branch of status-format[0] and uses the
# outline variant of whichever glyph is showing:
#   @agent_icons          filled glyphs, for unselected pills
#   @agent_icons_outline  md-*_outline glyphs, for the selected pill
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
# Outline counterparts, for the selected pill.
ICON_IDLE_OUTLINE='󱙺'       # U+F167A nf-md-robot_outline
ICON_WORKING_OUTLINE='󱚤'    # U+F16A4 nf-md-robot_excited_outline
ICON_ATTENTION_OUTLINE='󱚠'  # U+F16A0 nf-md-robot_confused_outline

# Colors — overridable via @tmux_delta_color_agent_*; tmux-delta.tmux seeds
# them from catppuccin's active flavor when catppuccin/tmux is loaded.
COLOR_IDLE=$(tmux show-option -gqv @tmux_delta_color_agent_idle 2>/dev/null)
COLOR_WORKING=$(tmux show-option -gqv @tmux_delta_color_agent_working 2>/dev/null)
COLOR_ATTENTION=$(tmux show-option -gqv @tmux_delta_color_agent_attention 2>/dev/null)
# The selected pill has a mauve background, on which the muted idle grey is
# unreadable; it gets the pill's own dark foreground instead. Working and
# attention keep their hues, which stay legible on mauve.
COLOR_IDLE_ACTIVE=$(tmux show-option -gqv @tmux_delta_color_agent_idle_active 2>/dev/null)
: "${COLOR_IDLE:=#6c7086}"        # overlay0
: "${COLOR_WORKING:=#a6e3a1}"     # green
: "${COLOR_ATTENTION:=#fab387}"   # peach
: "${COLOR_IDLE_ACTIVE:=#11111b}" # crust

# More agents than this in one session and the rest collapse into a +N counter,
# so a busy apex session can't push the pills off the status line.
MAX_ICONS=$(tmux show-option -gqv @tmux_delta_agent_icons_max 2>/dev/null)
case "$MAX_ICONS" in ''|*[!0-9]*|0) MAX_ICONS=4 ;; esac

# Panes whose foreground command is one of these still count as hosting a live
# agent. Only consulted for *idle* panes: @agent_present is sticky for the life
# of the pane, so an agent that has exited leaves a pane that would otherwise
# keep drawing an idle robot forever. A pane reporting working/attention has
# just been heard from, so it is skipped — no flicker if an agent's tool call
# briefly changes the foreground command.
AGENT_CMDS=$(tmux show-option -gqv @tmux_delta_apex_agent_cmds 2>/dev/null)
: "${AGENT_CMDS:=node bun claude codex gemini pi opencode}"

# _is_agent_cmd <pane_current_command>
_is_agent_cmd() {
	local cmd="$1" allowed
	[ -n "$cmd" ] || return 0   # unknown: don't hide the agent on a guess
	for allowed in $AGENT_CMDS; do
		[ "$cmd" = "$allowed" ] && return 0
	done
	return 1
}

# icons_for <session> — prints the filled icon string, a TAB, then the outline
# icon string for one session. Either may be empty.
icons_for() {
	local session="$1" line pane role present working attention cmd
	local icons="" outline="" shown=0 extra=0 extra_state=idle

	while IFS='|' read -r pane role present working attention cmd; do
		[ -n "$pane" ] || continue
		# Not an agent pane: no apex role and no hook has ever fired here.
		[ -n "$role" ] || [ -n "$present" ] || continue
		# Idle and no agent process left in the pane: the agent has exited.
		if [ -z "$working" ] && [ -z "$attention" ] && ! _is_agent_cmd "$cmd"; then
			continue
		fi
		# Overflow keeps no glyph, but the +N counter is coloured by the most
		# urgent state hidden behind it — with the session-wide peach pill gone,
		# a blocked agent in the overflow would otherwise have no signal at all.
		if [ "$shown" -ge "$MAX_ICONS" ]; then
			extra=$((extra + 1))
			if [ -n "$attention" ]; then
				extra_state=attention
			elif [ -n "$working" ] && [ "$extra_state" = idle ]; then
				extra_state=working
			fi
			continue
		fi
		if [ "$shown" -gt 0 ]; then
			icons+=" "
			outline+=" "
		fi
		if [ -n "$attention" ]; then
			icons+="#[fg=${COLOR_ATTENTION}]${ICON_ATTENTION}"
			outline+="#[fg=${COLOR_ATTENTION}]${ICON_ATTENTION_OUTLINE}"
		elif [ -n "$working" ]; then
			icons+="#[fg=${COLOR_WORKING}]${ICON_WORKING}"
			outline+="#[fg=${COLOR_WORKING}]${ICON_WORKING_OUTLINE}"
		else
			icons+="#[fg=${COLOR_IDLE}]${ICON_IDLE}"
			outline+="#[fg=${COLOR_IDLE_ACTIVE}]${ICON_IDLE_OUTLINE}"
		fi
		shown=$((shown + 1))
	done <<-EOF
		$(tmux list-panes -s -t "$session" -F \
			'#{pane_id}|#{@apex_role}|#{@agent_present}|#{@agent_working}|#{@agent_needs_attention}|#{pane_current_command}' \
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
			outline="#[fg=${COLOR_ATTENTION}]${ICON_ATTENTION_OUTLINE}"
		elif [ -n "$working" ]; then
			icons="#[fg=${COLOR_WORKING}]${ICON_WORKING}"
			outline="#[fg=${COLOR_WORKING}]${ICON_WORKING_OUTLINE}"
		fi
	fi

	if [ "$extra" -gt 0 ]; then
		case "$extra_state" in
			attention) icons+=" #[fg=${COLOR_ATTENTION}]+${extra}"
			           outline+=" #[fg=${COLOR_ATTENTION}]+${extra}" ;;
			working)   icons+=" #[fg=${COLOR_WORKING}]+${extra}"
			           outline+=" #[fg=${COLOR_WORKING}]+${extra}" ;;
			*)         icons+=" #[fg=${COLOR_IDLE}]+${extra}"
			           outline+=" #[fg=${COLOR_IDLE_ACTIVE}]+${extra}" ;;
		esac
	fi
	# TAB-separated: neither variant can contain one.
	printf '%s\t%s' "$icons" "$outline"
}

# refresh <session> — recompute and store, writing only on change so tmux
# doesn't repaint the whole status line on every hook tick.
refresh() {
	local session="$1" both icons outline prev prev_outline
	[ -n "$session" ] || return 0
	both=$(icons_for "$session")
	icons="${both%%	*}"
	outline="${both#*	}"
	prev=$(tmux show-option -t "$session" -qv @agent_icons 2>/dev/null || true)
	prev_outline=$(tmux show-option -t "$session" -qv @agent_icons_outline 2>/dev/null || true)
	[ "$icons" = "$prev" ] && [ "$outline" = "$prev_outline" ] && return 0
	tmux set-option -t "$session" @agent_icons "$icons" 2>/dev/null || true
	tmux set-option -t "$session" @agent_icons_outline "$outline" 2>/dev/null || true
	tmux refresh-client -S 2>/dev/null || true
}

# ack <session> — the user switched into this session, so the "wants input"
# signal has been seen. Clears the session aggregate, plus the panes of the
# session's *current* window only: attention is per-agent now, and an agent
# blocked in a window the user hasn't looked at has not been seen.
ack() {
	local session="$1" pane
	[ -n "$session" ] || return 0
	tmux set-option -u -t "$session" @agent_needs_attention 2>/dev/null || true
	while read -r pane; do
		[ -n "$pane" ] || continue
		tmux set-option -u -p -t "$pane" @agent_needs_attention 2>/dev/null || true
	done <<-EOF
		$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null)
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
