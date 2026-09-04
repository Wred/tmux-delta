#!/usr/bin/env zsh
# A spawn whose manager check fails must create nothing (issue #67).
#
# `_require_manager` dies, but every callsite reads it through
# `manager=$(_require_manager)` — and a command substitution is a subshell, so
# its `exit 1` ended the subshell and nothing else. The message went to stderr
# and `spawn` carried straight on with `manager=''`, creating a tmux session and
# a worktree for an agent registered to no manager: absent from `status`,
# unreachable by `send`, invisible to `reap`, and still running when the
# worktree was later pruned. The human found it by noticing a session name the
# manager had never mentioned.
#
# The assertion is what the issue asks for and not just the exit status: after a
# spawn whose manager check fails, no new tmux session and no new worktree
# exist. The stub picker is the only thing in this test that creates either, so
# it creates them for real — a session line and a worktree directory — and the
# test checks they are absent. A guard that merely printed and continued would
# leave both behind.
#
# Run: tests/apex-spawn-orphan.test.sh

set -u
emulate -L zsh
setopt extended_glob

SCRIPTS="${0:A:h:h}/scripts"

typeset -i PASS=0 FAIL=0
ok()  { print --    "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq() { if [[ $2 == $3 ]]; then ok "$1"; else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi }
contains() { if [[ $3 == *$2* ]]; then ok "$1"; else bad "$1" "expected to contain: ${(qqq)2}
       actual  : ${(qqq)3}"; fi }

# Matches the real _die: it exits, and the call under test runs in a subshell.
_die() { print -u2 "tmux-apex: $*"; exit 1 }

eval "$(sed -n '/^_cmd_spawn()/,/^}/p'        "$SCRIPTS/tmux-apex.sh")"
eval "$(sed -n '/^_need_val()/,/^}/p'         "$SCRIPTS/tmux-apex.sh")"
eval "$(sed -n '/^_require_manager()/,/^}/p'  "$SCRIPTS/tmux-apex.sh")"
for fn in _cmd_spawn _require_manager; do
	(( ${+functions[$fn]} )) || {
		print -u2 "apex-spawn-orphan.test.sh: could not extract ${fn} from tmux-apex.sh"
		exit 1
	}
done

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-spawn-orphan-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

SESSIONS="$TMPROOT/sessions"
WORKTREES="$TMPROOT/worktrees"
: > "$SESSIONS"
mkdir -p "$WORKTREES"

# Stands in for everything past the guard. Creating the session line and the
# worktree directory is what makes "nothing was created" a real assertion
# rather than a restatement of the exit status.
mkdir -p "$TMPROOT/scripts"
cat > "$TMPROOT/scripts/tmux-picker.sh" <<STUB
#!/usr/bin/env zsh
print -r -- "apex-issue-99" >> "$SESSIONS"
mkdir -p "$WORKTREES/apex-issue-99"
printf 'apex-session\tapex-issue-99\t$WORKTREES/apex-issue-99\n'
STUB
chmod +x "$TMPROOT/scripts/tmux-picker.sh"

apex_event() { : }
source "$SCRIPTS/lib/apex-profiles.sh"
APEX_PROFILES_USER_FILE="$TMPROOT/no-such-user-profiles.json"

# Not a command substitution: _cmd_spawn dies by `exit`, and that status has to
# survive to the assertion.
spawn_out() {  # spawn_out <args...> -> $SPAWN_OUT, $SPAWN_RC
	SPAWN_RC=0
	: > "$SESSIONS"
	rm -rf "$WORKTREES"; mkdir -p "$WORKTREES"
	( SCRIPTS="$TMPROOT/scripts"; _cmd_spawn "$@" ) > "$TMPROOT/spawn.out" 2>&1 || SPAWN_RC=$?
	SPAWN_OUT=$(< "$TMPROOT/spawn.out")
	SESSIONS_MADE=$(< "$SESSIONS")
	WORKTREES_MADE=$(print -rl -- "$WORKTREES"/*(N:t))
}

print -- "spawn with no manager"

# The failure mode: no manager session anywhere to resolve.
_resolve_manager() { return 1 }

spawn_out --issue 99
eq       "the spawn fails"                1 "$SPAWN_RC"
contains "saying why"                     "no apex manager for this session" "$SPAWN_OUT"
eq       "creating no tmux session"       "" "$SESSIONS_MADE"
eq       "and no worktree"                "" "$WORKTREES_MADE"

print -- "spawn with a manager"

# The mirror image, so the assertions above cannot pass by the spawn being
# broken for every input.
_resolve_manager() { print -r -- "stub-manager" }

spawn_out --issue 99
eq       "the spawn succeeds"             0 "$SPAWN_RC"
eq       "creating the tmux session"      "apex-issue-99" "$SESSIONS_MADE"
eq       "and its worktree"               "apex-issue-99" "$WORKTREES_MADE"

print
print -- "  ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
