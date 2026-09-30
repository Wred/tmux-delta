#!/usr/bin/env zsh
# Which coding agent is running us, and which of its conversations — for every
# harness, not just claude (lib/agent-session.sh), and how a member's recorded
# conversation follows it (_record_agent_session in tmux-apex.sh).
#
# The ancestry walk is exercised with symlinks to zsh named after each agent:
# ps reports a process by the name it was exec'd as, which is exactly the
# signal the helper reads. A trailing `:` keeps such a shell alive as a parent
# rather than letting it exec into its only child.
#
# Run: tests/agent-session.test.sh
set -u
emulate -L zsh

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-session-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq() {
	if [[ $2 == $3 ]]; then ok "$1"
	else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}

# The suite runs under some agent; none of its own ids may leak in.
AGENT_VARS=(CLAUDE_CODE_SESSION_ID PI_SESSION_ID CODEX_THREAD_ID OPENCODE_SESSION_ID DELTA_AGENT_SESSION_ID)
unset $AGENT_VARS

FAKE="$TMPROOT/fake"; mkdir -p "$FAKE"
for a in claude pi codex opencode; do ln -s "$(command -v zsh)" "$FAKE/$a"; done

# under <agent> <shell-snippet> — run <snippet> with the helper sourced, as a
# child of a process named <agent>. Extra env comes from the caller.
under() {
	"$FAKE/$1" -c 'zsh -c ". \"$0\"; $1"; :' "$SCRIPTS/lib/agent-session.sh" "$2"
}

print "delta_agent_self"
for a in claude pi codex opencode; do
	eq "a $a ancestor is recognised" "$a" "$(under $a 'delta_agent_self')"
done
eq "the nearest agent wins over an outer one" pi \
	"$("$FAKE/claude" -c '"$0" -c "zsh -c \". $1; delta_agent_self\"; :"; :' "$FAKE/pi" "$SCRIPTS/lib/agent-session.sh")"
eq "posix sh can source it" pi \
	"$("$FAKE/pi" -c 'sh -c ". \"$0\"; delta_agent_self"; :' "$SCRIPTS/lib/agent-session.sh")"

print "\ndelta_agent_session_id"
eq "claude reads CLAUDE_CODE_SESSION_ID" c-1 "$(CLAUDE_CODE_SESSION_ID=c-1 under claude delta_agent_session_id)"
eq "pi reads PI_SESSION_ID"              p-1 "$(PI_SESSION_ID=p-1 under pi delta_agent_session_id)"
eq "codex reads CODEX_THREAD_ID"         x-1 "$(CODEX_THREAD_ID=x-1 under codex delta_agent_session_id)"
eq "opencode reads OPENCODE_SESSION_ID"  o-1 "$(OPENCODE_SESSION_ID=o-1 under opencode delta_agent_session_id)"
eq "a variable leaked from another agent is not read" "" \
	"$(CLAUDE_CODE_SESSION_ID=leaked under pi delta_agent_session_id)"
eq "a named agent pins the variable" p-2 \
	"$(CLAUDE_CODE_SESSION_ID=leaked PI_SESSION_ID=p-2 under claude 'delta_agent_session_id pi')"
eq "an explicit handoff beats everything" h-1 \
	"$(DELTA_AGENT_SESSION_ID=h-1 PI_SESSION_ID=p-3 under pi delta_agent_session_id)"
eq "no recognisable ancestor falls back to whichever is set" p-4 \
	"$(PI_SESSION_ID=p-4 zsh -c ". $SCRIPTS/lib/agent-session.sh; delta_agent_self() { return 1 }; delta_agent_session_id")"

# ─── _record_agent_session ───────────────────────────────────────────

print "\n_record_agent_session"
source "$SCRIPTS/lib/agent-session.sh"
DELTA_DEFAULT_AGENT=pi
eval "$(sed -n '/^_record_agent_session()/,/^}/p' "$SCRIPTS/tmux-apex.sh")"
(( ${+functions[_record_agent_session]} )) || { print -u2 "could not extract _record_agent_session"; exit 1; }

typeset -A REC=()
# Runs inside $(...), so it counts through a file, not a variable.
SCANS="$TMPROOT/scans"; : > "$SCANS"
scans() { grep -c '' "$SCANS" }
apex_member_get()   { print -r -- "${REC[$3]:-}" }
apex_member_merge() { REC[agent_session_id]=$(jq -r '.agent_session_id' <<< "$3") }
apex_event()        { : }
_agent_session_for() { print >> "$SCANS"; print -r -- scanned-id }
WT="$TMPROOT/wt"; mkdir -p "$WT"

REC=(agent pi worktree "$WT")
PI_SESSION_ID=live-1 _record_agent_session mgr m
eq "a member's live conversation is recorded" live-1 "${REC[agent_session_id]}"
eq "without scanning its session store" 0 "$(scans)"

PI_SESSION_ID=live-2 _record_agent_session mgr m
eq "a new conversation (/new, /clear) replaces it" live-2 "${REC[agent_session_id]}"

CLAUDE_CODE_SESSION_ID=leaked _record_agent_session mgr m
eq "another agent's variable does not" live-2 "${REC[agent_session_id]}"

REC=(agent claude worktree "$WT")
_record_agent_session mgr m
eq "with nothing published, the session store is scanned" scanned-id "${REC[agent_session_id]}"
_record_agent_session mgr m
eq "once" 1 "$(scans)"

print ""
print -- "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
