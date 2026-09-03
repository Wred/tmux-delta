#!/usr/bin/env zsh
# `commits_ahead` must never report 0 for a branch it cannot measure (issue #57).
#
# In an apex worktree the upstream is *configured* but often has no local
# remote-tracking ref, because `remote.origin.fetch` is narrowed to `main` (the
# same condition behind #31). `rev-list --count @{upstream}..HEAD` then fails,
# and the old `|| echo 0` turned that failure into the number that means "fully
# pushed" — so a manager read `commits_ahead=0` off a ping line while a real
# unpushed commit sat in the worktree.
#
# Real repos here, not a git stub: the whole point is what git actually reports
# about this ref layout, and a stub would only assert that the test author and
# the implementation agree on the same wrong model.
#
# Run: tests/apex-commits-ahead.test.sh
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
contains() {
	if [[ $3 == *$2* ]]; then ok "$1"
	else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi
}

for fn in _commits_ahead _facts_line; do
	eval "$(sed -n "/^${fn}()/,/^}/p" "$SCRIPTS/tmux-apex.sh")"
	(( ${+functions[$fn]} )) || {
		print -u2 "apex-commits-ahead.test.sh: could not extract $fn from tmux-apex.sh"
		exit 1
	}
done

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-commits-ahead-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

GBIN="$TMPROOT/bin"; mkdir -p "$GBIN"
REAL_GIT=$(PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" whence -p git)
ln -sf "$REAL_GIT" "$GBIN/git"
export PATH="$GBIN:$PATH"

REMOTE="$TMPROOT/remote.git"
git init -q --bare "$REMOTE"
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main

WT="$TMPROOT/wt"
git clone -q "$REMOTE" "$WT" 2>/dev/null
(
	cd "$WT" || exit
	git config user.email t@t; git config user.name t
	print base > f; git add f; git commit -qm base; git push -q origin HEAD:main
	git branch -q --set-upstream-to=origin/main main 2>/dev/null || true
) >/dev/null 2>&1

print "\n_commits_ahead — the measurable cases"

eq "a fully pushed branch with a live tracking ref reports 0" "0" \
	"$(_commits_ahead "$WT" main)"

(
	cd "$WT" || exit
	git checkout -qb side
	print pushed > g; git add g; git commit -qm pushed-on-side
	git push -q -u origin side
	print local > h; git add h; git commit -qm unpushed-on-side
) >/dev/null 2>&1

eq "…and so does the same query while the tracking ref still exists" "1" \
	"$(_commits_ahead "$WT" side)"

print "\n_commits_ahead — the no-tracking-ref case (issue #57)"

# Reproduce the apex worktree's ref layout: upstream configured, refspec
# narrowed to main, no origin/side ref anywhere.
git -C "$WT" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git -C "$WT" config branch.side.remote origin
git -C "$WT" config branch.side.merge refs/heads/side
git -C "$WT" update-ref -d refs/remotes/origin/side 2>/dev/null || true

# Pins the premise the fix rests on. If @{upstream} ever did resolve here, the
# whole reason for a fallback would be stale and this is what would say so.
if git -C "$WT" rev-list --count '@{upstream}..HEAD' >/dev/null 2>&1; then
	bad "@{upstream} really is unresolvable in this layout" \
		"rev-list '@{upstream}..HEAD' succeeded; the fixture no longer reproduces #57"
else
	ok "@{upstream} really is unresolvable in this layout"
fi

eq "an unmeasurable count is empty, NOT 0" "" \
	"$(_commits_ahead "$WT" side)"

eq "…and --ask-remote recovers the real count from the remote" "1" \
	"$(_commits_ahead "$WT" side --ask-remote)"

print "\n_commits_ahead — never pushed at all"

(
	cd "$WT" || exit
	git checkout -qb virgin
	print never > i; git add i; git commit -qm never-pushed
	git config branch.virgin.remote origin
	git config branch.virgin.merge refs/heads/virgin
) >/dev/null 2>&1

eq "a branch the remote has never heard of is not 0 either" "" \
	"$(_commits_ahead "$WT" virgin)"

# 4 commits: base, pushed-on-side, unpushed-on-side, never-pushed. None of them
# is on the remote under refs/heads/virgin, so all of them are unpushed *there*.
eq "…and --ask-remote counts every commit as unpushed" "4" \
	"$(_commits_ahead "$WT" virgin --ask-remote)"

print "\n_commits_ahead — a STALE tracking ref beats nothing, but not the remote"

# The mirror of the case above: the tracking ref *does* exist, so `@{upstream}`
# succeeds — with a number derived from a ref that is only as fresh as the last
# fetch. `--ask-remote` must not prefer that just because it answered first.
#
# The refspec goes back to the default glob here, because that is what makes a
# tracking ref reachable from `@{upstream}` at all: under the narrowed refspec
# above, git cannot map `refs/heads/side` to any remote-tracking ref even when
# `refs/remotes/origin/side` is sitting right there. Narrow refspec is the
# missing-ref case (already covered); a stale-but-present ref is this one.
git -C "$WT" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
(
	cd "$WT" || exit
	git checkout -q side
	# Pin origin/side to the branch's *first* commit while the remote really
	# holds its second, so the stale local view says 2 and the remote says 1 —
	# two different numbers, not merely present vs absent.
	git update-ref refs/remotes/origin/side "$(git rev-parse 'HEAD~2')"
) >/dev/null 2>&1

eq "the stale tracking ref is what @{upstream} reports" "2" \
	"$(_commits_ahead "$WT" side)"

eq "…but --ask-remote takes the remote's answer over it" "1" \
	"$(_commits_ahead "$WT" side --ask-remote)"

print "\n_commits_ahead — an unreachable remote"

git -C "$WT" remote set-url origin "$TMPROOT/no-such-remote.git"

# With no tracking ref left to fall back to, unreachable is unknown — not 0,
# and not "the remote has never heard of this branch" either.
git -C "$WT" update-ref -d refs/remotes/origin/side 2>/dev/null || true
eq "an unreachable remote is unknown, not 0" "" \
	"$(_commits_ahead "$WT" side --ask-remote)"
( cd "$WT" && git checkout -q virgin ) >/dev/null 2>&1
eq "…and not 'never pushed' either" "" \
	"$(_commits_ahead "$WT" virgin --ask-remote)"

# Unreachable is nonetheless the one case that *does* fall back to the local
# ref: it is the only view left and it beats reporting nothing. This is what
# separates "the remote could not answer" from "the remote answered
# incomparably", which must not fall back.
( cd "$WT" && git checkout -q side ) >/dev/null 2>&1
git -C "$WT" update-ref refs/remotes/origin/side "$(git -C "$WT" rev-parse 'side~2')"
eq "…but an unreachable remote does fall back to the tracking ref" "2" \
	"$(_commits_ahead "$WT" side --ask-remote)"

print "\n_facts_line rendering"

facts() { jq -nc --argjson a "$1" --arg b "${2-b}" \
	'{branch:$b, pr_number:"", commits_ahead:$a, dirty:false, alive:true}' }

contains "a known count prints as a number" "commits_ahead=3" "$(_facts_line "$(facts 3)")"
contains "a known zero still prints as 0" "commits_ahead=0" "$(_facts_line "$(facts 0)")"
contains "an unknown count says so instead of printing 0" "commits_ahead=unknown" \
	"$(_facts_line "$(facts null)")"
if [[ $(_facts_line "$(facts null)") == *"commits_ahead=0"* ]]; then
	bad "an unknown count is never rendered as 0" "rendered commits_ahead=0 for null"
else
	ok "an unknown count is never rendered as 0"
fi

# A member with no worktree or a worktree that is gone has no branch, so
# `ahead` is null for a reason that has nothing to do with pushing. Reporting
# "unpushed?" there swaps #57's phantom for a new one, on exactly the members
# `recover` already skips.
if [[ $(_facts_line "$(facts null "")") == *commits_ahead* ]]; then
	bad "a member with no branch gets no commits_ahead field at all" \
		"rendered: $(_facts_line "$(facts null "")")"
else
	ok "a member with no branch gets no commits_ahead field at all"
fi
contains "…and the rest of the line still renders" "pr=none" \
	"$(_facts_line "$(facts null "")")"

print "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
