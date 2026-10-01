#!/usr/bin/env zsh

# The manager pill outliving apex mode.
#
# @apex_role is durable state keyed on a tmux session *name*, but apex mode only
# exists inside the one agent conversation that ran `init`. /clear ends that
# conversation and leaves both the tmux session and the on-disk record standing,
# so relink kept re-asserting the role — and the status-bar pill kept claiming
# apex mode at an agent with no apex context at all.
#
# The agent's own session id is what tells the two cases apart: `--continue`
# carries it forward (relink must still re-link), /clear mints a new one (the
# role must expire). Covered here, with tmux and the state dir stubbed:
#
#   1. same id           -> role kept
#   2. different id      -> role expired, manager-stop written
#   3. no id stored (a pre-change record) -> adopted, not expired
#   4. no id knowable    -> kept, nothing written
#   5. expiry is durable -> the next relink does not resurrect it
#   6. other harnesses   -> a pi manager is judged by PI_SESSION_ID, and a
#                           variable leaked from a parent agent is ignored
#   7. pane moved        -> the manager's @agent_pane follows its agent, so the
#                           watcher is not left nudging a dead pane

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-relink-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq() {
	if [[ $2 == $3 ]]; then ok "$1"
	else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}

# ─── fake environment ────────────────────────────────────────────────

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"
export TMUX=fake-socket
export XDG_CACHE_HOME="$TMPROOT/cache"
export HOME="$TMPROOT/home"; mkdir -p "$HOME"
APEX_ROOT="$XDG_CACHE_HOME/tmux-delta/apex"
SESSION=mgr

STUB="$TMPROOT/stub"; mkdir -p "$STUB"
export STUB
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env zsh
emulate -L zsh
_key() { print -r -- "${1//[^a-zA-Z0-9]/_}" }
case "$1" in
display-message) print -r -- "${STUB_SESSION:-mgr}" ;;
show-option)
	local scope=session target="" key=""
	if [[ $2 == -p ]]; then scope=pane; target="$4"; key="$6"
	else target="$3"; key="$5"; fi
	cat "$STUB/opt.${scope}.$(_key "$target").$(_key "$key")" 2>/dev/null
	;;
set-option)
	shift
	local scope=session unset=no target="" key="" val=""
	while (( $# )); do
		case "$1" in
			-p) scope=pane; shift ;;
			-g|-F) shift ;;
			-u) unset=yes; shift ;;
			-t) target="$2"; shift 2 ;;
			*)  if [[ -z $key ]]; then key="$1"; else val="$1"; fi; shift ;;
		esac
	done
	local f="$STUB/opt.${scope}.$(_key "$target").$(_key "$key")"
	if [[ $unset == yes ]]; then rm -f "$f"; else print -r -- "$val" > "$f"; fi
	;;
# The watcher daemon and redraws are not what this file is about.
run-shell|refresh-client|list-sessions|list-panes) : ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"

role()   { cat "$STUB/opt.session.${SESSION}._apex_role" 2>/dev/null }
last_ev() {
	jq -rs '[.[] | select(.event=="manager-init" or .event=="manager-stop")] | last | .event // empty' \
		"$APEX_ROOT/$SESSION/events.jsonl" 2>/dev/null
}
stored() { jq -r '.agent_session // empty' "$APEX_ROOT/$SESSION/apex.json" 2>/dev/null }

# A session that init left as manager, with $1 as the owning agent session id.
setup() {
	rm -rf "$APEX_ROOT" "$STUB"; mkdir -p "$APEX_ROOT/$SESSION/members" "$STUB"
	jq -nc --arg s "$SESSION" --arg r "$TMPROOT/repo" --arg a "$1" \
		'{session:$s, repo:$r, agent_pane:"%1", agent_session:$a, created_at:1}' \
		> "$APEX_ROOT/$SESSION/apex.json"
	jq -nc --arg s "$SESSION" '{event:"manager-init", session:$s}' \
		> "$APEX_ROOT/$SESSION/events.jsonl"
	print -r -- manager > "$STUB/opt.session.${SESSION}._apex_role"
}

# Every agent's session variable is cleared first: the suite itself runs under
# some coding agent, whose own id must not leak into these assertions.
AGENT_VARS=(CLAUDE_CODE_SESSION_ID PI_SESSION_ID CODEX_THREAD_ID OPENCODE_SESSION_ID DELTA_AGENT_SESSION_ID)
relink() {
	( unset $AGENT_VARS
	  [[ -n ${1:-} ]] && export CLAUDE_CODE_SESSION_ID="$1"
	  STUB_SESSION="$SESSION" TMUX_PANE="${RELINK_PANE:-%1}" \
		"$SCRIPTS/tmux-apex.sh" relink ) >/dev/null 2>&1 || true
}

# relink_as <agent> <var=value>... — relink from under a process named <agent>,
# which is how lib/agent-session.sh decides whose variable to read. A symlink
# to zsh is enough: ps reports it by the name it was exec'd as. The trailing
# `:` keeps that shell alive as a parent instead of exec'ing into its child.
FAKE="$TMPROOT/fake-agents"; mkdir -p "$FAKE"
relink_as() {
	local agent="$1"; shift
	ln -sf "$(command -v zsh)" "$FAKE/$agent"
	( unset $AGENT_VARS
	  export "$@"
	  STUB_SESSION="$SESSION" TMUX_PANE="${RELINK_PANE:-%1}" \
		"$FAKE/$agent" -c '"$0" relink; :' "$SCRIPTS/tmux-apex.sh" ) >/dev/null 2>&1 || true
}

# ─── 1. the same conversation keeps the role ─────────────────────────

print "same agent session"
setup agent-aaa
relink agent-aaa
eq "role kept"              manager      "$(role)"
eq "no stop event written"  manager-init "$(last_ev)"

# ─── 2. a new conversation (/clear) loses it ─────────────────────────

print "\nagent session changed"
setup agent-aaa
relink agent-bbb
eq "role expired"            ""           "$(role)"
eq "manager-stop written"    manager-stop "$(last_ev)"
eq "reason recorded"         agent-session-changed \
	"$(jq -rs 'last | .reason // empty' "$APEX_ROOT/$SESSION/events.jsonl")"

# ─── 5. and stays expired ────────────────────────────────────────────

relink agent-bbb
eq "next relink does not resurrect it" "" "$(role)"

# ─── 3. a record from before the field existed adopts ────────────────

print "\nrecord with no agent session"
setup ""
relink agent-bbb
eq "role kept"                manager     "$(role)"
eq "current agent adopted"    agent-bbb   "$(stored)"

# ─── 4. nothing knowable means nothing assumed ───────────────────────

print "\nno agent session in the environment"
setup agent-aaa
relink ""
eq "role kept"                manager      "$(role)"
eq "stored id untouched"      agent-aaa    "$(stored)"
eq "no stop event written"    manager-init "$(last_ev)"

# ─── 6. every harness, not just claude ───────────────────────────────

print "\npi manager"
setup pi-aaa
relink_as pi PI_SESSION_ID=pi-aaa
eq "the same pi conversation keeps the role" manager "$(role)"

relink_as pi PI_SESSION_ID=pi-bbb
eq "a new pi conversation expires it" "" "$(role)"

setup pi-aaa
relink_as pi PI_SESSION_ID=pi-aaa CLAUDE_CODE_SESSION_ID=leaked-from-a-parent
eq "a variable leaked from a parent agent is ignored" manager "$(role)"

print "\ncodex manager"
setup codex-aaa
relink_as codex CODEX_THREAD_ID=codex-bbb
eq "a new codex thread expires it" "" "$(role)"

# ─── 7. the manager's agent moved panes ──────────────────────────────

agent_pane() { cat "$STUB/opt.session.${SESSION}._agent_pane" 2>/dev/null }

print "\nmanager agent in a new pane"
setup pi-aaa
print -r -- '%44' > "$STUB/opt.session.${SESSION}._agent_pane"
RELINK_PANE='%130' relink_as pi PI_SESSION_ID=pi-aaa
eq "@agent_pane follows the agent" '%130' "$(agent_pane)"
eq "the move is logged" manager-pane \
	"$(jq -rs '[.[] | select(.event=="manager-pane")] | last | .event // empty' "$APEX_ROOT/$SESSION/events.jsonl")"

setup pi-aaa
print -r -- '%44' > "$STUB/opt.session.${SESSION}._agent_pane"
RELINK_PANE='%130' relink ""
eq "an unknown conversation does not move it" '%44' "$(agent_pane)"

setup pi-aaa
print -r -- '%44' > "$STUB/opt.session.${SESSION}._agent_pane"
print -r -- worker > "$STUB/opt.pane._130._apex_role"
RELINK_PANE='%130' relink_as pi PI_SESSION_ID=pi-aaa
eq "a member's pane is never adopted" '%44' "$(agent_pane)"

setup ""
# No repo on record, so re-derivation does not need $PWD to be that repo.
jq -c 'del(.repo)' "$APEX_ROOT/$SESSION/apex.json" > "$TMPROOT/apex.json" \
	&& mv "$TMPROOT/apex.json" "$APEX_ROOT/$SESSION/apex.json"
print -r -- '%44' > "$STUB/opt.session.${SESSION}._agent_pane"
rm -f "$STUB/opt.session.${SESSION}._apex_role"
RELINK_PANE='%130' relink_as pi PI_SESSION_ID=pi-aaa
eq "a re-derived manager adopts its pane too" '%130' "$(agent_pane)"

print ""
print "  $PASS passed, $FAIL failed"
(( FAIL == 0 ))
