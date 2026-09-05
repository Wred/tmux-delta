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
#   @agent_needs_attention  wants input            U+F169F, mauve
#   @agent_working          mid-turn               U+F16A3, mauve
#   neither                 idle but present       U+F06A9/U+F167A, pill's own text color
#
# Only one real accent color exists: mauve, for "active" (working or
# attention — the two are distinguished by icon shape, not color, since
# either one just means "look at this pane"). Nothing is peach or green any
# more, on purpose — the mauve is the same hue as the selected pill's own
# background, so a robot mid-turn or blocked reads as an extension of "this
# session wants you" rather than a separate alarm color.
#
# Idle isn't a color at all: it renders in whatever color the rest of the
# pill's text already is, so an idle robot reads as part of the pill rather
# than a second signal next to it. That text color differs by pill (plain fg
# normally, dark crust on the mauve-background selected pill), which is why
# idle's glyph *shape* differs too — see the two-string layout below.
#
# "Wants input" and not "blocked": the flag is set both by a worker stopped at
# a permission dialog and by one that merely ended its turn, and the icon
# cannot tell them apart. `tmux-apex.sh status` can — it classifies the pane
# and reports a reason (issue #63). Do not read urgency into this glyph.
#
# Two strings are written per session, because the pill for the *selected*
# session is drawn from a different branch of status-format[0], has a mauve
# background, and needs contrast rules of its own:
#   @agent_icons          for unselected pills (plain-text-colored pill):
#                         idle draws the outline glyph in the pill's own fg,
#                         working/attention draw filled glyphs in mauve.
#   @agent_icons_outline  for the selected (mauve-background) pill: idle
#                         draws the *filled* glyph in the pill's own (dark)
#                         fg — the outline shape is idle's "on plain text"
#                         look, no longer needed once idle already matches
#                         whatever's behind it; working/attention flip to the
#                         outline glyph, in the pill's dark fg rather than
#                         mauve, because a filled mauve robot on a mauve pill
#                         would disappear. Despite the name, this string is
#                         not "always outline" — it is "whatever reads, and
#                         matches the pill's text, on a mauve background".
#
# Usage:
#   agent-icons-refresh.sh                 refresh the current session
#   agent-icons-refresh.sh <session>       refresh one session by name
#   agent-icons-refresh.sh --all           refresh every session
#   agent-icons-refresh.sh --ack [session] clear attention flags, then refresh

set -u

[ -z "${TMUX:-}" ] && exit 0

# Nerd Font Material Design icons (supplementary PUA, 4-byte UTF-8)
ICON_IDLE='󰚩'         # U+F06A9 nf-md-robot — idle, selected pill (filled)
ICON_IDLE_OUTLINE='󱙺' # U+F167A nf-md-robot_outline — idle, unselected pill
ICON_WORKING='󱚣'      # U+F16A3 nf-md-robot_excited
ICON_ATTENTION='󱚟'    # U+F169F nf-md-robot_confused
# Outline counterparts, for working/attention on the selected pill.
ICON_WORKING_OUTLINE='󱚤'    # U+F16A4 nf-md-robot_excited_outline
ICON_ATTENTION_OUTLINE='󱚠'  # U+F16A0 nf-md-robot_confused_outline

# Colors — overridable via @tmux_delta_color_agent_*; tmux-delta.tmux seeds
# them from catppuccin's active flavor when catppuccin/tmux is loaded.
#
# Idle has no color of its own: it's drawn in whatever fg the rest of that
# pill's text already uses, so @tmux_delta_color_agent_idle defaults to the
# same value as @tmux_delta_color_fg (unselected pill text) and
# @tmux_delta_color_agent_selected defaults to the same value as the selected
# pill's own crust foreground — tmux-delta.tmux's catppuccin snapshot keeps
# both in sync with the active flavor, same as every other agent color here.
COLOR_IDLE=$(tmux show-option -gqv @tmux_delta_color_agent_idle 2>/dev/null)
# Working and attention share one color: the icon shape alone tells them
# apart, so there is nothing left for a second color to distinguish.
COLOR_ACTIVE=$(tmux show-option -gqv @tmux_delta_color_agent_active 2>/dev/null)
# The selected pill has a mauve background, where mauve-on-mauve would be
# invisible, so anything drawn there — either state — gets the pill's own
# dark foreground instead of its usual color.
COLOR_SELECTED=$(tmux show-option -gqv @tmux_delta_color_agent_selected 2>/dev/null)
: "${COLOR_IDLE:=#cdd6f4}"     # fg
: "${COLOR_ACTIVE:=#cba6f7}"   # mauve
: "${COLOR_SELECTED:=#11111b}" # crust

# More agents than this in one session and the rest collapse into a +N counter,
# so a busy apex session can't push the pills off the status line.
MAX_ICONS=$(tmux show-option -gqv @tmux_delta_agent_icons_max 2>/dev/null)
case "$MAX_ICONS" in ''|*[!0-9]*|0) MAX_ICONS=4 ;; esac

# Liveness, in two tiers, because pane state outlives the agent process:
# @agent_present is sticky for the life of the pane, and an agent killed or
# crashed mid-turn never fires `clear`, so @agent_working /
# @agent_needs_attention stay set too.
#
# AGENT_CMDS — an *idle* pane must have one of these in the foreground to count
# as hosting an agent at all.
AGENT_CMDS=$(tmux show-option -gqv @tmux_delta_apex_agent_cmds 2>/dev/null)
: "${AGENT_CMDS:=node bun claude codex gemini pi opencode}"

# SHELL_CMDS — a pane claiming to be mid-turn is normally taken at its word,
# since an agent's own tool call can put `git`/`grep`/anything in the
# foreground and second-guessing it would blink the icon out mid-turn. An
# *interactive* login shell is the one unambiguous exception: nothing is
# running in the pane, so no tool call can be in flight and the agent is gone.
#
# Deliberately only the three shells people actually log into. `sh` and `dash`
# are routinely the foreground command *during* real work — a build script, a
# git hook, any `#!/bin/sh` the agent invoked — so treating them as death would
# blink the icon out mid-turn, which is the exact flicker this gate avoids.
SHELL_CMDS='zsh bash fish'

# _in_list <needle> <space-separated haystack>
#
# The haystack is intentionally unquoted so it word-splits, but that also
# exposes it to pathname expansion — a `*` in @tmux_delta_apex_agent_cmds would
# glob against the cwd instead of comparing literally. `set -f` for the loop
# only, restoring the caller's setting rather than assuming it was off.
_in_list() {
	local needle="$1" item rc=1 had_noglob=
	case "$-" in *f*) had_noglob=1 ;; esac
	set -f
	for item in $2; do
		if [ "$needle" = "$item" ]; then
			rc=0
			break
		fi
	done
	[ -n "$had_noglob" ] || set +f
	return "$rc"
}

# _is_agent_cmd <pane_current_command>
_is_agent_cmd() {
	[ -n "$1" ] || return 0   # unknown: don't hide the agent on a guess
	_in_list "$1" "$AGENT_CMDS"
}

# _is_dead_shell <pane_current_command> — the pane has dropped back to a shell.
_is_dead_shell() {
	[ -n "$1" ] || return 1   # unknown: never claim the agent died
	_in_list "$1" "$SHELL_CMDS"
}

# icons_for <session> — prints the filled icon string, a TAB, then the outline
# icon string for one session. Either may be empty.
icons_for() {
	local session="$1" line pane role present working attention cmd
	local icons="" outline="" shown=0 extra=0 extra_state=idle pruned=0

	while IFS='|' read -r pane role present working attention cmd; do
		[ -n "$pane" ] || continue
		# @apex_role is session-scoped for the manager (tmux-apex.sh sets it on
		# the session, not the pane), so tmux's pane->session fallback makes
		# every other pane in that session report it too — a plain shell pane
		# sharing the manager's session would otherwise look like an agent.
		# Only trust it here when this pane carries its own local value.
		if [ -n "$role" ] && ! tmux show-options -p -t "$pane" 2>/dev/null | grep -q '^@apex_role '; then
			role=""
		fi
		# Not an agent pane: no apex role and no hook has ever fired here.
		[ -n "$role" ] || [ -n "$present" ] || continue
		# Liveness. Idle: the pane must still be running an agent, unless it
		# was only just registered and hasn't reported in yet. Mid-turn or
		# blocked: believed unless the pane has dropped back to a bare shell,
		# which means the agent was killed without ever firing `clear`.
		if [ -n "$working" ] || [ -n "$attention" ]; then
			if _is_dead_shell "$cmd"; then
				pruned=$((pruned + 1))
				continue
			fi
		elif [ -n "$role" ] && [ -z "$present" ]; then
			# Registered as an apex member but no hook has ever fired here: the
			# agent is still launching, so the pane is typically still showing
			# the shell it was spawned from. Nothing has been heard from this
			# pane yet, so there is no stale presence to guard against — show
			# the icon from registration rather than a second later.
			:
		elif ! _is_agent_cmd "$cmd"; then
			pruned=$((pruned + 1))
			continue
		fi
		# Overflow keeps no glyph, but the +N counter is coloured by whether an
		# active agent is hidden behind it — with the session-wide alarm pill
		# gone, one in the overflow would otherwise have no signal at all.
		if [ "$shown" -ge "$MAX_ICONS" ]; then
			extra=$((extra + 1))
			if [ -n "$attention" ] || [ -n "$working" ]; then
				extra_state=active
			fi
			continue
		fi
		if [ "$shown" -gt 0 ]; then
			icons+=" "
			outline+=" "
		fi
		if [ -n "$attention" ]; then
			icons+="#[fg=${COLOR_ACTIVE}]${ICON_ATTENTION}"
			outline+="#[fg=${COLOR_SELECTED}]${ICON_ATTENTION_OUTLINE}"
		elif [ -n "$working" ]; then
			icons+="#[fg=${COLOR_ACTIVE}]${ICON_WORKING}"
			outline+="#[fg=${COLOR_SELECTED}]${ICON_WORKING_OUTLINE}"
		else
			icons+="#[fg=${COLOR_IDLE}]${ICON_IDLE_OUTLINE}"
			outline+="#[fg=${COLOR_SELECTED}]${ICON_IDLE}"
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
	#
	# Skipped when panes were pruned as dead: the session aggregate is just as
	# stale as the pane flags were (a killed agent fires no `clear` at either
	# scope), so consulting it would put back the glyph we just dropped — the
	# common single-agent-per-session case.
	if [ "$shown" -eq 0 ] && [ "$pruned" -eq 0 ]; then
		attention=$(tmux show-option -t "$session" -qv @agent_needs_attention 2>/dev/null || true)
		working=$(tmux show-option -t "$session" -qv @agent_working 2>/dev/null || true)
		if [ -n "$attention" ]; then
			icons="#[fg=${COLOR_ACTIVE}]${ICON_ATTENTION}"
			outline="#[fg=${COLOR_SELECTED}]${ICON_ATTENTION_OUTLINE}"
		elif [ -n "$working" ]; then
			icons="#[fg=${COLOR_ACTIVE}]${ICON_WORKING}"
			outline="#[fg=${COLOR_SELECTED}]${ICON_WORKING_OUTLINE}"
		fi
	fi

	if [ "$extra" -gt 0 ]; then
		case "$extra_state" in
			active) icons+=" #[fg=${COLOR_ACTIVE}]+${extra}"
			        outline+=" #[fg=${COLOR_SELECTED}]+${extra}" ;;
			*)      icons+=" #[fg=${COLOR_IDLE}]+${extra}"
			        outline+=" #[fg=${COLOR_SELECTED}]+${extra}" ;;
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
