#!/usr/bin/env zsh
# `spawn` must never pass mode=autonomous alongside a permission mode that
# cannot run unattended (issue #43).
#
# The two knobs were set from different places and compared nowhere: --mode
# defaults to autonomous, while the permission mode came from a named --profile
# or a raw --agent-flags string. Three shipped profiles use `acceptEdits`, which
# pauses for approval on every shell command — so `spawn --profile hard` told a
# worker to work unattended to a draft PR and then blocked it on its first git
# call. This asserts the contradiction is refused where it is created, and that
# the refusal covers hand-rolled --agent-flags and non-claude agents too, not
# just the named profiles.
#
# The classifier and the guard are extracted from tmux-apex.sh rather than
# driven through a real `spawn`: a real spawn would create a worktree and a tmux
# session, and the point under test is the decision, which happens before any of
# that.
#
# Run: tests/apex-spawn-mode.test.sh
set -u
emulate -L zsh
setopt extended_glob

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

# Matches the real _die: it exits, and every call below runs in a subshell.
_die() { print -u2 "tmux-apex: $*"; exit 1; }
for fn in _perm_unattended _spawn_check_mode; do
	eval "$(sed -n "/^${fn}()/,/^}/p" "$SCRIPTS/tmux-apex.sh")"
	(( ${+functions[$fn]} )) || {
		print -u2 "apex-spawn-mode.test.sh: could not extract $fn from tmux-apex.sh"
		exit 1
	}
done

# ─── the classifier ──────────────────────────────────────────────────
# 0 = runs unattended, 1 = will prompt, 2 = unknown

cls() { _perm_unattended "$1" "${2:-claude}"; print $? }

print -- "_perm_unattended (claude)"
eq "bypassPermissions runs unattended"      0 "$(cls bypassPermissions)"
eq "acceptEdits prompts"                    1 "$(cls acceptEdits)"
eq "plan prompts"                           1 "$(cls plan)"
eq "default prompts"                        1 "$(cls default)"
eq "no flags at all means claude's default" 1 "$(cls '')"
eq "--dangerously-skip-permissions argv"    0 "$(cls '--dangerously-skip-permissions')"
eq "argv --permission-mode bypass"          0 "$(cls '--permission-mode bypassPermissions')"
eq "argv --permission-mode acceptEdits"     1 "$(cls '--permission-mode acceptEdits')"
eq "argv with no permission-mode: unknown"  2 "$(cls '--verbose --add-dir /tmp')"
eq "an unrecognised bare token: unknown"    2 "$(cls someFutureMode)"

print -- "_perm_unattended (non-claude agents)"
eq "codex --full-auto runs unattended"      0 "$(cls '--full-auto' codex)"
eq "codex bypass flag runs unattended"      0 "$(cls '--dangerously-bypass-approvals-and-sandbox' codex)"
eq "pi --approve is unknown, not assumed"   2 "$(cls '--approve' pi)"
eq "opencode with no flags is unknown"      2 "$(cls '' opencode)"
eq "a claude token on codex is unknown"     2 "$(cls bypassPermissions codex)"

# ─── the guard ───────────────────────────────────────────────────────

run() {  # run <mode> <perm> <agent> <profile> -> "<rc>\n<stderr>"
	local err rc
	err=$(_spawn_check_mode "$1" "$2" "${3:-claude}" "${4:-}" 2>&1 >/dev/null); rc=$?
	print -r -- "$rc"
	print -r -- "$err"
}

print -- "_spawn_check_mode: the reported combination (issue #43)"
out=$(run autonomous acceptEdits claude hard)
eq       "profile hard + autonomous is refused"   1 "${out%%$'\n'*}"
contains "names the mode"          "--mode autonomous"      "$out"
contains "names the permission mode" "'acceptEdits'"        "$out"
contains "names the profile it came from" "profile 'hard'"  "$out"
contains "offers the unattended remedy" "--agent-flags bypassPermissions" "$out"
contains "offers the supervised remedy" "--mode interactive"  "$out"
contains "does not overpromise; points at #63" "issue #63"    "$out"

print -- "_spawn_check_mode: coverage beyond named profiles"
out=$(run autonomous acceptEdits claude '')
eq       "raw --agent-flags acceptEdits is refused too" 1 "${out%%$'\n'*}"
contains "attributes it to the flag, not a profile" "--agent-flags acceptEdits" "$out"

out=$(run autonomous '' claude '')
eq       "the bare default (no flags) is refused too" 1 "${out%%$'\n'*}"
contains "says whose default it is" "<agent default>" "$out"

out=$(run autonomous '--permission-mode plan' claude '')
eq "argv-form plan is refused too" 1 "${out%%$'\n'*}"

print -- "_spawn_check_mode: combinations that must still be allowed"
eq "autonomous + bypassPermissions"  0 "$(run autonomous bypassPermissions claude easy | head -1)"
eq "interactive + acceptEdits"       0 "$(run interactive acceptEdits claude hard | head -1)"
eq "interactive + no flags"          0 "$(run interactive '' claude '' | head -1)"
eq "interactive keeps quiet"        "" "$(run interactive acceptEdits claude hard | tail -n +2)"

print -- "_spawn_check_mode: unknown flags are flagged, not silently accepted"
out=$(run autonomous '--approve' pi '')
eq       "unverifiable flags do not block the spawn" 0 "${out%%$'\n'*}"
contains "but they are reported"  "cannot verify"    "$out"
contains "naming the agent"       "'pi'"             "$out"

print -- "_spawn_check_mode: mode itself is validated"
out=$(run bogus bypassPermissions claude '')
eq       "an unknown --mode is refused" 1 "${out%%$'\n'*}"
contains "listing the valid values" "'autonomous' or 'interactive'" "$out"

# ─── the shipped profiles must be usable as documented ───────────────
#
# The guard is only half the fix: a profile whose agent_flags can never run
# unattended is a profile the manager cannot spawn autonomously at all. Assert
# every shipped claude profile is either unattended-capable or documented as
# needing supervision, so the pair stays consistent as profiles are edited.

print -- "shipped profiles"
source "$SCRIPTS/lib/apex-profiles.sh"
# The repo file only: a user's own apex-profiles.json is not this repo's to
# assert about, and apex_profiles_merged would pull it in.
pjson=$(< "$(apex_profiles_repo_file)")
for name in ${(f)"$(jq -r 'keys[]' <<< "$pjson")"}; do
	agent=$(jq -r --arg n "$name" '.[$n].agent // "claude"' <<< "$pjson")
	flags=$(jq -r --arg n "$name" '.[$n].agent_flags // ""' <<< "$pjson")
	desc=$(jq -r --arg n "$name" '.[$n].description // ""' <<< "$pjson")
	_perm_unattended "$flags" "$agent"
	case $? in
		0) ok "profile '$name' can run autonomously" ;;
		*) if [[ ${desc:l} == *(supervis|approval|approve|attended|pause|interactive)* ]]; then
			   ok "profile '$name' needs supervision and says so"
		   else
			   bad "profile '$name' needs supervision" \
			       "agent_flags='${flags}' cannot run unattended, but the description does not say a human must watch it: ${desc}"
		   fi ;;
	esac
done

print -- ""
print -- "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
