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
eq() {
	if [[ $2 == $3 ]]; then ok "$1"; else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}
contains() {
	if [[ $3 == *$2* ]]; then ok "$1"; else bad "$1" "expected to contain: ${(qqq)2}
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
PATH="$BIN:$PATH"

# run [-a <agent>] <name>=<value>... — call delta_agent_exec with the given
# environment (every DELTA_AGENT_* var defaults to empty), printing
# "<status>|<stderr>".
run() {
	: > "$STUB_LOG"
	local agent=pi
	if [[ ${1:-} == -a ]]; then agent="$2"; shift 2; fi
	(
		export STUB_LOG
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
contains "names the missing task inputs" "DELTA_AGENT_PROMPT, DELTA_AGENT_RESUME" "$out"
contains "names the agent"               "managed agent 'pi'" "$out"
eq   "never invokes the agent"      "" "$(cat "$STUB_LOG")"

out=$(run DELTA_AGENT_MANAGED=1 DELTA_AGENT_SYSTEM='you are managed')
eq   "a system prompt alone is still no task" "78" "${out%%|*}"
eq   "still never invokes the agent"          "" "$(cat "$STUB_LOG")"

print ""
print "delta_agent_exec: launches that do carry a task"

out=$(run DELTA_AGENT_MANAGED=1 DELTA_AGENT_PROMPT='GitHub issue #68.')
contains "a task prompt launches"       "pi GitHub issue #68." "$(cat "$STUB_LOG")"

out=$(run -a claude DELTA_AGENT_MANAGED=1 DELTA_AGENT_RESUME=abc123)
contains "a resume id launches"         "--resume abc123" "$(cat "$STUB_LOG")"

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
contains "says the fresh argv was empty" "empty fresh-session argv" "$out"
eq   "the resume attempt is all it ran"  "pi --continue" "$(cat "$STUB_LOG")"

print ""
print "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
