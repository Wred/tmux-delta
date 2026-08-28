#!/usr/bin/env bash
# Pull-based delivery of apex pings into the manager's own context.
#
# Wired from ~/.claude/settings.json hooks. The script takes the delivery
# point as its one required argument, because each hook event needs a
# different output channel (see below) and a different amount of setup work:
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
# The argument is required, with no default, precisely because the two
# channels aren't interchangeable. An earlier revision defaulted to `prompt`
# for compatibility with the original single-event wiring; that turned a
# plausible copy-paste — the old argument-less command duplicated under
# PostToolBatch or Stop — into silent, permanent ping loss, since the plain
# text it printed on those events goes only to the debug log. Now an
# unrecognized argument delivers nothing and consumes nothing: the events stay
# pending, and `tmux-apex.sh doctor` names the wiring that needs fixing.
#
# No-op, and fast, for the overwhelming majority of invocations: every Claude
# Code session on the machine fires these hooks, so this exits before doing
# any work unless the current session is actually an apex manager.

event="${1:-}"

# channel: text = Claude Code reads plain stdout as context on this event
#          json = context has to come back as hookSpecificOutput JSON
#          ""   = argument missing or unrecognized; no safe way to deliver
case "$event" in
	prompt)        hook_name=UserPromptSubmit; channel=text ;;
	session-start) hook_name=SessionStart;     channel=text ;;
	post-tools)    hook_name=PostToolBatch;    channel=json ;;
	stop)          hook_name=Stop;             channel=json ;;
	*)             hook_name=;                 channel= ;;
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
# Only on the two events that can open a turn. `post-tools` and `stop` both
# fire strictly inside a turn something else already opened, so the
# session-level options they would look at have been resolved already — and
# `post-tools` fires after every tool batch, where the cost would repeat.
case "$event" in
	prompt | session-start) "$self_dir/tmux-apex.sh" relink 2>/dev/null ;;
esac

[ "$(tmux show-option -t "$session" -qv @apex_role 2>/dev/null)" = manager ] || exit 0

# From here on this session is a manager, so a misconfiguration is worth
# saying out loud. Print to stdout as well as stderr: an exit-0 hook's stderr
# reaches the debug log only, whereas stdout at least reaches the agent on the
# two text-channel events — which are exactly the events where the argument-less
# wiring this catches used to be correct.
if [ -z "$channel" ]; then
	msg="[apex] apex-manager-notify.sh was invoked as '${event:-<no argument>}', which is not a delivery point.
[apex] Worker pings are NOT being delivered to this session. Run 'tmux-apex.sh doctor' for the wiring to fix."
	printf '%s\n' "$msg"
	printf '%s\n' "$msg" >&2
	exit 0
fi

# Pre-flight the JSON channel's dependency *before* consuming anything.
# `pending --mark-delivered` advances each reported member's pinged_seq in the
# same pass that prints it, so anything that can fail after that call loses
# events outright rather than delaying them — and this script runs with
# whatever PATH Claude Code hands the hook, which need not have jq on it even
# though tmux-apex.sh itself requires it. Checking here rather than reordering
# to emit-then-mark is deliberate: a separate marking pass would have to
# re-read state that a worker may have bumped in between, which loses the newer
# event instead. Failing before the read leaves everything pending for the
# next delivery point, a few seconds later.
if [ "$channel" = json ] && ! command -v jq >/dev/null 2>&1; then
	printf 'apex-manager-notify: jq not found on PATH; leaving pings pending\n' >&2
	exit 0
fi

pending=$("$self_dir/tmux-apex.sh" pending --mark-delivered 2>/dev/null)
[ -z "$pending" ] && exit 0

text=$(printf '%s\n%s' "[apex] pending events since you last checked:" "$pending")

# Delivered exactly once either way: the `--mark-delivered` above advanced
# pinged_seq past what it printed, which is also what keeps the Stop-event
# injection from looping.
if [ "$channel" = text ]; then
	printf '%s\n' "$text"
else
	jq -nc --arg h "$hook_name" --arg c "$text" \
		'{hookSpecificOutput: {hookEventName: $h, additionalContext: $c}}'
fi
