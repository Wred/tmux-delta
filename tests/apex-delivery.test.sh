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

# A stub `claude` covering the bits of `claude plugin ...` that
# install-agent-hooks.sh and doctor's plugin check depend on. State lives at
# $HOME/.claude-stub-plugins.json, exactly the way the real CLI's plugin
# config lives under $HOME — so tests that vary $HOME (the fixtures below,
# each install-agent-hooks.sh run against its own throwaway HOME) get
# naturally isolated state without any extra plumbing, and a HOME nothing has
# touched yet reads back as "no marketplace, nothing installed" rather than
# erroring.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -u
state="${HOME:?}/.claude-stub-plugins.json"
[[ -f "$state" ]] || echo '{"marketplaces":[],"plugins":[]}' > "$state"

[[ "${1:-}" == plugin ]] || exit 0
sub="${2:-}"
case "$sub" in
	--help) exit 0 ;;
	marketplace)
		case "${3:-}" in
			list) jq '.marketplaces' "$state" ;;
			add)
				path="${4:-}"
				jq --arg p "$path" '
					.marketplaces = ([.marketplaces[] | select(.name != "tmux-delta")]
						+ [{name: "tmux-delta", path: $p}])
				' "$state" > "$state.tmp" && mv "$state.tmp" "$state" ;;
		esac ;;
	list) jq '.plugins' "$state" ;;
	install)
		id="${3:-}"
		jq --arg id "$id" '
			.plugins = ([.plugins[] | select(.id != $id)] + [{id: $id, enabled: true}])
		' "$state" > "$state.tmp" && mv "$state.tmp" "$state" ;;
esac
EOF
chmod +x "$BIN/claude"

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

# A verb that is a prefix of the real one must not match. Anchored to the
# missing-line text, not to a bare "SessionStart": doctor names the event on
# the "wired already" line too, so a looser needle passes even with the verb
# check removed entirely — i.e. it could not fail for the bug it guards.
prefix=$(fixture prefix "{\"hooks\":{\"SessionStart\":[$(entry session)]}}")
contains "prefix of a verb does not match" \
	"missing Claude Code hooks: UserPromptSubmit, SessionStart" "$(doctor "$prefix")"

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

# The fix hint must not hand out a worktree path: both hooks and the plugin
# marketplace are global config and would break silently once the worktree is
# removed. Give doctor a HOME with a plugin install in it and check it prefers
# that over its own location.
fake_home="$TMPROOT/home-with-install"
mkdir -p "$fake_home/.tmux/plugins/tmux-delta/scripts"
touch "$fake_home/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh"
out=$(APEX_REPO="$none" HOME="$fake_home" "$SCRIPTS/tmux-apex.sh" doctor 2>&1 || true)
contains "fix hint uses the stable install path" \
	'~/.tmux/plugins/tmux-delta/claude-plugin' "$out"
# The unrelated "run '<SELF> pending' by hand" line always names this
# checkout (it invokes the running copy directly, not a stable install), so
# check the plugin hint specifically rather than the whole output.
if [[ $out != *"$SCRIPTS:h/claude-plugin"* ]]; then
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
contains "fix hint falls back to the running copy" "$SCRIPTS:h/claude-plugin" "$out"

# ── installer contract ──────────────────────────────────────────────
# scripts/install-agent-hooks.sh runs backgrounded on every plugin load, so
# whatever it does is what most machines actually get. Since issue #73 that
# means installing the tmux-delta-claude plugin (marketplace add + install)
# rather than jq-merging settings.json directly, and cleaning up whatever an
# older run of this same installer left in settings.json so the two delivery
# paths don't both fire. `claude` is stubbed above; state lives under each
# scenario's own $HOME.
print "\ninstaller contract"

REPO_ROOT="${SCRIPTS:h}"
plugin_dir="$REPO_ROOT/claude-plugin"

# marketplace()/plugin_enabled() read the stub's own state file back — the
# same thing a real `claude plugin marketplace|list --json` would report.
marketplace() { jq -r '.marketplaces[]? | select(.name=="tmux-delta") | .path // empty' "$1/.claude-stub-plugins.json" 2>/dev/null }
plugin_enabled() { jq -e --arg id "$2" 'any(.plugins[]?; .id==$id and .enabled==true)' "$1/.claude-stub-plugins.json" >/dev/null 2>&1 }

inst_home="$TMPROOT/home-installer"
mkdir -p "$inst_home/.claude"

# Seed the pre-plugin wiring this same installer used to write, right down to
# the argument-less entry PR #11 fixed — the migration has to clear it too,
# not just the well-formed kind.
cat > "$inst_home/.claude/settings.json" <<JSON
{"hooks":{
	"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"/old/clone/scripts/apex-manager-notify.sh","timeout":10}]}],
	"SessionStart":[{"matcher":"startup|resume","hooks":[
		{"type":"command","command":"/old/clone/scripts/apex-manager-notify.sh session-start","timeout":10},
		{"type":"command","command":"/unrelated/other-tool.sh init"}]}],
	"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/old/clone/scripts/agent-tmux-status.sh clear"}]}]
}}
JSON

HOME="$inst_home" "$SCRIPTS/install-agent-hooks.sh" >/dev/null 2>&1 || true
installed="$inst_home/.claude/settings.json"

eq "installer leaves valid JSON" 0 "$(jq -e . "$installed" >/dev/null 2>&1; print $?)"
eq "installer points the marketplace at this checkout's plugin" "$plugin_dir" "$(marketplace "$inst_home")"
if plugin_enabled "$inst_home" "tmux-delta-claude@tmux-delta"; then ok "installer installs and enables the plugin"
else bad "installer installs and enables the plugin" "$(cat "$inst_home/.claude-stub-plugins.json")"; fi

# The contract test: doctor must accept what the installer produced, purely
# off the plugin — settings.json has nothing left to find.
inst_rc=0
APEX_REPO="$TMPROOT/nonexistent" HOME="$inst_home" \
	"$SCRIPTS/tmux-apex.sh" doctor >/dev/null 2>&1 || inst_rc=$?
eq "doctor accepts what the installer wrote" 0 "$inst_rc"

# Migration must remove exactly the entries it owns and nothing else.
eq "migration removes the old apex-manager-notify.sh entries" 0 \
	"$(jq '[.. | .command? // empty | select(test("apex-manager-notify\\.sh"))] | length' "$installed")"
eq "migration removes the old agent-tmux-status.sh entries" 0 \
	"$(jq '[.. | .command? // empty | select(test("agent-tmux-status\\.sh"))] | length' "$installed")"
contains "migration leaves an unrelated hook on the same event alone" "other-tool.sh" \
	"$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command? // ""] | join(" | ")' "$installed")"
eq "migration drops an event left with nothing but our own hooks" 0 \
	"$(jq '[.hooks.Stop // empty] | length' "$installed")"

# Same contract from nothing at all, not just from a stale wiring.
fresh_home="$TMPROOT/home-fresh"
mkdir -p "$fresh_home"
HOME="$fresh_home" "$SCRIPTS/install-agent-hooks.sh" >/dev/null 2>&1 || true
fresh_rc=0
APEX_REPO="$TMPROOT/nonexistent" HOME="$fresh_home" \
	"$SCRIPTS/tmux-apex.sh" doctor >/dev/null 2>&1 || fresh_rc=$?
eq "doctor accepts a from-scratch install" 0 "$fresh_rc"

# Re-running must be a no-op, since it runs on every plugin load: no further
# marketplace/install calls (the stub is idempotent either way, but the point
# is the installer doesn't need it to be — it checks state before acting).
before_mp=$(marketplace "$inst_home")
before_settings=$(cat "$installed")
HOME="$inst_home" "$SCRIPTS/install-agent-hooks.sh" >/dev/null 2>&1 || true
eq "installer is idempotent (marketplace)" "$before_mp" "$(marketplace "$inst_home")"
eq "installer is idempotent (settings.json)" "$before_settings" "$(cat "$installed")"

# `claude` present but too old for `plugin` support: the installer must leave
# whatever wiring already exists alone rather than deleting it with nothing to
# take its place. Different HOME from $inst_home so the stub's own state can't
# leak the "already installed" answer in from a different test.
noplugin_home="$TMPROOT/home-noplugin"
mkdir -p "$noplugin_home/.claude"
cat > "$noplugin_home/.claude/settings.json" <<JSON
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/old/clone/scripts/agent-tmux-status.sh clear"}]}]}}
JSON
# Shadow just `claude`, ahead of the working stub already on \$PATH — jq,
# mkdir, ln and everything else the installer needs still resolve normally.
OLDBIN="$TMPROOT/oldbin"
mkdir -p "$OLDBIN"
cat > "$OLDBIN/claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-} ${2:-}" == "plugin --help" ]] && exit 1
exit 0
EOF
chmod +x "$OLDBIN/claude"
before_noplugin=$(cat "$noplugin_home/.claude/settings.json")
HOME="$noplugin_home" PATH="$OLDBIN:$PATH" "$SCRIPTS/install-agent-hooks.sh" >/dev/null 2>&1 || true
eq "no plugin support: settings.json is untouched" "$before_noplugin" "$(cat "$noplugin_home/.claude/settings.json")"

# Dry run must not call the stub's mutating paths at all.
dry_home="$TMPROOT/home-dry"
mkdir -p "$dry_home"
HOME="$dry_home" "$SCRIPTS/install-agent-hooks.sh" --dry-run >/dev/null 2>&1 || true
eq "dry run adds no marketplace" "" "$(marketplace "$dry_home")"

# ── summary ──────────────────────────────────────────────────────────
print "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
