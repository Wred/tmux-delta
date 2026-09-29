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
list-panes)
	# Members named in STUB_PANES are alive; everyone else is dead.
	[[ -n ${STUB_PANES:-} ]] && print -r -- "${STUB_PANES//,/$'\n'}"
	;;
list-sessions|has-session|kill-pane|kill-session|refresh-client|switch-client|run-shell|list-clients)
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

# ── The mode a session actually runs in, against the one it was spawned with ──
#
# A spawn asks for bypassPermissions, but policy can run the session in auto
# instead, and the record kept saying bypassPermissions while a classifier
# denied the reviewers' PR comments. `status` reads the mode from the member's
# own transcript, where each turn records the one it ran under.
has() {
	if [[ $3 == *$2* ]]; then ok "$1"
	else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi
}
export CLAUDE_CONFIG_DIR="$TMPROOT/claude"
WT="$TMPROOT/wt-reviewer"; mkdir -p "$WT"
TDIR="$CLAUDE_CONFIG_DIR/projects/${WT//[^a-zA-Z0-9]/-}"; mkdir -p "$TDIR"
# The last recorded mode wins: the session started in bypass, then ran in auto.
print -r -- '{"type":"user","permissionMode":"bypassPermissions","cwd":"'"$WT"'"}
{"type":"assistant","message":{"content":[]}}
{"type":"user","permissionMode":"auto","cwd":"'"$WT"'"}' > "$TDIR/sid-rev.jsonl"
member "reviewer:%3" '{"role":"worker","worktree":"'"$WT"'","issue":"","review_pr":"16","agent":"claude","mode":"review","model":"opus","permission_mode":"bypassPermissions","profile":"","status":"idle","seq":1,"agent_session_id":"sid-rev"}'

json=$(apex status --json 2>/dev/null)
eff=$(print -r -- "$json" | jq -r '.members[] | select(.session=="reviewer:%3") | .effective_permission_mode')
[[ $eff == auto ]] && ok "--json reports the transcript's last mode, not the spawn flag" \
	|| bad "--json reports the transcript's last mode, not the spawn flag" "got ${(qqq)eff}"
eff=$(print -r -- "$json" | jq -r '.members[] | select(.session=="worker-one:%1") | .effective_permission_mode')
[[ -z $eff ]] && ok "a member with no transcript reports no mode rather than a guess" \
	|| bad "a member with no transcript reports no mode rather than a guess" "got ${(qqq)eff}"

out=$(apex status 2>&1)
lacks "a dead member's old mode is not reported as drift" "different permission mode" "$out"

export STUB_PANES="reviewer:%3"
out=$(apex status 2>&1)
has "a live member in another mode is named" "reviewer:%3" "$out"
has "…with both modes" "running auto, spawned bypassPermissions" "$out"

print -r -- '{"type":"user","permissionMode":"bypassPermissions","cwd":"'"$WT"'"}' > "$TDIR/sid-rev.jsonl"
out=$(apex status 2>&1)
lacks "a member in the mode it asked for is not reported" "different permission mode" "$out"
unset STUB_PANES

print ""
print "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
