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
#              profiles watch doctor authority

SELF="${0:A}"
SCRIPTS="${SELF:h}"

source "${SCRIPTS}/lib/apex-state.sh"
source "${SCRIPTS}/lib/apex-authority.sh"
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

# _attention_reason_of <capture> — why a member showing "needs attention" is
# showing it, as "<reason>\t<detail>".
#
# `@agent_needs_attention` is a boolean, and three very different situations
# set it: a worker blocked at a permission/safety dialog it cannot dismiss
# itself, a worker that just ended its turn at an empty prompt, and a worker
# that finished and is waiting for follow-up. Only the first needs a decision
# *now*, and only the first produces no further transitions — so it also
# produces no further pings, which is how one sat blocked for seven hours
# while `status` reported it correctly the whole time (issue #63).
#
# Reasons:
#   permission-prompt  a modal choice dialog is on screen; the detail carries
#                      its text so the manager can answer without capturing
#                      the pane by hand.
#   interrupted        the box is idle, but the last thing the pane printed
#                      says the turn died mid-response — an API error, or
#                      Claude Code's own "your computer went to sleep
#                      mid-response, the response above may be incomplete".
#                      The agent is alive and will not continue on its own.
#   idle               no dialog, no error notice, input box on screen.
#   unknown            none of those could be established — no capture, no
#                      box, or something on screen this does not recognise.
#
# `unknown` is deliberately its own answer and never folds into `idle`: the
# reassuring case is the one that gets ignored, and the whole defect here was
# a manager reading a state that could not distinguish "fine" from "stuck".
# `interrupted` exists for the same reason — an interrupted turn leaves a
# pane that looks exactly like a clean end-of-turn from outside, sets the
# same flag, and likewise produces no further transitions and so no further
# ping. It is a distinct reason because the manager's read of it differs:
# clean idle is self-resolving, an interrupted turn needs a send, and often
# has uncommitted work behind it.
#
# Matching is on the dialog's own rendered shape rather than on any message
# text we choose, because the text belongs to the agent, not to us. Claude
# Code draws it inside the same box as the prompt:
#
#     ╭─────────────────────────────────────────╮
#     │ Bash command                            │
#     │   rm -f $TMPDIR/*                       │
#     │ Do you want to proceed?                 │
#     │ ❯ 1. Yes                                │
#     │   2. No, and tell Claude what to do (esc)│
#     ╰─────────────────────────────────────────╯
#
# so the load-bearing signal is the numbered choice list *inside the box*,
# with the selection caret Claude Code always renders on exactly one of them —
# or, as a fallback for a dialog whose caret did not render, one choice plus an
# explicit question line. A single numbered line is not enough (agent output is
# full of "1. do this"), being inside a box is not enough either (agents on
# this repo draw bordered tables with numbered rows), and requiring the
# question text alone would be worse still, since it is prose and prose gets
# reworded.
#
# The interrupted-turn notice has no shape to match on, only text, so that
# half is an explicit prefix list (_APEX_INTERRUPT_PATTERNS) against unframed
# lines. Prose does get reworded, which is why an unrecognised notice has to
# land in `idle` rather than being pretended away — the list is a way to catch
# the known cases early, not a claim to catch all of them. It errs in the same
# direction the dialog half does: a missed case reports a member as ordinarily
# idle, which is what it already looked like, whereas a false positive tells
# the manager to go send a worker that was fine.
# Lowercased line *prefixes* that mark a turn killed mid-response. Each one is
# how Claude Code has actually opened such a line on a stalled worker, matched
# case-insensitively so a reworded capitalisation does not silently drop a
# case, and anchored at the start of the line because unanchored they are
# short enough to occur in ordinary narration (see the match site below).
#
# "may be incomplete" was on this list and is not any more: it is the tail of
# the sleep notice, so the full notice still matches on its own opening, but
# on its own the phrase is something a worker writes about its own work.
#
# Each prefix is also kept short enough to survive the notice being *wrapped*
# across lines by a narrow pane — "your computer went to sleep" rather than
# "...mid-response", which a wrap can push onto the second line. The cost of a
# longer prefix is a silent false negative; the cost of this one is nothing,
# since nobody narrates that phrase about their own work.
#
# Not on the list, on purpose: "Interrupted by user" (a human stopped that
# turn deliberately — reporting it back to the manager as a fault would be
# reporting the manager to itself) and usage-limit notices (real stalls, but
# a send does not fix them, so they want their own reason and their own
# advice rather than being folded in here).
typeset -ga _APEX_INTERRUPT_PATTERNS=(
	'api error'
	'your computer went to sleep'
	'request was aborted'
)

_attention_reason_of() {
	setopt localoptions extendedglob
	# Same reason _box_line_of pins it: the box-drawing characters and the ❯
	# are multibyte, and under LC_ALL=C a bracket expression matches their
	# individual bytes instead — which is not an error, just a silently wrong
	# answer.
	local -x LC_ALL
	LC_ALL=$(_apex_utf8_locale)
	[[ -z $LC_ALL ]] && unset LC_ALL

	# `pat` is declared here rather than at its use site: a bare `local x` for
	# a name already local to the frame *prints* it in zsh, which on a loop
	# body means the function quietly emits "pat=..." lines into whatever is
	# reading it (tests/apex-status.test.sh guards exactly that).
	local cap="$1" line text pat
	local -a lines=(${(f)cap})
	(( ${#lines} > 30 )) && lines=(${lines[-30,-1]})

	local -i choices=0
	local question="" caret_seen="" sel_seen="" interrupt="" bare=""
	local -a detail=()
	for line in $lines; do
		local framed=""
		[[ $line == [[:space:]]#[│┃\|]* ]] && framed=1
		text=${line##[[:space:]]#[│┃|]}
		text=${text%[│┃|]}
		text=${${text##[[:space:]]##}%%[[:space:]]##}
		[[ -z $text ]] && continue

		# Every dialog signal below is gated on `framed`, because the dialog
		# is drawn inside the box and agent *output* is not. Ungated, an
		# ordinary end-of-turn recap — "Here is what I did: 1. Fixed the
		# parser 2. Added a test" — counts as a choice list and reports a
		# finished worker as blocked at a safety prompt. That is the mirror
		# image of the defect this function exists to fix, and it lands
		# somewhere worse than a wrong label: `_cmd_status` suppresses the
		# unsent-input warning for a permission-prompt member, so a
		# misclassification also hides a real stuck-send.
		if [[ -n $framed ]]; then
			# A numbered choice, with or without the selection caret:
			# "1. Yes", "❯ 2. No, and tell Claude ...". Tested before the
			# caret check, which the "❯ " would otherwise swallow.
			if [[ $text == ([❯\>][[:space:]]#|)<->.[[:space:]]* ]]; then
				# Claude Code renders the selection caret on exactly one
				# choice, and a table does not have one. `framed` alone only
				# asks "is this inside a box", and agents on this repo draw
				# boxes constantly — a bordered table with numbered rows was
				# still reading as a blocked safety dialog.
				[[ $text == [❯\>]* ]] && sel_seen=1
				# Pre-increment: `choices++` evaluates to the *old* value, so
				# the first one exits non-zero, and this function is sourced
				# into the test suite's shell, which runs under `err_return`
				# — the count would return out of the function at the first
				# choice line and every dialog would classify as idle. Found
				# that way.
				(( ++choices ))
				continue
			fi
		fi
		# A caret line means the input box is drawn and accepting input, which
		# is what tells "idle" apart from "unknown". It is never detail: it is
		# the frame, not the question.
		if [[ $text == [\>❯][[:space:]]* || $text == [\>❯] ]]; then
			caret_seen=1
			continue
		fi
		if [[ -n $framed ]]; then
			# The question line is pulled out and re-appended last, so the
			# detail reads operation-then-question however the dialog
			# ordered it.
			if [[ $text == *\? ]]; then
				question=$text
				continue
			fi
			# Everything else inside the box is what the dialog is *about* —
			# the tool name and the command it wants to run. That is the text
			# the decision actually turns on, so it is what the detail
			# reports.
			detail+=("$text")
			continue
		fi

		# Unframed, i.e. transcript output. Interrupted-turn notices are
		# printed here; a member that merely typed the phrase into its own
		# input box has not been interrupted by anything.
		#
		# Matched as a line *prefix*, not a substring. Claude Code prints
		# these on a line of their own, and the phrases are short enough to
		# occur in ordinary prose — "a retry wrapper so an API error no
		# longer aborts the poller" is the kind of sentence a worker on this
		# repo writes at the end of a perfectly healthy turn, and reading it
		# as a dead turn produces a spurious `send`. Anchoring costs a real
		# notice only if Claude Code starts prefixing them with text, which
		# leaves the member in `idle` — the direction this errs in already.
		#
		# Leading decoration is stripped first, so a bulleted or gutter-marked
		# notice ("· API Error: 500") still matches.
		bare=${text##[^[:alnum:]]##}
		for pat in $_APEX_INTERRUPT_PATTERNS; do
			if [[ ${bare:l} == ${pat}* ]]; then interrupt=$bare; break; fi
		done
	done

	# Two arms, and the caret is what makes the first one safe. The second
	# stays uncaret-ed on purpose: it is the fallback for a dialog whose caret
	# did not render, and it pays for that looseness with an explicit question
	# line, which a table has no reason to carry.
	if { (( choices >= 2 )) && [[ -n $sel_seen ]] } \
	   || { (( choices >= 1 )) && [[ -n $question ]] }; then
		local d
		# Oldest-first, capped: the dialog's first lines name the tool and the
		# operation, and a ping line has to stay a line. Capped before the
		# question is appended, so the question is never the thing that gets
		# dropped — it is the part that says what is being asked.
		(( ${#detail} > 3 )) && detail=(${detail[1,3]})
		[[ -n $question ]] && detail+=("$question")
		d=${(pj: | :)detail}
		(( ${#d} > 220 )) && d="${d[1,217]}..."
		print -r -- "permission-prompt	${d}"
		return 0
	fi
	# A live dialog outranks an error notice above it: the dialog is the thing
	# blocking *now*, and answering it is what unblocks the pane either way.
	if [[ -n $interrupt ]]; then
		local d=$interrupt
		(( ${#d} > 220 )) && d="${d[1,217]}..."
		print -r -- "interrupted	${d}"
		return 0
	fi
	if [[ -n $caret_seen ]]; then
		print -r -- "idle	"
		return 0
	fi
	print -r -- "unknown	"
}

# _pane_attention_reason <pane> — _attention_reason_of against a live pane.
# Answers "unknown" rather than failing when the pane cannot be read: a
# member whose pane has gone is a member whose reason is genuinely not known.
_pane_attention_reason() {
	local pane="$1" cap
	[[ -n $pane ]] || { print -r -- "unknown	"; return 0 }
	cap=$(tmux capture-pane -p -t "$pane" 2>/dev/null) || { print -r -- "unknown	"; return 0 }
	_attention_reason_of "$cap"
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

# _require_manager — the manager session every apex command's work belongs to,
# or a failure the caller MUST honour.
#
# The `_die` here cannot stop the caller on its own. Every callsite reads this
# through `manager=$(_require_manager)`, and a command substitution is a
# subshell: `exit 1` ends the subshell, the message reaches stderr, and the
# parent carries on with `manager=''` and a zero `$?`. That is how #67 happened
# — `spawn` printed "no apex manager", then went right on to create a tmux
# session and a worktree for an agent registered to nobody: absent from
# `status`, unreachable by `send`, invisible to `reap`, and still burning
# tokens in a worktree that later got pruned out from under it.
#
# So the contract is the callsite's: write `$(_require_manager) || exit 1`,
# never a bare `$(_require_manager)`.
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

# _commits_ahead <worktree> <branch> [--ask-remote] — how many commits HEAD is
# ahead of the remote, or the empty string when that genuinely cannot be
# determined. Never 0 as a stand-in for "could not tell".
#
# The obvious `rev-list --count @{upstream}..HEAD` is right when it works and
# useless when it does not. In an apex worktree the upstream is *configured*
# but frequently has no local remote-tracking ref, because `remote.origin.fetch`
# is narrowed to `main` (the same condition behind #31):
#
#   fatal: upstream branch 'refs/heads/apex-…' not stored as a remote-tracking branch
#
# The old code swallowed that with `|| echo 0`, so the failing form of the check
# returned the passing value — the vacuous pass. 0 then meant any of "fully
# pushed", "unpushed but no tracking ref", or "never pushed at all", and a
# manager reading `commits_ahead=0` off a ping line concluded the first, went
# looking for work that had been "lost", and nearly reported it lost (issue #57).
# Report unknown as unknown instead, and let the callers render it.
#
# `HEAD --not --remotes` is not the fallback: under a narrow refspec no
# origin/<worker-branch> ref ever exists, so it calls every commit on every
# worker branch unpushed forever — the mirror-image lie, argued out at length in
# `_reap_risk`. So ask the remote, the way `_reap_risk` does. That is a network
# round trip per member, which is why it is opt-in: `status` is invoked
# deliberately and can pay for it, while the per-hook path behind
# `_record_status` and `pending` runs constantly and takes the honest `null`.
#
# GIT_TERMINAL_PROMPT=0 so a repo whose remote wants credentials fails fast
# rather than blocking `status` on a prompt nobody will ever see.
_commits_ahead() {
	local wt="$1" branch="$2" ask=false a n="" out="" rc=0 remote_sha=""
	# Declared here, not at the point of use: `local` in an inner block risks
	# re-declaring a name that already exists in scope, which zsh answers by
	# printing the old value to stdout — the leak behind issue #53, and this
	# function's stdout *is* its return value.
	local -a allrefs=() others=()
	for a in "${@[3,-1]}"; do
		[[ $a == --ask-remote ]] && ask=true
	done

	# Order matters, and it is the reverse of the obvious one. `@{upstream}`
	# either fails (no tracking ref — the #57 case) or succeeds against a
	# *local* ref that a narrowed `remote.origin.fetch` never updates. A
	# lingering `refs/remotes/origin/<branch>` therefore makes the cheap query
	# succeed with a number derived from an arbitrarily old ref: too high if the
	# branch has been pushed since, too low if it was force-pushed from
	# elsewhere. Preferring it because it answered first would spend the network
	# round trip and then throw the good answer away — the same quiet-wrong-
	# number failure as #57, reached by a different route.
	#
	# So under --ask-remote the remote wins outright, and `@{upstream}` is only
	# the fallback for when the remote could not be reached at all. Without
	# --ask-remote there is nothing else to consult, so the local ref stands.
	if [[ $ask == true && -n $branch ]]; then
		out=$(GIT_TERMINAL_PROMPT=0 git -C "$wt" ls-remote origin "refs/heads/${branch}" 2>/dev/null) && rc=0 || rc=$?
		if (( rc == 0 )); then
			remote_sha=$(printf '%s' "$out" | cut -f1)
			if [[ -z $remote_sha ]]; then
				# The remote has no such branch, so this branch's own commits
				# genuinely are unpushed. `--not --remotes` subtracts the shared
				# history the branch inherited: a plain `rev-list --count HEAD`
				# counts every commit already sitting on origin/main too, so a
				# worker that made one commit reports the age of the repository
				# — hundreds here. That is the same unactionable number this
				# function exists to stop reporting, merely inverted from
				# understating to wildly overstating.
				#
				# `--remotes` is safe *here* specifically, and the standing
				# argument against it does not apply: we have just confirmed via
				# the remote that this branch is absent there, so `--remotes` is
				# only being used to subtract shared history, never to decide
				# whether anything is pushed. (That decision is what it gets
				# wrong under a narrow refspec — issue #31.)
				#
				# It can still overcount slightly under that same narrow
				# refspec: a commit pushed to some *other* worker branch has no
				# local remote ref to be subtracted by. That residual is bounded
				# by the branch's own divergence and errs toward "look at this",
				# which is the safe direction; the whole-history figure was
				# neither bounded nor informative.
				#
				# One ref must be held out of the subtraction, though: a stale
				# `refs/remotes/origin/<branch>` for the branch being measured.
				# We have just established via the remote that this branch is
				# absent there, so that ref is known-wrong — and a plain
				# `--remotes` would use it to cancel out the branch's own
				# commits and report 0, the one value this whole function exists
				# to stop emitting. Reachable whenever a worktree holds an
				# `origin/<branch>` ref the remote no longer does: a default
				# refspec, or an explicit fetch before the remote branch was
				# deleted.
				#
				# The list is explicit rather than `--exclude=… --remotes`,
				# which silently has no effect after `--not` (checked on git
				# 2.55). Ref names cannot contain `*`, `?` or `[`, so the branch
				# name is safe as a zsh removal pattern.
				allrefs=("${(@f)$(git -C "$wt" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)}")
				others=(${${allrefs:#refs/remotes/origin/${branch}}:#})
				if (( ${#others} )); then
					n=$(git -C "$wt" rev-list --count HEAD --not "${others[@]}" 2>/dev/null) || n=""
				else
					# Nothing left to subtract means the only count available is
					# the whole reachable history — the unbounded figure. That
					# is not an answer, so say so.
					n=""
				fi
			elif git -C "$wt" cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
				n=$(git -C "$wt" rev-list --count HEAD --not "$remote_sha" 2>/dev/null) || n=""
			else
				# The remote answered and its tip is not an object we have, so
				# the ranges are not comparable. That is unknown, and it
				# deliberately does *not* fall through to `@{upstream}`: any
				# tracking ref that could answer here is by construction behind
				# the remote, so the fallback's number would be precisely the
				# misleading one. Unreachable remote falls back;
				# answered-but-incomparable does not.
				return 0
			fi
			printf '%s' "$n"
			return 0
		fi
		# rc != 0: offline, no such remote, auth refused. Fall through.
	fi

	n=$(git -C "$wt" rev-list --count '@{upstream}..HEAD' 2>/dev/null) || n=""
	printf '%s' "$n"
}

# _member_facts <session> [--with-pane-input] — a JSON object of live,
# derived state.
#
# pane_input costs a capture-pane per member and only `status` displays it, so
# it is opt-in: `pending` runs on every agent hook and does not need it.
_member_facts() {
	local session="$1" wt branch pr_number pr_state pr_draft icons ahead dirty alive
	local want_pane_input=false want_remote=false a
	for a in "${@[2,-1]}"; do
		[[ $a == --with-pane-input ]] && want_pane_input=true
		[[ $a == --with-remote ]] && want_remote=true
	done
	alive=false
	_member_alive "$session" && alive=true

	wt=$(apex_member_get "$APEX_SESSION" "$session" worktree 2>/dev/null)
	[[ -z $wt || ! -d $wt ]] && wt=""

	# Empty, not 0: an unset `ahead` means "not knowable" and reaches jq as
	# null. Everything that reads .commits_ahead must handle null (issue #57).
	branch=""; ahead=""; dirty=false
	if [[ -n $wt ]]; then
		branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)
		[[ -n $(git -C "$wt" status --porcelain 2>/dev/null) ]] && dirty=true
		if $want_remote; then
			ahead=$(_commits_ahead "$wt" "$branch" --ask-remote)
		else
			ahead=$(_commits_ahead "$wt" "$branch")
		fi
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

	# Why the member wants attention, not just that it does (issue #63).
	# Computed only for members actually in the state, so the extra
	# capture-pane costs nothing on a team that is working — and computed
	# live here rather than stored at notify time, because the dialog can
	# render a beat after the hook fires and a stale snapshot of this field
	# is worse than none.
	local attn_reason="" attn_detail="" attn_pair
	if [[ -n $attention ]] && $alive; then
		local apane
		apane=$(_agent_pane "$session" 2>/dev/null)
		attn_pair=$(_pane_attention_reason "$apane" 2>/dev/null)
		attn_reason=${attn_pair%%$'\t'*}
		attn_detail=${attn_pair#*$'\t'}
		[[ -z $attn_reason ]] && attn_reason=unknown
	fi

	jq -nc \
		--arg session "$session" --arg wt "$wt" --arg branch "$branch" \
		--arg pr "$pr_number" --arg pr_state "$pr_state" --arg pr_draft "$pr_draft" \
		--arg icons "$icons" --argjson ahead "${ahead:-null}" \
		--argjson dirty "$dirty" --argjson alive "$alive" \
		--arg working "$working" --arg attention "$attention" \
		--arg attn_reason "$attn_reason" --arg attn_detail "$attn_detail" \
		--arg pane_input "$pane_input" \
		'{session:$session, alive:$alive, worktree:$wt, branch:$branch,
		  pane_input:$pane_input,
		  attention_reason:$attn_reason, attention_detail:$attn_detail,
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
		  (if .branch == "" then empty
		   elif .commits_ahead == null then "commits_ahead=unknown(unpushed?)"
		   else "commits_ahead=" + (.commits_ahead|tostring) end),
		  (if .dirty then "uncommitted-changes" else empty end),
		  (if .alive|not then "SESSION-DEAD" else empty end)
		] | join(" ")'
}

# ─── merge authority ─────────────────────────────────────────────────

# _apex_interactive — is there a human at the other end of this run?
#
# Both ends have to be a terminal: init is also run from a Claude Code hook and
# from `relink`, where stdin is closed or a pipe, and a `read` there either
# returns instantly (looking like an answer nobody gave) or blocks a session
# start forever. APEX_ASSUME_NONINTERACTIVE is the escape hatch for tests and
# for anyone scripting init.
_apex_interactive() {
	[[ -z ${APEX_ASSUME_NONINTERACTIVE:-} ]] || return 1
	[[ -t 0 && -t 1 ]]
}

# _apex_grant_allowed — may *this* run hand out authority?
#
# The skill says the grant is the human's to give and that granting it to itself
# is the one move that empties it of meaning. That was only ever wording, and an
# agent with a shell can run `authority --grant` as easily as a human can, so the
# wording now has a mechanism behind it: a grant needs a terminal at both ends,
# which an agent invoking the script from a tool call does not have.
#
# It gates grants only. Revoking needs no ceremony — it moves toward the default,
# and anything that makes taking authority away harder than giving it is backwards.
#
# APEX_AUTHORITY_UNATTENDED_GRANT is the deliberate opt-out for provisioning
# scripts and config management, where the human's decision is in the script.
# Naming it in the refusal keeps the gate honest: it is a speed bump against an
# agent granting itself authority in passing, not a security boundary, and
# pretending otherwise would be the more dangerous claim.
_apex_grant_allowed() {
	_apex_interactive && return 0
	[[ -n ${APEX_AUTHORITY_UNATTENDED_GRANT:-} ]]
}

# _apex_ask_merge_authority <repo-key> <session> <main-tree>
# Only ever called behind _apex_interactive. Every non-answer — a bare newline,
# an unrecognised word, EOF from a terminal that went away mid-question — is
# recorded as `no`, because the point of asking is to reach a decision and the
# only safe decision without one is the ungranted default.
_apex_ask_merge_authority() {
	local rkey="$1" session="$2" main="$3" reply="" ans=no self=no
	print ""
	print "Apex merge authority is not set for this repo. It defaults to NOT granted."
	print "  repo: $main"
	print "  key : $rkey"
	print ""
	print "Granted, apex may merge a PR that meets every criterion in its skill without"
	print "asking you first. Ungranted, it reports such a PR as ready-and-ineligible and"
	print "you merge it yourself; nothing else about apex changes."
	print ""
	print "Say yes only if merging here is genuinely yours to delegate. On a repo with"
	print "other contributors, an agent merge cuts across review expectations that no"
	print "mechanical criterion can see."
	print -n "Grant apex merge authority in this repo? [y/N] "
	if ! read -r reply; then print ""; reply=""; fi
	ans=$(apex_authority_normalise "$reply" 2>/dev/null) || ans=no

	# The second axis is only worth a question once the first is yes: ungranted,
	# self-review authorises nothing, and asking about it would be asking a
	# human to rule on a hypothetical.
	if [[ $ans == yes ]]; then
		print ""
		print "Second question. Apex can review a PR two ways: spawn an independent"
		print "reviewer, or read it itself. The grant above covers merging a PR a"
		print "reviewer signed off on. Merging on the strength of apex's own reading"
		print "is separate, and it is the weaker of the two — a reviewer that shares"
		print "the author's blind spots finds nothing the author missed."
		print -n "Also allow merging on apex's own review, with no second agent? [y/N] "
		if ! read -r reply; then print ""; reply=""; fi
		self=$(apex_authority_normalise "$reply" 2>/dev/null) || self=no
	fi

	apex_authority_set "$rkey" "$ans" "$session" "$main" "$self" \
		|| print -u2 "tmux-apex: warning — could not record the answer; it will be asked again"
	apex_event "$session" "$(jq -nc --arg k "$rkey" --arg a "$ans" --arg s "$self" \
		'{event:"merge-authority", repo_key:$k, merge:($a == "yes"),
		  self_review:($s == "yes"), source:"prompt"}')"
	print ""
	print "Recorded: $(apex_authority_describe "$ans" "$self")"
	print "Change it any time with '${SELF##*/} authority --grant|--revoke'"
	print "and '${SELF##*/} authority --self-review yes|no'."
}

# _cmd_authority [--grant|--revoke] [--self-review yes|no] [--ask] [--json]
#
# The read-back path the feature needs in order to be usable at all: an authority
# the agent cannot see is one it will forget it does not have. Keys on the repo
# rather than on a manager session, so a worker pane can check it too, and works
# from a linked worktree since every worktree shares the repo's origin.
_cmd_authority() {
	local want="" self="" ask=false as_json=false
	while (( $# )); do
		case "$1" in
			--grant)   want=yes; shift ;;
			--revoke)  want=no; shift ;;
			# --grant=WORD stays accepted so a script can pass a variable through
			# without branching on its value.
			--grant=*) want=$(apex_authority_normalise "${1#--grant=}" 2>/dev/null) \
				|| _die "authority: --grant takes yes|no (got '${1#--grant=}')"; shift ;;
			--self-review) _need_val authority --self-review $#
				self=$(apex_authority_normalise "$2" 2>/dev/null) \
					|| _die "authority: --self-review takes yes|no (got '$2')"; shift 2 ;;
			--self-review=*) self=$(apex_authority_normalise "${1#--self-review=}" 2>/dev/null) \
				|| _die "authority: --self-review takes yes|no (got '${1#--self-review=}')"; shift ;;
			--grant-self-review)  self=yes; shift ;;
			--revoke-self-review) self=no; shift ;;
			--ask)     ask=true; shift ;;
			--json)    as_json=true; shift ;;
			*) _die "authority: unknown option '$1'" ;;
		esac
	done
	[[ -n $want || -n $self ]] && $ask \
		&& _die "authority: --ask cannot be combined with --grant/--revoke/--self-review"

	local main rkey
	main=$(_main_tree) || true
	[[ -z $main ]] && _die "authority: not inside a git repository"
	rkey=$(apex_repo_key "$main") || _die "authority: cannot identify this repo"

	local session
	session=$(_cur_session 2>/dev/null) || session=""

	if [[ -n $want || -n $self ]]; then
		# Only grants are gated; either axis moving to `yes` is a grant.
		if [[ $want == yes || $self == yes ]] && ! _apex_grant_allowed; then
			_die "authority: granting needs a terminal — the grant is the human's to give,\
 and granting it to yourself empties it of meaning. Run this from a shell\
 prompt, or set APEX_AUTHORITY_UNATTENDED_GRANT=1 if a provisioning script\
 is carrying the human's decision. Revoking works from anywhere."
		fi
		# `--self-review` on its own has nothing to attach to until the merge
		# question has been answered, and it must not answer it by implication.
		# Backfilling the merge axis from `apex_authority_get` did exactly that:
		# `get` returns `no` both for "the human declined" and for "nobody has
		# been asked", so `--self-review no` on a fresh repo stored `merge:false`
		# and flipped `apex_authority_answered` to true — turning a pending
		# question into a recorded decline that nobody gave. `init` then stops
		# asking and `doctor` says "declined" instead of "never answered". Nothing
		# gained authority, but a `no` nobody said is indistinguishable from one
		# they did, which is the whole failure this feature exists to avoid.
		if [[ -z $want ]] && ! apex_authority_answered "$rkey"; then
			_die "authority: --self-review needs the merge question answered first —
 nobody has been asked about this repo, and --self-review must not answer for
 them. Run 'authority --ask', or pass --grant/--revoke alongside it."
		fi
		# Caught here rather than left to `apex_authority_set`'s return code, which
		# surfaced a flat contradiction as "could not write <file>" — an I/O error
		# for what is a contradictory request.
		if [[ $self == yes && $want == no ]]; then
			_die "authority: --revoke and --self-review yes contradict each other —
 self-review authorises nothing without merge authority, and revoking merge
 clears it. Pick one."
		fi
		# `--self-review yes` alone is refused rather than silently upgrading the
		# merge axis: self-review is not a way to acquire merge authority.
		if [[ $self == yes && -z $want ]] && ! apex_authority_may_merge "$rkey"; then
			_die "authority: --self-review yes needs merge authority first (it authorises
 nothing on its own). Grant merging too, or pass --grant with it."
		fi
		# An unspecified merge axis keeps its stored answer, so `--self-review no`
		# does not revoke merging as a side effect. Safe to read with `get` now:
		# the guard above established that the answer on record is a real one.
		local wmerge="$want"
		if [[ -z $wmerge ]]; then
			wmerge=$(apex_authority_get "$rkey")
		fi
		apex_authority_set "$rkey" "$wmerge" "$session" "$main" "$self" \
			|| _die "authority: could not write $(APEX_AUTHORITY_FILE)"
		[[ -n $session ]] && apex_event "$session" \
			"$(jq -nc --arg k "$rkey" --arg a "$wmerge" --arg s "$self" \
				'{event:"merge-authority", repo_key:$k, merge:($a == "yes"),
				  self_review:$s, source:"cli"}')"
	elif $ask; then
		_apex_interactive || _die "authority: --ask needs a terminal (use --grant or --revoke)"
		_apex_ask_merge_authority "$rkey" "$session" "$main"
	fi

	local ans sans answered=false
	ans=$(apex_authority_get "$rkey")
	sans=$(apex_authority_get "$rkey" self_review)
	apex_authority_answered "$rkey" && answered=true

	if $as_json; then
		jq -nc --arg k "$rkey" --arg r "$main" --arg f "$(APEX_AUTHORITY_FILE)" \
			--argjson merge "$([[ $ans == yes ]] && print true || print false)" \
			--argjson self_review "$([[ $sans == yes ]] && print true || print false)" \
			--argjson answered "$answered" \
			'{repo:$r, repo_key:$k, merge:$merge, self_review:$self_review,
			  answered:$answered, file:$f}'
		return 0
	fi

	print "repo     : $main"
	print "repo key : $rkey"
	print "authority: $(apex_authority_describe "$ans" "$sans")"
	$answered || print "           (never answered for this repo — the default stands)"
	print "recorded : $(APEX_AUTHORITY_FILE)"
	if [[ $ans == yes ]]; then
		print "revoke   : ${SELF##*/} authority --revoke"
		if [[ $sans == yes ]]; then
			print "           ${SELF##*/} authority --self-review no   (keep merging, drop self-review)"
		else
			print "self-rev : ${SELF##*/} authority --self-review yes"
		fi
	else
		print "grant    : ${SELF##*/} authority --grant"
	fi
	return 0
}

# _apex_authority_repo <manager> — the repo a manager's authority is keyed on.
#
# Fails rather than falling back to $PWD. The fallback was wrong in the one
# direction that matters: `status`/`doctor` run from an unrelated repo that
# happens to be granted would report the manager as having authority it does not
# have, which is a fail-*open* answer inside a fail-closed feature. Callers
# render the failure as `unknown` and treat it as no authority.
_apex_authority_repo() {
	setopt localoptions no_err_return
	local manager="$1" repo=""
	[[ -n $manager ]] || return 1
	repo=$(jq -r '.repo // empty' "$(apex_file "$manager")" 2>/dev/null) || return 1
	[[ -n $repo && -d $repo ]] || return 1
	print -r -- "$repo"
}

# _apex_status_authority <manager> [axis] — `yes`/`no`/`unknown` for the
# manager's repo. Resolved from the manager's recorded repo, so `status` run
# inside a worker worktree still reports the manager's authority.
_apex_status_authority() {
	setopt localoptions no_err_return
	local manager="$1" axis="${2:-merge}" repo key
	repo=$(_apex_authority_repo "$manager") || { print -r -- unknown; return 0 }
	key=$(apex_repo_key "$repo" 2>/dev/null) || key=""
	[[ -n $key ]] || { print -r -- unknown; return 0 }
	apex_authority_get "$key" "$axis"
}

# ─── init / stop ─────────────────────────────────────────────────────

_cmd_init() {
	local force=false grant="" raw="" saw_merge=false
	local selfgrant="" selfraw="" saw_self=false
	while (( $# )); do
		case "$1" in
			--force) force=true; shift ;;
			--merge) _need_val init --merge $#; raw="$2"; saw_merge=true; shift 2 ;;
			--merge=*) raw="${1#--merge=}"; saw_merge=true; shift ;;
			--self-review) _need_val init --self-review $#; selfraw="$2"; saw_self=true; shift 2 ;;
			--self-review=*) selfraw="${1#--self-review=}"; saw_self=true; shift ;;
			*) shift ;;
		esac
	done
	# Validated on the flag having been *seen*, not on its value being non-empty:
	# `--merge ''` is a mistake worth naming, and the old guard let it through to
	# be silently treated as "no flag given", i.e. as the default answer.
	if $saw_merge; then
		grant=$(apex_authority_normalise "$raw" 2>/dev/null) \
			|| _die "init: --merge takes yes|no (got '$raw')"
	fi
	if $saw_self; then
		selfgrant=$(apex_authority_normalise "$selfraw" 2>/dev/null) \
			|| _die "init: --self-review takes yes|no (got '$selfraw')"
		# Only reaches storage alongside an explicit --merge, so on its own it was
		# parsed, validated, and then silently dropped — and `--self-review no` on
		# a repo where self-review *is* granted read as a revocation that never
		# happened. Same bug as `--merge ''`, on the sibling flag, and the same
		# rule settles it: a flag that was seen either takes effect or is named as
		# an error. Named here rather than honoured, because standalone axis edits
		# are what `authority --self-review` is for, and doing them from `init`
		# would mean re-deriving the stored merge answer in a second place.
		$saw_merge || _die "init: --self-review needs --merge (change it on its own with
 '${SELF##*/} authority --self-review ${selfgrant}')"
		[[ $selfgrant == yes && $grant != yes ]] \
			&& _die "init: --self-review yes needs --merge yes (it authorises nothing alone)"
	fi
	if [[ $grant == yes || $selfgrant == yes ]] && ! _apex_grant_allowed; then
		_die "init: --merge yes needs a terminal, or APEX_AUTHORITY_UNATTENDED_GRANT=1
 if a provisioning script is carrying the human's decision. Merge authority is
 the human's to give; an init running from a hook is not the human."
	fi

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

	# Merge authority is a per-repo decision with a default of "not granted"
	# (issue #41). Settled here because init is where a human is most likely to
	# be watching, but it must never *depend* on one: init also runs from hooks
	# on session recreation, and a prompt that hangs an unattended start is worse
	# than not having the feature. So: an explicit --merge wins, an
	# already-answered repo is left alone, and a question we cannot ask
	# interactively is simply not asked — the unanswered default is no authority.
	local rkey rans rself
	rkey=$(apex_repo_key "$main") || rkey=""
	if [[ -n $rkey ]]; then
		if [[ -n $grant ]]; then
			apex_authority_set "$rkey" "$grant" "$session" "$main" "$selfgrant" \
				|| print -u2 "tmux-apex: warning — could not record the merge grant; it will be asked again"
			apex_event "$session" "$(jq -nc --arg k "$rkey" --arg a "$grant" --arg s "$selfgrant" \
				'{event:"merge-authority", repo_key:$k, merge:($a == "yes"),
				  self_review:$s, source:"flag"}')"
		elif ! apex_authority_answered "$rkey" && _apex_interactive; then
			_apex_ask_merge_authority "$rkey" "$session" "$main"
		fi
		rans=$(apex_authority_get "$rkey")
		rself=$(apex_authority_get "$rkey" self_review)
	else
		rans=no
		rself=no
	fi

	tmux refresh-client -S 2>/dev/null
	print "Apex manager active."
	print "  session : $session"
	print "  repo    : $main"
	print "  pane    : ${TMUX_PANE:-<unknown>}"
	print "  state   : $(apex_dir "$session")"
	print "  authority: $(apex_authority_describe "$rans" "$rself")"
	[[ -n $rkey ]] && print "  repo key : $rkey"
	if [[ $rans == no && -n $rkey ]] && ! apex_authority_answered "$rkey"; then
		print "  (nobody has been asked about this repo yet — grant with:"
		print "   ${SELF##*/} authority --grant)"
	fi

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
# Merge authority (issue #41) needs no re-deriving here, by construction: it is
# keyed on the repo and stored once at $APEX_ROOT/authority.json, and every
# reader resolves it on demand rather than caching it onto a tmux option. So a
# recreated session cannot silently revert to the ungranted default the way a
# lost @apex_role loses a manager — there is nothing session-shaped to lose.
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

# ─── autonomous-mode / permission-mode reconciliation (issue #43) ─────
#
# `spawn` carries two independent knobs that used to be set from different
# places and compared nowhere: `--mode` (autonomous|interactive, defaulting to
# autonomous) and the permission mode / agent flags (`--agent-flags`, or a named
# `--profile`'s `agent_flags`). `--mode autonomous` hands the agent a managed
# prompt telling it to work to completion unattended, while `acceptEdits` — the
# value three shipped profiles use — pauses for approval on every shell command.
# The pair is a contradiction: the worker stalls on its first `git` call and no
# one is watching. Reconcile (or refuse) it where it is created, so a new
# profile or a hand-rolled --agent-flags string cannot reintroduce it.
#
# Note the ceiling on what any of this can promise: claude's own safety
# classifier gates dangerous operations regardless of permission mode, so even
# `bypassPermissions` can sit on a modal prompt. Making a blocked worker
# *visible* is issue #63; this guard only removes the guaranteed-to-block
# combinations.

# _perm_unattended <perm> [agent] — can a run with these agent flags proceed
# without a human at the keyboard?
#   0 = yes, 1 = no (it will prompt), 2 = unknown (agent-native argv we can't judge)
_perm_unattended() {
	local perm="$1" agent="${2:-claude}"

	# Flags are classified per agent, never universally: a marker one agent
	# treats as "skip every gate" is an unknown argument to another, and the
	# agent that rejects it falls back to prompting — the very stall this guard
	# exists to prevent. Only flags this repo documents (README's agent-flags
	# table) are classified at all; everything else is "unknown", not a guess.
	if [[ ${agent:t} == claude ]]; then
		[[ " $perm " == *" --dangerously-skip-permissions "* ]] && return 0
		if [[ $perm == -* ]]; then
			# argv form: only a --permission-mode token is classifiable.
			[[ $perm != *--permission-mode[\ =]* ]] && return 2
			perm="${${perm##*--permission-mode[ =]}%% *}"
		fi
		case "$perm" in
			bypassPermissions)              return 0 ;;
			# Empty means "claude's default", which prompts for every tool use.
			""|default|acceptEdits|plan)    return 1 ;;
			*)                              return 2 ;;
		esac
	fi

	# Non-claude adapters take agent-native argv. Only the flags whose meaning
	# this repo actually documents (README's agent-flags table) are classified;
	# anything else is "unknown" rather than a guess.
	case "${agent:t}" in
		codex)
			[[ " $perm " == *" --dangerously-bypass-approvals-and-sandbox "* ]] && return 0
			[[ " $perm " == *" --ask-for-approval never "* ]] && return 0
			[[ " $perm " == *" -a never "* ]] && return 0
			# on-request/untrusted are documented as asking a human.
			[[ " $perm " == *" --ask-for-approval "* ]] && return 1 ;;
		opencode)
			[[ " $perm " == *" --auto "* ]] && return 0 ;;
	esac
	return 2
}

# _spawn_check_mode <mode> <perm> <agent> <perm_from_profile> — refuse or flag
# the contradiction. Prints a warning for the unknown case; dies for the
# known-bad one. Callers pass the *resolved* values, i.e. after --profile has
# been merged, plus the profile name only when the profile is where `perm`
# actually came from: an explicit --agent-flags wins that merge field-by-field,
# so attributing its value to the named profile would send the caller to edit
# the wrong knob.
_spawn_check_mode() {
	local mode="$1" perm="$2" agent="${3:-claude}" profile="$4"
	local shown="${perm:-<agent default>}"
	local src="--agent-flags ${perm}"
	[[ -z $perm ]] && src="no --agent-flags"
	[[ -n $profile ]] && src="profile '${profile}' (agent_flags=${shown})"

	[[ $mode == autonomous || $mode == interactive ]] || \
		_die "spawn: --mode must be 'autonomous' or 'interactive', got '${mode}'"

	[[ $mode == autonomous ]] || return 0

	_perm_unattended "$perm" "$agent"
	case $? in
		0) return 0 ;;
		2) print -u2 "tmux-apex: spawn: --mode autonomous with ${src} for agent '${agent:t}' — cannot verify these flags run unattended; the worker may stall on an approval prompt (see issue #63)"
		   return 0 ;;
	esac

	_die "spawn: --mode autonomous conflicts with permission mode '${shown}' (from ${src}).
  An autonomous worker is told to work to completion with no human watching, but
  '${shown}' pauses for approval on shell commands — it would stall on its first
  git call. Pick one:
    --agent-flags bypassPermissions   run it unattended (overrides the profile)
    --mode interactive                keep the approval prompts and watch it yourself
  Even bypassPermissions can still block on claude's safety classifier; see issue #63."
}


_cmd_spawn() {
	local issue="" review_pr="" role="worker" model="" perm="" mode="autonomous"
	local switch="no-switch" agent="" profile="" perm_profile=""

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
		# perm_profile records whether the profile is what supplied `perm`, so
		# the mode/permission-mode refusal below can name the knob the caller
		# would actually have to change.
		[[ -z $perm  ]] && { perm=$(jq -r '.agent_flags // empty' <<< "$pjson"); perm_profile="$profile" }
	fi

	# Only the claude adapter accepts a bare token here (it prepends
	# --permission-mode). Every other agent gets the value as verbatim argv, so a
	# bare token would arrive as a stray positional and silently derail the
	# spawn. Refuse it loudly instead.
	if [[ -n $perm && $perm != -* && -n $agent && ${agent:t} != claude ]]; then
		_die "spawn: --agent-flags for '${agent}' must be agent-native argv (e.g. --approve, --full-auto), not the claude token '${perm}'"
	fi

	_spawn_check_mode "$mode" "$perm" "${agent:-claude}" "$perm_profile"

	local manager
	manager=$(_require_manager) || exit 1
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
	print "  mode     : ${mode}"
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
	APEX_SEND_TEXT=""
	[[ -z $target || -z $text ]] && return 1
	_member_alive "$target" || return 1

	local full="[apex from:${from:-manager}] ${text}"
	# What was actually typed, sender tag and all. A caller that needs to
	# recognise its own message in the input box later cannot reconstruct this
	# from the text it passed in — and comparing the untagged text against a
	# tagged box read fails, which reads as "the box drained" (issue #49).
	APEX_SEND_TEXT="$full"

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
#   pair_worker_head  remote tip of the worker's branch when its turn began;
#                   unchanged at its idle means it pushed nothing (issue #48)
#   pair_message    text for `pending` to surface. Either a terminal
#                   escalation (pair_state complete | stuck), or the
#                   non-terminal no-push advisory of issue #48, which
#                   leaves the loop active and the turn where it was
#   verdict_round / verdict_findings / verdict_note   last recorded verdict
#   verdict_override  "1" iff that verdict bypassed the published-comment guard
#   verdict_channel   "inline" | "issue" | "both" — which comment channel the guard
#                   found that verdict's findings in, so the relay can point
#                   the fixer at that one rather than at both (issue #60)

APEX_PAIR_MAX_ROUNDS=${APEX_PAIR_MAX_ROUNDS:-5}
# Wall-clock bound, in seconds, on the one `ls-remote` the loop makes per
# turn (see `_pair_pushed_head`). Overridable so the tests can exercise the
# timeout path without waiting on it.
#
# Validated, because a set-but-nonsense value is the vacuous pass that
# `_commits_ahead` argues against — the failing form of the check returning
# the passing value. `0` is the conventional spelling of "no timeout" and
# would do the exact opposite: `sleep 0` returns at once, so the watchdog
# TERMs git immediately, every probe reports 124, and the whole issue #48
# branch-moved check fails open on every turn while looking like it is
# running. A non-numeric value fails the same way, via `sleep`'s own error.
#
# The upper bound is the same failure in the other direction: a "bound" past
# the transport's own timeout never fires, so it silently is not a bound.
# 300s is far beyond any honest `ls-remote`.
#
# And validated by falling back rather than by `_die`, because this is read
# on the unattended settle path, where dying is a loop that has silently
# stopped. A nonsense knob should cost the operator their setting, not the
# feature. The warning is unconditional so it is at least visible from any
# foreground command, but it is not fatal to any of them.
if [[ ${APEX_PAIR_HEAD_TIMEOUT-} != <-> ]] || (( APEX_PAIR_HEAD_TIMEOUT < 1 || APEX_PAIR_HEAD_TIMEOUT > 300 )); then
	[[ -n ${APEX_PAIR_HEAD_TIMEOUT-} ]] && print -u2 "tmux-apex: WARNING — ignoring APEX_PAIR_HEAD_TIMEOUT=${APEX_PAIR_HEAD_TIMEOUT} (want an integer 1-300 seconds); using 5"
	APEX_PAIR_HEAD_TIMEOUT=5
fi

# The non-note, non-override branch names *one* channel — the one the guard
# actually found the findings in (issue #60). Naming both let the fixer be
# sent to `pulls/N/comments` on a review that only posted an issue-level
# summary, where that endpoint returns 0: from the fixer's side, identical to
# findings that were never published at all.
_pair_worker_msg() {
	local pr="$1" round="$2" findings="$3" note="$4" override="$5" channel="$6"
	if [[ -n $note ]]; then
		print -r -- "PAIRED REVIEW round ${round}: the reviewer on PR #${pr} recorded ${findings} finding(s) worth addressing, noted inline (no PR comments were required for this verdict): \"${note}\". Fix every BUG/CONCERN finding and push to the PR branch; for anything you disagree with, reply on that review thread saying why rather than silently skipping it. Do NOT message the manager or wait for a human — when your commits are pushed, just stop. The reviewer is re-invoked automatically."
	elif [[ $override == 1 ]]; then
		print -r -- "PAIRED REVIEW round ${round}: the reviewer on PR #${pr} recorded ${findings} finding(s) worth addressing, asserted via --override — the findings were NOT published anywhere and no note was left, so there is nothing to read on the PR. Do not go hunting for comments. Reply on the review thread asking the reviewer to state the findings, or otherwise get them from the reviewer directly, before treating this as actionable. Do NOT message the manager or wait for a human beyond that. The reviewer is re-invoked automatically."
	else
		local where
		case "$channel" in
			inline) where="They are inline review comments, anchored to a file and line: read them with 'gh api repos/{owner}/{repo}/pulls/${pr}/comments'." ;;
			both)   where="Some are inline review comments anchored to a file and line and some are issue-level comments on the PR: read both with 'gh api repos/{owner}/{repo}/pulls/${pr}/comments' and 'gh pr view ${pr} --comments'." ;;
			issue)  where="They are issue-level comments on the PR, not inline ones: read them with 'gh pr view ${pr} --comments' ('gh api repos/{owner}/{repo}/pulls/${pr}/comments' returns nothing for this round, which is expected)." ;;
			# No channel recorded: a verdict from before verdict_channel
			# existed, i.e. a pair linked across this upgrade. Name both
			# endpoints and say the channel is unknown — `gh pr view
			# --comments` does *not* surface inline review comments (see
			# _pair_comment_counts), so claiming it covers both would
			# relocate the very #60 failure this branch fixes.
			*)      where="Check both 'gh pr view ${pr} --comments' and 'gh api repos/{owner}/{repo}/pulls/${pr}/comments' — which channel they are in was not recorded." ;;
		esac
		print -r -- "PAIRED REVIEW round ${round}: the reviewer on PR #${pr} recorded ${findings} finding(s) worth addressing. ${where} If nothing readable turns up, report that back rather than assuming you're looking in the wrong place. Fix every BUG/CONCERN finding and push to the PR branch; for anything you disagree with, reply on that review thread saying why rather than silently skipping it. Do NOT message the manager or wait for a human — when your commits are pushed, just stop. The reviewer is re-invoked automatically."
	fi
}

_pair_reviewer_msg() {
	local pr="$1" round="$2" kind="$3"
	local lead
	if [[ $kind == initial ]]; then
		lead="PAIRED REVIEW round ${round}: you are now the reviewer half of an automatic fix/re-review loop on PR #${pr}."
	else
		lead="PAIRED REVIEW round ${round}: the worker pushed fixes for PR #${pr}. Re-review it (/my-pr-review ${pr}), covering the findings you raised last round and anything new in the diff. Post findings as PR comments as usual."
	fi
	print -r -- "${lead} Before you stop you MUST record a machine-readable verdict — the loop halts and escalates to a human without one: run 'tmux-apex.sh verdict --findings <count worth addressing>', or 'tmux-apex.sh verdict --none' if nothing is left worth fixing. Count BUG/CONCERN findings, plus any SUGGESTION you genuinely think should be acted on; do not count nits you would not block on. Prefer inline review comments anchored to a file and line over a prose summary — they tell the fixer *where* — but an issue-level comment on the PR is accepted evidence too. Recording --none flips the PR out of draft and hands it to a human, so only do that when you would approve it. Do NOT message the manager."
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
# Returns 0 delivered, 1 undelivered (caller escalates), 2 *deferred* — the box
# still holds the relay but the pane is repainting, so delivery is neither
# confirmed nor refuted yet and the caller must arm a re-check rather than
# decide (issue #49).
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
# Whatever the box would not clear, so a deferred re-check can strip it before
# asking whether the box still holds our own text (see _box_pending).
_PAIR_RELAY_RESIDUE=""
# The text as it went into the box, sender tag included — see APEX_SEND_TEXT.
_PAIR_RELAY_SENT=""
_pair_relay() {
	local manager="$1" target="$2" text="$3" rc=0
	_PAIR_RELAY_WHY=""
	_PAIR_RELAY_RESIDUE=""
	_PAIR_RELAY_SENT=""
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
	# look — and this used to be reported as undelivered and escalated, on the
	# fail-safe argument that a loop waiting on a partner nobody woke is a
	# silent deadlock nothing recovers from.
	#
	# That argument is right about the deadlock and wrong about the deadline.
	# The confirmation window is racing the work the relay itself triggered:
	# hand a worker N findings and the pane stays busy for as long as fixing
	# them takes, so the more substantial the review the more certain the false
	# alarm, and no fixed ceiling can outrun a quantity that scales with the
	# message's own effect (issue #49; #36 raised it 5s → 30s and it still lost
	# every race).
	#
	# So this is not a verdict, it is an unfinished observation: return 2 and
	# let the caller re-check when the pane has something new to say. The
	# fail-safe survives as a bound on the *deferral* — see _pair_defer_arm,
	# which escalates the moment the pane goes quiet with our text still in the
	# box (the reading that does mean undelivered) and, failing that, after a
	# bounded number of re-checks.
	if (( rc == 0 )) && [[ -n ${APEX_SEND_UNCONFIRMED:-} ]]; then
		_PAIR_RELAY_RESIDUE="${APEX_SEND_SPLICED:-}"
		_PAIR_RELAY_SENT="${APEX_SEND_TEXT:-$text}"
		apex_event "$manager" \
			"$(print -r -- "$ev" | jq -c '{event:"pair-relay-deferred"} + .')"
		return 2
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

# ─── deferred relays (issue #49) ─────────────────────────────────────
#
# "The box still holds our relay" is two different facts wearing one face, and
# only one of them is worth waking a human for:
#
#   box holds our text + pane has gone quiet     → nobody took it. Escalate.
#   box holds our text + pane still repainting   → an agent is working on what
#                                                  we just sent, and the box is
#                                                  simply behind. Look again.
#
# The send path already tells them apart (it will not retype into a repainting
# pane — issue #24), but the relay used to collapse both into "undelivered"
# because it had nowhere to put an unfinished observation. This is that place.
#
# A deferral is recorded on *both* halves rather than only on the sender, so
# either member's next idle transition can settle it (see _cmd_settle) — the
# cheap version of #29's proposed watcher, riding transitions the loop already
# gets instead of adding a poller. A timer is armed as well, because the case
# that matters most produces no transitions at all: if the relay really was
# never submitted, the partner never runs a turn, and a deferral waiting on its
# transition would wait forever. Between them the bound is real, which is the
# fail-safe argument #36 made, honoured with a deadline measured in "the pane
# went quiet" rather than in seconds.
APEX_PAIR_DEFER_SECS=${APEX_PAIR_DEFER_SECS:-30}
APEX_PAIR_DEFER_MAX_CHECKS=${APEX_PAIR_DEFER_MAX_CHECKS:-20}
APEX_PAIR_DEFER_IDLE_TICKS=${APEX_PAIR_DEFER_IDLE_TICKS:-10}
# How many times a transition may be handed back because another trigger held
# the decision. The chain does terminate on its own in the cases contention
# actually creates — a clamped section, a killed holder whose flock the kernel
# drops, a member that takes another turn and fails the seq guard — but a lock
# held by a process that is alive and wedged has none of those, and this file
# argues the case for a bound at length. The deferral got one; the retry that
# rides it should too, and running out should say so rather than go quiet.
APEX_SETTLE_LOCK_RETRIES=${APEX_SETTLE_LOCK_RETRIES:-5}

# _pair_defer_knobs — clamp the four knobs that bound the deferral, into
# _PAIR_DEFER_SECS, _PAIR_DEFER_MAX, _PAIR_DEFER_TICKS and _PAIR_DEFER_RETRIES.
#
# None of them is trusted, for the reason _send_to_pane spells out for its own ticks:
# a knob that silently switches off the bound it exists to tune is worse than a
# knob that is ignored. `SECS=0` fires `run-shell -d 0` immediately and burns
# the whole re-check budget in seconds; a non-numeric value makes `run-shell`
# error, and the `|| true` there swallows it, so there is no timer at all —
# which removes the bound on precisely the case the header calls the important
# one, a relay that was never submitted and so generates no transitions to ride.
# `MAX_CHECKS=0` makes the first re-check the last, i.e. the feature off.
# Warn rather than _die: this runs on the relay path, and a defaulted bound
# beats refusing to adjudicate.
_pair_defer_knobs() {
	_PAIR_DEFER_SECS=${APEX_PAIR_DEFER_SECS}
	_PAIR_DEFER_MAX=${APEX_PAIR_DEFER_MAX_CHECKS}
	if [[ $_PAIR_DEFER_SECS != <-> ]] || (( _PAIR_DEFER_SECS < 1 )); then
		print -u2 "tmux-apex: APEX_PAIR_DEFER_SECS='${APEX_PAIR_DEFER_SECS}' is not a positive integer; using 30"
		_PAIR_DEFER_SECS=30
	fi
	if [[ $_PAIR_DEFER_MAX != <-> ]] || (( _PAIR_DEFER_MAX < 1 )); then
		print -u2 "tmux-apex: APEX_PAIR_DEFER_MAX_CHECKS='${APEX_PAIR_DEFER_MAX_CHECKS}' is not a positive integer; using 20"
		_PAIR_DEFER_MAX=20
	fi
	# The sample length gets the same treatment, and defaults *up*: clamping a
	# bad value to 1 leaves a single 0.2s frame deciding "nobody took the
	# relay", so one quiet gap between tokens rolls the round back and
	# escalates — the failure this whole path removes, reintroduced by the
	# guard meant to prevent it.
	_PAIR_DEFER_TICKS=${APEX_PAIR_DEFER_IDLE_TICKS}
	if [[ $_PAIR_DEFER_TICKS != <-> ]] || (( _PAIR_DEFER_TICKS < 1 )); then
		print -u2 "tmux-apex: APEX_PAIR_DEFER_IDLE_TICKS='${APEX_PAIR_DEFER_IDLE_TICKS}' is not a positive integer; using 10"
		_PAIR_DEFER_TICKS=10
	fi
	# The sample runs inside the lock, so its length has to stay under the wait
	# a second trigger is willing to serve: at five 0.2s frames per second a
	# sample of APEX_LOCK_WAIT × 5 ticks or more guarantees the waiter times
	# out, which is the "an idle threshold above the ceiling can never be
	# reached" relationship _send_to_pane clamps for its own two ticks. A
	# timeout is recoverable now (see _cmd_settle), but a knob that makes it
	# the certain outcome is still a knob that switches the loop off.
	local -i wait_ceiling
	wait_ceiling=${APEX_LOCK_WAIT:-5}
	(( wait_ceiling < 1 )) && wait_ceiling=1
	(( wait_ceiling = wait_ceiling * 5 - 1 ))
	if (( _PAIR_DEFER_TICKS > wait_ceiling )); then
		print -u2 "tmux-apex: APEX_PAIR_DEFER_IDLE_TICKS='${APEX_PAIR_DEFER_IDLE_TICKS}' would outlast APEX_LOCK_WAIT='${APEX_LOCK_WAIT:-5}'; using ${wait_ceiling}"
		_PAIR_DEFER_TICKS=$wait_ceiling
	fi
	# And the hand-back bound, which is read into arithmetic where a
	# non-numeric, empty or negative value all evaluate as 0 — making the
	# *first* contention, the ordinary sub-five-second kind, spend the
	# transition and report a wedged lock. That is this comment's own argument
	# turned on the newest member of the family.
	_PAIR_DEFER_RETRIES=${APEX_SETTLE_LOCK_RETRIES}
	if [[ $_PAIR_DEFER_RETRIES != <-> ]] || (( _PAIR_DEFER_RETRIES < 1 )); then
		print -u2 "tmux-apex: APEX_SETTLE_LOCK_RETRIES='${APEX_SETTLE_LOCK_RETRIES}' is not a positive integer; using 5"
		_PAIR_DEFER_RETRIES=5
	fi
}

# _pair_defer_write <manager> <from> <pair> <target> <prev-round> <prev-turn> <text> <residue> <checks>
#
# Write the record to both halves. Shared by the arm and the re-arm so the two
# cannot disagree about which fields make up a deferral, and so a re-check that
# defers again updates the same set of members the arm wrote.
_pair_defer_write() {
	local manager="$1" from="$2" pair="$3" target="$4"
	local prev_round="$5" prev_turn="$6" text="$7" residue="$8" checks="$9"
	local rec m
	rec=$(jq -nc --arg t "$target" --arg text "$text" --arg res "$residue" \
		--arg from "$from" --arg pair "$pair" --arg pt "$prev_turn" \
		--argjson pr "${prev_round:-1}" --argjson n "${checks:-0}" \
		'{pair_defer_target:$t, pair_defer_text:$text, pair_defer_residue:$res,
		  pair_defer_from:$from, pair_defer_pair:$pair,
		  pair_defer_prev_round:$pr, pair_defer_prev_turn:$pt,
		  pair_defer_checks:$n}')
	for m in "$from" "$pair"; do
		[[ -n $m ]] || continue
		[[ -f $(apex_member_file "$manager" "$m") ]] || continue
		apex_member_merge "$manager" "$m" "$rec"
	done
}

# _pair_defer_arm <manager> <from> <pair> <target> <prev-round> <prev-turn> <text> [residue]
#
# Record an unconfirmed relay for later adjudication and schedule the first
# re-check. The pair state stays *advanced*: on the evidence available the
# relay most likely landed, and rolling the round back here would undo a round
# that is probably running. The rollback belongs on the path that concludes it
# did not land — _pair_defer_settle, which is why the pre-relay round and turn
# are carried in the record.
_pair_defer_arm() {
	local manager="$1" from="$2" pair="$3" target="$4"
	local prev_round="$5" prev_turn="$6" text="$7" residue="${8:-}"
	# Match what actually reached the box, not what the caller composed:
	# _send_to_pane collapses newlines to spaces before typing, and a
	# re-check that compares the box against the uncollapsed message never
	# recognises its own text — so every deferral would resolve as "the box
	# drained", which is the false confirmation this whole path exists to avoid.
	text=${text//$'\n'/ }
	text=${text//$'\r'/ }

	_pair_defer_write "$manager" "$from" "$pair" "$target" \
		"$prev_round" "$prev_turn" "$text" "$residue" 0
	apex_event "$manager" "$(jq -nc --arg s "$from" --arg t "$target" \
		'{event:"pair-relay-deferred-armed", session:$s, target:$t}')"
	_pair_defer_schedule "$manager" "$from"
}

# _pair_defer_schedule <manager> <member> — next re-check, deferred inside the
# tmux server the way _record_status defers _settle, so nothing here has to
# outlive a hook process or hold a sleeping watcher open.
_pair_defer_schedule() {
	local manager="$1" member="$2" attempt="${3:-0}"
	local _PAIR_DEFER_SECS _PAIR_DEFER_MAX _PAIR_DEFER_TICKS _PAIR_DEFER_RETRIES
	_pair_defer_knobs
	tmux run-shell -b -d "$_PAIR_DEFER_SECS" \
		"${SELF} _pair-defer-check ${(q)member} ${(q)manager} ${attempt}" 2>/dev/null || true
}

# _pair_defer_clear <manager> <member> — drop the record from every half.
#
# The record names its own members, so clear by those rather than by which half
# happened to call: pair_defer_pair is the *target*, identical in both files, so
# deriving "the other one" from it clears the caller twice and leaves the sender
# armed — and a sender still armed after its relay was confirmed goes on to
# re-check a resolved relay and can roll back a round that landed.
_pair_defer_clear() {
	local manager="$1" member="$2" m x
	local -a members
	# Read each name into a variable and append it explicitly. Letting an
	# unquoted substitution drop the empties would also split on IFS, and a
	# member id is `<session>:<pane>` with no validation anywhere — a tmux
	# session name with a space in it would split into two ids that both miss
	# the file guard below, which is round 1's symptom for a legal input.
	members=("$member")
	for x in pair_defer_from pair_defer_pair pair; do
		m=$(apex_member_get "$manager" "$member" "$x" 2>/dev/null)
		[[ -n $m ]] || continue
		(( ${members[(Ie)$m]} )) && continue
		members+=("$m")
	done
	for m in "${members[@]}"; do
		[[ -f $(apex_member_file "$manager" "$m") ]] || continue
		apex_member_merge "$manager" "$m" \
			'{"pair_defer_target":"","pair_defer_text":"","pair_defer_residue":"",
			  "pair_defer_from":"","pair_defer_pair":"","pair_defer_prev_turn":"",
			  "pair_defer_prev_round":0,"pair_defer_checks":0}'
	done
}

# _pair_defer_wedged <manager> <member> <attempts> — the hand-back bound ran out.
#
# Every other way a deferral runs out ends in _pair_escalate, and this one has
# to as well: an events.jsonl line is not something `pending` hands a human in
# words, and on the timer side nothing else was left armed at all, so the loop
# read as one that simply went quiet. The message names the lock rather than the
# pane, because that is the whole distinction — nobody ever got to look at the
# pane. The round is left where it is for the same reason the MAX_CHECKS
# hand-over leaves it: nothing here observed the target, so there is no evidence
# a round is not running. The record is cleared because no trigger will look at
# it again once the chain has stopped.
_pair_defer_wedged() {
	setopt localoptions no_err_return
	local manager="$1" member="$2" attempts="$3" from pr
	from=$(apex_member_get "$manager" "$member" pair_defer_from 2>/dev/null)
	[[ -n $from ]] || from="$member"
	pr=$(apex_member_get "$manager" "$from" pair_pr 2>/dev/null)
	apex_event "$manager" "$(jq -nc --arg s "$member" --argjson n "$attempts" \
		'{event:"pair-defer-lock-wedged", session:$s, attempts:$n}')" 2>/dev/null
	_pair_defer_clear "$manager" "$member"
	_pair_escalate "$manager" "$from" stuck \
		"PAIRED REVIEW STUCK: a deferred relay on PR #${pr} could not be adjudicated after ${attempts} attempts, because another check held its lock every time. This is a stuck lock, not a stuck pane — nothing ever got to look at the pane, so the round was left as it is. Read the panes to see where the loop actually got to, then 'pair-resume' this member."
}

# _pair_defer_settle <manager> <member>
#
# Adjudicate the deferred relay recorded on <member>, if any.
#
# Returns 0 when there is nothing outstanding — no record, or one this call
# resolved as delivered — so the caller can carry on with the normal loop; 1
# when the deferral consumed the moment, by deferring again or by escalating;
# and 3 when another trigger holds the decision, which the caller must hand
# back rather than treat as either.
#
# The whole adjudication runs under one lock, not just the read. A deferral has
# two independent triggers by design — the timer and either half's idle
# transition — and deciding one is a read-modify-write across a sampling window
# the target finishing its relayed work is exactly likely to land inside. The
# record therefore stays in state until a terminal decision is written, which
# is what makes it durable: hook processes are killed freely (see the threat
# model in apex-state.sh), and a claim held only in shell variables would take
# the deferral with it, leaving the round advanced and no timer pending — the
# silent deadlock the bound exists to prevent. A second trigger that cannot get
# the lock returns 1 and skips its turn rather than falling through to
# _pair_advance, because "relay and flip the turn while the holder is about to
# roll the round back" is worse than the double escalation the lock removes.
_pair_defer_settle() {
	setopt localoptions no_err_return
	local manager="$1" member="$2" lock key rc
	# Nothing to serialise if there is no record; the recheck under the lock is
	# what decides, so this only keeps the uncontended common path cheap.
	[[ -n $(apex_member_get "$manager" "$member" pair_defer_target 2>/dev/null) ]] || return 0
	# Keyed on the deferral's sender, which both halves carry identically, so
	# the lock excludes the two triggers of *this* deferral and no others: with
	# one lock per manager an unrelated pair's re-check would queue behind a
	# sample it has no stake in, and every added pair would widen the timeout
	# window below for all of them.
	key=$(apex_member_get "$manager" "$member" pair_defer_from 2>/dev/null)
	[[ -n $key ]] || key="$member"
	key=${key//[^A-Za-z0-9_-]/_}
	lock="$APEX_ROOT/$manager/.pair-defer-${key}.lock"
	if ! apex_lock_acquire "$lock"; then
		# Recorded rather than silent, the way _apex_authority_set records its
		# own: an unexplained skip here reads as a lost deferral, and if this
		# ever falls through to an unlocked write the duplicate escalation that
		# follows needs something in the log pointing at why.
		apex_event "$manager" "$(jq -nc --arg s "$member" \
			'{event:"lock_timeout", file:"pair-defer.lock", session:$s}')" 2>/dev/null
		# 3, not 1: the caller has to be able to tell "another trigger is
		# deciding, hand this transition back" from "decided, nothing to
		# advance on". Dropping it outright would leave nothing driving the
		# loop, since the lock holder's own re-check chain is the only other
		# thing armed and a sample that outlasts the wait makes the timeout the
		# rule rather than the exception.
		return 3
	fi
	_pair_defer_adjudicate "$manager" "$member"
	rc=$?
	apex_lock_release "$lock"
	return $rc
}

# _pair_defer_adjudicate <manager> <member> — _pair_defer_settle's body, run
# with the pair-defer lock held. Same return contract.
_pair_defer_adjudicate() {
	setopt localoptions no_err_return
	local manager="$1" member="$2"
	local target text residue from pair prev_round prev_turn
	local _PAIR_DEFER_SECS _PAIR_DEFER_MAX _PAIR_DEFER_TICKS _PAIR_DEFER_RETRIES
	_pair_defer_knobs

	target=$(apex_member_get "$manager" "$member" pair_defer_target 2>/dev/null)
	[[ -n $target ]] || return 0
	text=$(apex_member_get "$manager" "$member" pair_defer_text 2>/dev/null)
	residue=$(apex_member_get "$manager" "$member" pair_defer_residue 2>/dev/null)
	from=$(apex_member_get "$manager" "$member" pair_defer_from 2>/dev/null)
	pair=$(apex_member_get "$manager" "$member" pair_defer_pair 2>/dev/null)
	prev_round=$(apex_member_get "$manager" "$member" pair_defer_prev_round 2>/dev/null)
	prev_turn=$(apex_member_get "$manager" "$member" pair_defer_prev_turn 2>/dev/null)
	local -i checks
	checks=$(apex_member_get "$manager" "$member" pair_defer_checks 2>/dev/null)
	[[ -n $from ]] || from="$member"
	[[ $prev_round == <-> ]] || prev_round=1

	local pr; pr=$(apex_member_get "$manager" "$from" pair_pr 2>/dev/null)

	# A partner that has gone away answers the question outright, and it is the
	# one answer that cannot improve by waiting.
	if ! _member_alive "$target"; then
		_pair_defer_clear "$manager" "$member"
		_pair_rollback "$manager" "$from" "$pair" "$prev_round" "$prev_turn"
		_pair_escalate "$manager" "$from" stuck \
			"PAIRED REVIEW STUCK: a relay on PR #${pr} was left unconfirmed while its target pane ($target) was busy, and that session has since gone. Whatever it was working on is not coming back to this loop."
		return 1
	fi

	local pane; pane=$(_agent_pane "$target" 2>/dev/null)
	if [[ -z $pane ]]; then
		_pair_defer_clear "$manager" "$member"
		_pair_rollback "$manager" "$from" "$pair" "$prev_round" "$prev_turn"
		_pair_escalate "$manager" "$from" stuck \
			"PAIRED REVIEW STUCK: a relay on PR #${pr} was left unconfirmed, and ${target} no longer has a reachable agent pane to re-check."
		return 1
	fi

	# One capture answers both halves of the question about the same instant,
	# for the reason _box_line_of exists. The first capture is iteration 0 of
	# the sample rather than a block of its own: "the box drained" is the same
	# conclusion whether it is true on arrival or two ticks in, and stating it
	# once is what stops the two readings drifting apart.
	local -i ticks=$_PAIR_DEFER_TICKS static=0 j
	local sig sig0 box
	sig0=$(_pane_activity_sig "$pane" 2>/dev/null)
	box=$(_box_line_of "$sig0")
	for (( j = 0; j <= ticks; j++ )); do
		if (( j > 0 )); then
			sleep 0.2
			sig=$(_pane_activity_sig "$pane" 2>/dev/null)
			box=$(_box_line_of "$sig")
		fi
		if ! _box_pending "$box" "$text" "$residue"; then
			# The box drained. The relay was submitted after all — which is what
			# the busy pane was weak evidence for all along — so this is an
			# ordinary delivery that took longer to prove than the window allowed.
			_pair_defer_clear "$manager" "$member"
			apex_event "$manager" "$(jq -nc --arg s "$target" --arg text "$text" \
				--argjson n "$checks" \
				'{event:"pair-relay", session:$s, text:$text,
				  confirmed_late:true, defer_checks:$n}')"
			return 0
		fi
		if (( j > 0 )); then
			if [[ $sig == "$sig0" ]]; then
				(( static += 1 ))
			else
				sig0="$sig"; static=0
			fi
		fi
	done

	if (( static >= ticks )); then
		# Our text in the box and not one cell changed for the whole sample:
		# this is the reading that means something. Nobody took the relay.
		_pair_defer_clear "$manager" "$member"
		_pair_rollback "$manager" "$from" "$pair" "$prev_round" "$prev_turn"
		_pair_escalate "$manager" "$from" stuck \
			"PAIRED REVIEW STUCK: the relay on PR #${pr} is still sitting unsent in ${target}'s input box, and that pane has now been completely idle with it there — so it was never submitted and the partner was never woken. Read the pane, submit or clear the box, then 'pair-resume' this member."
		return 1
	fi

	(( checks += 1 ))
	if (( checks >= _PAIR_DEFER_MAX )); then
		# Still busy, but a deferral with no floor is the silent deadlock #36
		# refused to allow. Hand it over saying exactly that, and say which of
		# the two readings ran out — a pane that never stopped working is a
		# different thing to explain than a pane that stalled.
		_pair_defer_clear "$manager" "$member"
		_pair_escalate "$manager" "$from" stuck \
			"PAIRED REVIEW STUCK: a relay on PR #${pr} has been unconfirmed for ${checks} re-checks — ${target}'s pane has been busy with our text in its input box the whole time and never went quiet. It is most likely working on the relay and the box is just stale, so read the pane before doing anything: if it is working, let it finish and push, then 'pair-resume'. The round was not rolled back, because a round is most likely running."
		return 1
	fi

	# Still busy: count the re-check on the same two halves the arm wrote to,
	# through the same writer, so the record cannot mean one thing here and
	# another there.
	_pair_defer_write "$manager" "$from" "$pair" "$target" \
		"$prev_round" "$prev_turn" "$text" "$residue" "$checks"
	apex_event "$manager" "$(jq -nc --arg s "$target" --argjson n "$checks" \
		'{event:"pair-relay-still-deferred", session:$s, defer_checks:$n}')"
	_pair_defer_schedule "$manager" "$member"
	# Consume the ping on the way out. A deferral that is still deferring is
	# nothing for the manager to act on — waking it once per re-check would be
	# the same per-round tax as the false escalations, paid in a different
	# currency. The durable record is the pair-relay-still-deferred event.
	local seq
	seq=$(apex_member_get "$manager" "$member" seq); [[ -n $seq ]] || seq=0
	apex_member_merge "$manager" "$member" \
		"$(jq -nc --argjson s "$seq" '{pinged_seq:$s}')"
	return 1
}

# _pair-defer-check <member> <manager> — internal, fired by run-shell -d and by
# `_settle` on either half's idle transition.
_cmd_pair_defer_check() {
	local member="$1" manager="$2"
	local -i attempt=${3:-0}
	[[ -n $member && -n $manager ]] || return 0
	APEX_SESSION="$manager"
	[[ -f $(apex_member_file "$manager" "$member") ]] || return 0
	local rc=0
	_pair_defer_settle "$manager" "$member" || rc=$?
	# Contended: the timer chain is one of the two triggers, so returning here
	# would end it and leave the deferral riding transitions alone. Re-arm it,
	# under the same bound as _cmd_settle's hand-back and for the same reason —
	# these attempts observed nothing, so pair_defer_checks deliberately does
	# not count them and cannot serve as the bound. A re-check that gets the
	# lock re-arms with the count reset, since that chain is bounded by
	# APEX_PAIR_DEFER_MAX_CHECKS instead.
	if (( rc == 3 )); then
		(( attempt += 1 ))
		local _PAIR_DEFER_SECS _PAIR_DEFER_MAX _PAIR_DEFER_TICKS _PAIR_DEFER_RETRIES
		_pair_defer_knobs
		if (( attempt > _PAIR_DEFER_RETRIES )); then
			_pair_defer_wedged "$manager" "$member" "$attempt"
		else
			_pair_defer_schedule "$manager" "$member" "$attempt"
		fi
	fi
	return 0
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

	# What happens next is not a fixed fact about the loop, it is this repo's
	# answer to the merge-authority question (#41/#46). The message used to
	# assert "nothing is left for an agent to do — this needs the human's merge
	# decision", which predates the grant existing at all and now contradicts
	# the skill on any repo where merging *is* granted (issue #49). Read the
	# grant and say the true thing; `unknown` and `no` are the same instruction
	# here, which is what fail-closed means.
	local auth next_step
	auth=$(_apex_status_authority "$manager")
	if [[ $auth == yes ]]; then
		next_step="Merge authority is granted for this repo, so this is yours to finish: check the PR against the merge criteria in the apex skill and merge it if they all hold, or report why they do not. It is an independent reviewer's sign-off, so it does not need the self-review axis."
	else
		next_step="Merge authority is NOT granted for this repo, so do not merge: report the PR as ready-and-ineligible and leave the merge decision to the human."
	fi

	_pair_escalate "$manager" "$member" complete \
		"READY FOR HUMAN REVIEW: the paired reviewer found no further findings worth addressing on PR #${pr} after ${round} round(s). ${ready_note} ${next_step}"
}

# _git_bounded <secs> <git-args...> — `git "$@"` under a hard wall-clock bound.
#
# On success prints git's stdout and returns 0. On failure prints nothing and
# returns git's exit status, or 124 when the bound was hit rather than reached.
# GIT_TERMINAL_PROMPT=0 throughout: a call worth bounding is by definition one
# nobody is watching, so a credential prompt is only ever a stall.
#
# `timeout(1)` is not shelled out to on purpose. It is GNU coreutils, absent
# from a stock macOS base system, and this plugin does not otherwise require
# coreutils — so on the very platform it is developed on the bound would
# silently not exist. A watchdog child needs nothing that is not already here.
#
# git's stdout goes to that file rather than up the caller's command
# substitution, and this is load-bearing, not tidiness. Over a real transport
# git spawns a helper (ssh, git-remote-https) that inherits stdout, so TERMing
# git alone leaves the helper holding the write end of the substitution's pipe
# — the caller then blocks on EOF for exactly as long as the stall it was
# trying to bound, and the ceiling quietly does nothing. Verified: with a
# transport that accepts and then says nothing, the pipe form runs past a 2s
# bound indefinitely while this form returns 124 at 2s.
#
# Two processes are deliberately left running past the TERM, and both are
# harmless rather than merely unnoticed:
#
#   - the transport helper. It is the whole reason stdout is a file, so of
#     course it survives killing git; it goes on writing into a file that was
#     unlinked before git ever started, and exits when its own timeout
#     expires — after which the kernel reclaims the blocks. It is not
#     killed as a process group because there is no job control here, so the
#     group is tmux-apex's own — a group TERM would take the caller with it.
#   - the watchdog's `sleep`. It is orphaned by the TERM aimed at its parent,
#     and the `kill` it would have gone on to run died with that parent.
#
# The temp file is unlinked the moment it exists, and the probe then works
# through the two descriptors already open on it. Nothing can leak it, on any
# path, because after those three lines there is no name left to clean up:
# not a signal, not a `_die`, not SIGKILL.
#
# That is why there is no trap here, and the distinction matters. An EXIT trap
# was the obvious form and does not actually hold: zsh does not run TRAPEXIT
# for an *untrapped* fatal signal, and `_settle` — the entry point this whole
# bound exists for — arms nothing, so the file survived a TERM mid-probe. Only
# `watch` arms INT/TERM, which is why the trap looked correct when tested
# there. Adding INT/TERM/HUP with a re-raise fixes the leak and breaks
# something worse: measured, the re-raise reaches the default disposition
# rather than the handler `localtraps` has shadowed, so `watch` exits 143 with
# its pidfile still on disk. Not owning the name at all beats both.
#
# The one honest gap is the few instructions between `mktemp` and `rm`, which
# fork nothing and cannot block.
_git_bounded() {
	local secs="$1"; shift
	local tmp rc=0 wfd rfd
	tmp=$(mktemp "${TMPDIR:-/tmp}/tmux-apex-git.XXXXXX") || return 1
	exec {wfd}>"$tmp" {rfd}<"$tmp"
	rm -f "$tmp"
	(
		export GIT_TERMINAL_PROMPT=0
		git "$@" >&$wfd 2>/dev/null &
		gitpid=$!
		{ sleep "$secs"; kill -TERM $gitpid 2>/dev/null; } >/dev/null 2>&1 &
		dogpid=$!
		wait $gitpid
		gitrc=$?
		kill -TERM $dogpid 2>/dev/null
		exit $gitrc
	) || rc=$?
	# A watchdog TERM surfaces as 143. Report the conventional 124 instead, so
	# a caller can tell "the bound was hit" from "git answered, negatively".
	(( rc == 143 )) && rc=124
	(( rc == 0 )) && cat <&$rfd
	exec {wfd}>&- {rfd}<&-
	return $rc
}

# _pair_pushed_head <worktree> — what the remote currently reports for this
# worktree's branch, as the loop's answer to "did the work actually move?"
#
# Prints the tip SHA, or the literal `-` when the remote answers and has no
# such branch (nothing pushed yet). Returns 1, printing nothing, when the
# answer is not knowable — no worktree, detached HEAD, or a remote that could
# not be reached. The three outcomes must stay distinct: callers relay on
# unknown and hold on unchanged, and collapsing them turns one into the other.
#
# Pushed, not committed, is the question — the reviewer reads the PR, so a
# local commit the remote has never seen is no more reviewable than no commit
# at all.
#
# The same two shortcuts are unavailable here as in `_commits_ahead`, for the
# same reason (issue #31): an apex worktree's `remote.origin.fetch` is narrowed
# to `main`, so `@{upstream}` resolves against a local ref nothing updates and
# `--not --remotes` has no `origin/<branch>` ref to consult at all. Both would
# answer confidently and wrongly. Ask the remote.
#
# This is a network round trip, which `_commits_ahead` makes opt-in rather than
# automatic. That rule is not being quietly crossed here — it is about *where*
# the round trip lands. `_commits_ahead` declines to pay on the per-hook path
# behind `_record_status` and `pending`, which runs constantly for every member
# and whose answer is a cosmetic number on a ping line, so the honest `null`
# costs nothing. This probe runs at most twice per round of a single linked
# pair, and its answer is not cosmetic: without it the loop takes the wrong
# branch, which is the whole of issue #48. The deliberately-invoked callers
# (`status --ask-remote`, `_reap_risk`) pay for the same trip already.
#
# Bounded, though, because unlike those two this one has no human watching it:
# it runs from `_cmd_settle` under `tmux run-shell -b -d`. GIT_TERMINAL_PROMPT=0
# only covers a remote that *asks* for something; a remote that accepts the
# connection and then says nothing stalls for the transport's own timeout,
# which is minutes, and stalls the settle callback with it. Hitting the bound
# is a non-zero exit, so it lands in the existing unknown case and fails open.
_pair_pushed_head() {
	local wt="$1" branch out rc=0 sha
	[[ -n $wt && -d $wt ]] || return 1
	branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || return 1
	[[ -n $branch ]] || return 1
	out=$(_git_bounded "$APEX_PAIR_HEAD_TIMEOUT" \
		-C "$wt" ls-remote origin "refs/heads/${branch}") || rc=$?
	(( rc == 0 )) || return 1
	sha=$(printf '%s' "$out" | head -1 | cut -f1)
	print -r -- "${sha:--}"
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
		local vround findings note voverride vchannel
		vround=$(apex_member_get "$manager" "$member" verdict_round)
		findings=$(apex_member_get "$manager" "$member" verdict_findings)
		note=$(apex_member_get "$manager" "$member" verdict_note)
		voverride=$(apex_member_get "$manager" "$member" verdict_override)
		vchannel=$(apex_member_get "$manager" "$member" verdict_channel)

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
		# Record what the worker's branch looks like on the remote *now*, so
		# its own idle transition can tell "pushed the fixes" from "stopped
		# without pushing" (issue #48). Written unconditionally, empty when
		# unknowable: a stale baseline from an earlier round would compare
		# against the wrong tip, and an absent one is the fail-open case the
		# worker side already handles.
		local whead=""
		whead=$(_pair_pushed_head "$(apex_member_get "$manager" "$pair" worktree)") || whead=""
		# Write the partner's pair state *before* delivering, not after.
		# Delivery wakes the partner agent, whose own `event set` merges
		# {status,seq} into the same member file. apex_member_merge now holds
		# the record's mutex, so neither write can lose the other's fields;
		# the ordering is kept anyway because it is the cheaper guarantee —
		# the partner's write blocks rather than racing.
		local turn_worker
		turn_worker=$(jq -nc --argjson r "$next" --arg h "$whead" \
			'{pair_round:$r, pair_turn:"worker", pair_worker_head:$h}')
		apex_member_merge "$manager" "$member" "$turn_worker"
		apex_member_merge "$manager" "$pair" "$turn_worker"
		local msg rrc=0
		msg=$(_pair_worker_msg "$pr" "$next" "$findings" "$note" "$voverride" "$vchannel")
		_pair_relay "$manager" "$pair" "$msg" || rrc=$?
		if (( rrc == 2 )); then
			# Deferred, not failed: the worker's pane is busy holding our text,
			# which is far more often the work this relay just started than a
			# swallowed Enter. Leave the round bumped and the turn passed —
			# both are right if it landed — and let the re-check decide.
			_pair_defer_arm "$manager" "$member" "$pair" "$pair" \
				"$round" reviewer "$_PAIR_RELAY_SENT" "$_PAIR_RELAY_RESIDUE"
		elif (( rrc )); then
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
		# Relay only when the branch actually moved (issue #48). Idle is the
		# only signal this transition carries, and a worker goes idle for three
		# different reasons: it pushed the round's fixes, it stopped to await a
		# human decision exactly as its prompt instructs, or it stopped early
		# for some other reason. Relaying all three spends a round of the cap
		# on a re-review of unchanged code, which produces a duplicate finding
		# set the reviewer cannot even recognise as duplicate without comparing
		# SHAs by hand.
		#
		# Unknown baseline or unknown current tip means relay: the check exists
		# to catch a specific, recognisable non-event, and a check that cannot
		# see is not entitled to stop a loop that would otherwise run.
		local head_base head_now=""
		head_base=$(apex_member_get "$manager" "$member" pair_worker_head)
		if [[ -n $head_base ]]; then
			head_now=$(_pair_pushed_head "$(apex_member_get "$manager" "$member" worktree)") || head_now=""
		fi
		if [[ -n $head_base && -n $head_now && $head_now == "$head_base" ]]; then
			# Do not consume the round and do not consume the ping. This is a
			# worker that stopped without doing the work — a manager-shaped
			# problem, not a reviewer-shaped one — so let the transition fall
			# through to `pending` the way an unlinked member's idle does, with
			# a line saying why rather than a bare "worker went idle".
			#
			# The turn stays with the worker and the loop stays active, so a
			# later push and idle relays normally with no operator action. Only
			# pair_message is written, which `pending` delivers once and then
			# clears: a worker parked on a human decision must not re-interrupt
			# the manager on every subsequent transition.
			local stall
			stall=$(print -r -- "PAIRED REVIEW WAITING: the worker on PR #${pr} went idle in round ${round} without pushing anything — the branch tip on the remote is unchanged since the findings were relayed. No re-review was requested and no round was spent. Read the worker's pane and its PR body: it has most likely stopped on a decision only you or the human can make. Once it is unblocked and has pushed, its next idle continues the loop on its own.")
			apex_member_merge "$manager" "$member" \
				"$(jq -nc --arg m "$stall" '{pair_message:$m}')"
			apex_event "$manager" "$(jq -nc --arg s "$member" --arg pr "$pr" \
				--argjson r "$round" --arg h "$head_base" \
				'{event:"pair-no-push", session:$s, review_pr:$pr, round:$r, head:$h}')"
			return 1
		fi

		# Stamp this round's comment baseline on the reviewer before waking
		# it: verdict compares against this, so a stale comment left over
		# from an earlier round cannot keep satisfying the "findings were
		# published" guard forever (issue #47 follow-up). Best-effort — if
		# GitHub cannot be queried right now, leave the prior baseline in
		# place rather than block the relay on it; verdict's own query will
		# fail closed on the same outage if it matters.
		# Both channel baselines come from the same query and are stamped
		# together or not at all (issue #60): a fresh count for one channel
		# next to a stale one for the other is the same "two different things
		# by the same number" hazard _pair_comment_counts refuses to create.
		local wt counts baseline inline
		wt=$(apex_member_get "$manager" "$member" worktree)
		if [[ -n $wt && -d $wt ]]; then
			counts=$(_pair_comment_counts "$wt" "$pr" 2>/dev/null) || counts=""
		else
			counts=""
		fi

		apex_member_merge "$manager" "$member" '{"pair_turn":"reviewer"}'
		if [[ -n $counts ]]; then
			baseline=${counts%% *}; inline=${counts##* }
			apex_member_merge "$manager" "$pair" \
				"$(jq -nc --argjson b "$baseline" --argjson bi "$inline" \
					'{pair_turn:"reviewer", pair_comment_baseline:$b, pair_inline_baseline:$bi}')"
		else
			apex_member_merge "$manager" "$pair" '{"pair_turn":"reviewer"}'
		fi
		local msg rrc=0
		msg=$(_pair_reviewer_msg "$pr" "$round" rereview)
		_pair_relay "$manager" "$pair" "$msg" || rrc=$?
		if (( rrc == 2 )); then
			_pair_defer_arm "$manager" "$member" "$pair" "$pair" \
				"$round" worker "$_PAIR_RELAY_SENT" "$_PAIR_RELAY_RESIDUE"
		elif (( rrc )); then
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
	manager=$(_require_manager) || exit 1
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

	# Stamp round 1's baseline too — otherwise a PR that already has
	# comments on it (e.g. from a human, or a prior unrelated pairing)
	# satisfies the verdict guard on round 1 without the reviewer having
	# published anything, which is issue #47's failure mode relocated
	# rather than fixed. Best-effort like the round-2+ stamp in
	# _pair_advance: if GitHub cannot be queried right now, fall back to
	# an empty baseline (0) rather than block the link.
	local rwt rcounts rbaseline rinline
	rwt=$(apex_member_get "$manager" "$reviewer" worktree)
	if [[ -n $rwt && -d $rwt ]]; then
		rcounts=$(_pair_comment_counts "$rwt" "$pr" 2>/dev/null) || rcounts="0 0"
	else
		rcounts="0 0"
	fi
	rbaseline=${rcounts%% *}; rinline=${rcounts##* }

	apex_member_merge "$manager" "$worker" "$(jq -nc \
		--arg pair "$reviewer" --arg pr "$pr" --argjson max "$max" \
		'{pair:$pair, pair_role:"worker", pair_pr:$pr, pair_round:1,
		  pair_max_rounds:$max, pair_turn:"reviewer", pair_state:"active",
		  pair_message:"", pair_worker_head:""}')"
	apex_member_merge "$manager" "$reviewer" "$(jq -nc \
		--arg pair "$worker" --arg pr "$pr" --argjson max "$max" \
		--argjson b "$rbaseline" --argjson bi "$rinline" \
		'{pair:$pair, pair_role:"reviewer", pair_pr:$pr, pair_round:1,
		  pair_max_rounds:$max, pair_turn:"reviewer", pair_state:"active",
		  pair_message:"", pair_worker_head:"", verdict_round:"",
		  verdict_findings:"", verdict_note:"", verdict_override:"",
		  verdict_channel:"",
		  pair_comment_baseline:$b, pair_inline_baseline:$bi}')"

	apex_event "$manager" "$(jq -nc --arg w "$worker" --arg r "$reviewer" \
		--arg pr "$pr" --argjson max "$max" \
		'{event:"pair-link", session:$w, reviewer:$r, review_pr:$pr, max_rounds:$max}')"

	# The reviewer is already running with its own review prompt and knows
	# nothing about the verdict protocol until told.
	local brief_rc=0
	_pair_relay "$manager" "$reviewer" "$(_pair_reviewer_msg "$pr" 1 initial)" || brief_rc=$?
	if (( brief_rc == 0 )); then
		print "Linked pair on PR #${pr} (max ${max} rounds); reviewer briefed on the verdict protocol."
	elif (( brief_rc == 2 )); then
		# Deferring is for the unattended loop; `link` is run by a human who is
		# looking at the terminal, so say what was and was not observed.
		print "Linked pair on PR #${pr} (max ${max} rounds); the briefing is in the reviewer's input box."
		print -u2 "tmux-apex: WARNING — the reviewer's pane repainted throughout, so the briefing's"
		print -u2 "  submission could not be confirmed. Check the pane; if it never took, re-send it"
		print -u2 "  or the loop will escalate as stuck for want of a verdict."
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
	manager=$(_require_manager) || exit 1
	APEX_SESSION="$manager"

	local pair m
	pair=$(apex_member_get "$manager" "$member" pair)
	for m in "$member" "$pair"; do
		[[ -n $m ]] || continue
		[[ -f $(apex_member_file "$manager" "$m") ]] || continue
		apex_member_merge "$manager" "$m" \
			'{"pair":"","pair_role":"","pair_state":"","pair_turn":"","pair_message":"",
			  "pair_defer_target":"","pair_defer_text":"","pair_defer_residue":"",
			  "pair_defer_from":"","pair_defer_pair":"","pair_defer_prev_turn":"",
			  "pair_defer_prev_round":0,"pair_defer_checks":0,
			  "pair_worker_head":""}'
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
	manager=$(_require_manager) || exit 1
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
			'{"verdict_round":"","verdict_findings":"","verdict_note":"","verdict_override":"","verdict_channel":""}'
	fi

	# A human has now adjudicated whatever the loop was stuck on, so any relay
	# still awaiting a verdict of its own is moot — and left armed it would fire
	# a re-check against a pane the resume is about to make busy again, and
	# escalate the loop straight back out of the state this command just put it
	# in (issue #49).
	_pair_defer_clear "$manager" "$member"

	local resume_rc=0
	_pair_relay "$manager" "$reviewer" "$(_pair_reviewer_msg "$pr" "$round" rereview)" \
		|| resume_rc=$?
	# rc 2 is "the box still holds it and the pane is busy" — for the unattended
	# loop that is a deferral, but a human ran this command and can look at the
	# pane, so report it rather than either dying or claiming confirmation.
	if (( resume_rc == 2 )); then
		print -u2 "tmux-apex: pair-resume: the re-review request is in ${reviewer}'s input box but the pane was"
		print -u2 "  repainting throughout, so submission could not be confirmed. It is most likely"
		print -u2 "  working on it — check the pane before resuming again."
	elif (( resume_rc )); then
		_die "pair-resume: could not reach the reviewer ($reviewer)"
	fi
	apex_event "$manager" "$(jq -nc --arg s "$member" --argjson max "$max" \
		'{event:"pair-resume", session:$s, max_rounds:$max}')"
	print "Resumed the loop on PR #${pr}; reviewer re-invoked for round ${round} of ${max}."
}

# _pair_comment_counts <worktree> <pr> — the two *separate* channels a fixer
# can read findings from, printed as "<issue> <inline>":
#
#   issue   issue-level PR comments plus non-empty review bodies — what
#           `gh pr view N --comments` surfaces
#   inline  inline review comments anchored to a file and line —
#           `gh api repos/{owner}/{repo}/pulls/N/comments`
#
# They are kept apart rather than summed because the verdict guard and the
# relay have to agree about *where* the findings are (issue #60). A summed
# count let a reviewer satisfy the guard with a single issue-level summary
# and still have the fixer pointed at the inline endpoint, which returns 0 —
# indistinguishable, from the fixer's side, from the unpublished-findings
# failure the guard was built to eliminate (issue #47).
#
# `gh pr view --json comments,reviews` cannot see inline comments at all:
# posting one creates a COMMENTED review with an *empty* body, which the
# reviews filter drops. Hence the second query.
#
# Prints both counts and returns 0, or prints nothing and returns 1 if
# either query failed. Both must succeed: a baseline taken while one
# endpoint was down is not comparable to a later count taken with it up, so
# a partial failure would silently mean two different things by the same
# number, false-blocking or (worse) false-passing a stale round.
_pair_comment_counts() {
	local wt="$1" pr="$2" c1 c2 rc1=0 rc2=0
	c1=$(cd "$wt" && gh pr view "$pr" --json comments,reviews \
		--jq '(.comments | length) + ([.reviews[] | select(.body != "")] | length)' 2>/dev/null) || rc1=$?
	c2=$(cd "$wt" && gh api "repos/{owner}/{repo}/pulls/${pr}/comments" --jq 'length' 2>/dev/null) || rc2=$?
	(( rc1 == 0 && rc2 == 0 )) || return 1
	print -r -- "${c1:-0} ${c2:-0}"
}

# verdict — run by the *reviewer* in its own pane. This is the loop's only
# termination signal, and deliberately a structured one.
_cmd_verdict() {
	local findings="" note="" override=0
	while (( $# )); do
		case "$1" in
			--findings) _need_val verdict "$1" $#; findings="$2"; shift 2 ;;
			--none)     findings=0; shift ;;
			--note)     _need_val verdict "$1" $#; note="$2"; shift 2 ;;
			--override) override=1; shift ;;
			*) _die "verdict: unknown argument '$1'" ;;
		esac
	done
	[[ -n $findings ]] || _die "verdict: usage: verdict --findings N | --none [--note TEXT] [--override]"
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

	# `verdict --findings N` with N>0 used to be trusted on its word: nothing
	# checked that the findings were ever posted somewhere the fixer (or
	# anyone outside this pane) could actually read them. A reviewer could
	# run --findings 3 having only thought about the findings, and the relay
	# would send the fixer to read comments that don't exist (issue #47).
	# So: if there are findings and no --note, require at least one PR
	# comment *since this round started* as evidence the findings are
	# readable outside this pane. This does not try to match the count —
	# one comment can carry three findings — it only checks that
	# *something new* was posted. Comparing against a per-round baseline
	# (not just "any comment ever") matters from round 2 onward: without
	# it, a stale round-1 comment would keep satisfying every later round's
	# guard even though nothing new was ever published.
	# --override exists for the reviewer's own genuine can't-publish case
	# (no network, PR closed) — not as a routine substitute for --note.
	# Reaching for it is common under pressure (an unpublished-finding
	# verdict is exactly the failure this guard exists to catch), so a
	# bypass must never be silent: `bypassed` below is recorded in member
	# state and emitted as its own event, and the worker relay is told
	# the findings were asserted rather than published, so it stops
	# there instead of hunting for comments that were never posted.
	#
	# The two channels are counted *separately* and either one is accepted as
	# evidence (issue #60). Summing them meant a reviewer who posted a single
	# issue-level summary and no inline comments passed the guard, while the
	# relay still sent the fixer to `pulls/N/comments` — an endpoint that
	# returns 0 for exactly that reviewer. From the fixer's side that is
	# indistinguishable from the #47 failure this guard exists to catch. So
	# the channel that actually grew is recorded in `verdict_channel` and the
	# relay points the fixer at that one.
	local bypassed=0 channel=""
	if (( findings > 0 )) && [[ -z $note ]]; then
		if (( override )); then
			bypassed=1
		else
			local pr wt counts base_issue base_inline pub_issue pub_inline
			pr=$(apex_member_get "$manager" "$member" pair_pr)
			wt=$(apex_member_get "$manager" "$member" worktree)
			if [[ -z $pr || -z $wt || ! -d $wt ]]; then
				_die "verdict: refusing --findings ${findings} — could not determine the PR or worktree to check for published comments (pair_pr='${pr}', worktree='${wt}'); nothing recorded. Pass --note TEXT to record the findings inline instead"
			fi
			counts=$(_pair_comment_counts "$wt" "$pr") || \
				_die "verdict: refusing --findings ${findings} — could not confirm findings were published on PR #${pr} (failed to query GitHub); nothing recorded. Post the findings first, or pass --note TEXT to record them inline. (--override exists only for a genuine can't-publish case — e.g. no network — and is recorded as a bypass, visible to the human, not a quiet way past this)"
			pub_issue=${counts%% *}; pub_inline=${counts##* }
			base_issue=$(apex_member_get "$manager" "$member" pair_comment_baseline); [[ $base_issue == <-> ]] || base_issue=0
			# An *absent* inline baseline is not a zero one. Unlike
			# pair_comment_baseline, which `link` has always stamped, this
			# field is new: a pair linked before it existed has no value to
			# compare against, and defaulting to 0 would let inline comments
			# from *earlier* rounds pass this round's guard — the #47
			# false-pass, reintroduced for the length of the upgrade window.
			# So treat unmeasurable as not-grown, and let only the channel
			# with a real baseline satisfy the guard. A non-numeric value is
			# corruption rather than absence and still clamps to 0.
			base_inline=$(apex_member_get "$manager" "$member" pair_inline_baseline)
			if [[ -z $base_inline ]]; then
				base_inline=$pub_inline
			elif [[ $base_inline != <-> ]]; then
				base_inline=0
			fi
			# When both grew, say so: naming only one would leave the fixer
			# unaware of half the findings, which is the same
			# guard-and-relay disagreement in the other direction.
			if (( pub_inline > base_inline && pub_issue > base_issue )); then
				channel=both
			elif (( pub_inline > base_inline )); then
				channel=inline
			elif (( pub_issue > base_issue )); then
				channel=issue
			else
				_die "verdict: refusing --findings ${findings} — PR #${pr} has no comments published since this round started (inline ${base_inline}→${pub_inline}, issue-level ${base_issue}→${pub_issue}); nothing recorded. The fixer would be sent to read nothing. Post the findings as PR comments first — inline comments anchored to a file and line are preferred — or pass --note TEXT to record them inline. (--override exists only for a genuine can't-publish case — e.g. no network — and is recorded as a bypass, visible to the human, not a quiet way past this)"
			fi
		fi
	fi

	apex_member_merge "$manager" "$member" "$(jq -nc \
		--arg r "$round" --arg f "$findings" --arg n "$note" --argjson o "$bypassed" --arg c "$channel" \
		'{verdict_round:$r, verdict_findings:$f, verdict_note:$n, verdict_override:(if $o == 1 then "1" else "" end), verdict_channel:$c}')"
	apex_event "$manager" "$(jq -nc --arg s "$member" --arg r "$round" \
		--argjson f "$findings" --arg n "$note" --argjson o "$bypassed" --arg c "$channel" \
		'{event:"pair-verdict", session:$s, round:$r, findings:$f, note:$n, override:($o == 1), channel:$c}')"
	if (( bypassed )); then
		apex_event "$manager" "$(jq -nc --arg s "$member" --arg r "$round" --argjson f "$findings" \
			'{event:"pair-verdict-override", session:$s, round:$r, findings:$f}')"
	fi

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
	local -i attempt=${4:-0}
	APEX_SESSION="$manager"
	[[ $(apex_member_get "$manager" "$session" seq) == "$seq" ]] || return 0
	[[ $(apex_member_get "$manager" "$session" settled_seq) == "$seq" ]] && return 0
	apex_member_merge "$manager" "$session" "$(jq -nc --argjson seq "$seq" '{settled_seq:$seq}')"
	_record_status "$manager" "$session" idle

	# An outstanding deferred relay gets first refusal on this transition. It is
	# the cheapest moment to settle one: something in the pair has just stopped
	# working, which is precisely the new information a deferral is waiting for
	# (issue #49). Either it resolves as delivered — and the loop carries on
	# below, which is the common case when the *target* is the one settling,
	# having just finished the relayed work — or it consumed the transition, by
	# escalating or by deferring again, and there is nothing for the loop to
	# advance on top of.
	local drc=0
	_pair_defer_settle "$manager" "$session" || drc=$?
	if (( drc == 3 )); then
		# Another trigger is mid-decision. Give the transition back rather than
		# spending it: put settled_seq back so this seq is eligible again, and
		# re-arm the callback. Without that the transition is gone for good —
		# nothing else re-derives it — and the loop would sit still waiting on a
		# partner it never relayed to. The cost is one extra idle status event
		# per retry, which is the honest record of what happened.
		(( attempt += 1 ))
		local _PAIR_DEFER_SECS _PAIR_DEFER_MAX _PAIR_DEFER_TICKS _PAIR_DEFER_RETRIES
		_pair_defer_knobs
		if (( attempt > _PAIR_DEFER_RETRIES )); then
			_pair_defer_wedged "$manager" "$session" "$attempt"
			return 0
		fi
		apex_member_merge "$manager" "$session" '{"settled_seq":""}'
		tmux run-shell -b -d "$APEX_QUIET_SECS" \
			"${SELF} _settle ${(q)session} ${(q)manager} ${seq} ${attempt}" 2>/dev/null || true
		return 0
	fi
	if (( drc )); then return 0; fi

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
	manager=$(_require_manager) || exit 1
	APEX_SESSION="$manager"

	local -a rows=()
	local s facts stored merged
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		facts=$(_member_facts "$s" --with-pane-input --with-remote)
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
				--arg auth "$(_apex_status_authority "$manager")" \
				--arg selfrev "$(_apex_status_authority "$manager" self_review)" \
				'{manager:$m, merge_authority:$auth, self_review_authority:$selfrev,
				  members:., recent_events:$ev}'
		return
	fi

	print "Apex manager: $manager"
	print "State: $(apex_dir "$manager")"
	print "Authority: $(apex_authority_describe "$(_apex_status_authority "$manager")" \
		"$(_apex_status_authority "$manager" self_review)")"
	if (( ${#rows} == 0 )); then
		print "\nNo members yet. Spawn one with: ${SELF##*/} spawn --issue N"
		return
	fi
	print ""
	# AGENT is wide because "needs-attention" now carries its reason inline —
	# the boolean on its own was the defect (issue #63), so the reason travels
	# in the column the manager already reads rather than in a footnote it
	# might not.
	printf '%-34s %-8s %-34s %-12s %s\n' SESSION ROLE AGENT TASK STATE
	local r
	for r in "${rows[@]}"; do
		printf '%s' "$r" | jq -r '
			[ .session,
			  (.role // "?"),
			  (if .alive|not then "dead"
			    elif .agent == "needs-attention" then
			      "needs-attention(" + (if (.attention_reason // "") != "" then .attention_reason else "unknown" end) + ")"
			    else (.agent // "?") end),
			  ((if .issue != "" and .issue != null then "issue#" + .issue
			    elif .review_pr != "" and .review_pr != null then "pr#" + .review_pr
			    else "-" end)),
			  ([ (if .branch != "" then .branch else empty end),
			     (if .pr_number != "" then "PR#" + .pr_number
			        + (if .pr_draft == "true" then " draft" else "" end)
			        + (if .pr_state != "" and .pr_state != "OPEN" then " " + (.pr_state|ascii_downcase) else "" end)
			      else empty end),
			     (if .branch == "" then empty
			      elif .commits_ahead == null then "unpushed?"
			      elif .commits_ahead > 0 then (.commits_ahead|tostring) + " ahead"
			      else empty end),
			     (if .dirty then "dirty" else empty end) ] | join(", "))
			] | @tsv' \
		| while IFS=$'\t' read -r c1 c2 c3 c4 c5; do
			printf '%-34s %-8s %-34s %-12s %s\n' "$c1" "$c2" "$c3" "$c4" "$c5"
		done
	done
	# An agent pane can show text sitting unsent in its input box. That text is
	# very often Claude Code's own autosuggestion — it predicts a plausible next
	# input and paints it into the idle box — and from outside the pane it is
	# indistinguishable from something having been typed or injected there
	# (issue #10). Name that ambiguity here so nobody spends an hour chasing a
	# delivery bug that isn't one, and nobody submits a guess by accident.
	local unsent=()
	local u
	for r in "${rows[@]}"; do
		# Not for a member at a permission dialog: the dialog is drawn in the
		# same box as the prompt, so `_pane_input_line` reads its selected
		# choice ("1. Yes") as pending input. Reporting that as unsent text is
		# worse than saying nothing — it invites submitting it, which is
		# answering a safety prompt by accident.
		u=$(printf '%s' "$r" | jq -r '
			if .attention_reason == "permission-prompt" then empty
			else "\(.session)\t\(.pane_input // "")" end')
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

	# The reason alone says which of the three situations a member is in; the
	# dialog's own text says what the answer should be. In the seven-hour case
	# this was written for, the correct answer was *decline*, and nothing short
	# of the command text could have told the manager that — so print it here
	# rather than making it a second `tmux capture-pane` the manager only runs
	# once it already suspects something.
	local blocked=()
	# Declared outside the render loop below — see _attention_reason_of on why
	# a repeated bare `local` inside a loop starts printing itself.
	local bs="" rest=""
	for r in "${rows[@]}"; do
		u=$(printf '%s' "$r" | jq -r '
			if .alive and .agent == "needs-attention"
			   and (.attention_reason // "") != ""
			   and .attention_reason != "idle"
			then "\(.session)\t\(.attention_reason)\t\(.attention_detail // "")"
			else empty end')
		[[ -n $u ]] && blocked+=("$u")
	done
	if (( ${#blocked} )); then
		print "\nMembers waiting on a decision:"
		for r in "${blocked[@]}"; do
			bs=${r%%$'\t'*}; rest=${r#*$'\t'}
			printf '  %-32s %s\n' "$bs" "${rest%%$'\t'*}"
			[[ -n ${rest#*$'\t'} ]] && printf '  %-32s %s\n' "" "${rest#*$'\t'}"
		done
		print "  A permission-prompt member is blocked until someone answers it and will"
		print "  not transition again, so it will not ping again either. Read the text,"
		print "  then answer in its pane — declining is often the right call. An"
		print "  interrupted member is alive but done responding: '${SELF##*/} send' it."
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
#
# The second half of the predicate is the member that never reached its first
# turn (issue #42). `starting` is written once, at registration, and is only
# ever moved off by the member's own hooks — so an agent whose launch failed,
# whose hooks are not wired, or that came back from `recover` and is sitting at
# an empty prompt stays `starting` with seq 0 for as long as the pane lives,
# and every reporting path used to agree it had nothing to say. That was a
# silent 24h stall on two workers. Past APEX_STARTING_STALE seconds, never
# having taken a turn is not a state, it is a failure, so report it.
#
# Gated on seq 0 as well as on status, not status alone: a member that has run
# turns and is somehow back at `starting` has a live agent and a different
# problem. And gated on `spawned_at` being present — records written before
# that field existed read as "spawned just now" and are never called stale,
# which is the safe direction for a check whose false positive tells the
# manager to go poke a healthy worker.
#
# Note that this reports *once*, like every other reportable state: the
# `--mark-delivered` CAS advances pinged_seq to 0, which equals the stalled
# member's seq, so the member falls out of the predicate again. One nudge is
# the whole point — it breaks the silence and hands the manager a member key.
# It deliberately does not keep repeating, because a manager that has been
# told and has chosen to wait should not be re-interrupted every minute.
_APEX_REPORTABLE_JQ='def stale_after:
	(env.APEX_STARTING_STALE | tonumber?)
	// (env._APEX_STARTING_STALE_DEFAULT | tonumber?)
	// 900;
def stalled_start:
	.status == "starting"
	and (.seq // 0) == 0
	and (.spawned_at != null)
	and (now - .spawned_at) >= stale_after;
def attn_stale_after:
	(env.APEX_ATTENTION_STALE | tonumber?)
	// (env._APEX_ATTENTION_STALE_DEFAULT | tonumber?)
	// 900;
def stalled_attention:
	.status == "attention"
	and (.updated_at != null)
	and (now - .updated_at) >= attn_stale_after
	and (.attention_escalated_seq // -1) != (.seq // 0);
def reportable:
	(((.seq // 0) != (.pinged_seq // -1))
	 and (((.pair_message // "") != "")
	      or .status == "idle" or .status == "attention"
	      or stalled_start))
	or stalled_attention;
'

# How long a member may sit at `starting`, never having taken a turn, before
# `reportable` calls it a failure. Generous by default: a cold agent launch on a
# loaded machine is seconds, not minutes, but a spawn that is merely slow must
# never be reported as broken.
#
# Exported because the predicate reads it out of the environment rather than
# taking it as a `--argjson` binding, and a value set in the invoking shell
# without `export` would otherwise be invisible to jq while looking configured.
#
# Reading it there, and reading the clock via jq's own `now`, is what keeps the
# predicate a *self-contained* string. The alternative — two bindings every
# reader has to remember to pass — puts back exactly the drift the shared
# definition exists to prevent (issue #23), and fails in the worst available
# direction: a reader that forgets them makes jq exit non-zero, which reads as
# "nothing to report" on every path at once. `tonumber?` on both branches is
# the same argument for a garbage value: clamp in the predicate, where no caller
# can skip it, rather than at a door there is no single one of. That is also why
# the last fallback is a literal and not the env lookup: an env var can be
# absent, and `stale_after` returning null would make `>= stale_after` true for
# every member — reporting healthy workers, the one direction this check must
# not fail in. The literal is a backstop, not a second configuration point, and
# `tests/apex-watch.test.sh` pins it equal to the binding below.
#
# One binding for the number otherwise, referenced everywhere it is needed — the
# default itself, the predicate's fallback, and the warning that quotes it.
# Written out three times it would drift, and the failure is quiet in the worst
# way: a clamp that reverts to one value while the warning names another.
_APEX_STARTING_STALE_DEFAULT=900

# How long a member may sit in `attention` after its one delivery before
# `reportable` says it again — the second half of the issue-#63 fix, and the
# half that actually closes the seven-hour hole.
#
# The first report of an `attention` member goes out on its seq bump like any
# other transition, and then the reporting stops, because reporting is keyed
# on transitions and a *blocked* member has none left to make. The condition
# most in need of reporting is the one that stops generating reports, so "no
# news" and "still working" read identically. Past this threshold, silence in
# `attention` is itself the event.
#
# Unlike `stalled_start` this is not gated on the reason. A member Claude Code
# has explicitly said wants input, still wanting it a quarter of an hour
# later, is worth one line whichever of the reasons it is — and gating on the
# reason would put the pane heuristic on the critical path of the escalation
# that exists because the heuristic might be wrong. The reason is reported
# alongside, live, so the manager still learns which case it is.
_APEX_ATTENTION_STALE_DEFAULT=900

# Two clamps, because the diagnostic and the safety net are independent and only
# one of them can be inside the predicate. `<->` is the stricter test of the two
# and it runs here: `tonumber?` screens non-numeric, not nonsense, so it takes
# `15m` for 900 without a word — the operator asked for fifteen minutes and got
# fifteen minutes of a different unit — and accepts `-5`, which makes
# `(now - .spawned_at) >= -5` true for a member spawned a second ago and reports
# every starting member at once. Say so and use the default instead; the
# predicate's own clamp stays as the backstop for values that never came through
# here.
if [[ -n ${APEX_STARTING_STALE:-} && $APEX_STARTING_STALE != <-> ]]; then
	print -u2 "${SELF:-tmux-apex}: APEX_STARTING_STALE='${APEX_STARTING_STALE}' is not a whole number of seconds; using ${_APEX_STARTING_STALE_DEFAULT}"
	APEX_STARTING_STALE=$_APEX_STARTING_STALE_DEFAULT
fi
APEX_STARTING_STALE=${APEX_STARTING_STALE:-$_APEX_STARTING_STALE_DEFAULT}

# Same clamp, same reasoning, same failure direction as APEX_STARTING_STALE
# above: a garbage value here would make `(now - .updated_at) >= x` true for
# every member and report the whole team at once.
if [[ -n ${APEX_ATTENTION_STALE:-} && $APEX_ATTENTION_STALE != <-> ]]; then
	print -u2 "${SELF:-tmux-apex}: APEX_ATTENTION_STALE='${APEX_ATTENTION_STALE}' is not whole seconds; using ${_APEX_ATTENTION_STALE_DEFAULT}"
	APEX_ATTENTION_STALE=$_APEX_ATTENTION_STALE_DEFAULT
fi
APEX_ATTENTION_STALE=${APEX_ATTENTION_STALE:-$_APEX_ATTENTION_STALE_DEFAULT}
export APEX_STARTING_STALE _APEX_STARTING_STALE_DEFAULT
export APEX_ATTENTION_STALE _APEX_ATTENTION_STALE_DEFAULT

_cmd_pending() {
	local mark=false a
	for a in "$@"; do [[ $a == --mark-delivered ]] && mark=true; done

	local manager
	manager=$(_require_manager) || exit 1
	APEX_SESSION="$manager"

	local s st seq rawseq role task facts summary pair_msg spawned age
	local attn_reason attn_detail attn_note esc since
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

		# Why this member wants attention, and whether it is being reported
		# only because it has been wanting it for a while (issue #63). The
		# reason is read live off the pane, not out of the record: the record
		# is written by the member's hook at the moment the flag flips, and
		# the dialog can render a beat after that.
		attn_reason=""; attn_detail=""; attn_note=""; esc=false
		if [[ $st == attention ]]; then
			attn_reason=$(printf '%s' "$facts" | jq -r '.attention_reason // ""')
			attn_detail=$(printf '%s' "$facts" | jq -r '.attention_detail // ""')
			[[ -z $attn_reason ]] && attn_reason=unknown
			jq -e "$_APEX_REPORTABLE_JQ"'stalled_attention' \
				"$(apex_member_file "$manager" "$s")" >/dev/null 2>&1 && esc=true
		fi
		case "$attn_reason" in
			permission-prompt)
				attn_note=" It is stopped at a permission/safety dialog it cannot dismiss itself, so it will not move or report again until someone answers it. \`bypassPermissions\` does not override the safety classifier. Read the dialog text, then answer in its pane — declining is often the right call.${attn_detail:+ Dialog: ${attn_detail}}" ;;
			interrupted)
				attn_note=" Its turn died mid-response, so the agent is alive and idle but has no intention of continuing, and may have uncommitted work. Tell it to carry on with '${SELF} send ${s} <continue where you left off>'.${attn_detail:+ Pane: ${attn_detail}}" ;;
			unknown)
				attn_note=" Its pane shows neither a dialog nor a ready input box, so why it is waiting could not be determined — look at it with 'tmux capture-pane -p -t ${s}' before assuming it is fine." ;;
		esac
		# Only the escalation says how long, because only there is the
		# duration the reason for the line existing at all.
		if $esc; then
			since=$(apex_member_get "$manager" "$s" updated_at)
			[[ $since == <-> ]] && attn_note=" It has been waiting $(( $(date +%s) - since ))s and has not transitioned since, which is why this is being raised without being asked — a blocked member generates no further pings.${attn_note}"
		fi

		if [[ -n $pair_msg ]]; then
			print "[apex] session=${s} role=${role} ${task:+task=${task} }— ${pair_msg} (${summary})"
		elif [[ $st == starting ]]; then
			# A stalled start needs a different line from every other report,
			# because the manager's usual reflex — read the member's facts, decide
			# what to tell it next — is wrong here. Nothing has happened yet, the
			# facts line describes a worktree nobody has touched, and the actual
			# question is whether the agent is even running. Say that, and say the
			# two things that fix it.
			spawned=$(apex_member_get "$manager" "$s" spawned_at)
			age=""
			[[ $spawned == <-> ]] && age=" for $(( $(date +%s) - spawned ))s"
			print "[apex] session=${s} role=${role} ${task:+task=${task} }status=starting${age} — it has never taken a turn. Its agent may have failed to launch, its hooks may not be wired (${SELF} doctor), or it was recovered and is waiting at an empty prompt. Look at the pane, then either '${SELF} send ${s} <continue where you left off>' or recover/respawn it. Not reported again unless it changes."
		else
			# attention carries its reason inline: from the ping line alone,
			# "blocked at a dialog nobody can answer" and "ended its turn at
			# an empty prompt" used to read identically (issue #63).
			print "[apex] session=${s} role=${role} ${task:+task=${task} }status=${st}${attn_reason:+(${attn_reason})} — ${summary}.${attn_note} Full state: ${SELF} status --json"
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
		#
		# A staleness escalation needs its own marker rather than riding on
		# pinged_seq. pinged_seq already equals seq by the time it fires — the
		# member's one transition was delivered long ago — so advancing it
		# marks nothing, and the escalation would repeat on every pull. Record
		# the seq it escalated instead: one line per attention episode, and a
		# later transition (new seq) earns a fresh one.
		if $mark; then
			apex_member_merge_cas "$manager" "$s" "$(jq -nc \
				--argjson seq "$seq" --arg msg "$pair_msg" --argjson esc "$esc" \
				'{pinged_seq:$seq}
				 + (if $msg == "" then {} else {pair_message:""} end)
				 + (if $esc then {attention_escalated_seq:$seq} else {} end)')" \
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
	# branch that was never pushed has no upstream, so rev-list fails. That
	# failure now reports as null rather than 0 (issue #57), which is honest but
	# still not an answer — and this path needs an answer, because the member
	# whose count is unknowable is precisely the one whose work reap destroys.
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
		# GIT_TERMINAL_PROMPT=0 for the same reason `_commits_ahead` sets it,
		# and more urgently: a remote that wants credentials would otherwise
		# block on a prompt nobody can see, and this is the destructive path —
		# a hang here means the HOLD decision never gets made at all.
		remote_sha=$(GIT_TERMINAL_PROMPT=0 git -C "$wt" ls-remote origin "refs/heads/${branch}" 2>/dev/null | cut -f1) || remote_sha=""
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
	# `gh pr view` for baseRefName first and keep the chain strictly for when
	# there is no PR to ask, or gh cannot answer (issue #40).
	if [[ -n $unpushed ]] && (( unpushed > 0 )) && [[ $pr_state == MERGED ]]; then
		local base="" b base_ref=""
		local -a bases=()
		if [[ -n $pr_number ]]; then
			base_ref=$(cd "$wt" && gh pr view "$pr_number" --json baseRefName -q .baseRefName 2>/dev/null) || base_ref=""
			[[ $base_ref == null ]] && base_ref=""
		fi
		if [[ -n $base_ref ]]; then
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
			#
			# `|| true`, like every other git call here: this function is
			# eval'd into the test suite's shell under `err_return`, where a
			# bare failing command returns from the function before it can
			# print anything — and an empty return is what _cmd_reap reads
			# as "safe to reap". 2>/dev/null hides the message, not the exit
			# status.
			git -C "$wt" fetch -q origin \
				"+refs/heads/${base_ref}:refs/remotes/origin/${base_ref}" 2>/dev/null || true
			# And nothing else. The chain is what you consult when you have
			# no answer; once the PR has given one, substituting a different
			# base is not a fallback, it is a wrong answer with a fallback's
			# manners. A fetch that fails — offline, expired auth, deleted
			# base branch — used to fall through to origin/main here, which
			# is the pre-fix bug reached by a narrower door. Leaving `base`
			# empty instead skips the tree comparison, keeps `unpushed`
			# non-zero, and holds the member: unknown is not fine, which is
			# the same rule this change put in criterion 3.
			bases=("refs/remotes/origin/${base_ref}")
		else
			bases=(refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/master)
		fi
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

# _reap_live_pr_state <facts> — re-reads $facts with pr_state replaced by a
# live `gh pr view`, or with .pr_state_unknown:true if that call fails.
#
# `_member_facts` reads pr_state from the on-disk PR cache, which nothing
# invalidates when a PR merges (issue #50): the same reap run that should be
# catching a just-merged PR sees whatever state was cached before the merge,
# and reports "Nothing to reap" for the member whose job this run exists to
# do. `reap` already pays for a `ls-remote` and a `gh pr view` per candidate
# in `_reap_risk`, so one more `gh pr view` for a member with a known PR
# number is the same budget, not a new one — reap is explicit,
# low-frequency, and destructive.
#
# A failed call must not fall back to the stale cached state: that state is
# exactly what caused the bug, so silently trusting it again would just move
# the failure mode from "network hiccup" to "network hiccup, indefinitely".
# Marking it unknown lets the caller hold the member and say so, rather than
# quietly treating a member that might already be mergeable as not-yet-ready.
_reap_live_pr_state() {
	local facts="$1" wt pr_number live
	wt=$(printf '%s' "$facts" | jq -r '.worktree')
	pr_number=$(printf '%s' "$facts" | jq -r '.pr_number // ""')
	if [[ -z $pr_number ]]; then
		print -r -- "$facts"
		return 0
	fi
	live=""
	if [[ -n $wt && -d $wt ]]; then
		live=$(cd "$wt" && gh pr view "$pr_number" --json state -q .state 2>/dev/null) || live=""
	fi
	if [[ -n $live ]]; then
		printf '%s' "$facts" | jq --arg s "$live" '.pr_state = $s'
	else
		printf '%s' "$facts" | jq '.pr_state_unknown = true'
	fi
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
	manager=$(_require_manager) || exit 1
	APEX_SESSION="$manager"

	local -a done_members=() held=() unknown=()
	local s facts alive pr_state pr_unknown risk
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		facts=$(_member_facts "$s")
		facts=$(_reap_live_pr_state "$facts")
		alive=$(printf '%s' "$facts" | jq -r '.alive')
		pr_state=$(printf '%s' "$facts" | jq -r '.pr_state')
		pr_unknown=$(printf '%s' "$facts" | jq -r '.pr_state_unknown // false')
		if [[ $alive == false || $pr_state == MERGED || $pr_state == CLOSED ]]; then
			risk=$(_reap_risk "$facts")
			if [[ -n $risk ]] && ! $force; then
				held+=("$s")
				print "  $s  — HOLD: $risk — $(_facts_line "$facts")"
			else
				done_members+=("$s")
				print "  $s  — $(_facts_line "$facts")"
			fi
		elif [[ $alive == true && $pr_unknown == true ]]; then
			unknown+=("$s")
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

	if (( ${#unknown} )); then
		print "\n${#unknown} member(s) skipped: could not reach \`gh\` to confirm PR"
		print "state for ${(j:, :)unknown} — not the same as confirmed still open,"
		print "so re-run reap once \`gh\` is reachable rather than trusting this pass."
	fi

	if (( ${#done_members} == 0 )); then
		if (( ${#held} )); then
			print "\nNothing reaped."
		elif (( ${#unknown} )); then
			print "\nCould not determine PR state for ${#unknown} member(s); nothing else to reap."
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

# How long `recover` waits, after a nudge is delivered, for the member to
# actually start a turn. Any turn moves it — `event set` fires on the first tool
# call and `event clear` on Stop, and both bump seq and write status — so this
# covers "the agent accepted the keystrokes", not the whole turn.
APEX_RECOVER_NUDGE_CONFIRM=${APEX_RECOVER_NUDGE_CONFIRM:-45}

# _apex_nudge_confirmed <manager> <member> <seconds> — did the member actually
# start a turn?
#
# `_pane_is_agent` is the strongest precondition available before typing, and it
# is not strong enough to justify the claim `recover` prints: it compares
# `#{pane_current_command}`, which proves the agent process execed, not that its
# TUI is accepting input. On the `--resume` path specifically that gap is wide —
# claude execs and then spends time restoring the conversation, and the longer
# the transcript the wider it gets, which is exactly the case `recover` exists
# for. Keystrokes typed into that window are dropped, and `_send_to_pane` cannot
# tell: an empty `_pane_input_line` reads the same whether the box is ready and
# empty or has not been drawn yet, and its post-send "our text is no longer
# pending" check is trivially satisfied by text that was never accepted.
#
# So do not infer the outcome from the delivery. Read the member's own state,
# which its hooks write and nothing here can fake, and report what it says.
# Costs a few file reads and the wait, and turns a confident wrong line into a
# hedged right one.
_apex_nudge_confirmed() {
	local manager="$1" member="$2" secs="$3"
	[[ $secs == <-> ]] || secs=45
	local -i i st_seq
	local st
	for (( i = 0; i <= secs; i++ )); do
		st=$(apex_member_get "$manager" "$member" status 2>/dev/null)
		st_seq=$(apex_member_get "$manager" "$member" seq 2>/dev/null) || st_seq=0
		# An unreadable record is not confirmation: an empty status must not
		# pass for "no longer starting". Fail towards the hedged line — the
		# stale-start report picks the member up either way.
		[[ ( -n $st && $st != starting ) || $st_seq -gt 0 ]] && return 0
		(( i < secs )) && sleep 1
	done
	return 1
}

# How long `recover` waits for a resumed agent's pane to actually be running an
# agent before it gives up on nudging it. A cold launch is seconds; this is the
# ceiling for "something went wrong", and it is what a `recover --yes` of a
# broken member costs in wall-clock, so it is not generous.
APEX_RECOVER_NUDGE_WAIT=${APEX_RECOVER_NUDGE_WAIT:-60}

# _apex_wait_for_agent <pane> <seconds> — block until <pane> is running a
# coding agent, or give up.
#
# Needed because a freshly split pane is a *shell* for the first second or two:
# tmux returns the pane id the moment the split exists, long before
# `direnv exec … zsh -ic 'claude …'` has execed anything. Sending into it then
# would run the message as a shell command, which _pane_is_agent exists to
# prevent — so the choice is to wait for the agent or not to nudge at all.
_apex_wait_for_agent() {
	local pane="$1" secs="$2"
	local -i ticks
	[[ $secs == <-> ]] || secs=60
	ticks=$(( secs * 2 ))
	(( ticks < 1 )) && ticks=1
	local -i i
	for (( i = 1; i <= ticks; i++ )); do
		_pane_is_agent "$pane" && return 0
		(( i < ticks )) && sleep 0.5
	done
	return 1
}

# _apex_continue_resumed <manager> <member> <pane> — tell a just-resumed agent
# to carry on (issue #42).
#
# The resume path gives DELTA_AGENT_RESUME precedence over DELTA_AGENT_PROMPT on
# purpose, so a recovered worker cannot re-run its task and duplicate commits.
# The cost of that correctness is that the agent comes back and sits at an empty
# prompt forever: `status` says `starting`, seq never moves, and (before the
# reportable change above) nothing anywhere would ever say so. Two workers sat
# like that for ~24h.
#
# So `recover` delivers the nudge a human otherwise has to type. This is not the
# task prompt — see delta_resume_continuation — so the no-duplicate-work
# property the resume path buys is untouched.
#
# Synchronous, and reported line by line, on purpose. A backgrounded nudge would
# make `recover --yes` return before anyone knows whether the member is actually
# working, which is the same "looks like recovery worked" failure the transcript
# resolution above was written to avoid. Waiting a few seconds per member is the
# cheaper half of that trade, and it means the printed output — the only thing
# the manager reads — states plainly which members were nudged and which are
# still sitting at a prompt.
_apex_continue_resumed() {
	local manager="$1" member="$2" pane="$3" text rc=0
	source "${SCRIPTS}/lib/agent-prompts.sh"
	text=$(delta_resume_continuation)

	local -a ev=(--arg s "$member")
	if [[ ${APEX_RECOVER_NUDGE:-1} != 1 ]]; then
		print "  NOT nudged (APEX_RECOVER_NUDGE=${APEX_RECOVER_NUDGE}): it is waiting at an empty prompt and will not start on its own."
		print "  Send it a continuation yourself: ${SELF} send ${member} <continue where you left off>"
		apex_event "$manager" "$(jq -nc "${ev[@]}" \
			'{event:"recover-continue", session:$s, delivered:false, reason:"disabled"}')"
		return 0
	fi

	if ! _apex_wait_for_agent "$pane" "$APEX_RECOVER_NUDGE_WAIT"; then
		print "  NOT nudged: pane ${pane} was still not running an agent after ${APEX_RECOVER_NUDGE_WAIT}s, so it is waiting at an empty prompt and will not start on its own."
		print "  Its launch may have failed. Look at the pane; if the agent is up, ${SELF} send ${member} <continue where you left off>"
		apex_event "$manager" "$(jq -nc "${ev[@]}" \
			'{event:"recover-continue", session:$s, delivered:false,
			  reason:"pane never came up as an agent"}')"
		return 0
	fi

	_deliver "$member" recover "$text" || rc=$?
	if (( rc != 0 )); then
		print "  NOT nudged: delivery failed (rc=${rc}); it is waiting at an empty prompt."
		print "  Retry with: ${SELF} send ${member} <continue where you left off>"
		apex_event "$manager" "$(jq -nc "${ev[@]}" --argjson rc "$rc" \
			'{event:"recover-continue", session:$s, delivered:false, deliver_rc:$rc}')"
		return 0
	fi

	local confirmed=true
	_apex_nudge_confirmed "$manager" "$member" "$APEX_RECOVER_NUDGE_CONFIRM" || confirmed=false

	if $confirmed; then
		print "  Nudged it to continue (${_DELIVER_VIA}) — it has started a turn."
	else
		# Delivered but never acted on. The likeliest cause is the one
		# _pane_is_agent cannot rule out: the agent had execed but was still
		# restoring its conversation, and the keystrokes went nowhere.
		print "  Nudged it (${_DELIVER_VIA}), but it has NOT started a turn after ${APEX_RECOVER_NUDGE_CONFIRM}s."
		[[ -n ${APEX_SEND_UNCONFIRMED:-} ]] \
			&& print "  Its input box never drained either, so the keystrokes may never have been accepted."
		print "  It was probably still restoring its conversation when the nudge was typed. Look at the pane; if it is idle at an empty prompt, ${SELF} send ${member} <continue where you left off>"
		print "  If it really never starts, it stays status=starting and \`pending\` reports it after ${APEX_STARTING_STALE}s."
	fi

	apex_event "$manager" "$(jq -nc "${ev[@]}" --arg text "$text" \
		--arg via "${_DELIVER_VIA:-}" --arg unconf "${APEX_SEND_UNCONFIRMED:-}" \
		--argjson conf "$confirmed" \
		'{event:"recover-continue", session:$s, delivered:true, confirmed:$conf,
		  via:$via, text:$text}
		 + (if $unconf != "" then {unconfirmed:true} else {} end)')"
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
	manager=$(_require_manager) || exit 1
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
			# A resumed agent restores context and waits; a fresh one was launched
			# with the task prompt and is already working. Only the first needs
			# telling to carry on, and only the first must never be re-prompted.
			_apex_continue_resumed "$manager" "$new_key" "$pane"
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
		manager=$(_require_manager) || exit 1
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

	# Authority is advisory here too, and for the same reason as the poller: not
	# having it is a correct state, not a broken one, so it never moves the exit
	# code. It is reported because an authority the agent cannot see is one it
	# will forget it does not have (issue #41).
	# Both the answer and the hint come off one key, and the line says which repo
	# that key is. The first cut read the answer from the manager's repo and the
	# hint from $PWD's, so run from a worker worktree with a different origin it
	# could report "granted" and "never answered for this repo" together, each
	# true of a different repo and the pair true of neither.
	local auth_line ans self akey arepo
	arepo=$(_apex_authority_repo "$mgr" 2>/dev/null) || arepo="$PWD"
	akey=$(apex_repo_key "$arepo" 2>/dev/null) || akey=""
	if [[ -n $akey ]]; then
		ans=$(apex_authority_get "$akey")
		self=$(apex_authority_get "$akey" self_review)
	else
		ans=unknown
		self=no
	fi
	auth_line="Merge authority: $(apex_authority_describe "$ans" "$self")"
	auth_line+=$'\n  for '"$arepo"$' ('"${akey:-not a git repository}"$')'
	if [[ $ans == no ]] && ! apex_authority_answered "$akey"; then
		auth_line+=$'\n  Never answered for that repo. Grant it with\n  '"'${SELF} authority --grant'"$' — apex never decides this for itself.'
	fi

	if (( ${#missing} == 0 )); then
		$quiet || print "Ping delivery: all hooks wired (${(j:, :)present})."
		$quiet || print "$watch_line"
		$quiet || print "$auth_line"
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
	print -u2 "$auth_line"
	return 1
}

# ─── dispatch ────────────────────────────────────────────────────────

case "${1:-}" in
	init)     shift; _cmd_init "$@" ;;
	authority) shift; _cmd_authority "$@" ;;
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
	_pair-defer-check) shift; _cmd_pair_defer_check "$@" ;;
	_register-member) shift; _cmd_register_member "$@" ;;
	*)
		print "tmux-apex.sh — apex mode for tmux-delta"
		print ""
		print "  init [--force] [--merge yes|no] mark this session as the apex manager"
		print "       [--self-review yes|no]    --merge answers the merge-authority question"
		print "                                 non-interactively; with no flag init asks only"
		print "                                 if a human is watching, and an unasked repo"
		print "                                 gets no merge authority. --self-review adds the"
		print "                                 second axis and needs --merge yes"
		print "  authority [--grant|--revoke]   show or set this repo's merge authority"
		print "            [--self-review yes|no] (every repo starts with none; the two axes are"
		print "            [--ask] [--json]     separate — merging a reviewed PR vs merging on"
		print "                                 apex's own review). Granting needs a terminal."
		print "  stop                           leave manager mode (members keep running)"
		print "  relink                         re-derive role/linkage after a session restart"
		print "  spawn --issue N [opts]         spawn a worker on a GitHub issue"
		print "  spawn --review-pr N [opts]     spawn a reviewer on a pull request"
		print "      opts: --profile NAME       named {agent,model,agent-flags} preset (see 'profiles')"
		print "            --role worker|monitor --agent claude|pi|codex|opencode"
		print "            --model M"
		print "            --agent-flags ARGV --mode autonomous|interactive --switch"
		print "                                 (--mode autonomous is refused with a permission mode"
		print "                                  that pauses for approval, e.g. acceptEdits)"
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
		print "                                 and nudging each resumed agent to continue"
		print "  profiles                       list available spawn profiles"
		print "  doctor                         check that ping-delivery hooks are wired"
		[[ -n ${1:-} ]] && exit 1
		;;
esac
