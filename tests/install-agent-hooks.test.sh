#!/usr/bin/env zsh
# install-agent-hooks.sh must leave a machine fully wired from nothing more than
# loading the plugin — skill and extensions included — without clobbering a
# file it does not own.
#
# Three things can already sit where it wants a symlink: a link into a moved
# tmux-delta clone (repoint it), a hand-copied tmux-delta extension from before
# the installer existed (back it up and replace it — a stale pi copy pinged the
# apex manager "blocked" at the end of every turn), and someone else's file
# (leave it). All run against a throwaway HOME with stub agents on PATH.
#
# Run: tests/install-agent-hooks.test.sh
set -u
emulate -L zsh

REPO="${0:A:h:h}"
INSTALL="$REPO/scripts/install-agent-hooks.sh"

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq() {
	if [[ $2 == $3 ]]; then ok "$1"
	else bad "$1" "expected: \"$2\"$'\n'       actual  : \"$3\""; fi
}

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-hooks-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home"; mkdir -p "$HOME"
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
# pi, opencode and codex only need to exist (HOME is throwaway, so codex's
# config lands there); claude is left off PATH so the installer skips its
# CLI-driven plugin install instead of touching real config.
for a in pi opencode codex; do print '#!/bin/sh' > "$BIN/$a"; chmod +x "$BIN/$a"; done
export PATH="$BIN:/usr/bin:/bin:/opt/homebrew/bin"

run() { bash "$INSTALL" "$@" 2>&1 }

PI_EXT="$HOME/.pi/agent/extensions/tmux-status.ts"
OC_EXT="$HOME/.config/opencode/plugin/tmux-status.js"

# A hand-copied tmux-delta pi extension, and a moved clone's opencode link.
mkdir -p "${PI_EXT:h}" "${OC_EXT:h}"
print -r -- 'execFile(join(homedir(), ".local/scripts/agent-tmux-status.sh"), ["notify"])' > "$PI_EXT"
ln -s "/old/clone/tmux-delta/extensions/opencode/tmux-status.js" "$OC_EXT"
# codex hooks: someone else's, plus one of ours from a moved clone.
CX_HOOKS="$HOME/.codex/hooks.json"; mkdir -p "${CX_HOOKS:h}"
jq -n '{hooks: {Stop: [
	{hooks: [{type: "command", command: "/usr/local/bin/their-hook"}]},
	{hooks: [{type: "command", command: "/old/clone/tmux-delta/scripts/agent-tmux-status.sh clear"}]}
]}}' > "$CX_HOOKS"

print "dry run"
out=$(run --dry-run)
[[ -f $PI_EXT && ! -L $PI_EXT ]] && ok "a dry run changes nothing" \
	|| bad "a dry run changes nothing" "$(ls -la "${PI_EXT:h}")"

print "first run"
out=$(run)
eq "the skill is linked for claude" "$REPO/skills/delta-apex" "$(readlink "$HOME/.claude/skills/delta-apex")"
eq "and for pi, codex and opencode" "$REPO/skills/delta-apex" "$(readlink "$HOME/.agents/skills/delta-apex")"
eq "an old tmux-delta copy is replaced by the link" "$REPO/extensions/pi/tmux-status.ts" "$(readlink "$PI_EXT")"
[[ -f $PI_EXT.bak && $(<"$PI_EXT.bak") == *agent-tmux-status.sh* ]] \
	&& ok "and kept as a backup" || bad "and kept as a backup" "$(ls -la "${PI_EXT:h}")"
eq "a moved clone's link is repointed" "$REPO/extensions/opencode/tmux-status.js" "$(readlink "$OC_EXT")"
cx_cmds() { jq -r --arg e "$1" '.hooks[$e][]?.hooks[]?.command' "$CX_HOOKS" }
eq "codex gets the prompt-time ping delivery" "$REPO/scripts/apex-manager-notify.sh prompt json" "$(cx_cmds UserPromptSubmit)"
eq "and the blocked signal" "$REPO/scripts/agent-tmux-status.sh notify" "$(cx_cmds PermissionRequest)"
eq "someone else's codex hook survives, ours is repointed" \
	"/usr/local/bin/their-hook
$REPO/scripts/agent-tmux-status.sh clear" "$(cx_cmds Stop)"

print "second run"
out=$(run)
[[ $out != *replaced* && $out != *repointed* && $out != *": linked"* && $out != *"entries written"* ]] \
	&& ok "re-running is a no-op" || bad "re-running is a no-op" "$out"
[[ ! -e $PI_EXT.bak.1 ]] && ok "and makes no second backup" || bad "and makes no second backup" "$(ls -la "${PI_EXT:h}")"

print "foreign files"
rm "$PI_EXT"
print -r -- '// somebody else'"'"'s extension' > "$PI_EXT"
out=$(run)
[[ ! -L $PI_EXT && $(<"$PI_EXT") == *"somebody else"* ]] \
	&& ok "a file that isn't tmux-delta's is left alone" || bad "a file that isn't tmux-delta's is left alone" "$(ls -la "$PI_EXT")"
[[ $out == *"isn't ours"* ]] && ok "and the installer says so" || bad "and the installer says so" "$out"

print ""
print -- "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
