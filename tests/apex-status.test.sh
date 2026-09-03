#!/usr/bin/env zsh

# `status` output hygiene (github issue #51).
#
# In zsh, `local name` with no value DISPLAYS the parameter if it already
# exists in the current scope — the same behavior as `typeset name` at top
# level. A `local u` sitting inside a `for` loop body is therefore silent on
# the first iteration and prints `u=$'...'` to stdout on every iteration
# after that. With two or more members, `status` leaked exactly such a line
# between the member table and the events list. tmux is stubbed; nothing
# here attaches to a real server.
#
# Run: tests/apex-status.test.sh

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-status-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
lacks() {
	if [[ $3 != *$2* ]]; then ok "$1"
	else bad "$1" "expected NOT to contain: ${(qqq)2}
       actual                 : ${(qqq)3}"; fi
}

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"
export TMUX=fake-socket
export XDG_CACHE_HOME="$TMPROOT/cache"
APEX_ROOT="$XDG_CACHE_HOME/tmux-delta/apex"

# Minimal tmux stub: enough for `status` to resolve the manager and treat
# every member as dead (no live panes), which is the case that still hits
# the leak — the bug fires on loop iteration count, not on member liveness.
STUB="$TMPROOT/stub"; mkdir -p "$STUB"
export STUB
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env zsh
emulate -L zsh
case "$1" in
display-message)
	print -r -- "${STUB_SESSION:-manager}"
	;;
show-option)
	if [[ $2 == -p ]]; then
		:
	else
		[[ $5 == @apex_role ]] && print -r -- manager
	fi
	;;
list-panes|list-sessions|has-session|kill-pane|kill-session|refresh-client|switch-client|run-shell|list-clients)
	:
	;;
*)
	:
	;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"

MANAGER=manager
export STUB_SESSION="$MANAGER"

member() {
	# member <key> <json>
	local f="$APEX_ROOT/$MANAGER/members/$1.json"
	mkdir -p "${f:h}"
	print -r -- "$2" | jq . > "$f"
}

member "worker-one:%1" '{"role":"worker","worktree":"","issue":"1","review_pr":"","agent":"claude","mode":"autonomous","model":"opus","permission_mode":"bypassPermissions","profile":"","status":"idle","seq":1}'
member "worker-two:%2" '{"role":"worker","worktree":"","issue":"2","review_pr":"","agent":"claude","mode":"autonomous","model":"opus","permission_mode":"bypassPermissions","profile":"","status":"idle","seq":1}'

apex() { "$SCRIPTS/tmux-apex.sh" "$@" }

out=$(apex status 2>&1)

lacks "status prints no bare shell-assignment line" $'\nu=' "$out"

typeset -a stray
stray=( ${(f)"$(print -r -- "$out" | grep -E '^[a-z_]+=' || true)"} )
if (( ${#stray} == 0 )); then
	ok "no output line matches ^[a-z_]*="
else
	bad "no output line matches ^[a-z_]*=" "stray line(s): ${(j:, :)stray}"
fi

print ""
print "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
