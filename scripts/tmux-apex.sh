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
# That pull is manager-driven, so on its own it leaves the manager blind
# between its own turns (issue #14). `watch` closes that gap: a background
# poller, not an agent turn, that watches durable state at ~1s and nudges the
# manager's pane only when `pending` has something — see `watch`.
#
# Subcommands: init stop relink recover spawn send event status pending reap
#              profiles watch doctor

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

# Session pills draw one icon per agent pane; membership changes change that
# set, so nudge the cache after registering or releasing a member.
_refresh_agent_icons() {
	[[ -n ${1:-} ]] || return 0
	"${0:A:h}/agent-icons-refresh.sh" "$1" >/dev/null 2>&1 || true
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
		# Session-scoped on purpose. Pane ids are recycled across a tmux server
		# restart, so matching a bare pane id finds "%7" alive in some unrelated
		# session and reports a dead member as healthy — which made `recover`
		# skip exactly the members it exists to recover (issue #18).
		tmux list-panes -a -F '#{session_name}:#{pane_id}' 2>/dev/null | grep -qxF "$1"
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
	local pane="$1" cap
	[[ -n $pane ]] || return 1
	cap=$(tmux capture-pane -p -t "$pane" 2>/dev/null) || return 1
	_box_line_of "$cap"
}

# _box_line_of <capture> — _pane_input_line's parsing half, against a capture
# the caller already has. Split out so the send verify loop can answer both of
# its questions ("is our text still in the box", "has the pane changed at
# all") from one capture: it used to fork tmux twice per tick, which is 50
# forks per attempt at the default ceiling and — less obviously — sampled the
# two facts milliseconds apart, giving them one more way to disagree about the
# same moment.
_box_line_of() {
	setopt localoptions extendedglob
	# Scoped to this function; zsh calls setlocale() on assignment, and the
	# restore on return puts back whatever the caller had.
	local -x LC_ALL
	LC_ALL=$(_apex_utf8_locale)
	[[ -z $LC_ALL ]] && unset LC_ALL
	local cap="$1" line text
	local boxed="" boxed_seen="" bare=""
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

# _box_pending <box-line> <sent-text> [residue] — is <box-line> our own line
# still sitting unsent, rather than something else the pane has since drawn?
#
# True when the box shows the whole line or the leading part of it. Prefix,
# not suffix: a line wider than the box soft-wraps and _pane_input_line only
# ever returns the caret line, so the tail of a long message is not visible
# there at all and matching on it would pass unconditionally, checking
# nothing. Anything else in the box is somebody else's text — a repainted
# suggestion, a human's draft — which means ours is gone.
#
# <residue> is text the caller already knows was in the box and would not
# clear, so our message got typed onto the end of it and the box reads
# `<residue><message>`. Strip it and the prefix test works on the remainder
# as if the box had been clean. Without that, a spliced send fails the prefix
# test on its very first read, the retry loop concludes "our text is gone, so
# it was submitted", and rc 2 — typed but never submitted — is unreachable on
# every spliced path (issue #22). Note this is a *known* residue, recorded
# before we typed: a substring match would find our text under an unknown
# prefix too, but it also matches an autosuggestion that quotes us back and
# gives up the soft-wrap protection the prefix direction exists for.
_box_pending() {
	local sent="$2" residue="${3:-}" left
	left=${1#"$residue"}
	if [[ -n $residue ]]; then
		# _pane_input_line trims, so a residue that ended in spaces was
		# recorded without them while the box still renders them between it
		# and our text. Drop that gap rather than let it fail the prefix test.
		while [[ $left == ' '* ]]; do left=${left# }; done
		# A retype into a box that will not clear appends rather than replaces,
		# so after N attempts the box holds `<residue><text><text>…`. Collapse
		# the repeats, or the second attempt onward reads as "not our text" and
		# the stall is lost again. Only on this path: on a clean box, text
		# beyond ours still means ours is gone.
		# Guarded on a non-empty $sent: stripping "" never shortens $left, so
		# an empty sent-text would spin here forever.
		if [[ -n $sent ]]; then
			while [[ $left == "$sent"?* ]]; do left=${left#"$sent"}; done
		fi
	fi
	[[ -n $left ]] || return 1
	[[ $sent == "$left"* ]]
}

# _pane_activity_sig <pane> — fingerprint of the *whole* visible pane.
#
# _pane_input_line answers "is our text still in the box", which cannot tell
# "never submitted" apart from "submitted, but the TUI has not repainted the
# box empty yet" (issue #24). This answers a different question — "is the pane
# doing anything at all" — and the two together can: an agent that accepted
# our message is rendering something (spinner, token counter, tool output), so
# its pane changes between samples. A pane whose every cell is identical for a
# full second, with our text still sitting in the box, is genuinely stalled.
#
# The fingerprint is the capture itself. Panes are one screen, so string
# comparison is exact and cheaper than shelling out to a hash.
_pane_activity_sig() {
	local pane="$1" cap
	[[ -n $pane ]] || return 1
	cap=$(tmux capture-pane -p -t "$pane" 2>/dev/null) || return 1
	print -r -- "$cap"
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
#      text is still sitting there *and the pane has gone completely quiet* —
#      see the retry loop below for why the second half matters (issue #24).
#
# Sets APEX_SEND_CLEARED to the pre-existing input it discarded ("" if none),
# and APEX_SEND_UNCONFIRMED=1 when it returned 0 without ever seeing the box
# drain (a busy pane held our text past the ceiling; retrying would risk a
# duplicate turn, so it did not).
# Returns 0 delivered, 1 refused/tmux failure, 2 typed but never submitted.
_send_to_pane() {
	local pane="$1" text="$2"
	text=${text//$'\n'/ }
	text=${text//$'\r'/ }
	[[ -z $text ]] && return 1

	# APEX_SEND_CLEARED is the pre-send box read, taken before we know whether
	# clearing will take. APEX_SEND_SPLICED says it did not: the text below is
	# still in the box and our message got appended to it. Callers that log
	# APEX_SEND_CLEARED must log this too — "we discarded a draft" and "we
	# garbled our own instruction onto one" are opposite outcomes, and on the
	# relay path the stderr line that distinguishes them is unread by design.
	APEX_SEND_CLEARED=$(_pane_input_line "$pane" 2>/dev/null)
	APEX_SEND_SPLICED=""
	APEX_SEND_UNCONFIRMED=""
	if [[ -n $APEX_SEND_CLEARED ]] && [[ ${APEX_SEND_CLEAR:-1} == 1 ]]; then
		print -u2 "tmux-apex: pane $pane had unsent input; clearing it before delivery:"
		print -u2 "  ${APEX_SEND_CLEARED}"
		print -u2 "  (often the agent's own autosuggestion ghost text rather than typed"
		print -u2 "   input — see issue #10; recorded in the apex event log either way)"
		local unclearable
		unclearable=$(_clear_pane_input "$pane")
		if [[ -n $unclearable ]]; then
			APEX_SEND_SPLICED="$unclearable"
			print -u2 "tmux-apex: pane $pane input box did not clear; delivery will be"
			print -u2 "  appended to: ${unclearable}"
		fi
	elif [[ -n $APEX_SEND_CLEARED ]]; then
		# APEX_SEND_CLEAR=0: report, but leave the box alone and let the
		# splice happen rather than destroying input the operator may want.
		APEX_SEND_SPLICED="$APEX_SEND_CLEARED"
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
	#
	# Retrying on a timeout alone is what delivered messages twice for real
	# (issue #24): under a loaded turn the box can still show our text
	# seconds after the submit landed, and no fixed poll window is long
	# enough to rule that out. So the retry is gated on pane *activity*, not
	# on elapsed time. Our text still in the box plus a pane that has not
	# changed a single cell for a second is a stall; the same box with a pane
	# that keeps repainting is an agent working on what we just sent, and
	# retyping into that is the duplicate. Wait such a pane out to the
	# ceiling and, if the box never drains, report delivery as unconfirmed
	# (APEX_SEND_UNCONFIRMED) rather than sending it again.
	# Residue tracks what the box still holds *under* our text, so the pending
	# check below can see past it. It starts as whatever clearing failed to
	# drain and is re-read on every retype, because a retry's own clear may
	# well succeed where the first attempt's did not.
	local left i j sig sig0 residue="$APEX_SEND_SPLICED"
	local -i static
	# Clamped, not trusted. `local -i x=abc` is 0 with no error in zsh, and a
	# settle of 0 skips the poll loop entirely: nothing is ever read back, so
	# every send reports delivered-but-unconfirmed forever and no retry can
	# fire. A knob that silently turns off the verification it exists to tune
	# is the failure this repo already guards against at the door for `watch`
	# (see _apex_watch_check_knobs). Warn rather than _die: this is a library
	# function on the delivery path, and refusing to send is worse than
	# sending with the documented defaults.
	local -i settle idle
	settle=${APEX_SEND_SETTLE_TICKS:-25}
	idle=${APEX_SEND_IDLE_TICKS:-5}
	if (( settle < 1 )); then
		print -u2 "tmux-apex: APEX_SEND_SETTLE_TICKS='${APEX_SEND_SETTLE_TICKS}' is not a positive integer; using 25"
		settle=25
	fi
	if (( idle < 1 )); then
		print -u2 "tmux-apex: APEX_SEND_IDLE_TICKS='${APEX_SEND_IDLE_TICKS}' is not a positive integer; using 5"
		idle=5
	fi
	# An idle threshold above the ceiling can never be reached, which is the
	# settle=0 failure by another route: no retry could ever fire.
	(( idle > settle )) && idle=$settle
	for i in 1 2 3; do
		# Re-snapshot per attempt, after that attempt's Enter: the retype's
		# own repaint is our doing, not the agent's activity.
		sig0=$(_pane_activity_sig "$pane")
		static=0
		for (( j = 1; j <= settle; j++ )); do
			sleep 0.2
			# One capture answers both questions, and answers them about the
			# same instant — see _box_line_of.
			sig=$(_pane_activity_sig "$pane" 2>/dev/null)
			left=$(_box_line_of "$sig")
			_box_pending "$left" "$text" "$residue" || return 0
			if [[ $sig == "$sig0" ]]; then
				(( static += 1 ))
				(( static >= idle )) && break
			else
				sig0="$sig"; static=0
			fi
		done
		if (( static < idle )); then
			# Never went quiet: the pane is alive and holding our text, which
			# is redraw lag far more often than a swallowed Enter. Say so and
			# stop, instead of guessing and risking a second real turn.
			APEX_SEND_UNCONFIRMED=1
			print -u2 "tmux-apex: pane $pane still shows the sent text after" \
				"$(printf '%.1f' $(( settle * 0.2 )))s, but has been repainting throughout —"
			print -u2 "  treating it as delivered rather than retyping (issue #24);" \
				"a duplicate turn is worse than an unconfirmed one."
			return 0
		fi
		# The only thing this attempt's clear can tell us about the residue is
		# whether it is gone. It cannot re-derive it: the box read it returns is
		# `<residue><text>` from the attempt before, truncated to the caret line,
		# so for any message wider than the box it ends mid-message. Taking that
		# as the residue would strip our own text out of every later box read —
		# which reads as "our text is gone, so it was submitted" and puts issue
		# #22 straight back for exactly the long relay messages that provoked
		# it. So keep the residue recorded before we ever typed, and let
		# _box_pending's collapse loop see past the copies stacked on it.
		if [[ -z $(_clear_pane_input "$pane") ]]; then
			residue=""
		fi
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
	sleep 1
	left=$(_pane_input_line "$pane" 2>/dev/null)
	_box_pending "$left" "$text" "$residue" && return 2
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

	# Hooks only fire on the manager's own turns; the watcher is what notices a
	# worker transition in between them. Started before the check below so that
	# doctor's report of it is accurate. See `watch`.
	_apex_watch_start "$session"

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
	_apex_watch_stop "$session" >/dev/null 2>&1 || true
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
# no durable state at all — except for one thing it always does: a manager
# that already has its role still gets its watcher restarted, since relink is
# the one code path that reliably runs in a resumed manager (and on every one
# of its turns), and a watcher can die for reasons a session restart is not —
# a crash, an OOM kill, a stray `kill`. `_apex_watch_start` is a pidfile read
# and a `kill -0` when one is already running, so paying it per hook is fine.
_cmd_relink() {
	local session pane
	session=$(_cur_session) || return 0
	pane="$TMUX_PANE"

	if [[ $(_sopt "$session" @apex_role) == manager ]]; then
		# Already linked — but the watcher may not be (see the header above).
		_apex_watch_start "$session"
		return 0
	fi
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
			_apex_watch_start "$session"
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
		# Compare resolved paths: the recorded worktree and $PWD can be the same
		# directory spelled differently (symlinked /tmp, doubled slashes).
		[[ -n $wt && ${wt:A} != ${PWD:A} ]] && continue
		matches+=("$f")
	done
	(( ${#matches} == 1 )) || return 0

	f="${matches[1]}"
	local manager role issue review_pr task old_key new_key
	manager="${f:h:h:t}"
	role=$(jq -r '.role // "worker"' "$f" 2>/dev/null)
	issue=$(jq -r '.issue // empty' "$f" 2>/dev/null)
	review_pr=$(jq -r '.review_pr // empty' "$f" 2>/dev/null)
	# One task per member. Concatenating both when a corrupted record carries
	# both is how "issue:12pr:34" got onto a live pane's @apex_task (issue #18);
	# the record is already wrong at that point, so pick one and stay legible.
	if [[ -n $review_pr ]]; then
		task="pr:$review_pr"
	elif [[ -n $issue ]]; then
		task="issue:$issue"
	else
		task=""
	fi

	tmux set-option -p -t "$pane" @apex_session "$manager"
	tmux set-option -p -t "$pane" @apex_role "$role"
	[[ -n $task ]] && tmux set-option -p -t "$pane" @apex_task "$task"

	old_key="${f:t:r}"
	new_key="${session}:${pane}"
	if [[ $old_key != $new_key ]]; then
		mv -f "$f" "$(apex_member_file "$manager" "$new_key")" 2>/dev/null
		apex_member_lock_forget "$manager" "$old_key"
	fi

	_refresh_agent_icons "$session"
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
# _register-member <pane_id> <manager> <role> <task> <worktree> [model] [perm] [mode] [agent] [profile] [issue] [pr] [agent_session_id]
_cmd_register_member() {
	local pane_id="$1" manager="$2" role="$3" task="$4" worktree="$5"
	local model="$6" perm="$7" mode="$8" agent="${9:-claude}" profile="${10}"
	local issue="${11}" pr="${12}" agent_session="${13}"
	[[ -z $pane_id || -z $manager ]] && _die "_register-member: need <pane_id> <manager>"

	local session member
	session=$(tmux display-message -p -t "$pane_id" '#S' 2>/dev/null)
	[[ -z $session ]] && _die "_register-member: pane '$pane_id' not found"
	member="${session}:${pane_id}"

	tmux set-option -p -t "$pane_id" @apex_role "${role:-worker}"
	tmux set-option -p -t "$pane_id" @apex_session "$manager"
	[[ -n $task ]] && tmux set-option -p -t "$pane_id" @apex_task "$task"

	# Pane ids are recycled: a restarted tmux server hands out %0, %1, … again,
	# so a durable member file for "<session>:<pane>" can be a *different*
	# member's record from before the restart. Merging a new registration onto it
	# is what produced the corrupted member reported in issue #18 — role reading
	# `monitor` while `issue` still named the old worker's task, and a task
	# string of "issue:Npr:M". Registration is the birth of a member, so when the
	# record already on that key describes another task, replace it rather than
	# merge into it.
	local stale
	stale=$(apex_member_file "$manager" "$member")
	if [[ -f $stale ]]; then
		local old_issue old_pr
		old_issue=$(jq -r '.issue // ""' "$stale" 2>/dev/null)
		old_pr=$(jq -r '.review_pr // ""' "$stale" 2>/dev/null)
		if [[ $old_issue != "$issue" || $old_pr != "$pr" ]]; then
			print -u2 "tmux-apex: _register-member: replacing a stale record on $member"
			print -u2 "  (was issue='${old_issue}' pr='${old_pr}', now issue='${issue}' pr='${pr}')"
			print -u2 "  — recycled pane id after a tmux restart; see issue #18"
			# Both real callers redirect this to /dev/null (tmux-picker.sh's
			# _add_agent_pane, tmux-dev-layout.sh), so stderr alone means the
			# diagnostic is only ever visible from the test harness. Record it
			# where `status` and the event log can still show it.
			apex_event "$manager" "$(jq -nc --arg s "$member" \
				--arg oi "$old_issue" --arg op "$old_pr" \
				--arg ni "$issue" --arg np "$pr" \
				'{event:"stale-record-replaced", session:$s,
				  was:{issue:$oi, review_pr:$op}, now:{issue:$ni, review_pr:$np}}')"
			rm -f "$stale"
		fi
	fi

	# `agent` is recorded durably (not just as the transient CODING_AGENT env var
	# used to pick an adapter at layout time) so `send` can later tell which
	# agents have a native session-message API — see _send_native.
	#
	# agent_session_id is written unconditionally, empty included. Registration
	# is the birth of a member, so there is nothing legitimate to inherit: a
	# record already sitting on this key belongs to a pane id the tmux server
	# recycled, and merging its conversation id through would point a brand-new
	# agent at a dead agent's conversation — the same class of bug as the stale
	# record above. Writing empty is also how `recover` clears an id it could
	# not resume; _record_agent_session then re-resolves it on the next turn.
	apex_member_merge "$manager" "$member" "$(jq -nc \
		--arg role "${role:-worker}" --arg wt "$worktree" --arg model "$model" \
		--arg perm "$perm" --arg mode "$mode" --arg agent "$agent" \
		--arg profile "$profile" --arg issue "$issue" --arg pr "$pr" \
		--arg sid "$agent_session" \
		--argjson t "$(date +%s)" \
		'{role:$role, worktree:$wt, model:$model, permission_mode:$perm,
		  mode:$mode, agent:$agent, profile:$profile, issue:$issue, review_pr:$pr,
		  status:"starting", seq:0, pinged_seq:-1,
		  spawned_at:$t, updated_at:$t}
		 + {agent_session_id:$sid}')"

	apex_event "$manager" "$(jq -nc --arg s "$member" --arg role "${role:-worker}" \
		--arg issue "$issue" --arg pr "$pr" \
		'{event:"register", session:$s, role:$role, issue:$issue, review_pr:$pr}')"

	_refresh_agent_icons "$session"
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

# _claude_project_dirs <worktree> — candidate Claude Code transcript directories
# for <worktree>, most likely first.
#
# Claude Code stores one transcript per conversation as
# ~/.claude/projects/<mangled-cwd>/<session-id>.jsonl, where <mangled-cwd> is the
# absolute path with every non-alphanumeric character replaced by "-"
# (verified against live transcript dirs: "/Users/a.b/.config/x" becomes
# "-Users-a-b--config-x"). That mangling is lossy and not a documented contract,
# so the exact name is only a fast path: a second candidate keeps "_" (in case
# it is preserved), and _claude_session_for verifies the directory it lands in by
# reading the cwd each transcript records for itself.
_claude_project_dirs() {
	local wt="$1" root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
	[[ -n $wt && -d $root ]] || return 1
	local a="${wt//[^a-zA-Z0-9]/-}" b="${wt//[^a-zA-Z0-9_]/-}"
	[[ -d "$root/$a" ]] && print -r -- "$root/$a"
	[[ $b != "$a" && -d "$root/$b" ]] && print -r -- "$root/$b"
	return 0
}

# _claude_normalize_prompt <first-user-message> — the message as the human typed
# it. Claude Code does not store a slash command verbatim: it records the
# expanded form
#
#   <command-message>my-pr-review</command-message>
#   <command-name>/my-pr-review</command-name>
#   <command-args>17</command-args>
#
# so a reviewer's transcript never begins with the literal "/my-pr-review 17"
# apex launched it with, and every reviewer would fail to match and be recovered
# with a blank context. Fold that shape back into "/name args" here, in one
# place, so the marker stays the string the launcher actually used.
_claude_normalize_prompt() {
	local m="$1" name args
	[[ $m == *"<command-name>"* ]] || { print -r -- "$m"; return 0; }
	name=${${m#*<command-name>}%%</command-name>*}
	if [[ $m == *"<command-args>"* ]]; then
		args=${${m#*<command-args>}%%</command-args>*}
	else
		args=""
	fi
	print -r -- "${name}${args:+ $args}"
}

# _claude_session_for <worktree> <task-marker> — the Claude Code session id of
# the conversation started in <worktree> whose first user message begins with
# <task-marker>, newest first; or nothing.
#
# The marker is what makes this usable at all. A worker and its reviewer share a
# worktree (pane-scoped members, a0bcf64), so "newest transcript for this
# directory" is a coin flip between the two — and resuming the wrong one is
# worse than not resuming, because it looks like it worked. The opening prompt is
# the only thing that distinguishes them, and it is a known string: apex spawned
# it (lib/agent-prompts.sh, delta_task_marker). With an empty marker this falls
# back to plain newest-for-this-directory, which is right for a member whose
# prompt apex didn't author.
_claude_session_for() {
	local wt="$1" marker="$2" d f cwd first
	local -a dirs
	dirs=(${(f)"$(_claude_project_dirs "$wt")"})
	(( ${#dirs} )) || return 1
	for d in $dirs; do
		for f in "$d"/*.jsonl(Nom); do
			# Cheapest disqualifier first: the recorded cwd. Transcripts run to
			# megabytes, so every read here is streaming + head, never slurped.
			cwd=$(jq -r 'select(.cwd != null) | .cwd' "$f" 2>/dev/null | head -n1)
			[[ ${cwd:A} == ${wt:A} ]] || continue
			if [[ -n $marker ]]; then
				# gsub before head: an expanded slash command spans three lines,
				# and `head -n1` on raw output would keep only the first of them.
				first=$(jq -r 'select(.type=="user" and (.message.content|type=="string"))
					| (.message.content | gsub("\n"; " "))' "$f" 2>/dev/null | head -n1)
				first=$(_claude_normalize_prompt "$first")
				# End of string or a space, never a bare prefix: "/my-pr-review 4"
				# prefixes "/my-pr-review 43", and resuming the wrong PR's review
				# looks like it worked.
				[[ $first == "$marker" || $first == "$marker "* ]] || continue
			fi
			print -r -- "${f:t:r}"
			return 0
		done
	done
	return 1
}

# _agent_session_for <agent> <worktree> <issue> <pr> — the agent-native
# conversation id to resume, for whichever agents expose one.
_agent_session_for() {
	local agent="${1:-claude}" wt="$2" issue="$3" pr="$4"
	case "${agent:t}" in
		claude|"")
			source "${SCRIPTS}/lib/agent-prompts.sh"
			_claude_session_for "$wt" "$(delta_task_marker "$issue" "$pr")"
			;;
		codex)    _codex_thread_for "$wt" ;;
		opencode) _opencode_session_for "$wt" ;;
		*)        return 1 ;;
	esac
}

# _record_agent_session <manager> <member> — resolve and durably record this
# member's agent conversation id, once.
#
# Why not at registration time: the id does not exist yet. The pane has only
# just been split, the agent process is still starting, and nothing hands the id
# to the launching process — Claude Code's own transcript is what publishes it,
# and that file appears after the first turn. So this runs from the member's own
# hooks instead (`event`), which is the first moment the answer exists. Guarded
# on "already recorded" so it costs one transcript scan per member for the
# lifetime of that member, not one per turn.
_record_agent_session() {
	local manager="$1" member="$2" have agent wt issue pr id
	have=$(apex_member_get "$manager" "$member" agent_session_id 2>/dev/null)
	[[ -n $have ]] && return 0
	agent=$(apex_member_get "$manager" "$member" agent 2>/dev/null)
	wt=$(apex_member_get "$manager" "$member" worktree 2>/dev/null)
	[[ -n $wt && -d $wt ]] || return 0
	issue=$(apex_member_get "$manager" "$member" issue 2>/dev/null)
	pr=$(apex_member_get "$manager" "$member" review_pr 2>/dev/null)
	id=$(_agent_session_for "$agent" "$wt" "$issue" "$pr") || return 0
	[[ -n $id ]] || return 0
	apex_member_merge "$manager" "$member" \
		"$(jq -nc --arg id "$id" '{agent_session_id:$id}')"
	apex_event "$manager" "$(jq -nc --arg s "$member" --arg id "$id" \
		'{event:"agent-session", session:$s, agent_session_id:$id}')"
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
#
# rc 0 has one soft edge: it also covers "typed, submitted, and the box never
# observably drained because the pane stayed busy the whole time" (issue #24),
# which is delivered by inference rather than by observation. Callers that
# cannot tolerate an inference must check APEX_SEND_UNCONFIRMED — _pair_relay
# does, and demotes it to undelivered, because on that path nobody would ever
# read the NOTE `send` prints.
_DELIVER_VIA=""
_deliver() {
	local target="$1" from="$2" text="$3"
	_DELIVER_VIA=""
	# Reset here rather than in each caller: the native path never enters
	# _send_to_pane, so a stale value from an earlier send-keys delivery would
	# otherwise be logged as this delivery's work.
	APEX_SEND_CLEARED=""
	APEX_SEND_SPLICED=""
	APEX_SEND_UNCONFIRMED=""
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
				--arg spliced "${APEX_SEND_SPLICED:-}" \
				'{event:"send-unsubmitted", session:$s, from:$from, text:$text}
				 + (if $cleared != "" then {cleared_input:$cleared} else {} end)
				 + (if $spliced != "" then {spliced_onto:$spliced} else {} end)')"
			_die "send: delivery unconfirmed"
			;;
		*) _die "send: delivery failed" ;;
	esac

	[[ -z $manager ]] && manager="$from"
	# unconfirmed marks the issue #24 case: the box never drained, but the pane
	# was repainting the whole time, so this reports delivered without ever
	# having retyped. Recorded because it is the only trace that a send was
	# assumed rather than observed — the thing to grep for if a member turns
	# out never to have received an instruction the log says was delivered.
	[[ -n $manager ]] && apex_event "$manager" "$(jq -nc \
		--arg s "$target" --arg from "$from" --arg text "$text" \
		--arg cleared "${APEX_SEND_CLEARED:-}" \
		--arg spliced "${APEX_SEND_SPLICED:-}" \
		--arg unconf "${APEX_SEND_UNCONFIRMED:-}" \
		'{event:"send", session:$s, from:$from, text:$text}
		 + (if $cleared != "" then {cleared_input:$cleared} else {} end)
		 + (if $spliced != "" then {spliced_onto:$spliced} else {} end)
		 + (if $unconf != "" then {unconfirmed:true} else {} end)')"

	print "Delivered to $target (${_DELIVER_VIA})."
	if [[ -n ${APEX_SEND_UNCONFIRMED:-} ]]; then
		print "NOTE: the input box never drained, but the pane stayed busy — assumed submitted, not re-sent."
	fi
	if [[ -n ${APEX_SEND_SPLICED:-} ]]; then
		print "WARNING: input box would not clear; this was appended to: ${APEX_SEND_SPLICED}"
	elif [[ -n ${APEX_SEND_CLEARED:-} ]]; then
		print "Cleared unsent input first: ${APEX_SEND_CLEARED}"
	fi
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
# Whatever the box held before the send (APEX_SEND_CLEARED, see _send_to_pane)
# is recorded as cleared_input on the event, the same as `send` does — and on
# the failure path too, since a draft destroyed by a relay that then failed is
# exactly as gone. This is the one delivery path that is both unattended and
# unwatched: it runs from _cmd_settle under `tmux run-shell -b -d`, so
# _send_to_pane's stderr report has no operator reading it, and the event log
# is the only place the discarded text survives.
#
# If clearing did not take, the delivery was appended to whatever was there
# (APEX_SEND_SPLICED) and the event says spliced_onto instead. The distinction
# is the point: a discarded draft is a lost note, but a spliced one means the
# partner agent received `<draft><relay>` as a single garbled instruction, and
# an unattended loop has no other way to say so.
_PAIR_RELAY_WHY=""
_pair_relay() {
	local manager="$1" target="$2" text="$3" rc=0
	_PAIR_RELAY_WHY=""
	# `send`'s confirmation ceiling (APEX_SEND_SETTLE_TICKS, 25 ticks = 5s) is
	# tuned for a human at a terminal: give up quickly and let them look at the
	# pane themselves. Here nobody is going to look, and the thing being waited
	# for — the box draining — is exactly the difference between continuing the
	# loop and disarming it. So watch for a lot longer before giving up.
	#
	# This buys more *observation*, not more typing. The retype is still gated
	# on the pane having gone completely quiet (issue #24), so a longer ceiling
	# cannot turn into a duplicate turn; it can only turn a give-up into a
	# confirmed delivery. That is what most of issue #29 was: a worker that had
	# received the relay and was busy acting on it, reported as unreachable
	# because 5s of redraw lag ran out.
	# An explicitly-set APEX_SEND_SETTLE_TICKS still wins: it is the more
	# specific knob, and silently overriding a ceiling someone tuned on purpose
	# would make the delivery path behave differently here than everywhere else
	# for no visible reason.
	local APEX_SEND_SETTLE_TICKS=${APEX_SEND_SETTLE_TICKS:-${APEX_PAIR_SETTLE_TICKS:-150}}
	_deliver "$target" "apex-pair" "$text" || rc=$?
	local ev
	ev=$(jq -nc --arg s "$target" --arg text "$text" \
		--arg cleared "${APEX_SEND_CLEARED:-}" \
		--arg spliced "${APEX_SEND_SPLICED:-}" --argjson rc "$rc" \
		--arg unconf "${APEX_SEND_UNCONFIRMED:-}" \
		'{session:$s, text:$text}
		 + (if $rc != 0 then {rc:$rc} else {} end)
		 + (if $cleared != "" then {cleared_input:$cleared} else {} end)
		 + (if $spliced != "" then {spliced_onto:$spliced} else {} end)
		 + (if $unconf != "" then {unconfirmed:true} else {} end)')
	# An unconfirmed send (_send_to_pane returned 0 without ever seeing the box
	# drain, because the pane stayed busy) is delivered-enough for a human at a
	# terminal: `send` prints a NOTE and they can look. Here there is nobody to
	# look. Advancing pair_turn on it would hand the loop a state where it
	# waits forever on a partner that may never have been woken, and the
	# rollback machinery built for exactly that case would be unreachable — so
	# treat it as undelivered, the same as rc 5, and let the escalation put a
	# human on it. The cost is a false alarm when the Enter did land; the cost
	# of the other choice is a silent deadlock, which nothing recovers from.
	if (( rc == 0 )) && [[ -n ${APEX_SEND_UNCONFIRMED:-} ]]; then
		rc=5
		_PAIR_RELAY_WHY="delivery to that pane could not be confirmed: it kept repainting for the whole confirmation window and the relay never visibly left its input box. A busy pane is weak evidence *for* delivery, so the partner may well have the message and be working on it — read the pane before treating this as a failure. If it is working, let it finish and push first: 'pair-resume' re-invokes the reviewer immediately, so resuming against unpushed work burns a round on unchanged code"
		ev=$(print -r -- "$ev" | jq -c '. + {rc:5}')
	fi
	if (( rc )); then
		if [[ -z $_PAIR_RELAY_WHY ]]; then
			case $rc in
				5) _PAIR_RELAY_WHY="the relay was typed into that pane but never submitted; it is sitting unsent in the input box" ;;
				2|3) _PAIR_RELAY_WHY="no reachable coding agent in that pane" ;;
				*) _PAIR_RELAY_WHY="delivery to that pane failed" ;;
			esac
		fi
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
		# {status,seq} into the same member file. apex_member_merge now holds
		# the record's mutex, so neither write can lose the other's fields;
		# the ordering is kept anyway because it is the cheaper guarantee —
		# the partner's write blocks rather than racing.
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
	local member="" extend="" force=""
	while (( $# )); do
		case "$1" in
			--max-rounds) _need_val pair-resume "$1" $#; extend="$2"; shift 2 ;;
			--force)      force=1; shift ;;
			-*) _die "pair-resume: unknown argument '$1'" ;;
			*)  member="$1"; shift ;;
		esac
	done
	[[ -n $member ]] || _die "pair-resume: usage: pair-resume <session:%pane> [--max-rounds N] [--force]"
	[[ -z $extend || $extend == <-> ]] || _die "pair-resume: --max-rounds must be a positive integer"

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local pair pr role round max reviewer worker
	pair=$(apex_member_get "$manager" "$member" pair)
	[[ -n $pair ]] || _die "pair-resume: '$member' is not linked to a partner"
	pr=$(apex_member_get "$manager" "$member" pair_pr)
	role=$(apex_member_get "$manager" "$member" pair_role)
	[[ $role == reviewer ]] && reviewer="$member" || reviewer="$pair"
	[[ $role == worker ]] && worker="$member" || worker="$pair"
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

	# A resume re-invokes the reviewer *now*, against whatever is on the branch
	# now. That is what a human wants after fixing whatever the loop was stuck
	# on, and wrong while the worker is still mid-change: the reviewer re-reads
	# code that has not moved, spends one of the cap's rounds, and posts the
	# findings it already posted.
	#
	# This is not a hypothetical ordering. The unconfirmed-relay escalation can
	# fire while the worker is provably still working on the relay it just
	# received (issue #29), and that escalation names `pair-resume` as the
	# remedy — so the remedy has to refuse the state it is most often reached
	# from, rather than warn about it in prose that goes unread.
	if [[ -z $force ]]; then
		local wstatus wdirty why=""
		wstatus=$(apex_member_get "$manager" "$worker" status 2>/dev/null)
		wdirty=$(_member_facts "$worker" 2>/dev/null | jq -r '.dirty // false')
		[[ $wstatus == working ]] && why="its pane is still active"
		if [[ $wdirty == true ]]; then
			why="${why:+${why} and }its worktree is dirty"
		fi
		[[ -n $why ]] && _die "pair-resume: the worker ($worker) is still mid-change (${why}), so re-invoking the reviewer now would re-review unchanged code and spend a round doing it. Wait for it to finish and push, then resume. To resume anyway: pair-resume ${member} --force"
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

	# First chance to learn this member's agent conversation id — see
	# _record_agent_session. Cheap after the first success, and it has to happen
	# here rather than at registration because the id does not exist yet then.
	_record_agent_session "$manager" "$session"

	local seq st
	case "$verb" in
		set)    st=working ;;
		notify) st=attention ;;
		clear)  st=idle ;;
		*)      return 0 ;;
	esac

	# Increment and claim seq in the same critical section as the status write:
	# reading it first, then merging, let two concurrent hook processes claim the
	# same number, and _settle below arms a callback keyed on it.
	seq=$(apex_member_merge_bump "$manager" "$session" "$(jq -nc \
		--arg st "$st" --argjson t "$(date +%s)" \
		'{status:$st, updated_at:$t}')") || seq=""

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
			#
			# No seq means the bump above failed outright, and a callback keyed
			# on nothing has nothing to confirm: skip it rather than arm it
			# blank and rely on _cmd_settle's comparisons falling through.
			[[ -n $seq ]] && tmux run-shell -b -d "$APEX_QUIET_SECS" \
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
# Reportability, defined once. Three things ask "would `pending` report this
# member": `_cmd_pending` below, and both of `_apex_pending_sig`'s paths (the
# slurped jq and its per-file fallback). They must agree exactly — the
# watcher's whole job is to nudge precisely when `pending` has something to
# say — and they cannot be checked against each other by any test that does
# not already know the answer, so they share the expression instead.
#
# A member is reportable when its seq has moved past pinged_seq AND it is
# either resting (idle/attention) or carrying a pair escalation. The
# escalation clause is why `status` alone will not do: a terminal pair
# escalation is reported on its own merit, because the partner's relay can
# wake the member back into `working` before the manager next pulls, which
# would otherwise defer "READY FOR HUMAN REVIEW" by a whole agent turn —
# likeliest in exactly the cases that need it soonest.
_APEX_REPORTABLE_JQ='def reportable:
	((.seq // 0) != (.pinged_seq // -1))
	and (((.pair_message // "") != "")
	     or .status == "idle" or .status == "attention");
'

_cmd_pending() {
	local mark=false a
	for a in "$@"; do [[ $a == --mark-delivered ]] && mark=true; done

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local s st seq rawseq role task facts summary pair_msg
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue

		# Whether this member is reportable is decided by the *shared* jq
		# definition, not re-expressed here. It used to be: this loop tested
		# `status` and `seq != pinged_seq` in shell, while the watcher's gate
		# tested the same thing in jq. Two copies of one decision is bad
		# enough; two copies in two *languages* is worse, because no shared
		# test can fail to compile and the byte-equality check that keeps the
		# gate's own two jq paths honest cannot reach across to shell. That
		# drift already happened once — the gate returned empty while
		# `pending` said READY FOR HUMAN REVIEW, suppressing the handoff the
		# whole ~1s tick exists to buy (issue #23).
		#
		# The watcher's gate keeps its slurped jq: it runs once a second and
		# must not touch `_member_facts`, so the two still *enumerate* members
		# differently. Only the predicate is shared, which is the part that
		# drifted.
		jq -e "$_APEX_REPORTABLE_JQ"'reportable' \
			"$(apex_member_file "$manager" "$s")" >/dev/null 2>&1 || continue

		st=$(apex_member_get "$manager" "$s" status)
		pair_msg=$(apex_member_get "$manager" "$s" pair_message)
		rawseq=$(apex_member_get "$manager" "$s" seq)
		seq=$rawseq; [[ -z $seq ]] && seq=0

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
		#
		# Compare-and-set on seq, because this is the one writer whose
		# correctness depends on a value it just read: if the member has
		# transitioned since, marking that seq delivered would swallow a
		# transition the manager never saw. A failed CAS re-reports the member
		# (and, for a pair escalation, repeats it) on the next pull — the safe
		# direction, and it self-heals in one round-trip.
		if $mark; then
			apex_member_merge_cas "$manager" "$s" "$(jq -nc \
				--argjson seq "$seq" --arg msg "$pair_msg" \
				'{pinged_seq:$seq} + (if $msg == "" then {} else {pair_message:""} end)')" \
				seq "$rawseq" || true
		fi
	done
}

# ─── reap ────────────────────────────────────────────────────────────

# _reap_risk <facts> — one line saying why reaping this member unattended would
# destroy work, or nothing if it is safe to take.
#
# `reap` force-removes the worktree and deletes the branch (gwtrm -f, with
# TMUX_DELTA_ASSUME_YES=1 suppressing the picker's own confirmation), so
# anything not pushed is gone for good — and `recover` cannot help afterwards
# because it skips members whose worktree is missing. That was survivable while
# a recycled pane id made some dead members read as alive; now that liveness is
# session-scoped, a server crash marks every member dead and one `reap --yes`
# takes the whole team's uncommitted work at once.
_reap_risk() {
	local facts="$1" wt dirty pr_state pr_number
	wt=$(printf '%s' "$facts" | jq -r '.worktree')
	dirty=$(printf '%s' "$facts" | jq -r '.dirty')
	pr_state=$(printf '%s' "$facts" | jq -r '.pr_state // "" | ascii_upcase')
	pr_number=$(printf '%s' "$facts" | jq -r '.pr_number // ""')
	# No worktree left means there is nothing to lose — that is `reap`'s job.
	[[ -z $wt || ! -d $wt ]] && return 0

	local -a why=()
	[[ $dirty == true ]] && why+=("uncommitted changes")

	# Deliberately not .commits_ahead: that is @{upstream}-relative, and a
	# branch that was never pushed has no upstream, so rev-list fails and the
	# count reads 0 — precisely the member whose work reap would destroy.
	#
	# `HEAD --not --remotes` was the replacement, and it asks a question one
	# step removed from the one that matters: it consults *local
	# remote-tracking refs*, not the remote. Where remote.origin.fetch is
	# narrowed to a single branch — as it is in the repo this was found in — no
	# origin/<worker-branch> ref is ever created, so every commit on every
	# worker branch counts as unpushed forever, including after its PR merged.
	# A guard that HOLDs unconditionally is not a guard; it is noise that
	# trains you to pass --force (issue #31).
	#
	# So ask the remote. `reap` is explicitly invoked, destructive, and
	# irreversible, which is exactly the budget one ls-remote is worth. When it
	# cannot answer — offline, no such branch — fall back to the local view,
	# which errs toward holding.
	#
	# Every git call below is guarded. This function is also eval'd into the
	# test suite's shell, which runs under `err_return`, where an unguarded
	# failing command substitution returns from the function *before it can
	# report anything* — a guard that silently answers "safe to reap" on the
	# exact input it exists to refuse. Found that way, not reasoned about.
	local unpushed="" branch="" remote_sha=""
	branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || branch=""
	if [[ -n $branch ]]; then
		remote_sha=$(git -C "$wt" ls-remote origin "refs/heads/${branch}" 2>/dev/null | cut -f1) || remote_sha=""
	fi
	if [[ -n $remote_sha ]] && git -C "$wt" cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
		unpushed=$(git -C "$wt" rev-list --count HEAD --not "$remote_sha" 2>/dev/null) || unpushed=""
	else
		unpushed=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) || unpushed=""
	fi

	# A squash merge rewrites the commits, so after one the branch's own commits
	# are unreachable from any remote ref by construction and no amount of
	# commit counting will ever say otherwise. Content is the only thing that
	# survives the rewrite, so compare that instead — but only once the PR is
	# actually merged. Tree-equals-base on an *open* PR means the worker has not
	# started, which is not the same as its work being safe, and a stale
	# origin/main leaves the diff non-empty and holds. Both fail closed.
	#
	# Which base, though, is not a guess where the PR number is known: the PR
	# says what it targets. The old fallback chain assumed origin/HEAD ->
	# origin/main -> origin/master, which is the right *shape* for a fallback
	# but the wrong answer for any PR that does not target the default branch
	# (release branches, maintenance branches, stacked PRs). Comparing against
	# the wrong base costs work in one direction — a false clear — so ask
	# `gh pr view` for baseRefName first and keep the chain only for when there
	# is no PR to ask, or gh cannot answer (issue #40).
	if [[ -n $unpushed ]] && (( unpushed > 0 )) && [[ $pr_state == MERGED ]]; then
		local base="" b
		local -a bases=()
		if [[ -n $pr_number ]]; then
			local base_ref=""
			base_ref=$(cd "$wt" && gh pr view "$pr_number" --json baseRefName -q .baseRefName 2>/dev/null) || base_ref=""
			if [[ -n $base_ref && $base_ref != null ]]; then
				# Knowing the base by name is not the same as having a ref for
				# it. Under the narrow remote.origin.fetch of issue #31 the only
				# remote-tracking ref that exists is origin/main, so asking the
				# PR and then rev-parsing origin/<base> falls straight through
				# to the fallback chain and lands on origin/main — the wrong
				# base this function was just fixed to stop using. Fetch the ref
				# by name so the answer exists to be read.
				#
				# The explicit refspec, not a bare `git fetch origin <base>`:
				# that one only populates FETCH_HEAD, which is per-repository
				# and therefore shared by every worker's worktree — two members
				# reaped at once would race over it.
				git -C "$wt" fetch -q origin \
					"+refs/heads/${base_ref}:refs/remotes/origin/${base_ref}" 2>/dev/null
				bases+=("refs/remotes/origin/${base_ref}")
			fi
		fi
		bases+=(refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/master)
		for b in "${bases[@]}"; do
			base=$(git -C "$wt" rev-parse --verify --quiet "$b" 2>/dev/null) || base=""
			[[ -n $base ]] && break
		done
		if [[ -n $base ]] && git -C "$wt" diff --quiet "$base" HEAD 2>/dev/null; then
			unpushed=0
		fi
	fi

	if [[ -z $unpushed ]]; then
		why+=("could not read git state")
	elif (( unpushed > 0 )); then
		why+=("$unpushed unpushed commit(s)")
	fi

	(( ${#why} )) && print -r -- "${(j:, :)why}"
	return 0
}

# _reap_cleanup <session> <worktree> — tear down a reaped member's worktree and
# session. Prints why and returns non-zero if the worktree is still there
# afterwards, so the caller can keep the member record rather than orphan it.
#
# The exit status of the cleanup itself is not the thing to trust: `gwtrm -f`
# used to prompt a second time for a dirty worktree, and with no tty that read
# failed into an "Aborted." path that returned 0 for a worktree it had not
# touched. Both halves of that are fixed now (gwt.zsh honours -f, the picker
# propagates a surviving worktree), but the only fact that actually settles the
# question is whether the directory is gone — so check that, and keep the
# output instead of discarding it to /dev/null.
_reap_cleanup() {
	local session="$1" wt="$2"
	if [[ -z $wt || ! -d $wt ]]; then
		tmux kill-session -t "$session" 2>/dev/null
		return 0
	fi

	local out
	out=$(TMUX_DELTA_ASSUME_YES=1 "${SCRIPTS}/tmux-picker.sh" --delete-wt "wt:${wt}" 2>&1)
	if [[ -d $wt ]]; then
		print "  worktree survived cleanup: $wt"
		[[ -n $out ]] && print -r -- "  ${out//$'\n'/$'\n'  }"
		return 1
	fi
	return 0
}

_cmd_reap() {
	local yes=false force=false a
	for a in "$@"; do
		case "$a" in
			--yes)   yes=true ;;
			--force) force=true ;;
		esac
	done

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local -a done_members=() held=()
	local s facts alive pr_state risk
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		facts=$(_member_facts "$s")
		alive=$(printf '%s' "$facts" | jq -r '.alive')
		pr_state=$(printf '%s' "$facts" | jq -r '.pr_state')
		if [[ $alive == false || $pr_state == MERGED || $pr_state == CLOSED ]]; then
			risk=$(_reap_risk "$facts")
			if [[ -n $risk ]] && ! $force; then
				held+=("$s")
				print "  $s  — HOLD: $risk — $(_facts_line "$facts")"
			else
				done_members+=("$s")
				print "  $s  — $(_facts_line "$facts")"
			fi
		fi
	done

	if (( ${#held} )); then
		print "\n${#held} member(s) held back: reap force-removes the worktree and"
		print "deletes the branch, so unpushed work would be unrecoverable — and"
		print "\`recover\` cannot bring back a member whose worktree is gone."
		print "Push or commit that work first (\`recover --yes\` puts a crashed"
		print "member back on its own conversation so it can), or pass --force to"
		print "reap them anyway."
	fi

	if (( ${#done_members} == 0 )); then
		if (( ${#held} )); then
			print "\nNothing reaped."
		else
			print "Nothing to reap."
		fi
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

		# Worktree first, member record second. The record carries
		# agent_session_id, and that is the only thing `recover` can put a
		# member back from — so deleting it before a cleanup that is allowed to
		# fail makes every such failure unrecoverable by construction. The pane
		# is expendable either way: `recover` makes a new one.
		#
		# Only clean up the shared worktree/session once no other apex member
		# (e.g. a worker, if we just reaped a reviewer) still owns a pane there.
		if ! _session_has_apex_member "$session"; then
			if ! _reap_cleanup "$session" "$wt"; then
				print "  Kept $s — its record is the only way \`recover\` can reach that work."
				continue
			fi
		fi

		rm -f "$(apex_member_file "$manager" "$s")"
		apex_member_lock_forget "$manager" "$s"
		apex_event "$manager" "$(jq -nc --arg s "$s" '{event:"reap", session:$s}')"
		print "Reaped $s"
	done
}

# ─── recover (tmux-server-crash recovery) ────────────────────────────

# _apex_session_label <session> <worktree> [pr] — the short pill label the picker
# would have given this session. A recovered session that keeps its full
# worktree-derived name reads as a different session to the human than the one
# that died, so this has to agree with the picker exactly — which is why the
# derivation now lives in lib/session-label.sh instead of being a second copy
# here. <pr> is passed through for the same reason: the picker prefixes a review
# session's label with its PR number, so dropping it here would bring a dead
# "43: fix-issue-42" back as "fix-issue-42".
_apex_session_label() {
	source "${SCRIPTS}/lib/session-label.sh"
	delta_session_label "$1" "$2" "${3:-}"
}

# recover [--yes] [member ...] — put crashed members back, with their
# conversations intact.
#
# When the tmux server dies, every member's session and pane die with it. The
# work does not: worktrees, branches, uncommitted diffs and the agents' own
# transcripts all survive on disk, and so does the apex member record. What used
# to be missing was the link from a record to the conversation it belonged to,
# so the only recovery was a fresh spawn — which reuses the worktree but throws
# the whole conversation away and makes the agent re-derive its state from git
# and gh. This resumes instead: same worktree, same role, same task, same
# conversation (see _record_agent_session, and --resume in lib/agents/claude.sh).
#
# Deliberately not automatic on relink. A human who kills a session on purpose
# must not have it grow back; the manager invokes this when it finds dead
# members whose worktrees are still there. Dry run unless --yes, mirroring
# `reap`.
_cmd_recover() {
	local yes=false a
	local -a want=()
	for a in "$@"; do
		case "$a" in
			--yes) yes=true ;;
			-*)    _die "recover: unknown argument '$a'" ;;
			*)     want+=("$a") ;;
		esac
	done

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"
	source "${SCRIPTS}/lib/agent-prompts.sh"
	source "${SCRIPTS}/lib/agent-launch.sh"

	local -a plan=()
	local s
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		(( ${#want} )) && [[ ${want[(Ie)$s]} == 0 ]] && continue
		_member_alive "$s" && continue

		local wt role mode model perm agent profile issue pr sid task session note
		wt=$(apex_member_get "$manager" "$s" worktree)
		role=$(apex_member_get "$manager" "$s" role);  [[ -z $role ]] && role=worker
		mode=$(apex_member_get "$manager" "$s" mode)
		model=$(apex_member_get "$manager" "$s" model)
		perm=$(apex_member_get "$manager" "$s" permission_mode)
		agent=$(apex_member_get "$manager" "$s" agent); [[ -z $agent ]] && agent=claude
		profile=$(apex_member_get "$manager" "$s" profile)
		issue=$(apex_member_get "$manager" "$s" issue)
		pr=$(apex_member_get "$manager" "$s" review_pr)
		session=$(_member_session "$s")

		if [[ -z $wt || ! -d $wt ]]; then
			print "  $s  — SKIP: worktree gone (${wt:-<unrecorded>}); nothing to recover into"
			continue
		fi

		if [[ -n $pr ]]; then task="pr:$pr"; elif [[ -n $issue ]]; then task="issue:$issue"; else task=""; fi

		# Already back? A previous recover, or a plain spawn, may have put a live
		# pane on this task in this session. Don't add a second one.
		#
		# A member with neither an issue nor a PR has an empty task, and
		# _register-member does not set @apex_task at all in that case — so
		# matching on the task would skip this guard entirely and every
		# `recover --yes` would stack another pane. Fall back to "any pane in
		# this session that is already an apex member".
		if _session_alive "$session"; then
			local p dup=""
			for p in ${(f)"$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null)"}; do
				if [[ -n $task ]]; then
					[[ $(tmux show-option -p -t "$p" -qv @apex_task 2>/dev/null) == "$task" ]] \
						&& dup="$p" && break
				else
					[[ -n $(tmux show-option -p -t "$p" -qv @apex_session 2>/dev/null) ]] \
						&& dup="$p" && break
				fi
			done
			if [[ -n $dup ]]; then
				print "  $s  — SKIP: ${session}:${dup} is already live on ${task:-this session}"
				continue
			fi
		fi

		# The transcript, not the record, decides what can be resumed. A recorded
		# id can be wrong — the conversation may have been pruned, or the record
		# may predate a correction — and handing a dead id to --resume was the
		# one failure mode worth avoiding: it looks like recovery worked. So
		# resolve from disk and treat the recorded value as a cache to correct.
		local recorded
		recorded=$(apex_member_get "$manager" "$s" agent_session_id)
		sid=$(_agent_session_for "$agent" "$wt" "$issue" "$pr" 2>/dev/null) || sid=""
		note="resume ${sid:-<none found>}"
		if [[ -n $recorded && $recorded != "$sid" ]]; then
			note+=" (recorded id ${recorded} no longer resolves; record corrected)"
		fi
		# Only the claude adapter knows how to resume one specific recorded
		# conversation (DELTA_AGENT_RESUME). codex and opencode both have their
		# own resume story and their ids are already discoverable
		# (_codex_thread_for/_opencode_session_for), but wiring their argv is a
		# separate change — say so rather than resuming something else.
		if [[ ${agent:t} != claude && -n $sid ]]; then
			note="fresh (agent '${agent}' has no apex resume support yet; id ${sid} recorded)"
			sid=""
		fi
		[[ -z $sid ]] && note="fresh (no resumable conversation found)"

		plan+=("${s}"$'\t'"${session}"$'\t'"${wt}"$'\t'"${role}"$'\t'"${task}"$'\t'"${sid}"$'\t'"${agent}"$'\t'"${mode}"$'\t'"${model}"$'\t'"${perm}"$'\t'"${profile}"$'\t'"${issue}"$'\t'"${pr}")
		print "  $s  — role=${role} ${task:+task=${task} }worktree=${wt}  ${note}"
	done

	if (( ${#plan} == 0 )); then
		print "Nothing to recover."
		return
	fi

	if ! $yes; then
		print "\n${#plan} dead member(s) recoverable. Re-run with --yes to recreate their panes."
		return
	fi

	local row
	for row in "${plan[@]}"; do
		local -a f=("${(@s:	:)row}")
		local old_key="${f[1]}" session="${f[2]}" wt="${f[3]}" role="${f[4]}" task="${f[5]}"
		local sid="${f[6]}" agent="${f[7]}" mode="${f[8]}" model="${f[9]}" perm="${f[10]}"
		local profile="${f[11]}" issue="${f[12]}" pr="${f[13]}"

		# Pane width follows the shape of the session, so a recovered layout is
		# the layout the human is used to: a session we just made gets the
		# dev-layout split (editor | agent), a surviving one gets the narrower
		# extra-pane width the picker uses.
		local pct=$DELTA_AGENT_PANE_PCT_EXTRA
		if ! _session_alive "$session"; then
			tmux new-session -ds "$session" -c "$wt" 2>/dev/null \
				|| { print -u2 "recover: could not create session '$session'"; continue }
			_apex_session_label "$session" "$wt" "$pr"
			pct=$DELTA_AGENT_PANE_PCT_NEW
		fi

		local system prompt inner pane adapter="${SCRIPTS}/lib/agent-adapter.sh"
		system=$(delta_managed_prompt "$role" "$manager")
		prompt=$(delta_task_prompt "$issue" "$pr" "$mode")
		inner=$(delta_agent_launch_cmd "${(q)agent}" "$model" "$perm" "$system" "$prompt" "$wt" "$adapter" "$sid" 1)
		pane=$(tmux split-window -t "$session" -h -p $pct -c "$wt" -P -F '#{pane_id}' \
			"direnv exec ${(q)wt} zsh -ic ${(q)inner}" 2>/dev/null)
		if [[ -z $pane ]]; then
			print -u2 "recover: could not create an agent pane in '$session'"
			continue
		fi
		tmux set-option -t "$session" @agent_pane "$pane" 2>/dev/null

		# New pane, new member key. Registration writes the fresh record (and
		# drops any stale one recycled onto this pane id); then retire the old
		# key so the member isn't counted twice.
		_cmd_register_member "$pane" "$manager" "$role" "$task" "$wt" \
			"$model" "$perm" "$mode" "$agent" "$profile" "$issue" "$pr" "$sid" >/dev/null

		local new_key="${session}:${pane}"
		if [[ $old_key != $new_key ]]; then
			rm -f "$(apex_member_file "$manager" "$old_key")"
			apex_member_lock_forget "$manager" "$old_key"
		fi

		apex_event "$manager" "$(jq -nc --arg old "$old_key" --arg new "$new_key" \
			--arg sid "$sid" --arg role "$role" \
			'{event:"recover", session:$new, previous_session:$old, role:$role,
			  agent_session_id:$sid, resumed:($sid != "")}')"

		if [[ -n $sid ]]; then
			print "Recovered $new_key (resumed conversation $sid)"
		else
			print "Recovered $new_key (fresh conversation — nothing resumable found)"
		fi
	done

	tmux refresh-client -S 2>/dev/null
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

# ─── watch (fast automatic ping delivery) ────────────────────────────
#
# `pending` is the whole delivery mechanism, and until now the only things
# that called it were the manager's own Claude Code hooks: before a human
# message, mid-turn after a tool batch, at end of turn, and on resume. All
# four are *manager-driven*. Nothing fires on a worker transition, so a
# manager that has finished its turn and is waiting sits blind: a worker can
# go `attention` and stay there indefinitely while `pending` would have
# reported it correctly the whole time, had anyone asked (issue #14).
#
# `watch` is the thing that asks. It is a plain background process, not an
# agent turn — one tick is a few file reads, so it can run at ~1s cadence,
# and it only spends manager tokens when there is genuinely something to
# deliver. That is the entire point of the split: `/loop 20m` pays a full
# manager turn per tick whether or not anything happened, which is why it
# had to be slow; this pays nothing per tick and a single turn per event.
#
# Delivery still goes through the same door as everything else — the nudge
# lands in the manager's input box via `_send_to_pane`, which fires the
# manager's UserPromptSubmit hook, which calls `pending --mark-delivered`
# and attaches the real event list as context. So the watcher never has to
# format or dedupe pings itself, and a manager with no hooks wired degrades
# to exactly the behaviour it has today (see `doctor`).
#
# Writing into the manager's pane is the thing `_record_status` deliberately
# refuses to do (issue #5: a keystroke can splice into a human's in-flight
# draft or the agent's own ghost autosuggestion, indistinguishable from
# outside the pane). That refusal is why this is a separate, guarded path
# rather than a push from the worker's hook:
#
#   - Only ever into a pane actually running an agent (`_pane_is_agent`).
#   - Never while the input box has text that is *changing*. A human typing
#     moves the box every few seconds; Claude Code's ghost text does not. So
#     unsent input defers the nudge, and only a box that has sat byte-identical
#     for APEX_WATCH_BOX_GRACE seconds is treated as stale and cleared —
#     otherwise ghost text would block delivery forever, which is the failure
#     this command exists to fix.
#   - One nudge per distinct set of undelivered pings, re-sent at most once
#     every APEX_WATCH_RENUDGE seconds if the manager still hasn't consumed
#     them (a queued message behind a long turn, a swallowed Enter).
#
# Knobs: APEX_WATCH_INTERVAL (1s), APEX_WATCH_BOX_GRACE (15s),
# APEX_WATCH_RENUDGE (60s).

APEX_WATCH_INTERVAL=${APEX_WATCH_INTERVAL:-1}
APEX_WATCH_BOX_GRACE=${APEX_WATCH_BOX_GRACE:-60}
APEX_WATCH_RENUDGE=${APEX_WATCH_RENUDGE:-60}

# _apex_watch_check_knobs — refuse to start on a knob that isn't a number.
#
# Not pedantry. A non-numeric interval makes `sleep` fail instantly, and the
# loop has no way to tell that from a slept second: it would spin a core
# running full ticks forever. The same value also blows up `--argjson` when the
# daemon records itself, and a failed `jq` there used to leave an empty state
# file behind, which is its own failure mode (see _apex_watch_save). Catch it
# once, at the door, rather than three times downstream.
_apex_watch_check_knobs() {
	local k v
	for k in APEX_WATCH_INTERVAL APEX_WATCH_BOX_GRACE APEX_WATCH_RENUDGE; do
		v=${(P)k}
		[[ $v =~ '^[0-9]+(\.[0-9]+)?$' ]] || _die "watch: $k must be a number, got '$v'"
	done
}

_apex_watch_pidfile()   { printf '%s/watch.pid' "$(apex_dir "$1")"; }
_apex_watch_statefile() { printf '%s/watch-state.json' "$(apex_dir "$1")"; }

# _apex_pending_sig <manager> — a stable one-line fingerprint of everything
# `pending` would report right now, or "" for nothing to report.
#
# This is the cheap gate the tick rate depends on, so it deliberately does
# not go near `_member_facts`: that shells out to git and the PR cache per
# member, which is fine once per manager turn and far too expensive once per
# second. Same predicate as `_cmd_pending` (idle/attention, seq ahead of
# pinged_seq), read straight out of the member state files in one jq.
#
# The seq is part of the fingerprint, not just the session: a worker that
# settles, gets pinged, wakes and settles again is a new event to deliver,
# and keying on session alone would swallow it as a duplicate.
# The predicate itself lives above `_cmd_pending` — all three readers of it
# share that one definition, which is the point (issue #23).

_apex_pending_sig() {
	local manager="$1" dir
	dir=$(apex_members_dir "$manager")
	local -a files=("$dir"/*.json(N)) names=()
	(( ${#files} )) || return 0
	local f
	for f in "${files[@]}"; do names+=("${${f:t}:r}"); done

	# One slurped jq over every member file is the cheap path. Names travel as a
	# single newline-joined --arg to line up with the slurped documents: jq's
	# --args cannot be used for this, it would swallow the file list as
	# positional arguments and leave jq reading stdin. Newline and not comma —
	# tmux session names may contain a comma (`tmux new-session -s a,b` is
	# legal), which would split one name into two and misalign every name after
	# it, but they cannot contain a newline.
	local sig rc=0
	sig=$(jq -rs --arg names "${(pj:\n:)names}" "$_APEX_REPORTABLE_JQ"'
		($names | split("\n")) as $n
		| [ range(0; length) as $i
		    | .[$i]
		    | select(reportable)
		    | "\($n[$i])#\(.seq // 0)\(if (.pair_message // "") != "" then "!" else "" end)" ]
		| sort | join(",")' "${files[@]}" 2>/dev/null) || rc=$?
	if (( rc == 0 )); then
		print -r -- "$sig"
		return 0
	fi

	# A slurp aborts on the first unparseable document, so one truncated member
	# file would otherwise return "" for the whole set — a poller that reports
	# itself healthy in `doctor` and `watch --status` and will never fire again,
	# while `_cmd_pending` (which reads each file on its own) keeps answering
	# correctly. Degrade per file instead, so a corrupt record only ever loses
	# its own member, and say so in the event log rather than silently.
	apex_event "$manager" "$(jq -nc '{event:"watch-degraded",
		reason:"unparseable member state; falling back to per-file reads"}')"
	local -a out=()
	local i one
	for (( i = 1; i <= ${#files}; i++ )); do
		one=$(jq -r "$_APEX_REPORTABLE_JQ"'
			select(reportable)
			| "#\(.seq // 0)\(if (.pair_message // "") != "" then "!" else "" end)"
			' "${files[$i]}" 2>/dev/null) || continue
		[[ -n $one ]] && out+=("${names[$i]}${one}")
	done
	# (@o), not (o): inside double quotes a nested ${(o)out} collapses to one
	# space-joined word, leaving the outer (j:,:) a single element and nothing
	# to join — so this path used to emit "a b" where the slurped path emits
	# "a,b". Both halves matter: the separator differs on every fallback with
	# two pending members, and the sort keeps the two paths agreeing if the
	# glob ever stops arriving in order. A sig that changes shape without the
	# pending set changing is a spurious nudge into the manager's pane.
	print -r -- "${(j:,:)${(@o)out}}"
}

# _apex_watch_state <manager> <key> / _apex_watch_save <manager> <patch-json>
#
# Tick state lives in a file rather than in shell variables so that a
# `watch --once` invocation behaves identically to one iteration of the
# daemon loop — that is what makes the decision logic testable, and it also
# means a restarted daemon does not re-nudge for pings it already sent.
_apex_watch_state() {
	local f
	f=$(_apex_watch_statefile "$1")
	[[ -f $f ]] || return 0
	jq -r --arg k "$2" '.[$k] // "" | tostring' "$f" 2>/dev/null
}

# _apex_watch_repair <manager> — if the state file exists but does not parse,
# replace it with an empty object. Returns 1 when it had to.
#
# Not cosmetic: every key read out of an unparseable file comes back "", and ""
# is not a safe default anywhere in the tick. It makes the debounce compare
# against an empty last-signature (so every tick looks like a brand-new event)
# and the grace window start at the epoch (so every box looks stale). At a 1s
# cadence that is a nudge per second, each one clearing the manager's input box
# — the exact hazard this path is guarded against. So the tick repairs the file
# and skips its own turn rather than acting on nothing.
_apex_watch_repair() {
	local f
	f=$(_apex_watch_statefile "$1")
	[[ -f $f ]] || return 0
	jq -e . "$f" >/dev/null 2>&1 && return 0
	apex_write_atomic "$f" '{}'
	return 1
}

# Every read of the base goes through jq rather than `cat`, and a failure is
# reported rather than written. Without that, one bad merge writes an empty
# state file, every later save reads the empty base and fails identically, and
# the file never recovers: `_apex_watch_state` then answers "" for every key,
# which does not fail closed — it makes the debounce stop debouncing and the
# grace window expire instantly, so the daemon types a nudge per second into
# the manager's pane, clearing whatever is in the box each time. That is the
# precise hazard this whole path is guarded against.
_apex_watch_save() {
	local manager="$1" patch="$2" f base merged
	[[ -n $patch ]] || return 1
	f=$(_apex_watch_statefile "$manager")
	base=$(jq -c . "$f" 2>/dev/null) || base='{}'
	[[ -n $base ]] || base='{}'
	merged=$(printf '%s\n%s\n' "$base" "$patch" | jq -s '.[0] * .[1]') || return 1
	[[ -n $merged ]] || return 1
	apex_write_atomic "$f" "$merged"
}

# _apex_client_activity <manager> <pane> — epoch seconds of the most recent
# input from a client that is currently looking at <pane>, or "" if there is no
# such client.
#
# client_activity is a *client* attribute, so `list-clients -t <session>` alone
# answers a broader question than the one being asked: it would count typing in
# a sibling shell pane, a window switch, or a scroll in copy-mode as evidence
# that the human is mid-draft in the manager's box. In a session where someone
# works steadily next door, that defers delivery for as long as they keep
# working — a partial return of the blindness this whole path exists to fix. So
# narrow it to clients whose active pane really is the manager's.
#
# One `display-message` per attached client is more tmux calls than the tick
# budget would like, but this only runs on the cold path: something is pending,
# the box is non-empty, and it has not changed since the last tick.
#
# Treat this as a conservative extra reason to *defer*, never as the thing that
# authorises a clear — the `box_since` timer below is what guarantees the window
# eventually closes. Two limits worth naming: whether client_activity advances
# on every keystroke is not something this repo can assert (it cannot synthesise
# real client input — `send-keys` goes through the server, not a client's tty),
# and observation only confirms the half that matters, that it stays frozen
# while a pane emits output with nobody typing.
_apex_client_activity() {
	local manager="$1" pane="$2" c t best=""
	[[ -n $pane ]] || return 0
	for c in ${(f)"$(tmux list-clients -t "=$manager" -F '#{client_name}' 2>/dev/null)"}; do
		[[ -n $c ]] || continue
		[[ $(tmux display-message -p -c "$c" '#{pane_id}' 2>/dev/null) == "$pane" ]] || continue
		t=$(tmux display-message -p -c "$c" '#{client_activity}' 2>/dev/null)
		[[ $t =~ '^[0-9]+$' ]] || continue
		# Explicit `if`, not `[[ ]] || (( )) && best=$t`: that form is correct
		# (|| and && are equal-precedence and left-associative, so the two
		# tests group together) but it reads identically to the other
		# grouping, which would also happen to work here — so it gives a
		# later editor no signal that the precedence is load-bearing.
		if [[ -z $best ]] || (( t > best )); then
			best=$t
		fi
	done
	[[ -n $best ]] && print -r -- "$best"
	return 0
}

# _apex_watch_tick <manager> — one poll. Prints a line per action taken so
# `watch --once` is inspectable by hand; silent when there is nothing to do.
_apex_watch_tick() {
	local manager="$1" sig now
	if ! _apex_watch_repair "$manager"; then
		print -r -- "watch state was unreadable; reset and skipping this tick"
		return 0
	fi
	sig=$(_apex_pending_sig "$manager")
	now=$(date +%s)

	if [[ -z $sig ]]; then
		# Nothing outstanding: forget the box we were waiting on, so the next
		# real event starts its grace window from scratch instead of inheriting
		# a stale timestamp and clearing someone's draft immediately.
		_apex_watch_save "$manager" '{"box":"","box_since":0}'
		return 0
	fi

	local pane
	pane=$(_agent_pane "$manager")
	if ! _pane_is_agent "$pane"; then
		print -r -- "no agent pane for $manager; not delivering"
		return 0
	fi

	local box last_box box_since
	box=$(_pane_input_line "$pane" 2>/dev/null)
	last_box=$(_apex_watch_state "$manager" box)
	box_since=$(_apex_watch_state "$manager" box_since); [[ -z $box_since ]] && box_since=0

	if [[ -n $box ]]; then
		if [[ $box != $last_box ]]; then
			# Every early return below must survive its own save failing, and
			# "defer" is the safe direction: a tick that cannot remember what it
			# saw must not conclude the box is stale and clear it.
			_apex_watch_save "$manager" \
				"$(jq -nc --arg b "$box" --argjson t "$now" '{box:$b, box_since:$t}')" \
				|| print -u2 -- "watch: could not record input-box state; deferring"
			print -r -- "manager input box busy; deferring"
			return 0
		fi
		# A missing box_since means the state file could not be read. Treat it
		# as "first seen now" rather than epoch 0, so an unreadable state file
		# defers instead of expiring the grace window instantly.
		if [[ -z $box_since || $box_since == 0 ]]; then
			_apex_watch_save "$manager" \
				"$(jq -nc --arg b "$box" --argjson t "$now" '{box:$b, box_since:$t}')" || true
			print -r -- "manager input box busy; deferring"
			return 0
		fi
		# The grace window is really asking "is a human present at this box?",
		# and a plain timer is only a proxy for it. Recent input from a client
		# looking at this pane pushes the clock forward, so someone pausing
		# mid-draft keeps their draft — but only up to a hard cap measured from
		# when the box was first seen, so the window closes on schedule whatever
		# the activity signal says. Without that cap "ghost text delays delivery,
		# it never blocks it" would hold only while the human eventually stops.
		local since=$(( now - box_since )) act
		act=$(_apex_client_activity "$manager" "$pane")
		if [[ -n $act ]] && (( now - act < since )); then
			since=$(( now - act ))
			local cap=$(( 2 * APEX_WATCH_BOX_GRACE ))
			(( now - box_since >= cap )) && since=$(( now - box_since ))
		fi
		if (( since < APEX_WATCH_BOX_GRACE )); then
			print -r -- "manager input box in use ${since}s ago; deferring"
			return 0
		fi
		# Quiet past the grace window: ghost text or an abandoned draft.
		# _send_to_pane clears it, and says what it cleared on stderr and in
		# the event log.
	else
		[[ -n $last_box ]] && _apex_watch_save "$manager" '{"box":"","box_since":0}'
	fi

	local last_sig last_nudge
	last_sig=$(_apex_watch_state "$manager" sig)
	last_nudge=$(_apex_watch_state "$manager" nudged_at)
	if [[ $sig == $last_sig ]]; then
		# An unreadable nudged_at cannot be read as "nudged at the epoch" —
		# that makes the debounce silently stop debouncing, which at a 1s
		# cadence is a nudge per second. Same fingerprint and no usable
		# timestamp means we have already sent this one: hold.
		if [[ -z $last_nudge || $last_nudge == 0 ]]; then
			print -u2 -- "watch: no readable nudge timestamp; holding to avoid duplicates"
			return 0
		fi
		(( now - last_nudge < APEX_WATCH_RENUDGE )) && return 0
	fi

	local rc=0
	_send_to_pane "$pane" \
		"[apex] a member just changed state — the pending events are attached to this message; review them and act." \
		|| rc=$?

	_apex_watch_save "$manager" "$(jq -nc --arg s "$sig" --argjson t "$now" \
		'{sig:$s, nudged_at:$t, box:"", box_since:0}')"
	apex_event "$manager" "$(jq -nc --arg s "$sig" --argjson rc "$rc" \
		--arg cleared "${APEX_SEND_CLEARED:-}" \
		'{event:"watch-nudge", pending:$s, rc:$rc}
		 + (if $cleared != "" then {cleared_input:$cleared} else {} end)')"

	case $rc in
		0) print -r -- "nudged $manager for: $sig" ;;
		2) print -r -- "nudged $manager for: $sig (typed but not confirmed submitted)" ;;
		*) print -r -- "nudge to $manager failed (rc=$rc)" ;;
	esac
}

# _apex_watch_running <manager> — pid of a live watcher, or nothing.
#
# `kill -0` alone is not enough. The pidfile lives under $XDG_CACHE_HOME and
# survives reboots, after which the pid has very likely been reassigned — and
# then `kill -0` says "running", which both stops `init` from starting a real
# poller (while `doctor` cheerfully reports a healthy one) and points
# `watch --stop` at somebody else's process. So check the command line too, and
# treat a mismatch as not-running, unlinking the stale pidfile on the way out.
_apex_watch_running() {
	local f pid cmd
	f=$(_apex_watch_pidfile "$1")
	[[ -f $f ]] || return 1
	pid=$(cat "$f" 2>/dev/null)
	if [[ ! $pid =~ '^[0-9]+$' ]] || ! kill -0 "$pid" 2>/dev/null; then
		rm -f "$f"
		return 1
	fi
	cmd=$(ps -o command= -p "$pid" 2>/dev/null)
	if [[ $cmd != *tmux-apex* ]]; then
		rm -f "$f"
		return 1
	fi
	print -r -- "$pid"
}

# _apex_watch_start <manager> — idempotent; launches the daemon detached from
# the caller via the tmux server, the same way the status-bar refreshers are
# started. A hook process or an agent turn is far too short-lived to parent
# it, and run-shell -b outlives both.
_apex_watch_start() {
	local manager="$1"
	_apex_watch_running "$manager" >/dev/null && return 0
	# run-shell executes in the *tmux server's* environment, not the caller's,
	# so the knobs have to travel on the command line or the daemon silently
	# ignores every one of them and the documented tunables are inert.
	tmux run-shell -b "APEX_WATCH_INTERVAL=${(q)APEX_WATCH_INTERVAL} \
APEX_WATCH_BOX_GRACE=${(q)APEX_WATCH_BOX_GRACE} \
APEX_WATCH_RENUDGE=${(q)APEX_WATCH_RENUDGE} \
${(q)SELF} watch --daemon ${(q)manager}" 2>/dev/null
}

_apex_watch_stop() {
	local manager="$1" pid
	pid=$(_apex_watch_running "$manager") || { rm -f "$(_apex_watch_pidfile "$manager")"; return 1; }
	kill "$pid" 2>/dev/null
	rm -f "$(_apex_watch_pidfile "$manager")"
	return 0
}

_cmd_watch() {
	local mode=start manager="" a
	for a in "$@"; do
		case "$a" in
			--start)  mode=start ;;
			--once)   mode=once ;;
			--stop)   mode=stop ;;
			--status) mode=status ;;
			--daemon) mode=daemon ;;
			-*)       _die "watch: unknown option '$a'" ;;
			*)        manager="$a" ;;
		esac
	done

	if [[ -z $manager ]]; then
		manager=$(_require_manager)
	else
		# An explicitly named session is validated like every other command's
		# target (cf. `stop`). Without this, `watch typo` happily creates
		# $APEX_ROOT/typo/members/ and spins up a loop that immediately breaks.
		[[ $(_sopt "$manager" @apex_role) == manager ]] \
			|| _die "watch: session '$manager' is not an apex manager"
	fi
	APEX_SESSION="$manager"

	local pid
	case $mode in
		status)
			if pid=$(_apex_watch_running "$manager"); then
				# The knobs the *daemon* was started with, not this process's
				# defaults — they are different values read in different shells,
				# and the daemon's are the ones actually in force.
				local iv gr rn
				iv=$(_apex_watch_state "$manager" interval);  [[ -z $iv ]] && iv='?'
				gr=$(_apex_watch_state "$manager" box_grace); [[ -z $gr ]] && gr='?'
				rn=$(_apex_watch_state "$manager" renudge);   [[ -z $rn ]] && rn='?'
				print "watch: running (pid $pid) for $manager"
				print "  interval=${iv}s box-grace=${gr}s re-nudge=${rn}s"
			else
				print "watch: not running for $manager"
				return 1
			fi
			return 0 ;;
		stop)
			if _apex_watch_stop "$manager"; then
				print "watch: stopped for $manager"
			else
				print "watch: was not running for $manager"
			fi
			return 0 ;;
		once)
			_apex_watch_check_knobs
			_apex_watch_tick "$manager"
			return 0 ;;
		start)
			# The default has to return. `watch` is something an agent runs in a
			# tool call, and a blocking loop there hangs the manager's own turn
			# until the harness times out — the one session in the system that
			# must stay responsive. A human typing it loses their terminal to a
			# process that prints nothing. So the default hands off to the tmux
			# server and reports; `--daemon` is the loop itself.
			_apex_watch_check_knobs
			if pid=$(_apex_watch_running "$manager"); then
				print "watch: already running (pid $pid) for $manager"
				return 0
			fi
			_apex_watch_start "$manager"
			local i
			for i in 1 2 3 4 5 6 7 8 9 10; do
				sleep 0.1
				pid=$(_apex_watch_running "$manager") && break
			done
			if [[ -n $pid ]]; then
				print "watch: started (pid $pid, interval ${APEX_WATCH_INTERVAL}s) for $manager"
			else
				print -u2 "watch: could not start a poller for $manager"
				return 1
			fi
			return 0 ;;
	esac

	# --daemon: the loop. One per manager.
	_apex_watch_check_knobs
	apex_init_dirs "$manager"
	local pidfile
	pidfile=$(_apex_watch_pidfile "$manager")

	# Claim the pidfile with noclobber rather than checking-then-writing: two
	# concurrent starts both pass a prior `_apex_watch_running` check, and the
	# second `>` would overwrite the first daemon's pid, orphaning a loop with
	# nothing left able to stop it. An existing file whose pid is dead or not
	# ours is stale — `_apex_watch_running` unlinks those — so retry once.
	local claimed=false
	local i
	for i in 1 2; do
		if ( set -o noclobber; printf '%d\n' "$$" > "$pidfile" ) 2>/dev/null; then
			claimed=true
			break
		fi
		if pid=$(_apex_watch_running "$manager"); then
			print "watch: already running (pid $pid) for $manager"
			return 0
		fi
	done
	if ! $claimed; then
		print -u2 "watch: could not claim $pidfile"
		return 1
	fi

	# Only remove the pidfile if it is still ours; a successor that claimed it
	# after us must not be unlinked on our way out.
	trap 'if [[ $(cat "$pidfile" 2>/dev/null) == $$ ]]; then rm -f "$pidfile"; fi; exit 0' EXIT INT TERM

	_apex_watch_save "$manager" "$(jq -nc \
		--argjson i "$APEX_WATCH_INTERVAL" \
		--argjson g "$APEX_WATCH_BOX_GRACE" \
		--argjson r "$APEX_WATCH_RENUDGE" \
		'{interval:$i, box_grace:$g, renudge:$r}')"
	apex_event "$manager" "$(jq -nc --argjson i "$APEX_WATCH_INTERVAL" \
		'{event:"watch-start", interval:$i}')"

	while true; do
		# A failing sleep is indistinguishable from a slept second to the loop,
		# so it would spin a core running full ticks. Retire instead.
		sleep "$APEX_WATCH_INTERVAL" || break
		# Stop when the manager goes away or steps out of apex mode, so `stop`
		# and a killed session both retire the watcher without extra plumbing.
		tmux has-session -t "=$manager" 2>/dev/null || break
		[[ $(_sopt "$manager" @apex_role) == manager ]] || break
		_apex_watch_tick "$manager" >/dev/null 2>&1 || true
	done
	# The EXIT trap unlinks the pidfile, and only if it is still ours.
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

	# The watcher is what turns those hooks from "fires on the manager's own
	# turns" into "fires when a worker actually changes state" (issue #14).
	# Advisory only: its absence is a latency problem, not a delivery one, so
	# it does not change doctor's exit code.
	# Resolve like every other command rather than using the current session, so
	# that running doctor from a worker pane reports the *manager's* poller
	# instead of claiming there isn't one.
	local watch_line pid mgr iv
	mgr=$(_resolve_manager 2>/dev/null) || mgr=""
	if [[ -n $mgr ]] && pid=$(_apex_watch_running "$mgr" 2>/dev/null); then
		iv=$(_apex_watch_state "$mgr" interval); [[ -z $iv ]] && iv='?'
		watch_line="Fast poller: running (pid $pid, ${iv}s) for $mgr."
	else
		watch_line="Fast poller: NOT running${mgr:+ for $mgr} — the manager will only
  notice member transitions on its own turns. Start it with '${SELF} watch'
  (init does this automatically, and relink restarts it on every manager hook)."
	fi

	if (( ${#missing} == 0 )); then
		$quiet || print "Ping delivery: all hooks wired (${(j:, :)present})."
		$quiet || print "$watch_line"
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
	print -u2 "$watch_line"
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
	watch)    shift; _cmd_watch "$@" ;;
	reap)     shift; _cmd_reap "$@" ;;
	recover)  shift; _cmd_recover "$@" ;;
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
		print "  watch [--status|--stop|--once] start the background poller that nudges the"
		print "                                 manager ~1s after a member goes idle/attention"
		print "                                 (returns immediately; --once runs one tick)"
		print "  reap [--yes] [--force]         clean up finished/dead members"
		print "                                 (--force also takes members with"
		print "                                  uncommitted or unpushed work)"
		print "  recover [--yes] [member ...]   re-create dead members' panes, resuming"
		print "                                 their conversations (after a tmux crash)"
		print "  profiles                       list available spawn profiles"
		print "  doctor                         check that ping-delivery hooks are wired"
		[[ -n ${1:-} ]] && exit 1
		;;
esac
