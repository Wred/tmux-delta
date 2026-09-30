# agent-session.sh — which coding agent is running us, and which of its
# conversations. Plain POSIX sh: sourced by zsh (tmux-apex.sh) and bash
# (apex-manager-notify.sh, agent-tmux-status.sh) alike.
#
# Apex needs a conversation id in two places: to tell a resumed manager from a
# cleared one (relink, _apex_manager_agent_gone), and to resume a member into
# the conversation it had (recover). Every supported harness publishes one to
# the processes it starts, each under its own name:
#
#   claude    CLAUDE_CODE_SESSION_ID   tool commands and hooks
#   pi        PI_SESSION_ID            bash tool commands (docs/environment-variables.md)
#   codex     CODEX_THREAD_ID          exec'd commands
#   opencode  OPENCODE_SESSION_ID      exported by tmux-delta's own plugin via
#                                      its shell.env hook; opencode sets none
#
# Environment variables are inherited, so these leak: a pi started from a
# shell inside Claude Code carries CLAUDE_CODE_SESSION_ID too, and "first one
# set wins" would hand pi's caller Claude's conversation. The nearest coding
# agent among our ancestors is the one actually running this command, so that
# decides which variable is read. Only when no ancestor is recognisable does
# this fall back to the first variable set.
#
# DELTA_AGENT_SESSION_ID, when set, beats all of that. It is the explicit
# handoff for callers that know the id first-hand: tmux-delta's pi and opencode
# extensions pass it to the scripts they exec, since those run outside any
# agent tool call.

# _delta_agent_name <word> — the agent a process name or argv[0] denotes, if any.
_delta_agent_name() {
	case "${1##*/}" in
		claude)   printf 'claude' ;;
		pi)       printf 'pi' ;;
		codex)    printf 'codex' ;;
		opencode) printf 'opencode' ;;
		*)        return 1 ;;
	esac
}

# delta_agent_self [pid] — the nearest ancestor of <pid> (default: this shell)
# that is a coding agent, or nothing. Both the command name and argv[0] are
# checked: pi is a node script, so ps reports its command as `node`, but it sets
# process.title, which is what argv[0] shows.
delta_agent_self() {
	_das_pid="${1:-$$}" _das_n=0
	while [ -n "$_das_pid" ] && [ "$_das_pid" -gt 1 ] 2>/dev/null && [ "$_das_n" -lt 32 ]; do
		_das_comm=$(ps -o comm= -p "$_das_pid" 2>/dev/null) || return 1
		_das_args=$(ps -o args= -p "$_das_pid" 2>/dev/null)
		_delta_agent_name "$_das_comm" && return 0
		_delta_agent_name "${_das_args%% *}" && return 0
		_das_pid=$(ps -o ppid= -p "$_das_pid" 2>/dev/null | tr -d ' ')
		_das_n=$((_das_n + 1))
	done
	return 1
}

# _delta_agent_session_var <agent> — that agent's variable's value.
_delta_agent_session_var() {
	case "$1" in
		claude)   printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" ;;
		pi)       printf '%s' "${PI_SESSION_ID:-}" ;;
		codex)    printf '%s' "${CODEX_THREAD_ID:-}" ;;
		opencode) printf '%s' "${OPENCODE_SESSION_ID:-}" ;;
	esac
}

# delta_agent_session_id [agent] — the current conversation id, or nothing.
# <agent> skips the ancestry walk when the caller already knows which agent it
# is asking about (a member record names it).
delta_agent_session_id() {
	if [ -n "${DELTA_AGENT_SESSION_ID:-}" ]; then
		printf '%s' "$DELTA_AGENT_SESSION_ID"
		return 0
	fi
	_dasi_agent="${1:-}"
	[ -n "$_dasi_agent" ] || _dasi_agent=$(delta_agent_self) || _dasi_agent=""
	if [ -n "$_dasi_agent" ]; then
		_dasi_id=$(_delta_agent_session_var "$_dasi_agent")
		[ -n "$_dasi_id" ] && { printf '%s' "$_dasi_id"; return 0; }
		return 1
	fi
	for _dasi_agent in claude pi codex opencode; do
		_dasi_id=$(_delta_agent_session_var "$_dasi_agent")
		[ -n "$_dasi_id" ] && { printf '%s' "$_dasi_id"; return 0; }
	done
	return 1
}
