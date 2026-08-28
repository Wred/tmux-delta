#!/usr/bin/env zsh
# Tests for apex ping delivery: the per-event output-channel split in
# scripts/apex-manager-notify.sh, and `tmux-apex.sh doctor`'s wiring detection.
#
# Both are pure functions of a string argument and a JSON file, so neither needs
# a live agent: tmux and tmux-apex.sh are stubbed on PATH, and doctor reads
# fixture settings files via $APEX_REPO.
#
# Run: tests/apex-delivery.test.sh

set -u
emulate -L zsh
setopt err_return

SCRIPTS="${0:A:h:h}/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-delivery-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0

# `(( x++ ))` returns the *old* value as its status, which is 1 for the first
# increment — fatal under err_return. Assign instead.
ok()   { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad()  { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }

# eq <name> <expected> <actual>
eq() {
	if [[ $2 == $3 ]]; then ok "$1"; else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}

# contains <name> <needle> <haystack>
contains() {
	if [[ $3 == *$2* ]]; then ok "$1"; else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi
}

# ── stub environment ─────────────────────────────────────────────────
# A fake tmux that reports a manager session, and a fake tmux-apex.sh whose
# `pending` output is controlled by $STUB_PENDING. Both live in a directory
# alongside a copy of the script under test, because the script resolves
# tmux-apex.sh relative to its own location.
BIN="$TMPROOT/bin"
mkdir -p "$BIN"
cp "$SCRIPTS/apex-manager-notify.sh" "$BIN/"

cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$*" in
	"display-message -p #S") echo "$STUB_SESSION" ;;
	*"@apex_role"*)          echo "$STUB_ROLE" ;;
esac
EOF

cat > "$BIN/tmux-apex.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
	relink)  echo relink >> "$STUB_RELINK_LOG"; exit 0 ;;
	pending) echo "$*" >> "$STUB_PENDING_LOG"; printf '%s' "$STUB_PENDING"; [ -n "$STUB_PENDING" ] && echo; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux" "$BIN/tmux-apex.sh"

export PATH="$BIN:$PATH" TMUX=fake-socket
export STUB_SESSION=fake-manager STUB_ROLE=manager
export STUB_PENDING='[apex] session=w role=worker task=issue:42 status=idle — branch=b pr=#17(draft).'
export STUB_RELINK_LOG="$TMPROOT/relink.log"
export STUB_PENDING_LOG="$TMPROOT/pending.log"

notify() { : > "$STUB_RELINK_LOG"; : > "$STUB_PENDING_LOG"; "$BIN/apex-manager-notify.sh" "$@" 2>/dev/null }

# ── channel selection ────────────────────────────────────────────────
# Plain stdout only reaches the agent on UserPromptSubmit and SessionStart;
# the other two events must return hookSpecificOutput JSON instead. Getting
# this pairing wrong is silent — the text goes to the debug log.
print "channel selection"

for verb hook in post-tools PostToolBatch stop Stop; do
	out=$(notify $verb)
	eq "$verb emits JSON for $hook" \
		"$hook" \
		"$(print -r -- $out | jq -r '.hookSpecificOutput.hookEventName')"
	contains "$verb JSON carries the pending text" "status=idle" \
		"$(print -r -- $out | jq -r '.hookSpecificOutput.additionalContext')"
	eq "$verb emits nothing but the JSON object" 1 "$(print -r -- $out | wc -l | tr -d ' ')"
done

for verb in prompt session-start; do
	out=$(notify $verb)
	contains "$verb emits plain text" "pending events since you last checked" "$out"
	eq "$verb emits no JSON" "" "$(print -r -- $out | jq -e . 2>/dev/null && print BAD)"
done

# ── the misconfiguration that used to eat pings ───────────────────────
# An argument-less command duplicated under PostToolBatch/Stop used to default
# to `prompt`, print plain text nobody reads, and consume the events anyway.
# It must now deliver nothing, consume nothing, and say so. See PR #11 review.
print "\nunrecognized invocation"

out=$(notify)
contains "no argument warns" "not a delivery point" "$out"
contains "no argument names the fix" "doctor" "$out"
eq "no argument exits 0" 0 "$(notify >/dev/null 2>&1; print $?)"

out=$(notify bogus-verb)
contains "unknown argument warns" "not a delivery point" "$out"
eq "unknown argument exits 0" 0 "$(notify bogus-verb >/dev/null 2>&1; print $?)"

# The warning must not fire in sessions that aren't apex managers — the hooks
# run in every Claude Code session on the machine.
out=$(STUB_ROLE= notify bogus-verb)
eq "unknown argument is silent for non-managers" "" "$out"

# The point of the whole change: an invocation that cannot deliver must not
# consume. `pending --mark-delivered` advances pinged_seq in the same pass that
# prints, so calling it at all on a dead channel loses the events for good.
notify bogus-verb >/dev/null
eq "unknown argument does not consume pings" 0 "$(grep -c mark-delivered "$STUB_PENDING_LOG")"
notify stop >/dev/null
eq "a working channel does consume pings" 1 "$(grep -c mark-delivered "$STUB_PENDING_LOG")"

# ── jq missing from the hook's PATH ──────────────────────────────────
# The JSON channel needs jq, and hooks run with whatever PATH Claude Code hands
# them. An unmet dependency must leave the events pending, not eat them.
print "\nmissing jq"

NOJQ="$TMPROOT/nojq"
mkdir -p "$NOJQ"
# env and bash included because the scripts' shebangs need them; jq
# deliberately absent, which is the whole point of this PATH.
for c in env bash dirname readlink grep; do ln -sf "$(command -v $c)" "$NOJQ/$c"; done
ln -sf "$BIN/tmux" "$NOJQ/tmux"
ln -sf "$BIN/tmux-apex.sh" "$NOJQ/tmux-apex.sh"

nojq_notify() {
	: > "$STUB_PENDING_LOG"
	PATH="$NOJQ" "$BIN/apex-manager-notify.sh" "$@" 2>/dev/null
}

eq "no jq: json channel emits nothing" "" "$(nojq_notify stop)"
eq "no jq: json channel does not consume pings" 0 "$(grep -c mark-delivered "$STUB_PENDING_LOG")"
out=$(PATH="$NOJQ" "$BIN/apex-manager-notify.sh" stop 2>&1 || true)
contains "no jq: says why on stderr" "jq not found" "$out"
# The text channel doesn't need jq and must keep working without it.
contains "no jq: text channel still delivers" "status=idle" "$(nojq_notify prompt)"

# ── no-op paths ──────────────────────────────────────────────────────
print "\nno-op paths"

eq "nothing pending emits nothing" "" "$(STUB_PENDING= notify stop)"
eq "non-manager emits nothing" "" "$(STUB_ROLE=worker notify stop)"
eq "outside tmux emits nothing" "" "$(TMUX= notify prompt)"

# ── relink only on turn-opening events ───────────────────────────────
print "\nrelink"

for verb in prompt session-start; do
	notify $verb >/dev/null
	eq "$verb relinks" 1 "$(grep -c relink "$STUB_RELINK_LOG")"
done
for verb in post-tools stop; do
	notify $verb >/dev/null
	eq "$verb does not relink" 0 "$(grep -c relink "$STUB_RELINK_LOG")"
done

# ── doctor detection ─────────────────────────────────────────────────
print "\ndoctor"

# fixture <name> <json> — a repo whose .claude/settings.json is <json>
fixture() {
	local d="$TMPROOT/fx-$1"
	mkdir -p "$d/.claude"
	print -r -- "$2" > "$d/.claude/settings.json"
	print -r -- "$d"
}

# Output only; `doctor` exits non-zero when hooks are missing, and under
# err_return that status would abort the run if it escaped a substitution.
doctor() { APEX_REPO="$1" HOME="$TMPROOT/nohome" "$SCRIPTS/tmux-apex.sh" doctor 2>&1 || true }
# Status only. The `|| rc=$?` matters: under err_return a bare non-zero
# command would return from the function before it could report the status.
doctor_rc() {
	local rc=0
	APEX_REPO="$1" HOME="$TMPROOT/nohome" "$SCRIPTS/tmux-apex.sh" doctor >/dev/null 2>&1 || rc=$?
	print $rc
}
mkdir -p "$TMPROOT/nohome"

N='~/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh'
entry() { print -r -- "{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$N $1\"}]}" }

all_wired=$(fixture all "{\"hooks\":{
	\"UserPromptSubmit\":[$(entry prompt)],
	\"SessionStart\":[$(entry session-start)],
	\"PostToolBatch\":[$(entry post-tools)],
	\"Stop\":[
		{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"~/.tmux/plugins/tmux-delta/scripts/agent-tmux-status.sh clear\"}]},
		$(entry stop)
	]
}}")
out=$(doctor "$all_wired")
contains "all four wired passes" "all hooks wired" "$out"
eq "all four wired exits 0" 0 "$(doctor_rc "$all_wired")"

none=$(fixture none '{"hooks":{}}')
out=$(doctor "$none")
contains "nothing wired reports all four" "UserPromptSubmit, SessionStart, PostToolBatch, Stop" "$out"
eq "nothing wired exits 1" 1 "$(doctor_rc "$none")"

# The BLOCKING finding on PR #11: wired, but with no argument. The old check
# matched on the path alone and certified this as healthy, while the script
# defaulted to `prompt` and dropped the pings.
bare=$(fixture bare "{\"hooks\":{
	\"UserPromptSubmit\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$N\"}]}],
	\"SessionStart\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$N\"}]}],
	\"PostToolBatch\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$N\"}]}],
	\"Stop\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$N\"}]}]
}}")
out=$(doctor "$bare")
contains "argument-less wiring counts as missing" "missing Claude Code hooks: UserPromptSubmit, SessionStart, PostToolBatch, Stop" "$out"
eq "argument-less wiring exits 1" 1 "$(doctor_rc "$bare")"

# Right script, wrong verb for the event: same silent-channel-mismatch class.
crossed=$(fixture crossed "{\"hooks\":{
	\"PostToolBatch\":[$(entry prompt)],
	\"Stop\":[$(entry post-tools)]
}}")
out=$(doctor "$crossed")
contains "verb from another event counts as missing" "PostToolBatch, Stop" "$out"

# A verb that is a prefix of the real one must not match.
prefix=$(fixture prefix "{\"hooks\":{\"SessionStart\":[$(entry session)]}}")
contains "prefix of a verb does not match" "SessionStart" "$(doctor "$prefix")"

# Malformed JSON must not crash or read as wired.
malformed=$(fixture malformed '{"hooks": {"Stop": [')
out=$(doctor "$malformed")
contains "malformed settings reads as unwired" "Stop" "$out"
eq "malformed settings exits 1" 1 "$(doctor_rc "$malformed")"

# Path spellings that all mean the same install.
for spelling in '~/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh' \
                '$HOME/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh' \
                '/Users/x/.config/tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh'
do
	fx=$(fixture "path-${#spelling}" "{\"hooks\":{\"Stop\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$spelling stop\"}]}]}}")
	out=$(doctor "$fx")
	if [[ $out == *"wired already"*Stop* ]]; then
		ok "path spelling accepted: $spelling"
	else
		bad "path spelling accepted: $spelling" "$out"
	fi
done

# The fix hint must not hand out a worktree path: hooks are global config and
# would break silently once the worktree is removed. Give doctor a HOME with a
# plugin install in it and check it prefers that over its own location.
fake_home="$TMPROOT/home-with-install"
mkdir -p "$fake_home/.tmux/plugins/tmux-delta/scripts"
touch "$fake_home/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh"
out=$(APEX_REPO="$none" HOME="$fake_home" "$SCRIPTS/tmux-apex.sh" doctor 2>&1 || true)
contains "fix hint uses the stable install path" \
	'~/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh prompt' "$out"
if [[ $out != *"$SCRIPTS/apex-manager-notify.sh"* ]]; then
	ok "fix hint avoids this checkout's path"
else
	bad "fix hint avoids this checkout's path" "$out"
fi

# With no install location to point at, falling back to the running copy is the
# only thing left — but it must still be an absolute, working path.
bare_home="$TMPROOT/home-no-install"
mkdir -p "$bare_home"
out=$(APEX_REPO="$none" HOME="$bare_home" XDG_CONFIG_HOME="$bare_home/.config" \
	"$SCRIPTS/tmux-apex.sh" doctor 2>&1 || true)
contains "fix hint falls back to the running copy" "$SCRIPTS/apex-manager-notify.sh prompt" "$out"

# ── installer contract ──────────────────────────────────────────────
# scripts/install-agent-hooks.sh runs backgrounded on every plugin load, so
# whatever it writes is what most machines actually get. If its arrays drift
# from what apex-manager-notify.sh requires, it silently un-wires delivery
# everywhere — which is how the argument-less wiring got there in the first
# place. Assert the two agree by running the installer into a throwaway HOME
# and pointing `doctor` at the result.
print "\ninstaller contract"

inst_home="$TMPROOT/home-installer"
mkdir -p "$inst_home/.claude"

# Seed the pre-fix wiring: right script, no argument. The installer must
# repoint these in place, not leave them and not duplicate them.
cat > "$inst_home/.claude/settings.json" <<JSON
{"hooks":{
	"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"/old/clone/scripts/apex-manager-notify.sh","timeout":10}]}],
	"SessionStart":[{"matcher":"startup|resume","hooks":[{"type":"command","command":"/old/clone/scripts/apex-manager-notify.sh","timeout":10}]}],
	"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/old/clone/scripts/agent-tmux-status.sh clear"}]}]
}}
JSON

HOME="$inst_home" "$SCRIPTS/install-agent-hooks.sh" >/dev/null 2>&1 || true
installed="$inst_home/.claude/settings.json"

eq "installer leaves valid JSON" 0 "$(jq -e . "$installed" >/dev/null 2>&1; print $?)"

# The contract test: doctor must accept what the installer wrote.
inst_rc=0
APEX_REPO="$TMPROOT/nonexistent" HOME="$inst_home" \
	"$SCRIPTS/tmux-apex.sh" doctor >/dev/null 2>&1 || inst_rc=$?
eq "doctor accepts what the installer wrote" 0 "$inst_rc"

# Per-event verb, read back out of the file the installer produced.
for event verb in UserPromptSubmit prompt SessionStart session-start PostToolBatch post-tools Stop stop; do
	got=$(jq -r --arg e "$event" '
		[.hooks[$e][]?.hooks[]?.command? // ""
		 | select(test("apex-manager-notify"))]
		| join(",")' "$installed")
	contains "installer wires $event with '$verb'" "apex-manager-notify.sh $verb" "$got"
	eq "installer wires exactly one notify entry on $event" 1 "$(print -r -- $got | tr ',' '\n' | grep -c apex-manager-notify)"
done

# Repointing must not have duplicated the stale argument-less entries.
eq "no argument-less notify entry survives" 0 "$(jq '[.. | .command? // empty | select(test("apex-manager-notify\\.sh$"))] | length' "$installed")"
eq "old clone path is gone" 0 "$(jq '[.. | .command? // empty | select(test("^/old/clone/"))] | length' "$installed")"

# Stop keeps both scripts: this session's own idle record, and pings from
# members it manages.
stop_cmds=$(jq -r '[.hooks.Stop[]?.hooks[]?.command? // ""] | join(" | ")' "$installed")
contains "Stop keeps agent-tmux-status.sh clear" "agent-tmux-status.sh clear" "$stop_cmds"
contains "Stop gains apex-manager-notify.sh stop" "apex-manager-notify.sh stop" "$stop_cmds"

# Same contract from nothing at all, not just from a stale wiring.
fresh_home="$TMPROOT/home-fresh"
mkdir -p "$fresh_home"
HOME="$fresh_home" "$SCRIPTS/install-agent-hooks.sh" >/dev/null 2>&1 || true
fresh_rc=0
APEX_REPO="$TMPROOT/nonexistent" HOME="$fresh_home" \
	"$SCRIPTS/tmux-apex.sh" doctor >/dev/null 2>&1 || fresh_rc=$?
eq "doctor accepts a from-scratch install" 0 "$fresh_rc"

# Re-running must be a no-op, since it runs on every plugin load.
before=$(cat "$installed")
HOME="$inst_home" "$SCRIPTS/install-agent-hooks.sh" >/dev/null 2>&1 || true
eq "installer is idempotent" "$before" "$(cat "$installed")"

# A machine that ran the *old* installer after this one had already run ends
# up with two notify entries on the same event: the correct one, plus an
# argument-less duplicate the old stricter pattern appended instead of
# repointing. That is the state every `tmux source` produces until the
# installer fix lands, so the installer has to converge from it — rewriting
# both entries to the same command would leave the hook firing twice.
dup_home="$TMPROOT/home-dup"
mkdir -p "$dup_home/.claude"
cat > "$dup_home/.claude/settings.json" <<'JSON'
{"hooks":{
	"UserPromptSubmit":[
		{"matcher":"","hooks":[
			{"type":"command","command":"/new/clone/scripts/apex-manager-notify.sh prompt","timeout":10},
			{"type":"command","command":"/unrelated/other-tool.sh init"}]},
		{"matcher":"","hooks":[{"type":"command","command":"/old/clone/scripts/apex-manager-notify.sh","timeout":10}]}
	]}}
JSON
HOME="$dup_home" "$SCRIPTS/install-agent-hooks.sh" >/dev/null 2>&1 || true
dup_installed="$dup_home/.claude/settings.json"
eq "duplicate notify entries collapse to one" 1 \
	"$(jq '[.hooks.UserPromptSubmit[]?.hooks[]?.command? // "" | select(test("apex-manager-notify"))] | length' "$dup_installed")"
eq "collapse keeps unrelated hooks on the same event" 1 \
	"$(jq '[.hooks.UserPromptSubmit[]?.hooks[]?.command? // "" | select(test("other-tool"))] | length' "$dup_installed")"
dup_rc=0
APEX_REPO="$TMPROOT/nonexistent" HOME="$dup_home" \
	"$SCRIPTS/tmux-apex.sh" doctor >/dev/null 2>&1 || dup_rc=$?
eq "doctor accepts the collapsed result" 0 "$dup_rc"

# ── summary ──────────────────────────────────────────────────────────
print "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
