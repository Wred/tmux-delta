#!/usr/bin/env zsh
# A worker's managed prompt carries the PR-ownership paragraph; a reviewer's
# does not (issue #75). The skill must also list the "never" items.
#
# Run: tests/apex-worker-ownership.test.sh
set -u
emulate -L zsh
ROOT="${0:A:h:h}"
source "$ROOT/scripts/lib/agent-prompts.sh"

typeset -i FAIL=0
check() { if eval "$2"; then print -- "  ok   $1"; else print -u2 -- "  FAIL $1"; FAIL=$(( FAIL + 1 )); fi }

w=$(delta_managed_prompt worker tmux-delta)
r=$(delta_managed_prompt monitor tmux-delta)
check "worker prompt has ownership paragraph" '[[ $w == *"You own your PR until its head is green and current"* && $w == *"Do not report done before the CI check exists"* ]]'
check "reviewer prompt lacks it" '[[ $r != *"You own your PR"* ]]'
check "skill lists the never items" 'grep -q "Never, even when quick" "$ROOT/skills/delta-apex/SKILL.md"'
check "skill narrows Unblocking" 'grep -q "Unblocking by messaging and member lifecycle only" "$ROOT/skills/delta-apex/SKILL.md"'
(( FAIL == 0 )) || exit 1
