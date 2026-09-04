#!/usr/bin/env zsh
# Tests for scripts/lib/agent-adapter.sh — delta_agent_exec's refusal to launch
# an agent that has nothing to do (#68).
#
# The real function ends in `exec`, so every case runs in a subshell with a stub
# agent on PATH that records its argv to $STUB_LOG and exits 0 (or non-zero, to
# simulate "nothing to resume" and arm the fresh-session fallback).
#
# Run: tests/agent-adapter.test.sh

set -u
emulate -L zsh
setopt err_return

LIB="${0:A:h:h}/scripts/lib/agent-adapter.sh"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-adapter-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
# The expected value is the RIGHT operand of [[ == ]], which is a glob pattern
# there — so it is quoted in every helper below. Unquoted, a stray `*` in agent
# output would make an assertion pass that should fail.
eq() {
	if [[ $3 == "$2" ]]; then ok "$1"; else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}
contains() {
	if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi
}

BIN="$TMPROOT/bin"
mkdir -p "$BIN"
STUB_LOG="$TMPROOT/argv.log"

# pi: fails when asked to resume (nothing to resume here), succeeds otherwise —
# which is exactly the shape that arms the fresh-session fallback.
cat > "$BIN/pi" <<'STUB'
#!/usr/bin/env zsh
argv_str="${(j: :)@}"
print -r -- "${0:t}${argv_str:+ $argv_str}" >> "$STUB_LOG"
[[ ${1:-} == --continue ]] && exit 1
exit 0
STUB
chmod +x "$BIN/pi"
# Same stub as claude: the only adapter that honours DELTA_AGENT_RESUME.
cp "$BIN/pi" "$BIN/claude"
cp "$BIN/pi" "$BIN/codex"

# A refusal ends the pane's only command, so it pins the pane before printing.
# The stub records those writes; nothing else here talks to tmux.
TMUX_LOG="$TMPROOT/tmux.log"
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env zsh
print -r -- "${(j: :)@}" >> "$TMUX_LOG"
exit 0
STUB
chmod +x "$BIN/tmux"
PATH="$BIN:$PATH"

# run [-a <agent>] <name>=<value>... — call delta_agent_exec with the given
# environment (every DELTA_AGENT_* var defaults to empty), printing
# "<status>|<stderr>".
run() {
	: > "$STUB_LOG"
	: > "$TMUX_LOG"
	local agent=pi
	if [[ ${1:-} == -a ]]; then agent="$2"; shift 2; fi
	(
		export STUB_LOG TMUX_LOG
		export TMUX="/tmp/fake-tmux,1,0" TMUX_PANE="%7"
		export DELTA_AGENT_MODEL="" DELTA_AGENT_FLAGS="" DELTA_AGENT_SYSTEM=""
		export DELTA_AGENT_PROMPT="" DELTA_AGENT_DIR="$TMPROOT"
		export DELTA_AGENT_RESUME="" DELTA_AGENT_MANAGED=""
		local kv
		for kv in "$@"; do export "$kv"; done
		local st=0 err
		err=$( { source "$LIB"; delta_agent_exec "$agent" } 2>&1 >/dev/null ) || st=$?
		print -r -- "$st|$err"
	)
}

print "delta_agent_exec: managed launch with no task"

out=$(run DELTA_AGENT_MANAGED=1)
eq   "refuses (exit 78)"            "78" "${out%%|*}"
contains "names both empty task inputs" "DELTA_AGENT_PROMPT and DELTA_AGENT_RESUME are both empty" "$out"
contains "points at the session env the task comes from" "CODING_AGENT_ISSUE / CODING_AGENT_PR" "$out"
contains "names the agent"               "managed agent 'pi'" "$out"
eq   "never invokes the agent"      "" "$(cat "$STUB_LOG")"
contains "pins the pane so the message can be read" \
	"set-option -p -t %7 remain-on-exit on" "$(cat "$TMUX_LOG")"
contains "flags the pane for a human" \
	"set-option -p -t %7 @agent_needs_attention 1" "$(cat "$TMUX_LOG")"
# The pane flag is discarded by agent-icons-refresh.sh once the pane is a dead
# shell, so the session-scoped write is the one apex status actually reads.
contains "flags the session, which apex status reads" \
	"set-option -t %7 @agent_needs_attention 1" "$(cat "$TMUX_LOG")"

out=$(run DELTA_AGENT_MANAGED=1 DELTA_AGENT_SYSTEM='you are managed')
eq   "a system prompt alone is still no task" "78" "${out%%|*}"
eq   "still never invokes the agent"          "" "$(cat "$STUB_LOG")"

print ""
print "delta_agent_exec: launches that do carry a task"

out=$(run DELTA_AGENT_MANAGED=1 DELTA_AGENT_PROMPT='GitHub issue #68.')
contains "a task prompt launches"       "pi GitHub issue #68." "$(cat "$STUB_LOG")"

out=$(run -a claude DELTA_AGENT_MANAGED=1 DELTA_AGENT_RESUME=abc123)
contains "a resume id launches on an adapter that reads it" "--resume abc123" "$(cat "$STUB_LOG")"

print ""
print "delta_agent_exec: resume by id needs an adapter that reads it"

# pi resumes with --continue and opencode the same; codex has `resume --last`.
# All three mean "whatever ran last in this directory", which in a worktree a
# worker shares with its reviewer is a coin flip between the two conversations.
for a in pi codex; do
	out=$(run -a $a DELTA_AGENT_MANAGED=1 DELTA_AGENT_RESUME=abc123)
	eq   "$a: refuses a resume id it cannot honour" "78" "${out%%|*}"
	contains "$a: names the id that would be dropped" "DELTA_AGENT_RESUME=abc123" "$out"
	eq   "$a: never invokes the agent"              "" "$(cat "$STUB_LOG")"
done

# ...and a task prompt is the documented way out, on those same adapters.
out=$(run -a pi DELTA_AGENT_MANAGED=1 DELTA_AGENT_RESUME=abc123 DELTA_AGENT_PROMPT='GitHub issue #68.')
contains "a task prompt makes the launch legal again" "pi GitHub issue #68." "$(cat "$STUB_LOG")"

print ""
print "delta_agent_exec: unmanaged human open"

# `o` on a plain session: nothing configured, resume fails, and a bare
# interactive agent in this directory is the intended result — not an error.
out=$(run)
eq   "resume is attempted then falls back" "pi --continue
pi" "$(cat "$STUB_LOG")"
eq   "no refusal"                          "0" "${out%%|*}"

# But dropping configuration that WAS supplied is an adapter bug, not a
# fallback: the fresh argv would strip the model the caller asked for.
print ""
print "delta_agent_exec: adapter drops configured inputs"

cat > "$TMPROOT/agents-empty.sh" <<'ADAPTER'
delta_agent_argv() {
	agent_argv=(--continue)
	agent_argv_fresh=()
	agent_argv_fresh_set=1
}
ADAPTER
out=$(
	: > "$STUB_LOG"
	(
		export STUB_LOG
		export DELTA_AGENT_MODEL="opus" DELTA_AGENT_FLAGS="" DELTA_AGENT_SYSTEM=""
		export DELTA_AGENT_PROMPT="" DELTA_AGENT_DIR="$TMPROOT"
		export DELTA_AGENT_RESUME="" DELTA_AGENT_MANAGED=""
		source "$LIB"
		DELTA_AGENT_LIBDIR="$TMPROOT/nonexistent"
		# Point the loader at the stub adapter by name.
		mkdir -p "$TMPROOT/lib/agents"
		cp "$TMPROOT/agents-empty.sh" "$TMPROOT/lib/agents/pi.sh"
		DELTA_AGENT_LIBDIR="$TMPROOT/lib"
		local st=0 err
		err=$( { delta_agent_exec pi } 2>&1 >/dev/null ) || st=$?
		print -r -- "$st|$err"
	)
)
eq   "refuses (exit 78)"                 "78" "${out%%|*}"
contains "says no configuration survived" "no configuration survived into pi.sh's fresh-session argv" "$out"
eq   "the resume attempt is all it ran"  "pi --continue" "$(cat "$STUB_LOG")"

print ""
print "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
