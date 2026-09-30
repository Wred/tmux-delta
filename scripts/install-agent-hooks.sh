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

# ─── Claude Code: install the tmux-delta-claude plugin ────────────────
#
# Through 2b86ba6 this jq-merged PreToolUse/Notification/Stop/UserPromptSubmit/
# SessionStart/PostToolBatch entries straight into ~/.claude/settings.json —
# global config a human might otherwise manage entirely by hand (dotfiles),
# and the one file besides this repo's own that ever needed to know
# tmux-delta's internal script paths. `claude-plugin/` now carries the same
# six hooks (see claude-plugin/hooks/hooks.json), scoped to fire only while
# the plugin is installed and enabled, addressed via ${CLAUDE_PLUGIN_ROOT}
# instead of a path this installer has to keep correct by hand. See issue #73.
install_claude_hooks() {
	command -v claude >/dev/null 2>&1 || { skip "claude: not installed"; return; }
	claude plugin --help >/dev/null 2>&1 || { skip "claude: no 'plugin' subcommand (upgrade Claude Code)"; return; }
	command -v jq >/dev/null 2>&1 || { skip "claude hooks: jq not found"; return; }

	local plugin_dir="$REPO_ROOT/claude-plugin"
	local plugin_id="tmux-delta-claude@tmux-delta"

	# marketplace add is idempotent — re-adding the same name repoints it to
	# whatever path is passed, which is exactly what self-heals a moved clone —
	# so there is no need to special-case "already correct" beyond what it
	# takes to report a clean dry run.
	local mp_path
	mp_path=$(claude plugin marketplace list --json 2>/dev/null \
		| jq -r '.[] | select(.name == "tmux-delta") | .path // empty' 2>/dev/null)
	if [[ "$mp_path" == "$plugin_dir" ]]; then
		skip "claude: marketplace tmux-delta already at $plugin_dir"
	elif $DRY_RUN; then
		apply "claude: marketplace add $plugin_dir"
	elif claude plugin marketplace add "$plugin_dir" >/dev/null 2>&1; then
		apply "claude: marketplace add $plugin_dir"
	else
		note "claude: marketplace add $plugin_dir failed"
		return
	fi

	# Plain jq, not -e: a `false` result is a valid answer, not a failure, and
	# -e would exit 1 for it — fatal under set -e once that exit status lands
	# in a bare assignment instead of an `if`/`&&` that catches it.
	local already_installed
	already_installed=$(claude plugin list --json 2>/dev/null \
		| jq --arg id "$plugin_id" 'any(.[]; .id == $id and .enabled == true)' 2>/dev/null)
	if [[ "$already_installed" == true ]]; then
		skip "claude: plugin $plugin_id already installed"
	elif $DRY_RUN; then
		apply "claude: plugin install $plugin_id"
		return  # nothing was actually installed, so the migration below can't run yet
	elif claude plugin install "$plugin_id" >/dev/null 2>&1; then
		apply "claude: plugin installed ($plugin_id)"
	else
		note "claude: plugin install $plugin_id failed"
		return
	fi

	migrate_claude_settings_hooks
}

# migrate_claude_settings_hooks — remove the pre-plugin hook entries this
# installer used to jq-merge into ~/.claude/settings.json.
#
# Only called once the plugin above is confirmed installed and enabled, never
# on its own: removing the old wiring before the replacement is live would
# leave a machine with neither. Matched the same way the old upsert was
# (script basename, not the trailing verb), so an entry this installer never
# wrote — someone else's PreToolUse hook, say — is never touched.
migrate_claude_settings_hooks() {
	local settings="$HOME/.claude/settings.json"
	[[ -f "$settings" ]] || return
	local pat='(^|/)(agent-tmux-status|apex-manager-notify)\.sh( |$)'
	local tmp
	tmp="$(mktemp "${settings}.XXXXXX")"
	jq --arg pat "$pat" '
		.hooks //= {} |
		.hooks |= (
			with_entries(.value |= (
				map(.hooks = (.hooks | map(select((.command? // "" | test($pat)) | not))))
				| map(select((.hooks | length) > 0))
			))
			| with_entries(select((.value | length) > 0))
		)
	' "$settings" > "$tmp"
	if diff -q "$settings" "$tmp" >/dev/null; then
		rm -f "$tmp"
	elif $DRY_RUN; then
		apply "claude: remove pre-plugin hooks from $settings (superseded by plugin)"
		rm -f "$tmp"
	else
		mv "$tmp" "$settings"
		apply "claude: removed pre-plugin hooks from $settings (superseded by plugin)"
	fi
}

# ─── symlink helper: only touch links this script itself owns ────────
#
# Three things can already be sitting at <dst>, and only one of them is left
# alone:
#   - a symlink into *a* tmux-delta checkout at the same repo-relative path —
#     ours, possibly from a clone that has since moved. Repointed.
#   - a regular file that calls agent-tmux-status.sh — a hand-copied tmux-delta
#     extension from before this installer existed, which goes stale the moment
#     the shipped one changes (issue: a pi copy fired `notify` on every
#     agent_end, pinging the apex manager "blocked" at the end of every turn).
#     Moved aside to <dst>.bak, never deleted, then replaced by the link.
#   - anything else: someone else's file. Left alone, and said so.

# _repo_rel <src> — <src> relative to the repo root, e.g. extensions/pi/tmux-status.ts
_repo_rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }

_backup_path() {
	local dst="$1" bak="$1.bak" n=1
	while [[ -e "$bak" || -L "$bak" ]]; do bak="$dst.bak.$n"; n=$((n + 1)); done
	printf '%s' "$bak"
}

link_if_safe() {
	local src="$1" dst="$2" label="$3" cur rel
	rel="$(_repo_rel "$src")"
	if [[ -L "$dst" ]]; then
		cur="$(readlink "$dst")"
		if [[ "$cur" == "$src" ]]; then
			skip "$label already linked"
			return
		fi
		if [[ "$cur" == */"$rel" ]]; then
			if $DRY_RUN; then
				apply "$label: repoint $dst from $cur to $src"
			else
				ln -sfn "$src" "$dst"
				apply "$label: repointed (was $cur)"
			fi
			return
		fi
	fi
	if [[ -f "$dst" && ! -L "$dst" ]] && grep -q 'agent-tmux-status\.sh' "$dst" 2>/dev/null; then
		local bak
		bak="$(_backup_path "$dst")"
		if $DRY_RUN; then
			apply "$label: replace old tmux-delta copy $dst (backup to $bak)"
		else
			mv "$dst" "$bak"
			ln -s "$src" "$dst"
			apply "$label: replaced old tmux-delta copy (backup: $bak)"
		fi
		return
	fi
	if [[ -e "$dst" || -L "$dst" ]]; then
		note "$label: $dst already exists and isn't ours — leaving it alone"
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

# ─── apex skill ──────────────────────────────────────────────────────────
#
# One skill, two discovery roots. Claude Code reads ~/.claude/skills; pi, codex
# and opencode all read the cross-agent ~/.agents/skills (opencode reads both,
# and resolves the duplicate by name). Linked whether or not a given agent is
# installed yet: the link is inert until something reads it, and installing an
# agent later should not need this script re-run to get apex mode.

install_skill() {
	link_if_safe "$SKILL_SRC" "$HOME/.claude/skills/delta-apex" "skill (claude)"
	link_if_safe "$SKILL_SRC" "$HOME/.agents/skills/delta-apex" "skill (pi, codex, opencode)"
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
echo "apex skill:"
install_skill
echo
echo "Claude Code:"
install_claude_hooks
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
