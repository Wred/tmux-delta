#!/usr/bin/env bash
# Pull-based delivery of apex pings into the manager's own context.
#
# Wired from ~/.claude/settings.json hooks. The script takes the delivery
# point as its one argument, because each hook event needs a different
# output channel (see below) and a different amount of setup work:
#
#   prompt        UserPromptSubmit — before every human message
#   session-start SessionStart      — startup/resume, so a killed-and-reopened
#                                     manager (e.g. `claude --continue` in the
#                                     same directory) catches up on what it
#                                     missed
#   post-tools    PostToolBatch     — once after each tool batch resolves,
#                                     before the next model call
#   stop          Stop              — at the end of an assistant turn
#
# Argument-less invocation means `prompt`, which is what the original
# single-event wiring did.
#
# Why four events and not just the first two: UserPromptSubmit only fires on
# a *human* message. A manager doing a long autonomous stretch — spawn, poll,
# report — takes many model turns without one, so a worker that settled during
# that stretch stayed invisible until the human typed again. The manager then
# answered from a status check it had made before the worker went idle. See
# github issue #7. PostToolBatch closes the mid-turn gap (pings land before
# the next model call), and Stop closes the end-of-turn gap: a ping that
# arrives as the manager is wrapping up keeps the loop alive for one more turn
# instead of waiting for the human.
#
# Channels differ by event: UserPromptSubmit and SessionStart are the only
# events where Claude Code reads a hook's plain stdout as context. Everywhere
# else plain stdout goes to the debug log only, and context has to be returned
# as JSON `hookSpecificOutput.additionalContext`.
#
# No-op, and fast, for the overwhelming majority of invocations: every Claude
# Code session on the machine fires these hooks, so this exits before doing
# any work unless the current session is actually an apex manager.

event="${1:-prompt}"

case "$event" in
	prompt)        hook_name=UserPromptSubmit ;;
	session-start) hook_name=SessionStart ;;
	post-tools)    hook_name=PostToolBatch ;;
	stop)          hook_name=Stop ;;
	*)
		printf 'apex-manager-notify: unknown event %s\n' "$event" >&2
		exit 0
		;;
esac

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
#
# Only on the two once-per-turn-at-most events: `post-tools` fires after
# every tool batch, and by then the session-level options have already been
# resolved by whichever event started the turn.
case "$event" in
	prompt | session-start) "$self_dir/tmux-apex.sh" relink 2>/dev/null ;;
esac

[ "$(tmux show-option -t "$session" -qv @apex_role 2>/dev/null)" = manager ] || exit 0

pending=$("$self_dir/tmux-apex.sh" pending --mark-delivered 2>/dev/null)
[ -z "$pending" ] && exit 0

text=$(printf '%s\n%s' "[apex] pending events since you last checked:" "$pending")

case "$event" in
	prompt | session-start)
		printf '%s\n' "$text"
		;;
	*)
		# `pending --mark-delivered` above already advanced pinged_seq, so this
		# text is delivered exactly once no matter how many times the hook
		# fires — which is what keeps a Stop-event injection from looping.
		jq -nc --arg h "$hook_name" --arg c "$text" \
			'{hookSpecificOutput: {hookEventName: $h, additionalContext: $c}}'
		;;
esac
