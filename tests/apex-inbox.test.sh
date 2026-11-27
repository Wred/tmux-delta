#!/usr/bin/env zsh
# Tests for in-process delivery to pi (issue #78): the member inbox that
# `send` and pair relays write for a pi member whose extension advertises
# @apex_native_delivery, `tmux-apex.sh check`, and the `watch` skip for an
# advertising manager.
#
# A fake tmux on PATH answers the handful of calls involved; the member state
# is real, under a temp XDG_CACHE_HOME.
#
# Run: tests/apex-inbox.test.sh

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-inbox-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq()  { if [[ $2 == $3 ]]; then ok "$1"; else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi }
contains() { if [[ $3 == *$2* ]]; then ok "$1"; else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi }

# ── fake tmux ────────────────────────────────────────────────────────
# One member pane %5 in session w, managed by `mgr`. $NATIVE_PID is what the
# pane's @apex_native_delivery holds; every send-keys is logged to $KEYS_LOG.
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env zsh
case "$1" in
	list-panes)  print -r -- "w:%5"; print -r -- "%5"; print -r -- "%1" ;;
	has-session) exit 0 ;;
	display-message)
		case "$*" in
			*'#S'*) print -r -- "mgr" ;;
			*)      print -r -- node ;;
		esac ;;
	show-option)
		case "$*" in
			*@apex_native_delivery*) print -r -- "${NATIVE_PID:-}" ;;
			*@apex_session*)         print -r -- mgr ;;
			*"-t %5 "*@apex_role*)   print -r -- worker ;;
			*@apex_role*)            print -r -- manager ;;
			*@agent_pane*)           print -r -- "%1" ;;
		esac ;;
	send-keys)   shift; print -r -- "$*" >> "$KEYS_LOG" ;;
	capture-pane) print -r -- '│ >        │' ;;
esac
exit 0
STUB
chmod +x "$BIN/tmux"
export PATH="$BIN:$PATH" KEYS_LOG="$TMPROOT/keys" XDG_CACHE_HOME="$TMPROOT/cache"
export NATIVE_PID=$$

source "$SCRIPTS/tmux-apex.sh" >/dev/null 2>&1

MGR=mgr M='w:%5'
INBOX=$(apex_inbox_file "$MGR" "$M")
reset() {
	rm -rf "$(apex_dir "$MGR")"; apex_init_dirs "$MGR"; : > "$KEYS_LOG"
	jq -nc --arg a "${1:-pi}" '{agent:$a, status:"idle", seq:1, pinged_seq:1}' \
		> "$(apex_member_file "$MGR" "$M")"
}
keys() { cat "$KEYS_LOG" 2>/dev/null }
# The send-keys path itself is covered by apex-send.test.sh; here it only has
# to be visible whether it was taken.
_send_to_pane() { print -r -- "typed into $1: $2" >> "$KEYS_LOG" }

# ── send to a pi member ──────────────────────────────────────────────
print "send to a pi member"

reset
out=$(_cmd_send "$M" "fix the tests" 2>&1)
eq "nothing is typed into an advertising pi member" "" "$(keys)"
eq "the message lands in its inbox" "[apex from:mgr] fix the tests" "$(jq -r .text "$INBOX")"
eq "with its sender" "mgr" "$(jq -r .from "$INBOX")"
contains "send says it was stored, not read" "Not yet confirmed read" "$out"
contains "and names the channel" "inbox: pi" "$out"
eq "the send is logged" send "$(tail -n 1 "$(apex_events_file "$MGR")" | jq -r .event)"

reset
NATIVE_PID= _deliver "$M" mgr "hello" || true
contains "a pi member that does not advertise is typed into as before" "typed into %5" "$(keys)"
[[ ! -e $INBOX ]] && ok "…and gets no inbox" || bad "…and gets no inbox" "inbox exists"

reset
sleep 30 & dead=$!; kill $dead; wait $dead 2>/dev/null || true
NATIVE_PID=$dead _deliver "$M" mgr "hello" || true
contains "a dead advertiser's leftover option is ignored" "typed into %5" "$(keys)"

for agent in claude codex opencode; do
	reset "$agent"
	_deliver "$M" mgr "hello" || true
	[[ ! -e $INBOX ]] && ok "$agent is not sent to the inbox" || bad "$agent is not sent to the inbox" "inbox exists"
done

# A store that fails must not fall back to typing into the pane.
reset
mkdir -p "${INBOX:h}"; chmod 500 "${INBOX:h}"
rc=0; _deliver "$M" mgr "hello" 2>/dev/null || rc=$?
chmod 700 "${INBOX:h}"
eq "a failed store is a failed delivery" 4 "$rc"
eq "…and nothing is typed" "" "$(keys)"

# ── check ────────────────────────────────────────────────────────────
print "\ncheck"

reset
_deliver "$M" mgr "first"
_deliver "$M" mgr "second"
eq "--peek shows unread oldest first" "[apex from:mgr] first
[apex from:mgr] second" "$(_cmd_check --peek "$M")"
eq "--peek does not consume" 2 "$(_cmd_check --peek "$M" | wc -l | tr -d ' ')"
eq "check shows them oldest first" "[apex from:mgr] first
[apex from:mgr] second" "$(_cmd_check "$M")"
eq "…and marks them handled" "" "$(_cmd_check "$M")"
_deliver "$M" mgr "third"
eq "only what arrived since is unread" "[apex from:mgr] third" "$(_cmd_check "$M")"
_deliver "$M" mgr "fourth"
eq "--json prints the raw inbox line" "[apex from:mgr] fourth" "$(_cmd_check --json "$M" | jq -r .text)"
eq "an empty inbox prints nothing" "" "$(_cmd_check "$M")"
eq "the cursor is the handled line count" 4 "$(cat "$INBOX.handled")"
eq "check is wired as a subcommand" "" "$("$SCRIPTS/tmux-apex.sh" check "$M" 2>&1)"

# ── pair relay ───────────────────────────────────────────────────────
print "\npair relay"

reset
rc=0; _pair_relay "$MGR" "$M" "PAIRED REVIEW round 1" || rc=$?
eq "a relay stored in the inbox counts as delivered" 0 "$rc"
eq "…logged as a pair-relay" pair-relay "$(tail -n 1 "$(apex_events_file "$MGR")" | jq -r .event)"
eq "…lands in the inbox" "[apex from:apex-pair] PAIRED REVIEW round 1" "$(_cmd_check "$M")"
eq "…and is never typed" "" "$(keys)"

reset
mkdir -p "${INBOX:h}"; chmod 500 "${INBOX:h}"
rc=0; _pair_relay "$MGR" "$M" "PAIRED REVIEW round 2" 2>/dev/null || rc=$?
chmod 700 "${INBOX:h}"
eq "a relay that could not be stored is undelivered" 1 "$rc"
eq "…logged as failed" pair-relay-failed "$(tail -n 1 "$(apex_events_file "$MGR")" | jq -r .event)"
eq "…and not typed either" "" "$(keys)"

print "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
