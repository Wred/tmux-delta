#!/usr/bin/env zsh
# Tests for scripts/agent-icons-refresh.sh — the per-agent icon string behind
# the session pills.
#
# The script only talks to tmux, so a stub tmux on PATH is enough: pane state
# comes from $STUB_PANES (one "pane|role|present|working|attention" line per
# pane) and every write is appended to $STUB_LOG.
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
case "$1 $2" in
	"list-panes -s")
		if [[ "$*" == *"@apex_role"* ]]; then printf '%s\n' "$STUB_PANES"
		else printf '%s\n' "$STUB_PANES" | sed 's/|.*//'; fi
		exit 0 ;;
	"list-sessions -F") printf '%s\n' "$STUB_SESSIONS"; exit 0 ;;
	"display-message -p") printf '%s\n' "$STUB_SESSION"; exit 0 ;;
esac
case "$1" in
	set-option) echo "set-option $*" >> "$STUB_LOG"; exit 0 ;;
	refresh-client) exit 0 ;;
esac
case "$*" in
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
export STUB_SESS_WORKING="" STUB_SESS_ATTENTION=""

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
contains "idle agent gets the plain robot"   "$IDLE"    "$out"
contains "working agent gets the excited robot" "$WORKING" "$out"
n=$(print -r -- "$out" | grep -o "$IDLE\|$WORKING\|$ATTENTION" | grep -c .)
eq "two agent panes yield exactly two glyphs" 2 "$n"

# Each agent's state is its own — the session no longer has one shared state.
out=$(icons '%1|worker|1||1' '%2|worker|1|1|')
contains "blocked agent gets the confused robot" "$ATTENTION" "$out"
contains "its working sibling keeps the excited robot" "$WORKING" "$out"

# ── presence, not activity ───────────────────────────────────────────
print "presence"

out=$(icons '%1||1||')
contains "a non-apex pane with @agent_present shows an idle icon" "$IDLE" "$out"

out=$(icons '%1|||')
eq "a pane with neither role nor presence shows nothing" "" "$out"

out=$(icons '%1|worker||')
contains "an apex member with no hook events yet still shows" "$IDLE" "$out"

# Panes without agents are ignored, not counted.
out=$(icons '%1|worker|1||' '%2||||')
n=$(print -r -- "$out" | grep -o "$IDLE\|$WORKING\|$ATTENTION" | grep -c .)
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
contains "idle uses md-robot_outline"             "$IDLE_O"      "$out"
contains "working uses md-robot_excited_outline"  "$WORKING_O"   "$out"
contains "blocked uses md-robot_confused_outline" "$ATTENTION_O" "$out"
lacks "no filled idle glyph leaks in"    "$IDLE"      "$out"
lacks "no filled working glyph leaks in" "$WORKING"   "$out"
lacks "no filled attention glyph leaks in" "$ATTENTION" "$out"

# Same count, same order, same state colours — only the glyphs differ.
filled=$(icons '%1|worker|1||' '%2|worker|1|1|')
out=$(outline '%1|worker|1||' '%2|worker|1|1|')
eq "outline keeps the same glyph count" \
	"$(print -r -- "$filled" | grep -o "$IDLE\|$WORKING" | grep -c .)" \
	"$(print -r -- "$out" | grep -o "$IDLE_O\|$WORKING_O" | grep -c .)"

# Idle grey is unreadable on the selected pill's mauve background.
contains "selected-pill idle uses the dark foreground" "#11111b" "$out"

STUB_SESS_WORKING=1
out=$(outline '%1||||')
contains "the session-level fallback has an outline variant too" "$WORKING_O" "$out"
STUB_SESS_WORKING=""

# ── truncation ───────────────────────────────────────────────────────
print "truncation"

out=$(icons '%1|worker|1||' '%2|worker|1||' '%3|worker|1||' '%4|worker|1||' \
            '%5|worker|1||' '%6|worker|1||')
n=$(print -r -- "$out" | grep -o "$IDLE" | grep -c .)
eq "at most four glyphs are drawn" 4 "$n"
contains "the rest collapse into a counter" "+2" "$out"

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

print ""
print "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
