#!/usr/bin/env zsh
# Tests for scripts/agent-icons-refresh.sh — the per-agent icon string behind
# the session pills.
#
# The script only talks to tmux, so a stub tmux on PATH is enough: pane state
# comes from $STUB_PANES (one "pane|role|present|working|attention|command"
# line per pane) and every write is appended to $STUB_LOG.
#
# Run: tests/agent-icons.test.sh

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-icons-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }

eq() {
	if [[ $2 == $3 ]]; then ok "$1"; else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}
contains() {
	if [[ $3 == *$2* ]]; then ok "$1"; else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi
}
lacks() {
	if [[ $3 != *$2* ]]; then ok "$1"; else bad "$1" "expected NOT to contain: ${(qqq)2}
       actual                 : ${(qqq)3}"; fi
}

IDLE=$'\U000F06A9'
WORKING=$'\U000F16A3'
ATTENTION=$'\U000F169F'
IDLE_O=$'\U000F167A'
WORKING_O=$'\U000F16A4'
ATTENTION_O=$'\U000F16A0'

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
# Stub tmux. Reads pane state from $STUB_PANES, session state from
# $STUB_SESS_WORKING/$STUB_SESS_ATTENTION, and logs writes to $STUB_LOG.
case "$1" in
	list-panes)
		# With -s: every pane in the session. Without: the current window only,
		# which the stub models as $STUB_WINDOW_PANES.
		if [[ "$*" == *"@apex_role"* ]]; then printf '%s\n' "$STUB_PANES"
		elif [[ "$*" == *" -s "* ]]; then printf '%s\n' "$STUB_PANES" | sed 's/|.*//'
		else printf '%s\n' "${STUB_WINDOW_PANES:-$STUB_PANES}" | sed 's/|.*//'; fi
		exit 0 ;;
	list-sessions) printf '%s\n' "$STUB_SESSIONS"; exit 0 ;;
	display-message) printf '%s\n' "$STUB_SESSION"; exit 0 ;;
esac
case "$1" in
	set-option) echo "set-option $*" >> "$STUB_LOG"; exit 0 ;;
	refresh-client) exit 0 ;;
	show-options)
		# `show-options -p -t <pane>` lists only the options set on the pane
		# itself — no session fallback. agent-icons-refresh.sh uses that to tell
		# a real member from a pane that merely inherited the manager
		# session's @apex_role. Panes listed in $STUB_INHERITED_PANES model the
		# inherited-only case; every other pane owns its role locally.
		if [[ "$*" == *" -p "* ]]; then
			pane=""
			prev=""
			for arg in "$@"; do
				[[ "$prev" == "-t" ]] && pane="$arg"
				prev="$arg"
			done
			for skip in ${STUB_INHERITED_PANES:-}; do
				[[ "$skip" == "$pane" ]] && exit 0
			done
			role=$(printf '%s\n' "$STUB_PANES" | awk -F'|' -v p="$pane" '$1 == p { print $2; exit }')
			[[ -n "$role" ]] && echo "@apex_role $role"
		fi
		exit 0 ;;
esac
case "$*" in
	*@tmux_delta_agent_icons_max*) printf '%s\n' "$STUB_MAX" ;;
	*@tmux_delta_apex_agent_cmds*) printf '%s\n' "$STUB_AGENT_CMDS" ;;
	*@agent_icons_outline*)  printf '%s\n' "$STUB_PREV_OUTLINE" ;;
	*@agent_icons*)          printf '%s\n' "$STUB_PREV" ;;
	*@agent_needs_attention*) printf '%s\n' "$STUB_SESS_ATTENTION" ;;
	*@agent_working*)        printf '%s\n' "$STUB_SESS_WORKING" ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"

export PATH="$BIN:$PATH" TMUX=fake-socket LC_ALL=en_US.UTF-8
export STUB_LOG="$TMPROOT/tmux.log"
export STUB_SESSION=work STUB_SESSIONS=work STUB_PREV="" STUB_PREV_OUTLINE=""
export STUB_SESS_WORKING="" STUB_SESS_ATTENTION="" STUB_MAX="" STUB_WINDOW_PANES=""
export STUB_AGENT_CMDS="" STUB_INHERITED_PANES=""

# icons <panes...> — runs the script and prints the @agent_icons value written
# (empty when the script wrote nothing).
icons() {
	: > "$STUB_LOG"
	export STUB_PANES="${(F)@}"
	"$SCRIPTS/agent-icons-refresh.sh" work >/dev/null 2>&1
	local line
	line=$(grep '@agent_icons ' "$STUB_LOG" | tail -1)
	print -r -- "${line#*@agent_icons }"
}

# outline <panes...> — same, for the selected-pill variant.
outline() {
	: > "$STUB_LOG"
	export STUB_PANES="${(F)@}"
	"$SCRIPTS/agent-icons-refresh.sh" work >/dev/null 2>&1
	local line
	line=$(grep '@agent_icons_outline' "$STUB_LOG" | tail -1)
	print -r -- "${line#*@agent_icons_outline }"
}

# ── one icon per agent pane ──────────────────────────────────────────
print "per-agent icons"

out=$(icons '%1|worker|1||' '%2|reviewer|1|1|')
contains "idle agent gets the outline robot"   "$IDLE_O"    "$out"
contains "working agent gets the excited robot" "$WORKING" "$out"
n=$(print -r -- "$out" | grep -o "$IDLE_O\|$WORKING\|$ATTENTION" | grep -c .)
eq "two agent panes yield exactly two glyphs" 2 "$n"

# Each agent's state is its own — the session no longer has one shared state.
out=$(icons '%1|worker|1||1' '%2|worker|1|1|')
contains "blocked agent gets the confused robot" "$ATTENTION" "$out"
contains "its working sibling keeps the excited robot" "$WORKING" "$out"

# ── presence, not activity ───────────────────────────────────────────
print "presence"

out=$(icons '%1||1||')
contains "a non-apex pane with @agent_present shows an idle icon" "$IDLE_O" "$out"

out=$(icons '%1|||')
eq "a pane with neither role nor presence shows nothing" "" "$out"

out=$(icons '%1|worker||')
contains "an apex member with no hook events yet still shows" "$IDLE_O" "$out"

# The launching window: _cmd_register_member refreshes the icons immediately,
# while the pane is typically still sitting at the shell it spawned the agent
# from. @apex_role without @agent_present means "registered, never reported in"
# — nothing has been heard from the pane, so there is no stale presence to
# guard against and the icon appears at registration rather than a second later.
out=$(icons '%1|worker||||zsh')
contains "a launching apex member shows before its first hook event" "$IDLE_O" "$out"

# Once the pane HAS reported in, the exemption is gone and the ordinary idle
# check applies — otherwise an exited agent would keep an idle robot forever.
out=$(icons '%1|worker|1|||zsh')
eq "a reported-in apex member at a shell is dropped" "" "$out"

# tmux's pane->session option fallback means `list-panes -F '#{@apex_role}'`
# reports the manager session's role for every pane in it, including plain
# shells. Only a pane carrying its own local @apex_role counts as a member.
STUB_INHERITED_PANES='%1'
out=$(icons '%1|manager||||zsh')
eq "a pane that only inherited the session's @apex_role is ignored" "" "$out"

# ...and presence still stands on its own: the inherited role is discarded,
# but a hook that fired in this pane is direct evidence of an agent.
out=$(icons '%1|manager|1||')
contains "an inherited role still yields an icon when the pane reported in" "$IDLE_O" "$out"
STUB_INHERITED_PANES=""

# Panes without agents are ignored, not counted.
out=$(icons '%1|worker|1||' '%2||||')
n=$(print -r -- "$out" | grep -o "$IDLE_O\|$WORKING\|$ATTENTION" | grep -c .)
eq "editor pane adds no icon" 1 "$n"

# ── session-level fallback ───────────────────────────────────────────
# An agent whose hooks write only session-scoped state (older
# agent-tmux-status.sh, or hooks firing outside a tmux pane) must not lose its
# indicator entirely.
print "session-level fallback"

STUB_SESS_WORKING=1
out=$(icons '%1||||')
contains "session @agent_working still renders one icon" "$WORKING" "$out"
STUB_SESS_WORKING=""

STUB_SESS_ATTENTION=1
out=$(icons '%1||||')
contains "session @agent_needs_attention still renders one icon" "$ATTENTION" "$out"
STUB_SESS_ATTENTION=""

# Pane state wins: with agent panes present the aggregate is never consulted.
STUB_SESS_ATTENTION=1
out=$(icons '%1|worker|1||')
lacks "pane state takes precedence over the session aggregate" "$ATTENTION" "$out"
STUB_SESS_ATTENTION=""

# ── outline variants for the selected pill ───────────────────────────
# The pill for the active session is drawn from a different branch of
# status-format[0] and must use md-*_outline glyphs, per issue #15.
print "outline variants"

out=$(outline '%1|worker|1||' '%2|worker|1|1|' '%3|worker|1||1')
contains "idle stays the filled md-robot (not an outline)" "$IDLE"        "$out"
contains "working uses md-robot_excited_outline"           "$WORKING_O"   "$out"
contains "blocked uses md-robot_confused_outline"          "$ATTENTION_O" "$out"
lacks "no filled working glyph leaks in"   "$WORKING"   "$out"
lacks "no filled attention glyph leaks in" "$ATTENTION" "$out"

# Same count, same order — only idle's glyph shape, and every color, differ.
filled=$(icons '%1|worker|1||' '%2|worker|1|1|')
out=$(outline '%1|worker|1||' '%2|worker|1|1|')
eq "outline keeps the same glyph count" \
	"$(print -r -- "$filled" | grep -o "$IDLE_O\|$WORKING" | grep -c .)" \
	"$(print -r -- "$out" | grep -o "$IDLE\|$WORKING_O" | grep -c .)"

# Neither idle's plain-text color nor active mauve is readable on the
# selected pill's own mauve background, so both get redrawn in its dark
# foreground instead.
contains "selected-pill idle uses the dark foreground"   "#11111b" "$out"
n=$(print -r -- "$out" | grep -o '#11111b' | grep -c .)
eq "selected-pill working also uses the dark foreground, not mauve" 2 "$n"
lacks "no mauve leaks into the selected pill" "#cba6f7" "$out"

STUB_SESS_WORKING=1
out=$(outline '%1||||')
contains "the session-level fallback has an outline variant too" "$WORKING_O" "$out"
STUB_SESS_WORKING=""

# ── truncation ───────────────────────────────────────────────────────
print "truncation"

out=$(icons '%1|worker|1||' '%2|worker|1||' '%3|worker|1||' '%4|worker|1||' \
            '%5|worker|1||' '%6|worker|1||')
n=$(print -r -- "$out" | grep -o "$IDLE_O" | grep -c .)
eq "at most four glyphs are drawn" 4 "$n"
contains "the rest collapse into a counter" "+2" "$out"

# ── stale presence ───────────────────────────────────────────────────
# @agent_present is sticky for the life of the pane, so an exited agent would
# otherwise leave an idle robot on the pill forever.
print "stale presence"

out=$(icons '%1|worker|1|||zsh')
eq "an idle pane with no agent process shows nothing" "" "$out"

out=$(icons '%1|worker|1|||node')
contains "an idle pane still running the agent shows" "$IDLE_O" "$out"

# A working/attention pane is believed even when the foreground command is not
# an agent: the agent's own tool call can put anything there, and second-
# guessing it would blink the icon out mid-turn.
out=$(icons '%1|worker|1|1||git')
contains "a working pane survives a tool call in the foreground" "$WORKING" "$out"
out=$(icons '%1|worker|1||1|git')
contains "a blocked pane survives a tool call in the foreground" "$ATTENTION" "$out"

# ...with one exception: a bare login shell means nothing is running in the
# pane, so no tool call can be in flight. An agent killed or crashed mid-turn
# never fires `clear`, so its state flags stay set forever — without this the
# green or peach robot would persist for the life of the pane.
for sh in zsh bash fish; do
	out=$(icons "%1|worker|1|1||$sh")
	eq "an agent killed mid-turn drops its working glyph ($sh)" "" "$out"
	out=$(icons "%1|worker|1||1|$sh")
	eq "an agent killed while blocked drops its glyph ($sh)" "" "$out"
done

# `sh` and `dash` are NOT in that list: an agent's own build script or
# `#!/bin/sh` git hook shows up as the foreground command mid-turn, so reading
# them as death would blink the glyph out during genuine work.
for sh in sh dash; do
	out=$(icons "%1|worker|1|1||$sh")
	contains "a $sh subprocess keeps the working glyph" "$WORKING" "$out"
	out=$(icons "%1|worker|1||1|$sh")
	contains "a $sh subprocess keeps the blocked glyph" "$ATTENTION" "$out"
done

# The session aggregate is stale in exactly the same way (a killed agent fires
# no `clear` at either scope), so pruning the last agent pane must not fall
# through to it — that is the common one-agent-per-session case.
STUB_SESS_WORKING=1
out=$(icons '%1|worker|1|1||zsh')
eq "a pruned pane does not fall through to the stale session aggregate" "" "$out"
STUB_SESS_WORKING=""

# A glob in the command lists compares literally rather than expanding against
# the cwd. Run from a directory holding a file named exactly like the pane's
# command, so an unprotected `*` in the list would expand to it and wrongly
# count the pane as an agent — without that file the assertion passes for the
# wrong reason, since the glob just lands on names that cannot match anyway.
STUB_AGENT_CMDS='* node'
mkdir -p "$TMPROOT/globcwd"
: > "$TMPROOT/globcwd/definitely-not-an-agent"
out=$(cd "$TMPROOT/globcwd" && icons '%1||1|||definitely-not-an-agent')
eq "a '*' in the agent command list does not match everything" "" "$out"
STUB_AGENT_CMDS=""

# Same exposure through SHELL_CMDS, for symmetry: the list is a fixed literal
# in the script today, but _in_list is shared and a glob must not turn a
# working pane's command into a "the agent is gone" match.
mkdir -p "$TMPROOT/globcwd2"
: > "$TMPROOT/globcwd2/some-build-step"
out=$(cd "$TMPROOT/globcwd2" && icons '%1|worker|1|1||some-build-step')
contains "a working pane is not pruned by a glob against the cwd" "$WORKING" "$out"

# An unknown command is never read as death — better a stale glyph than an
# agent that vanishes from the pill while it is working.
out=$(icons '%1|worker|1|1||')
contains "an unknown foreground command keeps the working glyph" "$WORKING" "$out"

# ── overflow carries the most urgent hidden state ────────────────────
# The alarm-colored pill background is gone, so a blocked agent hidden behind
# +N would have no signal anywhere if the counter were always muted.
print "overflow urgency"

five_with() {
	icons '%1|worker|1||' '%2|worker|1||' '%3|worker|1||' '%4|worker|1||' "$1"
}
out=$(five_with '%5|worker|1||1')
contains "+N goes mauve when a blocked agent is hidden" "#cba6f7]+1" "$out"
out=$(five_with '%5|worker|1|1|')
contains "+N goes mauve when a working agent is hidden" "#cba6f7]+1" "$out"
out=$(five_with '%5|worker|1||')
contains "+N matches plain text when only idle agents are hidden" "#cdd6f4]+1" "$out"

# ── configurable cap ─────────────────────────────────────────────────
print "icon cap"

STUB_MAX=2
out=$(icons '%1|worker|1||' '%2|worker|1||' '%3|worker|1||')
n=$(print -r -- "$out" | grep -o "$IDLE_O" | grep -c .)
eq "@tmux_delta_agent_icons_max caps the glyphs" 2 "$n"
contains "and the remainder still counts" "+1" "$out"
STUB_MAX="bogus"
out=$(icons '%1|worker|1||' '%2|worker|1||' '%3|worker|1||' '%4|worker|1||' '%5|worker|1||')
eq "a non-numeric cap falls back to 4" 4 "$(print -r -- "$out" | grep -o "$IDLE_O" | grep -c .)"
STUB_MAX=""

# ── no-op writes ─────────────────────────────────────────────────────
print "change detection"

STUB_PREV=$(icons '%1|worker|1||')
STUB_PREV_OUTLINE=$(outline '%1|worker|1||')
: > "$STUB_LOG"
export STUB_PANES='%1|worker|1||'
"$SCRIPTS/agent-icons-refresh.sh" work >/dev/null 2>&1
eq "unchanged icons are not re-written" "" "$(grep -c '@agent_icons' "$STUB_LOG" | grep -v '^0$' || true)"

# A changed outline variant alone still triggers a write.
STUB_PREV_OUTLINE="stale"
: > "$STUB_LOG"
"$SCRIPTS/agent-icons-refresh.sh" work >/dev/null 2>&1
contains "a stale outline variant is rewritten" "@agent_icons_outline" "$(cat "$STUB_LOG")"
STUB_PREV="" STUB_PREV_OUTLINE=""

# ── ack clears attention everywhere ──────────────────────────────────
print "ack"

: > "$STUB_LOG"
export STUB_PANES=$'%1|worker|1||1\n%2|worker|1||1'
"$SCRIPTS/agent-icons-refresh.sh" --ack work >/dev/null 2>&1
log=$(cat "$STUB_LOG")
contains "ack clears the session flag"   "-u -t work @agent_needs_attention" "$log"
contains "ack clears pane %1's flag"     "-u -p -t %1 @agent_needs_attention" "$log"
contains "ack clears pane %2's flag"     "-u -p -t %2 @agent_needs_attention" "$log"

# Attention is per-agent now: an agent blocked in a window the user never
# looked at has not been seen, so ack must not reach it.
: > "$STUB_LOG"
export STUB_PANES=$'%1|worker|1||1\n%2|worker|1||1'
export STUB_WINDOW_PANES='%1|worker|1||1'
"$SCRIPTS/agent-icons-refresh.sh" --ack work >/dev/null 2>&1
log=$(cat "$STUB_LOG")
contains "ack reaches the current window's pane" "-u -p -t %1 @agent_needs_attention" "$log"
lacks "ack leaves other windows' panes flagged"  "-u -p -t %2 @agent_needs_attention" "$log"
export STUB_WINDOW_PANES=""

print ""
print "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
