#!/usr/bin/env zsh

# tmux-apex.sh — apex mode for tmux-delta.
#
# One tmux session hosts a "manager" coding agent that spawns, tracks and
# instructs "worker"/"monitor" agent sessions created through the normal
# tmux-delta picker machinery (worktree + session + dev layout).
#
# Transport: per-session @-options carry role metadata, and a JSON state
# tree under $XDG_CACHE_HOME/tmux-delta/apex survives agent context
# compaction. send-keys carries worker-directed messages (`send`), but
# status pings to the manager are pull-based, not pushed: the manager's own
# Claude Code hooks (scripts/apex-manager-notify.sh) call `pending` on its
# behalf on every turn and on resume, so nothing ever writes into the
# manager's own pane — see `pending` below for why that matters.
#
# Subcommands: init stop relink spawn send event status pending reap profiles
#              doctor

SELF="${0:A}"
SCRIPTS="${SELF:h}"

source "${SCRIPTS}/lib/apex-state.sh"
source "${SCRIPTS}/lib/apex-profiles.sh"
source "${SCRIPTS}/lib/pr-cache.sh"

APEX_QUIET_SECS=${APEX_QUIET_SECS:-30}

# ─── tmux helpers ────────────────────────────────────────────────────

_die() { print -u2 "tmux-apex: $*"; exit 1; }

# _need_val <context> <flag> $# — guard a two-argument option.
#
# zsh's `shift 2` with only one positional left fails *and leaves $# unchanged*,
# so an unguarded `while (( $# ))` parser spins at 100% CPU forever on a dropped
# value. That is not merely a bad error message here: `verdict` is run by the
# reviewer agent itself, and a wedged pane never reaches its Stop hook — so
# `_settle` never runs and the loop's own "reviewer went idle without a verdict"
# escalation never fires either. The pair just hangs, silently.
#
# Takes the remaining argument count rather than the value, so an intentionally
# empty value (`--note ''`) is still accepted.
_need_val() {
	(( $3 >= 2 )) || _die "$1: $2 needs a value"
}

_cur_session() {
	tmux display-message -p '#S' 2>/dev/null
}

# Member identity is "<session>:<pane_id>" (e.g. "myworktree:%57"); a manager
# is identified by its bare session name. Tmux session names can't contain
# "%", so "contains :%" reliably distinguishes the two shapes.
_is_member() { [[ $1 == *:%* ]]; }
_member_session() { print -r -- "${1%%:*}"; }
_member_pane() { print -r -- "${1#*:}"; }

# _sopt/_sset resolve to pane-scoped options for a member id, session-scoped
# options for a bare session (manager) name.
_sopt() {
	if _is_member "$1"; then
		tmux show-option -p -t "$(_member_pane "$1")" -qv "$2" 2>/dev/null
	else
		tmux show-option -t "$1" -qv "$2" 2>/dev/null
	fi
}

_sset() {
	local target="$1" key="$2" val="$3"
	if _is_member "$target"; then
		tmux set-option -p -t "$(_member_pane "$target")" "$key" "$val"
	else
		tmux set-option -t "$target" "$key" "$val"
	fi
}

_session_alive() { tmux has-session -t="$1" 2>/dev/null; }

# A member is alive as long as its pane still exists — the session it lives
# in may host other members too, so session liveness alone isn't enough.
_member_alive() {
	if _is_member "$1"; then
		tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$(_member_pane "$1")"
	else
		_session_alive "$1"
	fi
}

# Does any pane in <session> already have a registered apex member on it?
_session_has_apex_member() {
	local p
	for p in ${(f)"$(tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null)"}; do
		[[ -n $(tmux show-option -p -t "$p" -qv @apex_role 2>/dev/null) ]] && return 0
	done
	return 1
}

_main_tree() {
	git -C "${1:-$PWD}" worktree list 2>/dev/null | awk 'NR==1{print $1}'
}

# For a member id the pane IS the identity — no indirection needed.
_agent_pane() {
	if _is_member "$1"; then
		_member_pane "$1"
	else
		_sopt "$1" @agent_pane
	fi
}

# Only ever send keys into a pane that is actually running an interactive agent —
# sending into a shell would execute the message as a command.
_pane_is_agent() {
	local pane="$1" cmd allow
	[[ -n $pane ]] || return 1
	tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$pane" || return 1
	cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
	allow=$(tmux show-option -gqv @tmux_delta_apex_agent_cmds 2>/dev/null)
	[[ -z $allow ]] && allow="node claude codex gemini"
	local -a allowed=(${=allow})
	(( ${allowed[(Ie)$cmd]} ))
}

# _apex_utf8_locale — name of a UTF-8 locale to run multibyte pattern matches
# under, or "" if this machine has none.
#
# The box-drawing characters the prompt heuristic matches on are multibyte, and
# under a single-byte locale (LC_ALL=C, which hooks and cron can hand us) a
# bracket expression like [│┃|] matches individual *bytes* of them instead. The
# result is not an error, it is a silently wrong answer: the caret check then
# fails, every box reads as empty, and `send` quietly stops clearing before it
# types. Pin the locale rather than inherit it.
#
# Cached in APEX_UTF8_LOCALE — `locale -a` is not free and this runs per member
# in `status`.
_apex_utf8_locale() {
	if [[ -n ${APEX_UTF8_LOCALE+set} ]]; then
		print -r -- "$APEX_UTF8_LOCALE"
		return 0
	fi
	local cur=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
	if [[ ${cur:l} == *utf(-|)8* ]]; then
		APEX_UTF8_LOCALE=$cur
		print -r -- "$APEX_UTF8_LOCALE"
		return 0
	fi
	# Prefer C.UTF-8 (no collation surprises) over a language locale; take any
	# UTF-8 locale over none. Naming differs by platform: glibc spells it
	# "C.utf8", macOS ships only language locales.
	local l first=""
	APEX_UTF8_LOCALE=""
	for l in ${(f)"$(locale -a 2>/dev/null)"}; do
		case ${l:l} in
			c.utf8|c.utf-8)             APEX_UTF8_LOCALE=$l; break ;;
			en_us.utf8|en_us.utf-8)     APEX_UTF8_LOCALE=$l ;;
			*utf8|*utf-8) [[ -z $first ]] && first=$l ;;
		esac
	done
	[[ -z $APEX_UTF8_LOCALE ]] && APEX_UTF8_LOCALE=$first
	print -r -- "$APEX_UTF8_LOCALE"
}

# _pane_input_line <pane> — the text currently sitting unsent in the agent's
# input box, or "" if the box looks empty.
#
# Agent TUIs (Claude Code, codex) render input inside a box-drawn prompt:
#
#     ╭──────────────────────────────╮
#     │ > mark ready for review      │
#     ╰──────────────────────────────╯
#
# so the pending text is recoverable from a plain capture: find the last
# prompt line in the visible pane and strip the frame off it. This is a
# heuristic on rendered cells, and it deliberately cannot distinguish real
# typing from the agent's own *autosuggestion ghost text* — Claude Code
# predicts a plausible next input and paints it into the empty box, which
# looks identical here (issue #10). Callers must phrase what they report
# accordingly: "unsent input", never "someone typed this".
#
# Two things keep the heuristic from firing on ordinary agent output, which
# is full of lines that begin with a caret (shell transcripts, markdown
# blockquotes, diffs):
#
#   - Only the bottom of the *visible* pane is read, never scrollback. The
#     input box lives there; a wider window is all false-positive surface.
#   - A framed prompt wins over an unframed one. If the pane draws a box at
#     all, an unframed caret line is output rather than pending input. Panes
#     with no box at all (a bare `❯ ` prompt) still work, they just have no
#     frame to disambiguate with.
_pane_input_line() {
	setopt localoptions extendedglob
	# Scoped to this function; zsh calls setlocale() on assignment, and the
	# restore on return puts back whatever the caller had.
	local -x LC_ALL
	LC_ALL=$(_apex_utf8_locale)
	[[ -z $LC_ALL ]] && unset LC_ALL
	local pane="$1" cap line text
	local boxed="" boxed_seen="" bare=""
	[[ -n $pane ]] || return 1
	cap=$(tmux capture-pane -p -t "$pane" 2>/dev/null) || return 1
	local -a lines=(${(f)cap})
	(( ${#lines} > 12 )) && lines=(${lines[-12,-1]})
	for line in $lines; do
		local edge=""
		[[ $line == [[:space:]]#[│┃\|]* ]] && edge=1
		# Strip a leading box edge, then require a prompt caret. Note "$" is
		# NOT a caret here: no agent TUI uses it, but agent output prints
		# "$ some-command" constantly.
		text=${line##[[:space:]]#[│┃|]}
		text=${${text##[[:space:]]##}%%[[:space:]]##}
		[[ $text == [\>❯][[:space:]]* ]] || continue
		text=${text#[\>❯]}
		# Strip the trailing box edge and padding.
		text=${text%[│┃|]}
		text=${${text##[[:space:]]##}%%[[:space:]]##}
		if [[ -n $edge ]]; then
			boxed=$text; boxed_seen=1
		else
			bare=$text
		fi
	done
	if [[ -n $boxed_seen ]]; then
		print -r -- "$boxed"
	else
		print -r -- "$bare"
	fi
}

# _clear_pane_input <pane> — empty the agent's input box, best effort.
# Echoes whatever is still in the box afterwards ("" on success).
#
# C-u alone is not enough. It kills to the start of the line, so it leaves
# anything to the right of the cursor — and an autosuggestion is painted
# *ahead* of a cursor sitting at column 0, which is exactly the case this
# needs to handle, where C-u on its own is a no-op. C-e first, then C-u,
# kills a whole line; repeat for a multi-line draft, and verify.
_clear_pane_input() {
	local pane="$1" still i
	for i in 1 2 3; do
		tmux send-keys -t "$pane" C-e
		tmux send-keys -t "$pane" C-u
		sleep 0.1
		still=$(_pane_input_line "$pane" 2>/dev/null)
		[[ -z $still ]] && break
	done
	print -r -- "$still"
}

# _box_pending <box-line> <sent-text> — is <box-line> our own line still
# sitting unsent, rather than something else the pane has since drawn?
#
# True when the box shows the whole line or the leading part of it. Prefix,
# not suffix: a line wider than the box soft-wraps and _pane_input_line only
# ever returns the caret line, so the tail of a long message is not visible
# there at all and matching on it would pass unconditionally, checking
# nothing. Anything else in the box is somebody else's text — a repainted
# suggestion, a human's draft — which means ours is gone.
_box_pending() {
	local left="$1" sent="$2"
	[[ -n $left ]] || return 1
	[[ $sent == "$left"* ]]
}

# _send_to_pane <pane> <text> — one line, literal, then Enter.
#
# Three hazards, all seen live:
#
#   1. Whatever is already in the input box gets our text appended to it, and
#      the agent receives one spliced line. The box is not reliably empty:
#      a human may be mid-draft, and Claude Code paints predictive ghost text
#      into an idle box on its own (issue #10). So clear the box first — and
#      say what was cleared, on stderr and in the event log, so nothing
#      vanishes silently and the operator isn't left guessing whether they
#      lost real typing. Clearing is best effort and verified, not assumed;
#      if the box will not drain, say so and splice rather than lie.
#   2. tmux wraps a literal send in bracketed-paste; firing Enter in the same
#      instant lands mid-paste and gets dropped by some agent TUIs (observed
#      with codex — the message sits unsubmitted until a later, separate
#      Enter arrives). Give the pane a tick to finish processing the paste.
#   3. Even after that tick the Enter can be swallowed. Verify from the pane
#      that the box drained, and retry a bounded number of times if our own
#      text is still sitting there.
#
# Sets APEX_SEND_CLEARED to the pre-existing input it discarded ("" if none).
# Returns 0 delivered, 1 refused/tmux failure, 2 typed but never submitted.
_send_to_pane() {
	local pane="$1" text="$2"
	text=${text//$'\n'/ }
	text=${text//$'\r'/ }
	[[ -z $text ]] && return 1

	APEX_SEND_CLEARED=$(_pane_input_line "$pane" 2>/dev/null)
	if [[ -n $APEX_SEND_CLEARED ]] && [[ ${APEX_SEND_CLEAR:-1} == 1 ]]; then
		print -u2 "tmux-apex: pane $pane had unsent input; clearing it before delivery:"
		print -u2 "  ${APEX_SEND_CLEARED}"
		print -u2 "  (often the agent's own autosuggestion ghost text rather than typed"
		print -u2 "   input — see issue #10; recorded in the apex event log either way)"
		local unclearable
		unclearable=$(_clear_pane_input "$pane")
		if [[ -n $unclearable ]]; then
			print -u2 "tmux-apex: pane $pane input box did not clear; delivery will be"
			print -u2 "  appended to: ${unclearable}"
		fi
	elif [[ -n $APEX_SEND_CLEARED ]]; then
		# APEX_SEND_CLEAR=0: report, but leave the box alone and let the
		# splice happen rather than destroying input the operator may want.
		print -u2 "tmux-apex: pane $pane has unsent input and APEX_SEND_CLEAR=0;"
		print -u2 "  delivering anyway — it will be appended to: ${APEX_SEND_CLEARED}"
	fi

	tmux send-keys -t "$pane" -l -- "$text" || return 1
	sleep 0.2
	tmux send-keys -t "$pane" Enter || return 1

	# Submitted means our own line is no longer pending in the box.
	#
	# Retries never fire a bare Enter. After a successful submit the agent
	# frequently repaints an autosuggestion of its own; if that ghost ever
	# fooled _box_pending, a bare Enter would submit the agent's guess as a
	# real instruction — the issue #10 failure mode, reintroduced by the fix
	# for it. Clear and retype instead, so the worst case is our own message
	# delivered twice rather than the agent's guess delivered once.
	local left i
	for i in 1 2 3; do
		sleep 0.2
		left=$(_pane_input_line "$pane" 2>/dev/null)
		_box_pending "$left" "$text" || return 0
		_clear_pane_input "$pane" >/dev/null
		tmux send-keys -t "$pane" -l -- "$text" || return 1
		# Hazard 2 applies to the retype exactly as it does to the first
		# send: without this gap every retry fires its Enter mid-paste, and
		# the retry loop is systematically less likely to land than the
		# attempt it is retrying.
		sleep 0.2
		tmux send-keys -t "$pane" Enter || return 1
	done
	# The Enter above has had no time to land yet — wait before the verdict,
	# or a send that succeeded on the last retry gets reported as a failure.
	sleep 0.2
	left=$(_pane_input_line "$pane" 2>/dev/null)
	_box_pending "$left" "$text" && return 2
	return 0
}

# ─── apex identity ──────────────────────────────────────────────────

# Manager session governing the current session (or itself if it is the manager).
_resolve_manager() {
	local s="${1:-$(_cur_session)}" role
	[[ -z $s ]] && return 1
	role=$(_sopt "$s" @apex_role)
	if [[ $role == manager ]]; then
		printf '%s' "$s"
		return 0
	fi
	local m
	m=$(_sopt "$s" @apex_session)
	[[ -n $m ]] && printf '%s' "$m" && return 0
	return 1
}

_require_manager() {
	local m
	m=$(_resolve_manager) || _die "no apex manager for this session. Run: tmux-apex.sh init"
	printf '%s' "$m"
}

# _cur_member — identity of whichever pane/session a hook or command is
# currently running in: the bare session name for a manager or an untracked
# pane, or "session:pane" for a pane registered as an apex member.
_cur_member() {
	local session pane
	session=$(_cur_session) || return 1
	[[ $(_sopt "$session" @apex_role) == manager ]] && { print -r -- "$session"; return 0; }
	pane="$TMUX_PANE"
	if [[ -n $pane ]] && [[ -n $(tmux show-option -p -t "$pane" -qv @apex_role 2>/dev/null) ]]; then
		print -r -- "${session}:${pane}"
		return 0
	fi
	print -r -- "$session"
}

# ─── facts about a member session ────────────────────────────────────

# _member_facts <session> [--with-pane-input] — a JSON object of live,
# derived state.
#
# pane_input costs a capture-pane per member and only `status` displays it, so
# it is opt-in: `pending` runs on every agent hook and does not need it.
_member_facts() {
	local session="$1" wt branch pr_number pr_state pr_draft icons ahead dirty alive
	local want_pane_input=false a
	for a in "${@[2,-1]}"; do
		[[ $a == --with-pane-input ]] && want_pane_input=true
	done
	alive=false
	_member_alive "$session" && alive=true

	wt=$(apex_member_get "$APEX_SESSION" "$session" worktree 2>/dev/null)
	[[ -z $wt || ! -d $wt ]] && wt=""

	branch=""; ahead=0; dirty=false
	if [[ -n $wt ]]; then
		branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)
		[[ -n $(git -C "$wt" status --porcelain 2>/dev/null) ]] && dirty=true
		ahead=$(git -C "$wt" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
		[[ -z $ahead ]] && ahead=0
	fi

	pr_number=""; pr_state=""; icons=""; pr_draft=""
	if [[ -n $wt && -n $branch ]]; then
		local rec
		rec=$(pr_cache_read "$wt" "$branch" 2>/dev/null)
		if [[ -n $rec ]]; then
			pr_number=$(printf '%s' "$rec" | jq -r '.pr_number // ""')
			pr_state=$(printf '%s' "$rec"  | jq -r '.state // ""')
			pr_draft=$(printf '%s' "$rec"  | jq -r '.is_draft // ""')
			icons=$(printf '%s' "$rec"     | jq -r '.icons // ""')
		fi
	fi

	local pane_input=""
	if $want_pane_input && $alive; then
		local mpane
		mpane=$(_agent_pane "$session" 2>/dev/null)
		[[ -n $mpane ]] && pane_input=$(_pane_input_line "$mpane" 2>/dev/null)
	fi

	local working attention
	working=$(_sopt "$session" @agent_working)
	attention=$(_sopt "$session" @agent_needs_attention)

	jq -nc \
		--arg session "$session" --arg wt "$wt" --arg branch "$branch" \
		--arg pr "$pr_number" --arg pr_state "$pr_state" --arg pr_draft "$pr_draft" \
		--arg icons "$icons" --argjson ahead "${ahead:-0}" \
		--argjson dirty "$dirty" --argjson alive "$alive" \
		--arg working "$working" --arg attention "$attention" \
		--arg pane_input "$pane_input" \
		'{session:$session, alive:$alive, worktree:$wt, branch:$branch,
		  pane_input:$pane_input,
		  pr_number:$pr, pr_state:$pr_state, pr_draft:$pr_draft, pr_icons:$icons,
		  commits_ahead:$ahead, dirty:$dirty,
		  agent: (if $attention != "" then "needs-attention"
		          elif $working != "" then "working" else "idle" end)}'
}

# One-line human summary used in pings.
_facts_line() {
	printf '%s' "$1" | jq -r '
		[ (if .branch != "" then "branch=" + .branch else empty end),
		  (if .pr_number != "" then "pr=#" + .pr_number
		     + (if .pr_draft == "true" then "(draft)" else "" end)
		     + (if .pr_state != "" and .pr_state != "OPEN" then "(" + (.pr_state|ascii_downcase) + ")" else "" end)
		   else "pr=none" end),
		  ("commits_ahead=" + (.commits_ahead|tostring)),
		  (if .dirty then "uncommitted-changes" else empty end),
		  (if .alive|not then "SESSION-DEAD" else empty end)
		] | join(" ")'
}

# ─── init / stop ─────────────────────────────────────────────────────

_cmd_init() {
	local force=false a
	for a in "$@"; do [[ $a == --force ]] && force=true; done

	local session main other
	session=$(_cur_session) || _die "not inside tmux"
	main=$(_main_tree) || true
	[[ -z $main ]] && _die "not inside a git repository (run init from the repo you want to manage)"

	if [[ $force != true ]]; then
		for other in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"}; do
			[[ $other == "$session" ]] && continue
			[[ $(_sopt "$other" @apex_role) == manager ]] || continue
			[[ $(_sopt "$other" @apex_repo) == "$main" ]] || continue
			_die "session '$other' is already the apex manager for $main (use --force to take over)"
		done
	fi

	tmux set-option -t "$session" @apex_role manager
	tmux set-option -t "$session" @apex_repo "$main"
	# When init is run by the manager agent itself, $TMUX_PANE is that agent's
	# pane — the most reliable way to learn where to deliver pings.
	[[ -n $TMUX_PANE ]] && tmux set-option -t "$session" @agent_pane "$TMUX_PANE"

	apex_init_dirs "$session"
	apex_write_atomic "$(apex_file "$session")" \
		"$(jq -nc --arg s "$session" --arg r "$main" --arg p "${TMUX_PANE:-}" \
			--argjson t "$(date +%s)" \
			'{session:$s, repo:$r, agent_pane:$p, created_at:$t}')"
	apex_event "$session" "$(jq -nc --arg s "$session" '{event:"manager-init", session:$s}')"

	tmux refresh-client -S 2>/dev/null
	print "Apex manager active."
	print "  session : $session"
	print "  repo    : $main"
	print "  pane    : ${TMUX_PANE:-<unknown>}"
	print "  state   : $(apex_dir "$session")"

	# Loud on stderr if ping delivery isn't wired — a manager with no hooks
	# installed is silently blind to every worker transition. See `doctor`.
	APEX_REPO="$main" _cmd_doctor --quiet || true
}

_cmd_stop() {
	local session
	session=$(_cur_session) || _die "not inside tmux"
	[[ $(_sopt "$session" @apex_role) == manager ]] || _die "this session is not an apex manager"
	tmux set-option -u -t "$session" @apex_role 2>/dev/null
	tmux set-option -u -t "$session" @apex_repo 2>/dev/null
	apex_event "$session" "$(jq -nc '{event:"manager-stop"}')"
	tmux refresh-client -S 2>/dev/null
	print "Apex mode off. Member sessions keep running; state kept at $(apex_dir "$session")"
}

# ─── relink (session-restart recovery) ───────────────────────────────

# relink — re-derive @apex_role/@apex_session/@apex_task/@apex_repo for the
# CURRENT session from durable state.
#
# @-options are tmux session options: they never survive a killed-and-
# recreated session (a crash, `claude --continue` picking the session back
# up, the picker reusing a session name). Durable state under $APEX_ROOT
# does survive, but nothing used to re-attach the two — a resumed manager
# lost its pink robot pill and its ability to resolve itself via
# `_require_manager`, and a resumed worker stopped reporting status at all
# (agent-tmux-status.sh gates on @apex_session being set). Same fragility
# class as the manager-ping bug above, one layer down.
#
# Called unconditionally, for every session, at the top of
# scripts/apex-manager-notify.sh (itself wired to every session's own
# UserPromptSubmit/SessionStart hooks) — ahead of that script's `pending`
# call, since determining whether this session is even a manager is the
# whole point. No-op for a session that already has a role, or that matches
# no durable state at all.
_cmd_relink() {
	local session pane
	session=$(_cur_session) || return 0
	pane="$TMUX_PANE"

	[[ $(_sopt "$session" @apex_role) == manager ]] && return 0   # manager already linked
	[[ -n $pane ]] && [[ -n $(tmux show-option -p -t "$pane" -qv @apex_role 2>/dev/null) ]] && return 0   # member already linked

	# Manager? Only if the most recent manager-init/manager-stop event for
	# this session's own state directory is an init — otherwise the human
	# deliberately ran `stop` on it, and resuming the session (e.g.
	# `--continue`) must not silently undo that. Also cross-check the repo
	# a reused session name could otherwise resurrect the wrong manager.
	if [[ -d "$(apex_dir "$session")" ]]; then
		local repo last
		repo=$(jq -r '.repo // empty' "$(apex_file "$session")" 2>/dev/null)
		last=$(jq -rs '[.[] | select(.event=="manager-init" or .event=="manager-stop")] | last | .event // empty' \
			"$(apex_events_file "$session")" 2>/dev/null)
		if [[ $last == manager-init && ( -z $repo || $repo == "$(_main_tree "$PWD")" ) ]]; then
			tmux set-option -t "$session" @apex_role manager
			[[ -n $repo ]] && tmux set-option -t "$session" @apex_repo "$repo"
			tmux refresh-client -S 2>/dev/null
			return 0
		fi
	fi

	# Worker/reviewer/monitor? Relink runs inside the member's own pane
	# (triggered by that pane's own hooks), so $TMUX_PANE is exactly the pane
	# needing to be re-linked — but after a session is destroyed and
	# recreated, old pane ids are gone, so a durable record's old
	# "session:oldpane" key can't be found by exact match. Match by
	# session-name prefix instead, and only act when unambiguous: more than
	# one member previously registered for this session can't be
	# disambiguated from here, and is left for manual recovery (respawn).
	[[ -z $pane ]] && return 0
	local f wt
	local -a matches=()
	for f in "$APEX_ROOT"/*/members/"${session}:"*.json(N); do
		wt=$(jq -r '.worktree // empty' "$f" 2>/dev/null)
		[[ -n $wt && $wt != "$PWD" ]] && continue
		matches+=("$f")
	done
	(( ${#matches} == 1 )) || return 0

	f="${matches[1]}"
	local manager role issue review_pr task old_key new_key
	manager="${f:h:h:t}"
	role=$(jq -r '.role // "worker"' "$f" 2>/dev/null)
	issue=$(jq -r '.issue // empty' "$f" 2>/dev/null)
	review_pr=$(jq -r '.review_pr // empty' "$f" 2>/dev/null)
	task="${issue:+issue:$issue}${review_pr:+pr:$review_pr}"

	tmux set-option -p -t "$pane" @apex_session "$manager"
	tmux set-option -p -t "$pane" @apex_role "$role"
	[[ -n $task ]] && tmux set-option -p -t "$pane" @apex_task "$task"

	old_key="${f:t:r}"
	new_key="${session}:${pane}"
	[[ $old_key != $new_key ]] && mv -f "$f" "$(apex_member_file "$manager" "$new_key")" 2>/dev/null

	tmux refresh-client -S 2>/dev/null
}

# ─── spawn ───────────────────────────────────────────────────────────

_cmd_spawn() {
	local issue="" review_pr="" role="worker" model="" perm="" mode="autonomous"
	local switch="no-switch" agent="" profile=""

	while (( $# )); do
		case "$1" in
			--issue)      _need_val spawn "$1" $#; issue="$2"; shift 2 ;;
			--review-pr)  _need_val spawn "$1" $#; review_pr="$2"; shift 2 ;;
			--role)       _need_val spawn "$1" $#; role="$2"; shift 2 ;;
			--agent)      _need_val spawn "$1" $#; agent="$2"; shift 2 ;;
			--model)      _need_val spawn "$1" $#; model="$2"; shift 2 ;;
			--profile)    _need_val spawn "$1" $#; profile="$2"; shift 2 ;;
			# --agent-flags is the accurate name: only claude calls this a
			# "permission mode". Both spellings feed the same slot.
			--mode)       _need_val spawn "$1" $#; mode="$2"; shift 2 ;;
			--permission-mode|--agent-flags)
			              _need_val spawn "$1" $#; perm="$2"; shift 2 ;;
			--switch)     switch="switch"; shift ;;
			*) _die "spawn: unknown argument '$1'" ;;
		esac
	done

	[[ -n $issue || -n $review_pr ]] || _die "spawn: need --issue N or --review-pr N"
	[[ -n $issue && -n $review_pr ]] && _die "spawn: --issue and --review-pr are mutually exclusive"

	# A named profile fills in whichever of agent/model/agent-flags the caller
	# didn't already set explicitly — explicit flags always win field-by-field.
	# Must run before the bare-token-vs-non-claude-agent guard below, since a
	# profile can supply the very agent/perm values that guard inspects.
	if [[ -n $profile ]]; then
		local pjson rc
		pjson=$(apex_profile_resolve "$profile"); rc=$?
		case $rc in
			0) ;;
			1) _die "spawn: profile file missing: $(apex_profiles_repo_file)" ;;
			2) _die "spawn: malformed JSON in $(apex_profiles_repo_file)" ;;
			3) _die "spawn: malformed JSON in $(apex_profiles_user_file)" ;;
			*) _die "spawn: unknown profile '$profile' (see 'tmux-apex.sh profiles')" ;;
		esac
		[[ -z $agent ]] && agent=$(jq -r '.agent // empty' <<< "$pjson")
		[[ -z $model ]] && model=$(jq -r '.model // empty' <<< "$pjson")
		[[ -z $perm  ]] && perm=$(jq -r '.agent_flags // empty' <<< "$pjson")
	fi

	# Only the claude adapter accepts a bare token here (it prepends
	# --permission-mode). Every other agent gets the value as verbatim argv, so a
	# bare token would arrive as a stray positional and silently derail the
	# spawn. Refuse it loudly instead.
	if [[ -n $perm && $perm != -* && -n $agent && ${agent:t} != claude ]]; then
		_die "spawn: --agent-flags for '${agent}' must be agent-native argv (e.g. --approve, --full-auto), not the claude token '${perm}'"
	fi

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local -a envs=(
		"CODING_AGENT_ROLE=${role}"
		"CODING_AGENT_APEX_SESSION=${manager}"
	)
	[[ -n $agent ]] && envs+=("CODING_AGENT=${agent}")
	[[ -n $model ]] && envs+=("CODING_AGENT_MODEL=${model}")
	[[ -n $perm  ]] && envs+=("CODING_AGENT_PERMISSION_MODE=${perm}")

	local out
	if [[ -n $issue ]]; then
		out=$("${SCRIPTS}/tmux-picker.sh" --spawn-issue "$issue" "$mode" "$switch" "${envs[@]}") || _die "spawn failed"
	else
		local branch
		branch=$(gh pr view "$review_pr" --json headRefName --jq .headRefName 2>/dev/null)
		[[ -z $branch ]] && _die "spawn: could not resolve branch for PR #$review_pr"
		out=$("${SCRIPTS}/tmux-picker.sh" --spawn-pr-review "$branch" "$switch" "${envs[@]}") || _die "spawn failed"
	fi

	local line session worktree
	line=$(printf '%s\n' "$out" | awk -F'\t' '$1=="apex-session"' | tail -1)
	[[ -z $line ]] && { print -r -- "$out"; _die "spawn: picker did not report a session"; }
	session=$(printf '%s' "$line" | cut -f2)
	worktree=$(printf '%s' "$line" | cut -f3)

	# Member registration (pane-scoped @apex_role/@apex_task/@apex_session +
	# apex_member_merge) is no longer done here: the picker only knows a
	# session name at this point, not the agent's actual pane id (the first
	# agent pane in a fresh session is created asynchronously, inside that
	# session, by tmux-dev-layout.sh). Registration happens wherever the
	# pane is actually created — see tmux-apex.sh's `_register-member` and
	# its callers (tmux-dev-layout.sh for a fresh session, tmux-picker.sh's
	# _add_agent_pane for an extra pane in an already apex-tracked session,
	# which registers synchronously and so already reports a full
	# "session:pane" member id in $session here).
	apex_event "$manager" "$(jq -nc --arg s "$session" --arg role "$role" \
		--arg issue "$issue" --arg pr "$review_pr" \
		'{event:"spawn", session:$s, role:$role, issue:$issue, review_pr:$pr}')"

	print "Spawned ${role}: $session"
	print "  worktree : $worktree"
	print "  task     : ${issue:+issue #$issue}${review_pr:+PR #$review_pr}"
	print "  profile  : ${profile:-<none>}"
	print "  model    : ${model:-<default>}   permission-mode: ${perm:-<default>}"
}

# ─── register-member (called from wherever an agent pane is actually
#     created — tmux-dev-layout.sh for the first pane in a fresh session,
#     tmux-picker.sh's _add_agent_pane for an extra pane in an existing one)
#
# _register-member <pane_id> <manager> <role> <task> <worktree> [model] [perm] [mode] [agent] [profile] [issue] [pr]
_cmd_register_member() {
	local pane_id="$1" manager="$2" role="$3" task="$4" worktree="$5"
	local model="$6" perm="$7" mode="$8" agent="${9:-claude}" profile="${10}"
	local issue="${11}" pr="${12}"
	[[ -z $pane_id || -z $manager ]] && _die "_register-member: need <pane_id> <manager>"

	local session member
	session=$(tmux display-message -p -t "$pane_id" '#S' 2>/dev/null)
	[[ -z $session ]] && _die "_register-member: pane '$pane_id' not found"
	member="${session}:${pane_id}"

	tmux set-option -p -t "$pane_id" @apex_role "${role:-worker}"
	tmux set-option -p -t "$pane_id" @apex_session "$manager"
	[[ -n $task ]] && tmux set-option -p -t "$pane_id" @apex_task "$task"

	# Recorded durably (not just as the transient CODING_AGENT env var used to
	# pick an adapter at layout time) so `send` can later tell which agents
	# have a native session-message API — see _send_native.
	apex_member_merge "$manager" "$member" "$(jq -nc \
		--arg role "${role:-worker}" --arg wt "$worktree" --arg model "$model" \
		--arg perm "$perm" --arg mode "$mode" --arg agent "$agent" \
		--arg profile "$profile" --arg issue "$issue" --arg pr "$pr" \
		--argjson t "$(date +%s)" \
		'{role:$role, worktree:$wt, model:$model, permission_mode:$perm,
		  mode:$mode, agent:$agent, profile:$profile, issue:$issue, review_pr:$pr,
		  status:"starting", seq:0, pinged_seq:-1,
		  spawned_at:$t, updated_at:$t}')"

	apex_event "$manager" "$(jq -nc --arg s "$member" --arg role "${role:-worker}" \
		--arg issue "$issue" --arg pr "$pr" \
		'{event:"register", session:$s, role:$role, issue:$issue, review_pr:$pr}')"

	tmux refresh-client -S 2>/dev/null
}

# ─── native message delivery (codex/opencode) ─────────────────────────

# _codex_thread_for <worktree> — newest codex session id whose recorded cwd
# matches <worktree>, or nothing if none found. Codex writes a session_meta
# record as the first line of every rollout file under
# $CODEX_HOME/sessions/**, including the cwd it started in — durable state
# that already exists for free, no capture-at-spawn plumbing needed.
_codex_thread_for() {
	local wt="$1" home f
	[[ -z $wt ]] && return 1
	home="${CODEX_HOME:-$HOME/.codex}"
	for f in "$home"/sessions/*/*/*/rollout-*.jsonl(Nom); do
		jq -e --arg wt "$wt" \
			'select(.type=="session_meta" and .payload.cwd==$wt)' \
			<(head -n1 "$f") >/dev/null 2>&1 || continue
		jq -r '.payload.session_id' <(head -n1 "$f")
		return 0
	done
	return 1
}

# _opencode_session_for <worktree> — most recently updated opencode session
# whose exact starting directory is <worktree>. `opencode session list`
# looked like the obvious way to ask this, but it groups by git project
# (repo root) rather than exact directory — every worktree of the same repo
# gets the identical list back, which is useless here since apex's whole
# model is sibling worktrees of one repo (verified against two real
# worktrees: `session list` was byte-identical from both). opencode's own
# sqlite store does record the exact directory a session was started in
# (the `session.directory` column), so read that directly instead.
_opencode_session_for() {
	local wt="$1" db esc id
	[[ -d $wt ]] || return 1
	db="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
	[[ -f $db ]] || return 1
	esc=${wt//\'/\'\'}
	id=$(sqlite3 -readonly "$db" \
		"select id from session where directory = '${esc}' order by time_updated desc limit 1;" 2>/dev/null)
	[[ -n $id ]] || return 1
	printf '%s' "$id"
}

# _send_native <agent> <worktree> <text> — deliver via the agent's own
# out-of-band session-message API instead of tmux keystrokes, for the two
# agents that have one. Returns 1 (caller falls back to send-keys) for any
# other agent, or when no session id can be resolved for <worktree>.
#
# codex: `queue` hands the message to the shared app-server daemon and
# returns immediately — verified live against a running interactive codex
# session: a queued message showed up as a new turn in the same pane and
# was acted on, no keystrokes involved. Runs synchronously with a short
# timeout and reports failure honestly on a non-zero exit.
#
# opencode: `run -s ID -c` was verified live the same way, with one real
# caveat — it does append to the *same* session (confirmed via opencode's
# own sqlite store: one session, messages in order) and the agent does act
# on it (asked to recall its reply, it could), but the already-running
# interactive TUI in the worker's pane never visually refreshes to render
# that exchange — a human tmux-attaching to the pane right after a `send`
# will not see it there, only in `status --json`'s events, until they
# interact with that TUI again themselves. Also, unlike codex's queue,
# `run` most likely blocks for the full agent turn rather than just
# enqueuing, so it's backgrounded rather than run synchronously — this can
# only confirm the message was handed off, not that it was acted on, same
# as the send-keys path it replaces.
_send_native() {
	local agent="$1" wt="$2" text="$3" id
	case "$agent" in
		codex)
			id=$(_codex_thread_for "$wt") || return 1
			timeout 8 codex queue --thread "$id" --message "$text" >/dev/null 2>&1
			;;
		opencode)
			id=$(_opencode_session_for "$wt") || return 1
			( cd "$wt" && opencode run -s "$id" -c "$text" >/dev/null 2>&1 &! )
			;;
		*) return 1 ;;
	esac
}

# ─── send ────────────────────────────────────────────────────────────

# _deliver <target> <from-label> <text>
#
# The delivery half of `send`, factored out so the paired fix/re-review loop
# (see "pair" below) can relay between two members without going through the
# manager. Prints nothing; returns non-zero with a reason on stderr-free
# failure so callers can decide whether that is fatal.
#
# Sets _DELIVER_VIA to a human-readable channel description on success.
#
# Return codes: 0 delivered; 1 target dead or empty text; 2 no agent pane;
# 3 pane is not running a coding agent; 4 the send itself failed; 5 the text
# was typed into the pane but never confirmed submitted (see _send_to_pane).
# 5 is deliberately distinct from 4: the message *is* sitting in the member's
# input box, so an operator has something to act on, and `send` reports that
# rather than a flat failure. Non-interactive callers (the pair loop) still
# treat it as undelivered — an unsubmitted relay never wakes the partner.
_DELIVER_VIA=""
_deliver() {
	local target="$1" from="$2" text="$3"
	_DELIVER_VIA=""
	[[ -z $target || -z $text ]] && return 1
	_member_alive "$target" || return 1

	local full="[apex from:${from:-manager}] ${text}"

	# Native delivery only applies to a tracked apex member — anything else
	# (a hand-run session, or an agent with no native API) falls straight
	# through to the tmux send-keys path exactly as before.
	local manager agent wt pane
	manager=$(_resolve_manager "$target" 2>/dev/null)
	if [[ -n $manager ]]; then
		agent=$(apex_member_get "$manager" "$target" agent)
		wt=$(apex_member_get "$manager" "$target" worktree)
		if _send_native "$agent" "$wt" "$full"; then
			_DELIVER_VIA="native: $agent"
			return 0
		fi
	fi

	pane=$(_agent_pane "$target")
	[[ -n $pane ]] || return 2
	_pane_is_agent "$pane" || return 3
	local src=0
	_send_to_pane "$pane" "$full" || src=$?
	(( src == 1 )) && return 4
	(( src == 2 )) && return 5
	_DELIVER_VIA="$pane"
	return 0
}

_cmd_send() {
	local target="$1"; shift
	[[ -z $target ]] && _die "send: usage: send <session> <text>"
	local text="$*"
	[[ -z $text ]] && _die "send: empty message"
	APEX_SEND_CLEARED=""

	_member_alive "$target" || _die "send: session '$target' is not running"

	local from rc manager
	from=$(_cur_session 2>/dev/null)
	# Resolved before delivery, not after: the unconfirmed-send branch below
	# needs somewhere to record what is now sitting in the member's input box.
	manager=$(_resolve_manager "$target" 2>/dev/null)

	_deliver "$target" "${from:-manager}" "$text"; rc=$?
	case $rc in
		0) ;;
		2) _die "send: session '$target' has no @agent_pane (no coding agent split?)" ;;
		3) _die "send: pane $(_agent_pane "$target") of '$target' is not running a coding agent — refusing to send" ;;
		5)
			print -u2 "tmux-apex: send: text was typed into $(_agent_pane "$target") but never submitted"
			print -u2 "  (re-typed and Enter re-sent 3x; still in the input box)"
			# Record the text: it *is* in the member's pane now and may yet be
			# submitted by a stray Enter. Without it the log says a send failed
			# but not what is sitting there, which is the one thing an operator
			# needs to decide whether to submit it or clear it.
			[[ -n $manager ]] && apex_event "$manager" "$(jq -nc \
				--arg s "$target" --arg from "$from" --arg text "$text" \
				--arg cleared "${APEX_SEND_CLEARED:-}" \
				'{event:"send-unsubmitted", session:$s, from:$from, text:$text}
				 + (if $cleared != "" then {cleared_input:$cleared} else {} end)')"
			_die "send: delivery unconfirmed"
			;;
		*) _die "send: delivery failed" ;;
	esac

	[[ -z $manager ]] && manager="$from"
	[[ -n $manager ]] && apex_event "$manager" "$(jq -nc \
		--arg s "$target" --arg from "$from" --arg text "$text" \
		--arg cleared "${APEX_SEND_CLEARED:-}" \
		'{event:"send", session:$s, from:$from, text:$text}
		 + (if $cleared != "" then {cleared_input:$cleared} else {} end)')"

	print "Delivered to $target (${_DELIVER_VIA})."
	[[ -n ${APEX_SEND_CLEARED:-} ]] && \
		print "Cleared unsent input first: ${APEX_SEND_CLEARED}"
}

# ─── paired worker↔reviewer fix/re-review loop (issue #9) ────────────
#
# Two members already working the same PR (a `worker` on the issue and a
# `monitor` spawned with --review-pr) are, by default, independent records
# keyed by session:pane with no relationship between them. `link` records
# that relationship on both sides, after which every idle transition of
# either one is relayed straight to the other instead of surfacing to the
# manager:
#
#   reviewer idle → verdict says N>0 findings → relay to worker, round++
#   worker   idle → relay "re-review" to reviewer
#   reviewer idle → verdict says 0 findings   → `gh pr ready`, ping manager
#
# The termination signal is a real check, not a text-scrape of the review
# prose: the reviewer is required to record `verdict --findings N` (or
# --none) before it stops. A reviewer that goes idle without recording one
# halts the loop and escalates, because "no verdict" and "no findings" are
# very different states and guessing between them silently flips a PR to
# ready-for-review.
#
# Member fields owned by this section:
#   pair            other member's key ("session:%pane")
#   pair_role       worker | reviewer   (this member's role in the loop)
#   pair_pr         PR number the loop is about
#   pair_round      1-based round counter
#   pair_max_rounds cap; exceeding it escalates as "stuck", never loops on
#   pair_turn       worker | reviewer — whose idle transition relays next
#   pair_state      active | complete | stuck
#   pair_message    escalation text for `pending` to surface, once terminal
#   verdict_round / verdict_findings / verdict_note   last recorded verdict

APEX_PAIR_MAX_ROUNDS=${APEX_PAIR_MAX_ROUNDS:-5}

_pair_worker_msg() {
	local pr="$1" round="$2" findings="$3" note="$4"
	print -r -- "PAIRED REVIEW round ${round}: the reviewer on PR #${pr} recorded ${findings} finding(s) worth addressing${note:+ — \"${note}\"}. Read them with 'gh pr view ${pr} --comments' and 'gh api repos/{owner}/{repo}/pulls/${pr}/comments'. Fix every BUG/CONCERN finding and push to the PR branch; for anything you disagree with, reply on that review thread saying why rather than silently skipping it. Do NOT message the manager or wait for a human — when your commits are pushed, just stop. The reviewer is re-invoked automatically."
}

_pair_reviewer_msg() {
	local pr="$1" round="$2" kind="$3"
	local lead
	if [[ $kind == initial ]]; then
		lead="PAIRED REVIEW round ${round}: you are now the reviewer half of an automatic fix/re-review loop on PR #${pr}."
	else
		lead="PAIRED REVIEW round ${round}: the worker pushed fixes for PR #${pr}. Re-review it (/my-pr-review ${pr}), covering the findings you raised last round and anything new in the diff. Post findings as PR comments as usual."
	fi
	print -r -- "${lead} Before you stop you MUST record a machine-readable verdict — the loop halts and escalates to a human without one: run 'tmux-apex.sh verdict --findings <count worth addressing>', or 'tmux-apex.sh verdict --none' if nothing is left worth fixing. Count BUG/CONCERN findings, plus any SUGGESTION you genuinely think should be acted on; do not count nits you would not block on. Recording --none flips the PR out of draft and hands it to a human, so only do that when you would approve it. Do NOT message the manager."
}

# _pair_relay <manager> <target> <text> — deliver, or halt the loop if the
# partner cannot be reached. A relay that silently fails would strand both
# members idle with nobody notified.
#
# On failure, sets _PAIR_RELAY_WHY to a phrase naming the cause, so the
# escalation says something an operator can act on. An unsubmitted relay
# (_deliver rc 5) is a failure here even though a human `send` treats it as
# recoverable: the text sits in the box unread, so the partner never wakes.
#
# Whatever the pane-clearing discarded (APEX_SEND_CLEARED, see _send_to_pane)
# is recorded as cleared_input on the event, the same as `send` does — and on
# the failure path too, since a draft destroyed by a relay that then failed is
# exactly as gone. This is the one delivery path that is both unattended and
# unwatched: it runs from _cmd_settle under `tmux run-shell -b -d`, so
# _send_to_pane's stderr report has no operator reading it, and the event log
# is the only place the discarded text survives.
#
# The global is reset before delivering: on the native path _send_to_pane never
# runs, and a stale value from an earlier send-keys delivery would otherwise be
# logged as if this relay had cleared it.
_PAIR_RELAY_WHY=""
_pair_relay() {
	local manager="$1" target="$2" text="$3" rc=0
	_PAIR_RELAY_WHY=""
	APEX_SEND_CLEARED=""
	_deliver "$target" "apex-pair" "$text" || rc=$?
	local ev
	ev=$(jq -nc --arg s "$target" --arg text "$text" \
		--arg cleared "${APEX_SEND_CLEARED:-}" --argjson rc "$rc" \
		'{session:$s, text:$text}
		 + (if $rc != 0 then {rc:$rc} else {} end)
		 + (if $cleared != "" then {cleared_input:$cleared} else {} end)')
	if (( rc )); then
		case $rc in
			5) _PAIR_RELAY_WHY="the relay was typed into that pane but never submitted; it is sitting unsent in the input box" ;;
			2|3) _PAIR_RELAY_WHY="no reachable coding agent in that pane" ;;
			*) _PAIR_RELAY_WHY="delivery to that pane failed" ;;
		esac
		apex_event "$manager" \
			"$(print -r -- "$ev" | jq -c '{event:"pair-relay-failed"} + .')"
		return 1
	fi
	apex_event "$manager" \
		"$(print -r -- "$ev" | jq -c '{event:"pair-relay"} + .')"
	return 0
}

# _pair_rollback <manager> <member> <pair> <round> <turn>
#
# Undo the pair state written ahead of a relay that then failed to deliver.
# The pre-write is deliberate (it must not race the wake-up it causes), so the
# undelivered case is the one that has to clean up after it.
_pair_rollback() {
	local manager="$1" round="$4" turn="$5" m
	for m in "$2" "$3"; do
		[[ -n $m ]] || continue
		apex_member_merge "$manager" "$m" "$(jq -nc \
			--argjson r "$round" --arg t "$turn" \
			'{pair_round:$r, pair_turn:$t}')"
	done
}

# _pair_escalate <manager> <member> <state> <message>
#
# Terminal state for the loop: mark both halves, then make the *worker* the
# member the manager is told about (it owns the PR) with pinged_seq reset so
# `pending` is guaranteed to surface it once, even if this member's current
# seq was already delivered.
_pair_escalate() {
	local manager="$1" member="$2" state="$3" msg="$4"
	local pair worker
	pair=$(apex_member_get "$manager" "$member" pair)
	if [[ $(apex_member_get "$manager" "$member" pair_role) == worker ]]; then
		worker="$member"
	else
		worker="$pair"
	fi
	[[ -n $worker ]] || worker="$member"

	local m
	for m in "$member" "$pair"; do
		[[ -n $m ]] || continue
		apex_member_merge "$manager" "$m" \
			"$(jq -nc --arg st "$state" '{pair_state:$st}')"
	done

	apex_member_merge "$manager" "$worker" "$(jq -nc \
		--arg msg "$msg" --arg st attention --argjson p -1 \
		'{pair_message:$msg, status:$st, pinged_seq:$p}')"

	# Escalate once, about the PR — not twice, once per pane. The half that
	# is not carrying the message has its own ping consumed so `pending`
	# does not also emit a bare "reviewer went idle" line beside it.
	local seq
	for m in "$member" "$pair"; do
		[[ -n $m && $m != "$worker" ]] || continue
		seq=$(apex_member_get "$manager" "$m" seq); [[ -n $seq ]] || seq=0
		apex_member_merge "$manager" "$m" "$(jq -nc --argjson s "$seq" '{pinged_seq:$s}')"
	done

	apex_event "$manager" "$(jq -nc --arg s "$worker" --arg st "$state" --arg msg "$msg" \
		'{event:"pair-" + $st, session:$s, message:$msg}')"
}

_pair_finish() {
	local manager="$1" member="$2" round="$3"
	local pair worker pr wt ready_note=""
	pair=$(apex_member_get "$manager" "$member" pair)
	if [[ $(apex_member_get "$manager" "$member" pair_role) == worker ]]; then
		worker="$member"
	else
		worker="$pair"
	fi
	pr=$(apex_member_get "$manager" "$member" pair_pr)
	wt=$(apex_member_get "$manager" "$worker" worktree)

	if [[ -n $pr ]]; then
		if [[ -n $wt && -d $wt ]] && ( cd "$wt" && gh pr ready "$pr" >/dev/null 2>&1 ); then
			ready_note="PR #${pr} flipped out of draft to ready-for-review."
		else
			ready_note="Could not flip PR #${pr} out of draft automatically ('gh pr ready ${pr}' failed) — do it by hand."
		fi
	fi

	_pair_escalate "$manager" "$member" complete \
		"READY FOR HUMAN REVIEW: the paired reviewer found no further findings worth addressing on PR #${pr} after ${round} round(s). ${ready_note} Nothing is left for an agent to do — this needs the human's merge decision."
}

# _pair_advance <manager> <member>
#
# Returns 0 if this idle transition was consumed by the loop (so the caller
# must not surface it to the manager), 1 if it should fall through to normal
# reporting.
_pair_advance() {
	local manager="$1" member="$2"
	local pair role state turn round max pr
	pair=$(apex_member_get "$manager" "$member" pair)
	[[ -n $pair ]] || return 1
	state=$(apex_member_get "$manager" "$member" pair_state)
	[[ $state == active ]] || return 1

	role=$(apex_member_get "$manager" "$member" pair_role)
	turn=$(apex_member_get "$manager" "$member" pair_turn)
	[[ $turn == "$role" ]] || return 1     # not this half's move (e.g. the
	                                       # worker idling before the first
	                                       # review) — let the manager see it

	round=$(apex_member_get "$manager" "$member" pair_round); [[ -n $round ]] || round=1
	max=$(apex_member_get "$manager" "$member" pair_max_rounds); [[ -n $max ]] || max=$APEX_PAIR_MAX_ROUNDS
	pr=$(apex_member_get "$manager" "$member" pair_pr)

	if ! _member_alive "$pair"; then
		_pair_escalate "$manager" "$member" stuck \
			"PAIRED REVIEW STUCK: the ${role} on PR #${pr} finished round ${round}, but its partner session ($pair) is gone. The loop cannot continue on its own."
		return 0
	fi

	if [[ $role == reviewer ]]; then
		local vround findings note
		vround=$(apex_member_get "$manager" "$member" verdict_round)
		findings=$(apex_member_get "$manager" "$member" verdict_findings)
		note=$(apex_member_get "$manager" "$member" verdict_note)

		if [[ $vround != "$round" || -z $findings ]]; then
			_pair_escalate "$manager" "$member" stuck \
				"PAIRED REVIEW STUCK: the reviewer on PR #${pr} went idle after round ${round} without recording a verdict ('tmux-apex.sh verdict --findings N' / '--none'), so whether findings remain is unknown. Read the review yourself, or re-run the round: tmux-apex.sh pair-resume ${member}"
			return 0
		fi

		if (( findings == 0 )); then
			_pair_finish "$manager" "$member" "$round"
			return 0
		fi

		if (( round >= max )); then
			_pair_escalate "$manager" "$member" stuck \
				"PAIRED REVIEW STUCK: round ${round} of ${max} on PR #${pr} still has ${findings} open finding(s) — the loop cap is reached, so worker and reviewer are not converging. This needs a human call, not another round."
			return 0
		fi

		local next=$(( round + 1 ))
		# Write the partner's pair state *before* delivering, not after.
		# Delivery wakes the partner agent, whose own `event set` merges
		# {status,seq} into the same member file; apex_member_merge is a
		# lock-free read-modify-write, so a write scheduled after the relay
		# can lose the pair_turn flip to that agent's — and a lost flip is
		# silent, not escalated: the partner's next idle falls through to
		# the manager with a stale round counter.
		apex_member_merge "$manager" "$member" \
			"$(jq -nc --argjson r "$next" '{pair_round:$r, pair_turn:"worker"}')"
		apex_member_merge "$manager" "$pair" \
			"$(jq -nc --argjson r "$next" '{pair_round:$r, pair_turn:"worker"}')"
		if ! _pair_relay "$manager" "$pair" \
			"$(_pair_worker_msg "$pr" "$next" "$findings" "$note")"; then
			# Roll the pre-written state back: nobody performed round
			# $next, and leaving it bumped spends one of the cap's
			# attempts on a round that never happened — which now costs
			# more, since `pair-resume` refuses to resume at the cap
			# without a raised --max-rounds.
			_pair_rollback "$manager" "$member" "$pair" "$round" reviewer
			_pair_escalate "$manager" "$member" stuck \
				"PAIRED REVIEW STUCK: could not deliver the reviewer's ${findings} finding(s) on PR #${pr} to the worker ($pair) — ${_PAIR_RELAY_WHY}."
			return 0
		fi
	else
		apex_member_merge "$manager" "$member" '{"pair_turn":"reviewer"}'
		apex_member_merge "$manager" "$pair" '{"pair_turn":"reviewer"}'
		if ! _pair_relay "$manager" "$pair" \
			"$(_pair_reviewer_msg "$pr" "$round" rereview)"; then
			_pair_rollback "$manager" "$member" "$pair" "$round" worker
			_pair_escalate "$manager" "$member" stuck \
				"PAIRED REVIEW STUCK: the worker finished round ${round} on PR #${pr} but the reviewer ($pair) could not be reached — ${_PAIR_RELAY_WHY}."
			return 0
		fi
	fi

	# Consume the ping: the whole point of the loop is that the manager is
	# not woken at every idle transition.
	local seq
	seq=$(apex_member_get "$manager" "$member" seq); [[ -n $seq ]] || seq=0
	apex_member_merge "$manager" "$member" "$(jq -nc --argjson s "$seq" '{pinged_seq:$s}')"
	return 0
}

_cmd_link() {
	local worker="" reviewer="" pr="" max="$APEX_PAIR_MAX_ROUNDS"
	while (( $# )); do
		case "$1" in
			--worker)     _need_val link "$1" $#; worker="$2"; shift 2 ;;
			--reviewer)   _need_val link "$1" $#; reviewer="$2"; shift 2 ;;
			--pr)         _need_val link "$1" $#; pr="$2"; shift 2 ;;
			--max-rounds) _need_val link "$1" $#; max="$2"; shift 2 ;;
			*) _die "link: unknown argument '$1'" ;;
		esac
	done
	[[ -n $worker && -n $reviewer ]] || _die "link: usage: link --worker <session:%pane> --reviewer <session:%pane> [--pr N] [--max-rounds N]"
	[[ $worker == "$reviewer" ]] && _die "link: worker and reviewer must be different members"
	[[ $max == <-> ]] && (( max >= 1 )) || _die "link: --max-rounds must be a positive integer"

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local m
	for m in "$worker" "$reviewer"; do
		[[ -f $(apex_member_file "$manager" "$m") ]] || _die "link: '$m' is not a member of $manager (see 'status')"
		_member_alive "$m" || _die "link: '$m' is not running"
	done

	if [[ -z $pr ]]; then
		pr=$(_member_facts "$worker" | jq -r '.pr_number // ""')
		[[ -z $pr ]] && pr=$(apex_member_get "$manager" "$reviewer" review_pr)
	fi
	[[ -n $pr ]] || _die "link: could not determine the PR number — pass --pr N"

	apex_member_merge "$manager" "$worker" "$(jq -nc \
		--arg pair "$reviewer" --arg pr "$pr" --argjson max "$max" \
		'{pair:$pair, pair_role:"worker", pair_pr:$pr, pair_round:1,
		  pair_max_rounds:$max, pair_turn:"reviewer", pair_state:"active",
		  pair_message:""}')"
	apex_member_merge "$manager" "$reviewer" "$(jq -nc \
		--arg pair "$worker" --arg pr "$pr" --argjson max "$max" \
		'{pair:$pair, pair_role:"reviewer", pair_pr:$pr, pair_round:1,
		  pair_max_rounds:$max, pair_turn:"reviewer", pair_state:"active",
		  pair_message:"", verdict_round:"", verdict_findings:"", verdict_note:""}')"

	apex_event "$manager" "$(jq -nc --arg w "$worker" --arg r "$reviewer" \
		--arg pr "$pr" --argjson max "$max" \
		'{event:"pair-link", session:$w, reviewer:$r, review_pr:$pr, max_rounds:$max}')"

	# The reviewer is already running with its own review prompt and knows
	# nothing about the verdict protocol until told.
	if _pair_relay "$manager" "$reviewer" "$(_pair_reviewer_msg "$pr" 1 initial)"; then
		print "Linked pair on PR #${pr} (max ${max} rounds); reviewer briefed on the verdict protocol."
	else
		print -u2 "tmux-apex: WARNING — linked, but could not brief the reviewer ($reviewer)."
		print -u2 "  it will not know to record a verdict, and the loop will escalate as stuck."
	fi
	print "  worker   : $worker"
	print "  reviewer : $reviewer"
}

_cmd_unlink() {
	local member="$1"
	[[ -n $member ]] || _die "unlink: usage: unlink <session:%pane>"
	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local pair m
	pair=$(apex_member_get "$manager" "$member" pair)
	for m in "$member" "$pair"; do
		[[ -n $m ]] || continue
		[[ -f $(apex_member_file "$manager" "$m") ]] || continue
		apex_member_merge "$manager" "$m" \
			'{"pair":"","pair_role":"","pair_state":"","pair_turn":"","pair_message":""}'
	done
	apex_event "$manager" "$(jq -nc --arg s "$member" '{event:"pair-unlink", session:$s}')"
	print "Unlinked ${member}${pair:+ and $pair}."
}

# pair-resume — hand a stuck loop back to the agents after a human has
# unstuck whatever it was stuck on.
_cmd_pair_resume() {
	local member="" extend=""
	while (( $# )); do
		case "$1" in
			--max-rounds) _need_val pair-resume "$1" $#; extend="$2"; shift 2 ;;
			-*) _die "pair-resume: unknown argument '$1'" ;;
			*)  member="$1"; shift ;;
		esac
	done
	[[ -n $member ]] || _die "pair-resume: usage: pair-resume <session:%pane> [--max-rounds N]"
	[[ -z $extend || $extend == <-> ]] || _die "pair-resume: --max-rounds must be a positive integer"

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local pair pr role round max reviewer
	pair=$(apex_member_get "$manager" "$member" pair)
	[[ -n $pair ]] || _die "pair-resume: '$member' is not linked to a partner"
	pr=$(apex_member_get "$manager" "$member" pair_pr)
	role=$(apex_member_get "$manager" "$member" pair_role)
	[[ $role == reviewer ]] && reviewer="$member" || reviewer="$pair"
	round=$(apex_member_get "$manager" "$member" pair_round); [[ -n $round ]] || round=1
	max=$(apex_member_get "$manager" "$member" pair_max_rounds); [[ -n $max ]] || max=$APEX_PAIR_MAX_ROUNDS

	# Resuming a cap-stuck loop without raising the cap re-invokes the
	# reviewer at round == max, so the moment it reports any finding the cap
	# check fires again: a wasted review turn, duplicate PR comments, and the
	# same escalation. Refuse rather than pretend to have resumed.
	if [[ -n $extend ]]; then
		(( extend > max )) || _die "pair-resume: --max-rounds ${extend} is not above the current cap (${max})"
		max="$extend"
	elif (( round >= max )); then
		_die "pair-resume: round ${round} is already at the cap (${max}), so the loop would escalate again on the reviewer's first finding. Raise it: pair-resume ${member} --max-rounds $(( max + 2 ))"
	fi

	local m
	for m in "$member" "$pair"; do
		# Do not resurrect a reaped partner as a phantom member — `status`
		# and `pending` would then report a pane that no longer exists.
		[[ -f $(apex_member_file "$manager" "$m") ]] || continue
		apex_member_merge "$manager" "$m" "$(jq -nc --argjson max "$max" \
			'{pair_state:"active", pair_turn:"reviewer", pair_message:"",
			  pair_max_rounds:$max}')"
	done

	# Clear the reviewer's verdict. A resume re-invokes the reviewer for the
	# *same* round, and the freshness check only compares verdict_round to
	# pair_round — so a verdict recorded before the loop got stuck would be
	# accepted as this round's, relaying stale findings and skipping the
	# no-verdict escalation entirely. Resuming is a request for a fresh
	# verdict; the old one must not satisfy it.
	if [[ -f $(apex_member_file "$manager" "$reviewer") ]]; then
		apex_member_merge "$manager" "$reviewer" \
			'{"verdict_round":"","verdict_findings":"","verdict_note":""}'
	fi

	_pair_relay "$manager" "$reviewer" "$(_pair_reviewer_msg "$pr" "$round" rereview)" \
		|| _die "pair-resume: could not reach the reviewer ($reviewer)"
	apex_event "$manager" "$(jq -nc --arg s "$member" --argjson max "$max" \
		'{event:"pair-resume", session:$s, max_rounds:$max}')"
	print "Resumed the loop on PR #${pr}; reviewer re-invoked for round ${round} of ${max}."
}

# verdict — run by the *reviewer* in its own pane. This is the loop's only
# termination signal, and deliberately a structured one.
_cmd_verdict() {
	local findings="" note=""
	while (( $# )); do
		case "$1" in
			--findings) _need_val verdict "$1" $#; findings="$2"; shift 2 ;;
			--none)     findings=0; shift ;;
			--note)     _need_val verdict "$1" $#; note="$2"; shift 2 ;;
			*) _die "verdict: unknown argument '$1'" ;;
		esac
	done
	[[ -n $findings ]] || _die "verdict: usage: verdict --findings N | --none [--note TEXT]"
	[[ $findings == <-> ]] || _die "verdict: --findings must be a non-negative integer"

	local member manager
	member=$(_cur_member) || _die "verdict: not inside a tmux pane"
	manager=$(_sopt "$member" @apex_session)
	[[ -n $manager ]] || _die "verdict: this pane is not an apex member"
	APEX_SESSION="$manager"

	local role round
	role=$(apex_member_get "$manager" "$member" pair_role)
	[[ $role == reviewer ]] || _die "verdict: only the reviewer half of a linked pair records verdicts (this member's pair_role is '${role:-<unlinked>}')"
	round=$(apex_member_get "$manager" "$member" pair_round); [[ -n $round ]] || round=1

	apex_member_merge "$manager" "$member" "$(jq -nc \
		--arg r "$round" --arg f "$findings" --arg n "$note" \
		'{verdict_round:$r, verdict_findings:$f, verdict_note:$n}')"
	apex_event "$manager" "$(jq -nc --arg s "$member" --arg r "$round" \
		--argjson f "$findings" --arg n "$note" \
		'{event:"pair-verdict", session:$s, round:$r, findings:$f, note:$n}')"

	if (( findings == 0 )); then
		print "Verdict recorded for round ${round}: no findings worth addressing."
		print "When you stop, the PR is flipped to ready-for-review and the human is pinged."
	else
		print "Verdict recorded for round ${round}: ${findings} finding(s) worth addressing."
		print "When you stop, the worker is asked to address them; you will be re-invoked after it pushes."
	fi
}

# ─── event reporting (called from agent-tmux-status.sh hooks) ────────

# _record_status <manager> <session> <status>
#
# Durable log entry only — this never touches the manager's pane. Delivery
# into the manager's own context is pull-based: see `pending` below and
# scripts/apex-manager-notify.sh, wired to the manager's own
# UserPromptSubmit/SessionStart hooks. That split is the fix for the
# manager-pane collision bug (issue #5) — a keystroke injected here could
# splice into a human's in-flight input (or ghost autosuggestion text) with
# no way to tell the two apart from outside the pane, so nothing here ever
# writes to one.
_record_status() {
	local manager="$1" session="$2" st="$3"
	local role task facts summary
	role=$(_sopt "$session" @apex_role); [[ -z $role ]] && role=worker
	task=$(_sopt "$session" @apex_task)
	facts=$(_member_facts "$session")
	summary=$(_facts_line "$facts")

	apex_event "$manager" "$(jq -nc --arg s "$session" --arg st "$st" --arg sum "$summary" \
		'{event:"status", session:$s, status:$st, summary:$sum}')"
}

# event <set|notify|clear> — invoked in the member session's own context.
_cmd_event() {
	local verb="$1"
	local session manager
	session=$(_cur_member) || return 0
	manager=$(_sopt "$session" @apex_session)
	[[ -n $manager ]] || return 0            # not an apex member; nothing to do
	APEX_SESSION="$manager"

	local seq st
	seq=$(apex_member_bump_seq "$manager" "$session")

	case "$verb" in
		set)    st=working ;;
		notify) st=attention ;;
		clear)  st=idle ;;
		*)      return 0 ;;
	esac

	apex_member_merge "$manager" "$session" "$(jq -nc \
		--arg st "$st" --argjson seq "$seq" --argjson t "$(date +%s)" \
		'{status:$st, seq:$seq, updated_at:$t}')"

	case "$verb" in
		notify)
			# Blocked and waiting on input — record it now. The manager isn't
			# pushed this; it picks it up via `pending` on its next turn or on
			# resume (see scripts/apex-manager-notify.sh).
			_record_status "$manager" "$session" attention
			;;
		clear)
			# Stop fires at the end of EVERY assistant turn. Only record once the
			# session has actually settled: re-check the sequence number after a
			# quiet window. run-shell -d defers inside the tmux server, so this
			# outlives the short-lived hook process without a sleeping watcher.
			tmux run-shell -b -d "$APEX_QUIET_SECS" \
				"${SELF} _settle ${(q)session} ${(q)manager} ${seq}" 2>/dev/null
			;;
	esac
}

# _settle <session> <manager> <seq> — internal, fired by run-shell -d.
#
# settled_seq dedupes this specific durable write (avoids one events.jsonl
# entry per settle callback if several were scheduled back to back). It is
# deliberately a separate field from pinged_seq: pinged_seq now tracks what
# the manager has actually pulled via `pending`, not what this function has
# attempted to record.
_cmd_settle() {
	local session="$1" manager="$2" seq="$3"
	APEX_SESSION="$manager"
	[[ $(apex_member_get "$manager" "$session" seq) == "$seq" ]] || return 0
	[[ $(apex_member_get "$manager" "$session" settled_seq) == "$seq" ]] && return 0
	apex_member_merge "$manager" "$session" "$(jq -nc --argjson seq "$seq" '{settled_seq:$seq}')"
	_record_status "$manager" "$session" idle

	# A linked pair relays this idle transition to its partner and marks the
	# ping consumed, so the manager is not woken once per round-trip. The
	# status event above is still written either way — the durable log stays
	# complete whether or not the loop swallowed the ping.
	_pair_advance "$manager" "$session" || true
}

# ─── status ──────────────────────────────────────────────────────────

_cmd_status() {
	local as_json=false a
	for a in "$@"; do [[ $a == --json ]] && as_json=true; done

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local -a rows=()
	local s facts stored merged
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		facts=$(_member_facts "$s" --with-pane-input)
		stored=$(cat "$(apex_member_file "$manager" "$s")" 2>/dev/null)
		[[ -z $stored ]] && stored='{}'
		merged=$(printf '%s\n%s\n' "$stored" "$facts" | jq -s '.[0] * .[1]')
		rows+=("$merged")
	done

	if $as_json; then
		local events
		events=$(tail -n 40 "$(apex_events_file "$manager")" 2>/dev/null | jq -sc '.' 2>/dev/null)
		[[ -z $events ]] && events='[]'
		printf '%s\n' "${rows[@]}" \
			| jq -s --arg m "$manager" --argjson ev "$events" \
				'{manager:$m, members:., recent_events:$ev}'
		return
	fi

	print "Apex manager: $manager"
	print "State: $(apex_dir "$manager")"
	if (( ${#rows} == 0 )); then
		print "\nNo members yet. Spawn one with: ${SELF##*/} spawn --issue N"
		return
	fi
	print ""
	printf '%-34s %-8s %-10s %-12s %s\n' SESSION ROLE AGENT TASK STATE
	local r
	for r in "${rows[@]}"; do
		printf '%s' "$r" | jq -r '
			[ .session,
			  (.role // "?"),
			  (if .alive then (.agent // "?") else "dead" end),
			  ((if .issue != "" and .issue != null then "issue#" + .issue
			    elif .review_pr != "" and .review_pr != null then "pr#" + .review_pr
			    else "-" end)),
			  ([ (if .branch != "" then .branch else empty end),
			     (if .pr_number != "" then "PR#" + .pr_number
			        + (if .pr_draft == "true" then " draft" else "" end)
			        + (if .pr_state != "" and .pr_state != "OPEN" then " " + (.pr_state|ascii_downcase) else "" end)
			      else empty end),
			     (if .commits_ahead > 0 then (.commits_ahead|tostring) + " ahead" else empty end),
			     (if .dirty then "dirty" else empty end) ] | join(", "))
			] | @tsv' \
		| while IFS=$'\t' read -r c1 c2 c3 c4 c5; do
			printf '%-34s %-8s %-10s %-12s %s\n' "$c1" "$c2" "$c3" "$c4" "$c5"
		done
	done
	# An agent pane can show text sitting unsent in its input box. That text is
	# very often Claude Code's own autosuggestion — it predicts a plausible next
	# input and paints it into the idle box — and from outside the pane it is
	# indistinguishable from something having been typed or injected there
	# (issue #10). Name that ambiguity here so nobody spends an hour chasing a
	# delivery bug that isn't one, and nobody submits a guess by accident.
	local unsent=()
	for r in "${rows[@]}"; do
		local u
		u=$(printf '%s' "$r" | jq -r '"\(.session)\t\(.pane_input // "")"')
		[[ ${u#*$'\t'} == "" ]] || unsent+=("$u")
	done
	if (( ${#unsent} )); then
		print "\nUnsent text in member input boxes:"
		for r in "${unsent[@]}"; do
			printf '  %-32s %s\n' "${r%%$'\t'*}" "${r#*$'\t'}"
		done
		print "  This is usually the agent's OWN autosuggestion (Claude Code predicts a"
		print "  next input into the empty box), not an instruction that failed to send"
		print "  and not stray injected text. 'send' clears it before delivering, so you"
		print "  do not need to; do not submit it by hand unless you actually want it."
	fi

	print "\nRecent events:"
	tail -n 8 "$(apex_events_file "$manager")" 2>/dev/null \
		| jq -r '"  " + (.at|todate) + "  " + .event + "  " + (.session // "")' 2>/dev/null
}

# ─── pending ─────────────────────────────────────────────────────────

# pending [--mark-delivered] — one summary line per member whose current
# idle/attention status hasn't been delivered to the manager yet.
#
# This is the entire delivery mechanism for manager pings (see `_record_status`
# above): scripts/apex-manager-notify.sh calls this from the manager's own
# UserPromptSubmit/SessionStart hooks and hands the output to Claude as
# context, so a human can run it by hand for the same view the manager gets.
# Read-only unless --mark-delivered is passed, in which case each reported
# member's pinged_seq is advanced to its current seq so it isn't reported
# again next time.
#
# Only idle/attention are ever reported — a member mid-turn ("working" or
# "starting") has nothing actionable to say yet, and reporting on every seq
# bump would spam every intermediate transition instead of just the state
# that matters when the manager actually looks.
_cmd_pending() {
	local mark=false a
	for a in "$@"; do [[ $a == --mark-delivered ]] && mark=true; done

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local s st seq pinged role task facts summary pair_msg
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		st=$(apex_member_get "$manager" "$s" status)
		pair_msg=$(apex_member_get "$manager" "$s" pair_message)

		# A terminal pair escalation is reported on its own merit, not via
		# the `status` field it forces: the partner's relay can wake this
		# member back into `working` before the manager next pulls, which
		# would otherwise defer "READY FOR HUMAN REVIEW" by a whole agent
		# turn — likeliest in exactly the cases that need it soonest.
		if [[ -z $pair_msg ]]; then
			[[ $st == idle || $st == attention ]] || continue
		fi

		seq=$(apex_member_get "$manager" "$s" seq); [[ -z $seq ]] && seq=0
		pinged=$(apex_member_get "$manager" "$s" pinged_seq); [[ -z $pinged ]] && pinged=-1
		(( seq == pinged )) && continue

		role=$(_sopt "$s" @apex_role); [[ -z $role ]] && role=worker
		task=$(_sopt "$s" @apex_task)
		facts=$(_member_facts "$s")
		summary=$(_facts_line "$facts")

		if [[ -n $pair_msg ]]; then
			print "[apex] session=${s} role=${role} ${task:+task=${task} }— ${pair_msg} (${summary})"
		else
			print "[apex] session=${s} role=${role} ${task:+task=${task} }status=${st} — ${summary}. Full state: ${SELF} status --json"
		fi

		# pair_message is a one-shot escalation, not a status field: clearing
		# it on delivery keeps a later idle transition of the same member
		# from re-reporting a resolved round as if it were fresh.
		if $mark; then
			apex_member_merge "$manager" "$s" "$(jq -nc --argjson seq "$seq" '{pinged_seq:$seq}')"
			[[ -n $pair_msg ]] && apex_member_merge "$manager" "$s" '{"pair_message":""}'
		fi
	done
}

# ─── reap ────────────────────────────────────────────────────────────

_cmd_reap() {
	local yes=false a
	for a in "$@"; do [[ $a == --yes ]] && yes=true; done

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local -a done_members=()
	local s facts alive pr_state
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		facts=$(_member_facts "$s")
		alive=$(printf '%s' "$facts" | jq -r '.alive')
		pr_state=$(printf '%s' "$facts" | jq -r '.pr_state')
		if [[ $alive == false || $pr_state == MERGED || $pr_state == CLOSED ]]; then
			done_members+=("$s")
			print "  $s  — $(_facts_line "$facts")"
		fi
	done

	if (( ${#done_members} == 0 )); then
		print "Nothing to reap."
		return
	fi

	if ! $yes; then
		print "\n${#done_members} member(s) finished. Re-run with --yes to remove their worktrees and sessions."
		return
	fi

	local wt session
	for s in "${done_members[@]}"; do
		wt=$(apex_member_get "$manager" "$s" worktree)
		session=$(_member_session "$s")

		tmux kill-pane -t "$(_member_pane "$s")" 2>/dev/null
		rm -f "$(apex_member_file "$manager" "$s")"
		apex_event "$manager" "$(jq -nc --arg s "$s" '{event:"reap", session:$s}')"
		print "Reaped $s"

		# Only clean up the shared worktree/session once no other apex member
		# (e.g. a worker, if we just reaped a reviewer) still owns a pane there.
		_session_has_apex_member "$session" && continue
		if [[ -n $wt && -d $wt ]]; then
			TMUX_DELTA_ASSUME_YES=1 "${SCRIPTS}/tmux-picker.sh" --delete-wt "wt:${wt}" >/dev/null 2>&1
		else
			tmux kill-session -t "$session" 2>/dev/null
		fi
	done
}

_cmd_profiles() {
	local rows rc
	rows=$(apex_profiles_list); rc=$?
	case $rc in
		0) ;;
		1) _die "profiles: missing $(apex_profiles_repo_file)" ;;
		2) _die "profiles: malformed JSON in $(apex_profiles_repo_file)" ;;
		3) _die "profiles: malformed JSON in $(apex_profiles_user_file)" ;;
	esac
	[[ -z $rows ]] && { print "No profiles defined."; return; }
	print -r -- "$rows" | awk -F'\t' '{printf "  %-10s agent=%-9s model=%-16s flags=%-20s %s\n", $1, $2, $3, $4, $5}'
}

# ─── doctor (ping-delivery self-check) ───────────────────────────────

# The manager's pings are delivered by Claude Code hooks calling
# scripts/apex-manager-notify.sh (see `pending`). Nothing inside tmux can
# install those hooks, and a manager with none installed looks completely
# healthy — `pending` keeps returning the right answer to anyone who asks by
# hand, so the manager only ever finds out that nothing is being delivered
# when the human tells it a worker has been done for a while. That was the
# reported failure in github issue #7: no wiring at all in settings.json.
#
# So `init` checks, and says so. `doctor` runs the same check on demand.
#
# Which events matter, and why each one:
#   UserPromptSubmit  before every human message
#   SessionStart      on startup/resume, to catch up after a restart
#   PostToolBatch     mid-turn, so a long autonomous stretch still sees pings
#   Stop              end-of-turn, so a ping arriving as the manager wraps up
#                     gets one more turn instead of waiting for the human
# The first two are enough for a manager driven turn-by-turn by a human; the
# last two are what make an unattended manager notice anything.
_apex_hook_events() { print -r -- "UserPromptSubmit SessionStart PostToolBatch Stop"; }

# Event → the argument apex-manager-notify.sh must be invoked with there.
typeset -gA APEX_HOOK_VERB=(
	UserPromptSubmit prompt
	SessionStart     session-start
	PostToolBatch    post-tools
	Stop             stop
)

# _apex_hook_wired <event> — is apex-manager-notify.sh wired to <event>, *with
# the right argument*, in any settings file Claude Code reads?
#
# The argument is part of what makes the wiring correct, not a detail: the
# script picks its output channel from it, and the channels aren't
# interchangeable (plain stdout only reaches the agent on UserPromptSubmit and
# SessionStart). A command wired without its verb, or with another event's
# verb, therefore delivers nothing on two of the four events — so this check
# would be worse than useless if it certified that as healthy.
#
# Deliberately loose about the path (spelling varies: ~, $HOME, the ~/.tmux
# symlink, a worktree checkout) and about what follows on the command line
# (redirections, a wrapper's trailing arguments), but strict about the verb
# appearing as its own whitespace-delimited word.
_apex_hook_wired() {
	local event="$1" f
	local verb="${APEX_HOOK_VERB[$event]}"
	[[ -n $verb ]] || return 1
	for f in \
		"$HOME/.claude/settings.json" \
		"$HOME/.claude/settings.local.json" \
		"${APEX_REPO:-$PWD}/.claude/settings.json" \
		"${APEX_REPO:-$PWD}/.claude/settings.local.json"
	do
		[[ -f $f ]] || continue
		jq -e --arg e "$event" --arg verb "$verb" '
			(.hooks[$e] // [])
			| map(.hooks // [])
			| flatten
			| map(.command // "")
			| any(test("apex-manager-notify[^[:space:]]*[[:space:]]+" + $verb + "([[:space:]]|$)"))
		' "$f" >/dev/null 2>&1 && return 0
	done
	return 1
}

# _apex_notify_path — the path to suggest in the fix hint.
#
# Not necessarily this script's own path: `doctor` often runs from a worktree
# (that is how work on this repo happens), and hooks live in global config, so
# a worktree path pasted into ~/.claude/settings.json outlives the worktree and
# breaks silently once it is removed. Prefer a stable install location that
# actually exists, and print it unexpanded so it stays stable.
_apex_notify_path() {
	local rel="scripts/apex-manager-notify.sh" p
	for p in \
		"$HOME/.tmux/plugins/tmux-delta" \
		"${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tmux-delta"
	do
		if [[ -e $p/$rel ]]; then
			print -r -- "${p/#$HOME/~}/$rel"
			return
		fi
	done
	print -r -- "${SCRIPTS}/apex-manager-notify.sh"
}

# _cmd_doctor [--quiet] — report which delivery hooks are missing.
# Exits 0 when all four are wired, 1 otherwise. --quiet prints nothing when
# everything is wired, which is how `init` uses it.
_cmd_doctor() {
	local quiet=false a
	for a in "$@"; do [[ $a == --quiet ]] && quiet=true; done

	local -a missing=() present=()
	local e
	for e in ${=$(_apex_hook_events)}; do
		if _apex_hook_wired "$e"; then present+=("$e"); else missing+=("$e"); fi
	done

	if (( ${#missing} == 0 )); then
		$quiet || print "Ping delivery: all hooks wired (${(j:, :)present})."
		return 0
	fi

	local notify="$(_apex_notify_path)"
	print -u2 "tmux-apex: WARNING — apex pings will not reach this agent's context."
	print -u2 "  missing Claude Code hooks: ${(j:, :)missing}"
	(( ${#present} )) && print -u2 "  wired already            : ${(j:, :)present}"
	print -u2 "  (an entry wired without its argument counts as missing — the argument"
	print -u2 "   is what selects the output channel, and the channels differ by event)"
	print -u2 "  fix: add to ~/.claude/settings.json (see README, \"Apex mode\"):"
	print -u2 ""
	for e in "${missing[@]}"; do
		print -u2 "    \"$e\": [{ \"matcher\": \"\", \"hooks\": [{ \"type\": \"command\", \"command\": \"$notify ${APEX_HOOK_VERB[$e]}\" }] }]"
	done
	print -u2 ""
	print -u2 "  until then, run '${SELF} pending' by hand — it reports the same events."
	return 1
}

# ─── dispatch ────────────────────────────────────────────────────────

case "${1:-}" in
	init)     shift; _cmd_init "$@" ;;
	doctor)   shift; _cmd_doctor "$@" ;;
	stop)     shift; _cmd_stop "$@" ;;
	relink)   shift; _cmd_relink "$@" ;;
	spawn)    shift; _cmd_spawn "$@" ;;
	send)     shift; _cmd_send "$@" ;;
	link)     shift; _cmd_link "$@" ;;
	unlink)   shift; _cmd_unlink "$@" ;;
	pair-resume) shift; _cmd_pair_resume "$@" ;;
	verdict)  shift; _cmd_verdict "$@" ;;
	event)    shift; _cmd_event "$@" ;;
	status)   shift; _cmd_status "$@" ;;
	pending)  shift; _cmd_pending "$@" ;;
	reap)     shift; _cmd_reap "$@" ;;
	profiles) shift; _cmd_profiles "$@" ;;
	_settle)  shift; _cmd_settle "$@" ;;
	_register-member) shift; _cmd_register_member "$@" ;;
	*)
		print "tmux-apex.sh — apex mode for tmux-delta"
		print ""
		print "  init [--force]                 mark this session as the apex manager"
		print "  stop                           leave manager mode (members keep running)"
		print "  relink                         re-derive role/linkage after a session restart"
		print "  spawn --issue N [opts]         spawn a worker on a GitHub issue"
		print "  spawn --review-pr N [opts]     spawn a reviewer on a pull request"
		print "      opts: --profile NAME       named {agent,model,agent-flags} preset (see 'profiles')"
		print "            --role worker|monitor --agent claude|pi|codex|opencode"
		print "            --model M"
		print "            --agent-flags ARGV --mode autonomous|interactive --switch"
		print "  send <session> <text>          message a session's coding agent"
		print "  link --worker M --reviewer M   run an automatic fix/re-review loop between two"
		print "                                 members on one PR; the manager is only pinged"
		print "                                 once it terminates"
		print "      opts: --pr N --max-rounds N (default ${APEX_PAIR_MAX_ROUNDS})"
		print "  unlink <member>                drop the pairing (both halves)"
		print "  pair-resume <member>           restart a loop that escalated as stuck"
		print "      opts: --max-rounds N       required if it stuck at the round cap"
		print "  verdict --findings N | --none  reviewer-only: record the round's outcome"
		print "                                 (the loop's termination signal) [--note TEXT]"
		print "  status [--json]                state of every member"
		print "  pending [--mark-delivered]     members not yet delivered to the manager"
		print "  reap [--yes]                   clean up finished/dead members"
		print "  profiles                       list available spawn profiles"
		print "  doctor                         check that ping-delivery hooks are wired"
		[[ -n ${1:-} ]] && exit 1
		;;
esac
