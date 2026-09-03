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
eq "argv --permission-mode=X (equals form)" 0 "$(cls '--permission-mode=bypassPermissions')"
eq "a claude-only bypass flag on codex"     2 "$(cls '--dangerously-skip-permissions' codex)"
eq "an unrecognised bare token: unknown"    2 "$(cls someFutureMode)"

print -- "_perm_unattended (non-claude agents)"
eq "codex --ask-for-approval never"         0 "$(cls '--sandbox workspace-write --ask-for-approval never' codex)"
eq "codex bypass flag is codex's, not global" 0 "$(cls '--dangerously-bypass-approvals-and-sandbox' codex)"
eq "the same codex flag on opencode"        2 "$(cls '--dangerously-bypass-approvals-and-sandbox' opencode)"
eq "codex --ask-for-approval on-request prompts" 1 "$(cls '--ask-for-approval on-request' codex)"
eq "opencode --auto runs unattended"        0 "$(cls '--auto' opencode)"
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

# Both knobs at once: an explicit --agent-flags wins the profile merge
# field-by-field, so the refusal must name the flag, not the profile the value
# did not come from. `_cmd_spawn` signals that by passing an empty 4th argument.
out=$(run autonomous acceptEdits claude '')
contains "profile+flag together blames the flag" "from --agent-flags acceptEdits" "$out"
if [[ $out == *"profile '"* ]]; then
	bad "profile+flag together does not blame the profile" "$out"
else
	ok "profile+flag together does not blame the profile"
fi

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

# ─── the wiring: _cmd_spawn itself ───────────────────────────────────
#
# The two blocks above test the decision in isolation, which leaves the thing
# that actually matters unverified: *where* the check sits in `_cmd_spawn`. It
# has to run after --profile has been merged into `perm` and before anything is
# created, and it has to be handed the profile name only when the profile is
# what supplied `perm`. Moving the call one block earlier keeps every assertion
# above green while breaking both properties, so drive the real `_cmd_spawn`
# here — with a stub picker standing in for worktree/session creation, since
# what is under test is the decision, not the spawn.

print -- "_cmd_spawn wiring"
eval "$(sed -n '/^_cmd_spawn()/,/^}/p' "$SCRIPTS/tmux-apex.sh")"
(( ${+functions[_cmd_spawn]} )) || {
	print -u2 "apex-spawn-mode.test.sh: could not extract _cmd_spawn from tmux-apex.sh"
	exit 1
}
eval "$(sed -n '/^_need_val()/,/^}/p' "$SCRIPTS/tmux-apex.sh")"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-spawn-mode-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

# Everything past the guard is stubbed: reaching the stub picker at all is the
# assertion that the guard let the spawn through.
mkdir -p "$TMPROOT/scripts"
# The picker's stdout is consumed by _cmd_spawn, so the stub records its argv
# on the side: the recording is both "the guard let this through" and "these
# are the values the new session would have been given".
cat > "$TMPROOT/scripts/tmux-picker.sh" <<STUB
#!/usr/bin/env zsh
print -r -- "\$@" > "$TMPROOT/picker-args"
printf 'apex-session\tstub-session\t/stub/worktree\n'
STUB
chmod +x "$TMPROOT/scripts/tmux-picker.sh"
SCRIPTS_REAL="$SCRIPTS"
_require_manager() { print -r -- "stub-manager" }
apex_event() { : }

# The repo's own profiles, not this machine's: a user apex-profiles.json can
# redefine `hard`, and these assertions are about the shipped tiers.
source "$SCRIPTS/lib/apex-profiles.sh"
APEX_PROFILES_USER_FILE="$TMPROOT/no-such-user-profiles.json"

# Not a command substitution: `_cmd_spawn` dies by `exit`, and the exit status
# has to survive to the assertion.
spawn_out() {  # spawn_out <args...> -> "$SPAWN_OUT", $SPAWN_RC
	SPAWN_RC=0
	rm -f "$TMPROOT/picker-args"
	( SCRIPTS="$TMPROOT/scripts"; _cmd_spawn "$@" ) > "$TMPROOT/spawn.out" 2>&1 || SPAWN_RC=$?
	SPAWN_OUT=$(< "$TMPROOT/spawn.out")
	PICKER_ARGS=""
	[[ -f $TMPROOT/picker-args ]] && PICKER_ARGS=$(< "$TMPROOT/picker-args")
}

spawn_out --issue 42 --profile easy; out="$SPAWN_OUT"; rc=$SPAWN_RC
eq       "an unattended profile spawns"          0 "$rc"
contains "reaching the picker"      "--spawn-issue 42" "$PICKER_ARGS"
contains "and carrying the profile's flags" "CODING_AGENT_PERMISSION_MODE=bypassPermissions" "$PICKER_ARGS"
contains "and the autonomous mode"  "autonomous" "$PICKER_ARGS"
contains "reporting the mode it resolved" "mode     : autonomous" "$out"

spawn_out --issue 42 --profile hard; out="$SPAWN_OUT"; rc=$SPAWN_RC
eq       "a supervision-only profile is refused" 1 "$rc"
contains "before anything is created"       "conflicts with permission mode 'acceptEdits'" "$out"
contains "naming the profile as the source" "profile 'hard'" "$out"
if [[ -n $PICKER_ARGS ]]; then
	bad "a refused spawn never reaches the picker" "$out"
else
	ok "a refused spawn never reaches the picker"
fi

# The merge is field-by-field, so this is a *valid* spawn: the explicit flag
# overrides `hard`'s acceptEdits. If the check ran before the merge it would
# see an empty perm and refuse this.
spawn_out --issue 42 --profile hard --agent-flags bypassPermissions; out="$SPAWN_OUT"; rc=$SPAWN_RC
eq       "an explicit flag rescues a hard spawn" 0 "$rc"
contains "and it is the flag that is passed on" "CODING_AGENT_PERMISSION_MODE=bypassPermissions" "$PICKER_ARGS"

# And the mirror image: an explicit flag can also *break* an otherwise fine
# profile, and then the refusal must blame the flag.
spawn_out --issue 42 --profile easy --agent-flags acceptEdits; out="$SPAWN_OUT"; rc=$SPAWN_RC
eq       "an explicit flag can break a good profile" 1 "$rc"
contains "blaming the flag, not the profile" "from --agent-flags acceptEdits" "$out"

spawn_out --issue 42 --profile hard --mode interactive; out="$SPAWN_OUT"; rc=$SPAWN_RC
eq       "interactive spawns a supervised profile"  0 "$rc"
contains "still reaching the picker" "--spawn-issue 42" "$PICKER_ARGS"
contains "with interactive mode"    "interactive" "$PICKER_ARGS"
contains "and reporting the mode"    "mode     : interactive" "$out"

SCRIPTS="$SCRIPTS_REAL"

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
