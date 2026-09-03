#!/usr/bin/env zsh

# reap must not trust the cached PR state it inherits from _member_facts
# (github issue #50). The cache is only refreshed by whatever happened to run
# tmux-pr-status-refresh.sh last, so a member whose PR just merged can sit
# there reporting pr_state=OPEN indefinitely, and reap answers "Nothing to
# reap" for the exact member it exists to clean up.
#
# _reap_live_pr_state is the fix: reap re-reads PR state live for any
# candidate with a known PR number, and marks the state unknown — not
# silently falls back to the stale cache — when that lookup fails.

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq() {
	if [[ $2 == $3 ]]; then ok "$1"
	else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}

eval "$(sed -n '/^_reap_live_pr_state()/,/^}/p' "$SCRIPTS/tmux-apex.sh")"
(( ${+functions[_reap_live_pr_state]} )) || {
	print -u2 "apex-reap-pr-state.test.sh: could not extract _reap_live_pr_state from tmux-apex.sh"
	exit 1
}

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-reap-pr-state-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
WT="$TMPROOT/wt"; mkdir -p "$WT"

facts_for() {  # facts_for <pr-number> <cached-pr-state>
	jq -nc --arg wt "$WT" --arg pn "$1" --arg ps "$2" \
		'{worktree:$wt, pr_number:$pn, pr_state:$ps, alive:true}'
}

print "\n_reap_live_pr_state"

# No PR number at all: nothing to refresh, and no gh call should even happen —
# a stub that errors on any invocation proves that.
cat > "$BIN/gh" <<'EOF'
#!/bin/sh
echo "gh should not have been called: $*" >&2
exit 1
EOF
chmod +x "$BIN/gh"
out=$(PATH="$BIN:$PATH" _reap_live_pr_state "$(facts_for "" OPEN)")
eq "a member with no PR number is returned unchanged" OPEN \
	"$(print -r -- "$out" | jq -r '.pr_state')"
eq "…and is never marked unknown" false \
	"$(print -r -- "$out" | jq -r '.pr_state_unknown // false')"

# The bug itself: cache says OPEN, gh (the source of truth) says MERGED.
cat > "$BIN/gh" <<'EOF'
#!/bin/sh
case "$*" in
	*"pr view"*) echo MERGED ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$BIN/gh"
out=$(PATH="$BIN:$PATH" _reap_live_pr_state "$(facts_for 46 OPEN)")
eq "a live MERGED overrides a stale cached OPEN" MERGED \
	"$(print -r -- "$out" | jq -r '.pr_state')"
eq "…and is not marked unknown" false \
	"$(print -r -- "$out" | jq -r '.pr_state_unknown // false')"

# gh is unreachable: must not silently fall back to the stale cached state —
# that is the same bug wearing a different cause. It must come back unknown.
cat > "$BIN/gh" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$BIN/gh"
out=$(PATH="$BIN:$PATH" _reap_live_pr_state "$(facts_for 46 OPEN)")
eq "an unreachable gh does not fall back to the cached state" OPEN \
	"$(print -r -- "$out" | jq -r '.pr_state')"
eq "…and is marked unknown instead" true \
	"$(print -r -- "$out" | jq -r '.pr_state_unknown // false')"

print "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
