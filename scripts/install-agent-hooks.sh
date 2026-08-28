#!/usr/bin/env bash
# install-agent-hooks.sh — wire the coding-agent hooks tmux-delta's apex mode
# and activity pills depend on, for whatever machine this repo is cloned on.
#
# Those hooks live outside this repo (~/.claude/settings.json, agent
# extension directories, ~/.codex/config.toml) so `git clone`/TPM never
# installs them — that's the gap this script closes. It is safe to re-run:
# every change it makes is upsert-by-marker, so running it again after
# moving the clone (or after TPM re-lays it out) just repoints existing
# entries instead of duplicating them.
#
# Usage: scripts/install-agent-hooks.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts"
STATUS_SH="$SCRIPTS/agent-tmux-status.sh"
NOTIFY_SH="$SCRIPTS/apex-manager-notify.sh"
SKILL_SRC="$REPO_ROOT/skills/delta-apex"
PI_EXT_SRC="$REPO_ROOT/extensions/pi/tmux-status.ts"
OPENCODE_EXT_SRC="$REPO_ROOT/extensions/opencode/tmux-status.js"

note()  { printf '  %s\n' "$*"; }
skip()  { printf '  skip: %s\n' "$*"; }
apply() { printf '  + %s\n' "$*"; }

# ─── Claude Code: ~/.claude/settings.json hooks ───────────────────────

install_claude_hooks() {
	local settings="$HOME/.claude/settings.json"
	command -v jq >/dev/null 2>&1 || { skip "claude hooks: jq not found"; return; }

	mkdir -p "$(dirname "$settings")"
	[[ -f "$settings" ]] || echo '{}' > "$settings"
	jq -e . "$settings" >/dev/null 2>&1 || { note "claude hooks: $settings is not valid JSON, skipping"; return; }

	# Parallel arrays: event, matcher, command, pattern (matches existing
	# entries so they get repointed in place instead of duplicated), extra
	# jq object merged into the hook entry (e.g. timeout).
	local events=(PreToolUse Notification Stop UserPromptSubmit SessionStart)
	local matchers=("" "" "" "" "startup|resume")
	local cmds=("$STATUS_SH set" "$STATUS_SH notify" "$STATUS_SH clear" "$NOTIFY_SH" "$NOTIFY_SH")
	# Matched by script basename only (not the trailing verb) so a hook
	# left wired to the wrong verb — e.g. Notification still pointing at
	# "clear" — gets corrected in place instead of getting a duplicate
	# second entry alongside the stale one.
	local pats=(
		'(^|/)agent-tmux-status\.sh( |$)'
		'(^|/)agent-tmux-status\.sh( |$)'
		'(^|/)agent-tmux-status\.sh( |$)'
		'(^|/)apex-manager-notify\.sh$'
		'(^|/)apex-manager-notify\.sh$'
	)
	local extras=("{}" "{}" "{}" '{"timeout":10}' '{"timeout":10}')

	local i event matcher cmd pat extra tmp
	for i in "${!events[@]}"; do
		event="${events[$i]}"; matcher="${matchers[$i]}"; cmd="${cmds[$i]}"
		pat="${pats[$i]}"; extra="${extras[$i]}"

		tmp="$(mktemp "${settings}.XXXXXX")"
		jq --arg event "$event" --arg matcher "$matcher" --arg cmd "$cmd" \
		   --arg pat "$pat" --argjson extra "$extra" '
			.hooks //= {} |
			.hooks[$event] //= [] |
			(.hooks[$event] | any(.hooks[]?.command? // "" | test($pat))) as $exists |
			if $exists then
				.hooks[$event] = (.hooks[$event] | map(
					.hooks = (.hooks | map(
						if (.command? // "" | test($pat)) then .command = $cmd else . end
					))
				))
			else
				.hooks[$event] += [({matcher: $matcher, hooks: [({type:"command", command: $cmd} + $extra)]})]
			end
		' "$settings" > "$tmp"
		if $DRY_RUN; then
			if diff -q "$settings" "$tmp" >/dev/null; then
				skip "claude: $event -> $(basename "$cmd") already wired"
			else
				apply "claude: $event -> $cmd"
			fi
			rm -f "$tmp"
		else
			if diff -q "$settings" "$tmp" >/dev/null; then
				skip "claude: $event -> $(basename "$cmd") already wired"
				rm -f "$tmp"
			else
				mv "$tmp" "$settings"
				apply "claude: $event -> $cmd"
			fi
		fi
	done
}

# ─── symlink helper: only touch links this script itself owns ────────

link_if_safe() {
	local src="$1" dst="$2" label="$3"
	if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
		skip "$label already linked"
		return
	fi
	if [[ -e "$dst" || -L "$dst" ]]; then
		note "$label: $dst already exists and isn't our symlink — leaving it alone"
		return
	fi
	if $DRY_RUN; then
		apply "$label: ln -s $src $dst"
		return
	fi
	mkdir -p "$(dirname "$dst")"
	ln -s "$src" "$dst"
	apply "$label: linked"
}

# ─── Claude Code skill ─────────────────────────────────────────────────

install_claude_skill() {
	link_if_safe "$SKILL_SRC" "$HOME/.claude/skills/delta-apex" "claude skill"
}

# ─── pi extension ──────────────────────────────────────────────────────

install_pi_extension() {
	command -v pi >/dev/null 2>&1 || { skip "pi: not installed"; return; }
	link_if_safe "$PI_EXT_SRC" "$HOME/.pi/agent/extensions/tmux-status.ts" "pi extension"
}

# ─── opencode plugin ────────────────────────────────────────────────────

install_opencode_plugin() {
	command -v opencode >/dev/null 2>&1 || { skip "opencode: not installed"; return; }
	link_if_safe "$OPENCODE_EXT_SRC" "$HOME/.config/opencode/plugin/tmux-status.js" "opencode plugin"
}

# ─── codex notify hook ──────────────────────────────────────────────────

install_codex_hook() {
	command -v codex >/dev/null 2>&1 || { skip "codex: not installed"; return; }
	local cfg="$HOME/.codex/config.toml"
	if [[ -f "$cfg" ]] && grep -q '^notify' "$cfg"; then
		note "codex: $cfg already has a notify hook — leaving it alone"
		return
	fi
	local line
	line="notify = [\"$STATUS_SH\", \"clear\"]"
	if $DRY_RUN; then
		apply "codex: append '$line' to $cfg"
		return
	fi
	mkdir -p "$(dirname "$cfg")"
	{ [[ -s "$cfg" ]] && echo; printf '%s\n' "$line"; } >> "$cfg"
	apply "codex: appended notify hook to $cfg"
}

echo "tmux-delta agent hooks — repo: $REPO_ROOT"
$DRY_RUN && echo "(dry run — no changes will be made)"
echo
echo "Claude Code:"
install_claude_hooks
install_claude_skill
echo
echo "pi:"
install_pi_extension
echo
echo "opencode:"
install_opencode_plugin
echo
echo "codex:"
install_codex_hook
echo
echo "Done. Restart/reload any running agent sessions to pick up new hooks."
