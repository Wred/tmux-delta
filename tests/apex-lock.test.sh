#!/usr/bin/env zsh
# Tests for the per-member mutex in scripts/lib/apex-state.sh (issue #21).
#
# The property under test is that a member record cannot silently lose fields
# when two processes write it at once. That is a real concurrency claim, so the
# writers here are real background processes against a real temp $APEX_ROOT —
# the pre-lock implementation fails these, which is the point. No tmux and no
# agent is involved: apex-state.sh is pure disk state.
#
# Run: tests/apex-lock.test.sh

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-lock-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0

ok()   { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad()  { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }

eq() {
	if [[ $2 == $3 ]]; then ok "$1"; else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}

export XDG_CACHE_HOME="$TMPROOT/cache"
source "$SCRIPTS/lib/apex-state.sh"

MGR=fake-manager
M=worker:%1

reset() { rm -rf "$(apex_dir "$MGR")"; apex_init_dirs "$MGR" }
get()   { apex_member_get "$MGR" "$M" "$1" }

# ── concurrent disjoint writers ──────────────────────────────────────
# Sixteen processes, each merging one field of its own. Without the mutex each
# reads the same starting record and the last mv wins, so most fields vanish.
print "concurrent merges keep every writer's fields"
reset
apex_member_merge "$MGR" "$M" '{"status":"idle"}'
for i in {1..16}; do
	( apex_member_merge "$MGR" "$M" "$(jq -nc --arg k "f$i" '{($k): true}')" ) &
done
wait
count=$(jq '[to_entries[] | select(.key | startswith("f"))] | length' \
	"$(apex_member_file "$MGR" "$M")")
eq "all 16 fields survive"       16      "$count"
eq "pre-existing field survives" idle    "$(get status)"

# ── the pair race, exactly ───────────────────────────────────────────
# _pair_advance writes {pair_round,pair_turn} onto the partner's record while
# the partner's own hooks merge {status,seq} into it. Neither may lose.
print "\npair-state write vs partner's own status write"
reset
apex_member_merge "$MGR" "$M" '{"pair_turn":"reviewer","status":"idle","seq":1}'
( apex_member_merge "$MGR" "$M" '{"pair_round":2,"pair_turn":"worker"}' ) &
( apex_member_merge "$MGR" "$M" '{"status":"working","seq":2}' ) &
wait
eq "pair_turn flipped"  worker  "$(get pair_turn)"
eq "pair_round bumped"  2       "$(get pair_round)"
eq "status recorded"    working "$(get status)"
eq "seq recorded"       2       "$(get seq)"

# ── mutual exclusion and staleness ───────────────────────────────────
print "\nlock primitives"
reset
LOCK="$TMPROOT/l.lock"
_apex_have_flock && ok "zsh/system provides flock" \
	|| bad "zsh/system provides flock" "falling back to the lockdir path"

apex_lock_acquire "$LOCK" && ok "acquires a free lock" || bad "acquires a free lock" "returned 1"
r=$( APEX_LOCK_WAIT=1; apex_lock_acquire "$LOCK" && print held || print blocked )
eq "a held lock blocks another process" blocked "$r"
apex_lock_release "$LOCK"
r=$( APEX_LOCK_WAIT=1; apex_lock_acquire "$LOCK" && print held || print blocked )
eq "release hands it to the next waiter" held "$r"

# The reason for using a kernel lock rather than a lockdir: a holder that is
# killed mid-critical-section releases it, so there is no staleness rule to get
# wrong and nothing for a second writer to steal.
rm -f "$TMPROOT/holding"
( apex_lock_acquire "$LOCK"; touch "$TMPROOT/holding"; sleep 30 ) &
holder=$!
while [[ ! -e $TMPROOT/holding ]]; do sleep 0.05; done
kill -9 $holder 2>/dev/null
wait $holder 2>/dev/null || true
r=$( APEX_LOCK_WAIT=1; apex_lock_acquire "$LOCK" && print held || print blocked )
eq "a SIGKILLed holder's lock is free" held "$r"
rm -f "$TMPROOT/holding"

# Exactly one holder at a time, checked by the holders themselves: four
# processes contend, and each one fails loudly if it finds the critical section
# already occupied. The previous mkdir-with-stale-steal design passed a
# single-stealer test and failed this one — two waiters that saw the same stale
# lock each removed it and each created their own.
print "\nmutual exclusion under contention"
rm -f "$TMPROOT/occupied" "$TMPROOT/overlap" "$TMPROOT/won"
for w in 1 2 3 4; do
	(
		APEX_LOCK_WAIT=5
		apex_lock_acquire "$LOCK" || exit 0
		print -r -- "w$w" >> "$TMPROOT/won"
		[[ -e $TMPROOT/occupied ]] && print -r -- "w$w" >> "$TMPROOT/overlap"
		touch "$TMPROOT/occupied"
		sleep 0.2
		rm -f "$TMPROOT/occupied"
		apex_lock_release "$LOCK"
	) &
done
wait
eq "all four got a turn"        4 "$(grep -c . "$TMPROOT/won" 2>/dev/null || print 0)"
eq "no two held it at once"     0 "$(grep -c . "$TMPROOT/overlap" 2>/dev/null || print 0)"

# Giving up must not drop the state update — a racy write beats a lost one —
# but it must leave a trace, since silent loss is the whole bug.
print "\nlock timeout still writes, and is logged"
reset
apex_member_merge "$MGR" "$M" '{"status":"idle"}'
(
	apex_lock_acquire "$(apex_member_lockpath "$MGR" "$M")"
	touch "$TMPROOT/holding"
	sleep 3
) &
holder=$!
while [[ ! -e $TMPROOT/holding ]]; do sleep 0.05; done
( APEX_LOCK_WAIT=1; apex_member_merge "$MGR" "$M" '{"status":"working"}' )
eq "write still landed" working "$(get status)"
eq "timeout logged" 1 "$(grep -c lock_timeout "$(apex_events_file "$MGR")")"
kill $holder 2>/dev/null; wait $holder 2>/dev/null || true
rm -f "$TMPROOT/holding"

# ── lockdir fallback ─────────────────────────────────────────────────
# Exercised on a zsh built without zsh/system. It never steals a lock, because
# stealing cannot be made single-winner on top of mkdir: a wedged lock degrades
# to one stall plus an unlocked write per writer, and is cleared only after the
# giving-up writer has already decided to proceed.
print "\nlockdir fallback"
(
	APEX_HAVE_FLOCK=1 APEX_LOCK_WAIT=1
	FLOCK="$TMPROOT/f.lock"
	apex_lock_acquire "$FLOCK" && print -n "held " || print -n "failed "
	[[ -d $FLOCK.d ]] && print -n "dir " || print -n "nodir "
	( apex_lock_acquire "$FLOCK" ) && print -n "notexcl " || print -n "excl "
	apex_lock_release "$FLOCK"
	[[ -d $FLOCK.d ]] && print "notreleased" || print "released"
) | read -r r
eq "fallback locks, excludes, releases" "held dir excl released" "$r"

(
	APEX_HAVE_FLOCK=1 APEX_LOCK_WAIT=1 APEX_LOCK_STALE=0
	FLOCK="$TMPROOT/g.lock"
	mkdir -p "$FLOCK.d"
	apex_lock_acquire "$FLOCK" && print -n "held " || print -n "refused "
	[[ -d $FLOCK.d ]] && print "kept" || print "cleared"
) | read -r r
eq "a wedged lockdir is not claimed, but is cleared for the next writer" \
	"refused cleared" "$r"

# ── lock cleanup ─────────────────────────────────────────────────────
# reap, relink and recover re-keying all drop the lock state of a record that
# is going away; the glob has to catch the fallback's sibling directory too.
print "\napex_member_lock_forget"
reset
apex_lock_acquire "$(apex_member_lockpath "$MGR" "$M")"
apex_lock_release "$(apex_member_lockpath "$MGR" "$M")"
mkdir -p "$(apex_member_lockpath "$MGR" "$M").d"
apex_member_lock_forget "$MGR" "$M"
eq "nothing left behind" "" \
	"$(print -r -- "$(apex_members_dir "$MGR")"/.*.lock*(N))"

# ── merge_bump ───────────────────────────────────────────────────────
# Every concurrent bump must get a number of its own: _cmd_event arms a settle
# callback keyed on the seq it was handed, so two hooks claiming the same one
# means a callback can fire for a turn that is already over.
print "\napex_member_merge_bump"
reset
eq "first bump is 1" 1 "$(apex_member_merge_bump "$MGR" "$M" '{"status":"working"}')"
eq "patch applied"   working "$(get status)"

for i in {1..12}; do
	( print -r -- "$(apex_member_merge_bump "$MGR" "$M" '{"status":"working"}')" \
		>> "$TMPROOT/seqs" ) &
done
wait
eq "12 concurrent bumps reach 13" 13 "$(get seq)"
eq "no seq handed out twice"      12 \
	"$(sort -u "$TMPROOT/seqs" | grep -c .)"

# ── merge_cas ────────────────────────────────────────────────────────
print "\napex_member_merge_cas"
reset
apex_member_merge "$MGR" "$M" '{"seq":4,"pinged_seq":1}'
apex_member_merge_cas "$MGR" "$M" '{"pinged_seq":4}' seq 4 \
	&& ok "matching CAS writes" || bad "matching CAS writes" "returned 1"
eq "pinged_seq advanced" 4 "$(get pinged_seq)"

apex_member_merge "$MGR" "$M" '{"seq":5}'
apex_member_merge_cas "$MGR" "$M" '{"pinged_seq":4}' seq 4 \
	&& bad "stale CAS is refused" "returned 0" || ok "stale CAS is refused"
eq "pinged_seq untouched" 4 "$(get pinged_seq)"

# `pending` reads a member with no seq field at all as seq 0 but passes the raw
# "" through, so absent-vs-"" has to compare equal or first delivery never marks.
reset
apex_member_merge "$MGR" "$M" '{"status":"idle"}'
apex_member_merge_cas "$MGR" "$M" '{"pinged_seq":0}' seq '' \
	&& ok "absent key matches an empty expectation" \
	|| bad "absent key matches an empty expectation" "returned 1"

# ── report ───────────────────────────────────────────────────────────
print ""
print "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
