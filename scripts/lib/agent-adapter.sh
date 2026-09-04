#!/usr/bin/env zsh

# Agent adapter dispatch.
#
# Coding agents spell the same concepts differently — claude has
# --permission-mode, pi has a --tools allowlist, codex has --sandbox; codex has
# no --append-system-prompt at all and resumes with a subcommand rather than a
# flag. So tmux-dev-layout.sh never emits agent flags itself. It exports the
# neutral inputs below and calls delta_agent_exec, which loads the adapter for
# whichever agent actually resolved after direnv.
#
# Inputs (environment, all optional):
#   DELTA_AGENT_MODEL   model name, passed through to the agent's model flag
#   DELTA_AGENT_FLAGS   agent-native argv, word-split and passed verbatim
#   DELTA_AGENT_SYSTEM  extra system-prompt text (managed-worker instructions)
#   DELTA_AGENT_PROMPT  initial user prompt; empty means "resume last session"
#   DELTA_AGENT_DIR     project directory
#   DELTA_AGENT_RESUME  resume THIS specific recorded session id, rather than
#                       "whatever was last in this directory" — used by
#                       `tmux-apex.sh recover` after a tmux-server crash, where
#                       the pane is gone but the conversation is not
#
# An adapter is scripts/lib/agents/<command-basename>.sh defining
# delta_agent_argv(), which sets the array `agent_argv` to everything that
# follows the command name. Adding an agent is one file.
#
# When DELTA_AGENT_PROMPT is empty the adapter is resuming, and resuming fails
# on a worktree the agent has never seen. Adapters therefore also set
# `agent_argv_fresh` in that case: the same invocation without the resume flags,
# used if the resume attempt exits non-zero.
#
# DELTA_AGENT_MANAGED marks a launch made by the apex manager rather than by a
# human. Such a launch must carry a task (DELTA_AGENT_PROMPT) or a conversation
# to resume (DELTA_AGENT_RESUME); delta_agent_exec refuses it otherwise instead
# of falling back to a bare agent that would wait forever (#68).
#
# DELTA_AGENT_RESUME asks for one *specific* conversation, which most agents
# cannot express — codex has `resume --last`, pi and opencode have `--continue`,
# and all three mean "whatever ran last here". An adapter that does read
# DELTA_AGENT_RESUME therefore sets `agent_resume_id_honored`; delta_agent_exec
# refuses a resume-by-id launch through an adapter that does not, rather than
# letting it attach to someone else's conversation.

DELTA_AGENT_LIBDIR="${0:A:h}"

# _delta_agent_refuse <line>... — report a launch we will not make, and make
# the report survivable.
#
# delta_agent_exec is the pane's whole command (agent-launch.sh builds
# `zsh -ic 'delta_agent_exec ...'`), so returning here exits the pane. tmux does
# not set remain-on-exit anywhere in this repo, which means the pane closes and
# every line printed below scrolls into nothing — a diagnostic nobody can read
# is not a diagnostic. So pin the pane first: it stays as a dead pane with the
# text on screen.
#
# The attention flag is then set at BOTH scopes, because pinning the pane is
# what makes the pane-scoped one useless. A dead pane's pane_current_command is
# the login shell, and agent-icons-refresh.sh reads a flagged pane running a
# bare shell as "the agent was killed without firing clear" and prunes it — so
# the pane flag alone reaches nobody. The session-scoped one is what
# `tmux-apex.sh status --json` consults (_sopt @agent_needs_attention), and the
# manager is the consumer that matters here: tmux-dev-layout.sh has already
# registered this pane as a member, and apex liveness is session-level, so
# without this the member renders `agent: "idle", alive: true` forever — the
# round-one ghost, just quieter.
#
# The session pill still will not show it: the pruned pane also suppresses the
# session-aggregate fallback (agent-icons-refresh.sh gates it on pruned == 0).
# Teaching that script to tell a dead *pane* from a dead *shell* is a real fix
# and a separate one; apex status is the channel a manager actually reads.
#
# All three writes are best-effort: the guard must still refuse without tmux.
_delta_agent_refuse() {
	if [[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]]; then
		tmux set-option -p -t "$TMUX_PANE" remain-on-exit on 2>/dev/null || true
		tmux set-option -p -t "$TMUX_PANE" @agent_needs_attention 1 2>/dev/null || true
		# No -p/-g: a pane target resolves to that pane's session.
		tmux set-option -t "$TMUX_PANE" @agent_needs_attention 1 2>/dev/null || true
	fi
	local line
	for line in "$@"; do
		print -u2 -- "$line"
	done
	return 78
}

# delta_agent_exec <agent-command>
delta_agent_exec() {
	local agent="$1"
	local lib="${DELTA_AGENT_LIBDIR}/agents/${agent:t}.sh"

	# Unknown agents fall back to the claude adapter: its flag spellings are the
	# most widely copied, and a wrong flag is a visible startup error rather
	# than a silently mis-configured agent.
	[[ -r $lib ]] || lib="${DELTA_AGENT_LIBDIR}/agents/claude.sh"

	# A managed launch must carry a task or a conversation to resume. Every
	# other input is optional and every adapter appends it conditionally, so
	# with all of them empty the argv collapses to nothing and the agent comes
	# up at an interactive prompt with no idea it is managed and no job to do —
	# present, healthy from outside, waiting forever (#68, same shape as #42).
	# That is a configuration failure, not a degraded success: nothing
	# downstream can recover a worker that was never told what to do, so refuse
	# and say where the task should have come from. Unmanaged launches are
	# exempt on purpose — a human pressing `o` on a plain session wants exactly
	# a bare interactive agent in this directory.
	if [[ -n $DELTA_AGENT_MANAGED && -z $DELTA_AGENT_PROMPT && -z $DELTA_AGENT_RESUME ]]; then
		_delta_agent_refuse \
			"delta_agent_exec: refusing to launch managed agent '${agent}' with no task." \
			"  DELTA_AGENT_PROMPT and DELTA_AGENT_RESUME are both empty: no task, and no" \
			"  conversation to resume. The prompt is derived from the session's" \
			"  CODING_AGENT_ISSUE / CODING_AGENT_PR (see tmux-dev-layout.sh), so neither" \
			"  was set on this session — that is the thing to fix upstream."
		return 78
	fi

	typeset -ga agent_argv=() agent_argv_fresh=()
	unset agent_argv_fresh_set agent_resume_id_honored
	source "$lib"
	delta_agent_argv

	# DELTA_AGENT_RESUME names one specific conversation, and only an adapter
	# that actually reads it can honour that. The others resume "whatever ran
	# last in this directory" instead (`codex resume --last`, `--continue`) —
	# which is not the same conversation and, in a worktree a worker shares with
	# its reviewer, is a coin flip between the two. That is worse than the
	# failure it replaces: the pane comes up attached to someone else's history,
	# looking perfectly healthy. So an adapter that cannot resume by id must be
	# given a task instead; adapters that can set agent_resume_id_honored.
	if [[ -n $DELTA_AGENT_RESUME && -z $DELTA_AGENT_PROMPT ]] \
		&& (( ! ${+agent_resume_id_honored} )); then
		_delta_agent_refuse \
			"delta_agent_exec: adapter ${lib:t} cannot resume a specific conversation." \
			"  DELTA_AGENT_RESUME=${DELTA_AGENT_RESUME} would be ignored and '${agent}' would" \
			"  attach to whatever conversation ran last in this directory instead. Give this" \
			"  agent DELTA_AGENT_PROMPT, or teach the adapter to read DELTA_AGENT_RESUME."
		return 78
	fi

	# Resume, falling back to a fresh session when there is nothing to resume.
	if (( ${+agent_argv_fresh_set} )); then
		"$agent" "${agent_argv[@]}" && return 0

		# The fallback is only worth taking if it carries what the caller asked
		# for. An empty fresh argv while any input was set means none of it
		# survived into the fallback, so exec'ing it would launch an agent
		# stripped of its model, flags or system prompt. No shipped adapter can
		# reach this — they snapshot exactly those inputs, so empty implies all
		# empty — which is the point: it is an assertion against the next
		# adapter, not a diagnosis of a known bug.
		if (( ${#agent_argv_fresh} == 0 )) \
			&& [[ -n $DELTA_AGENT_MODEL$DELTA_AGENT_FLAGS$DELTA_AGENT_SYSTEM$DELTA_AGENT_PROMPT$DELTA_AGENT_MANAGED ]]; then
			_delta_agent_refuse \
				"delta_agent_exec: no configuration survived into ${lib:t}'s fresh-session argv" \
				"  for '${agent}', though inputs were set. Refusing to exec an unconfigured agent."
			return 78
		fi

		agent_argv=("${agent_argv_fresh[@]}")
	fi

	exec "$agent" "${agent_argv[@]}"
}
