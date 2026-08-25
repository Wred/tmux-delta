/**
 * tmux-delta status reporting for opencode.
 *
 * The opencode equivalent of the Claude Code hook block in tmux-delta's README:
 * drives the session pill, and — for sessions spawned in apex mode —
 * feeds tmux-apex.sh so the manager learns when this worker is busy, blocked,
 * or idle.
 *
 * Install:
 *   mkdir -p ~/.config/opencode/plugin
 *   ln -s ~/.tmux/plugins/tmux-delta/extensions/opencode/tmux-status.js \
 *         ~/.config/opencode/plugin/tmux-status.js
 *
 * Event mapping (the semantics matter — see scripts/tmux-apex.sh):
 *   set    → working.   No ping.
 *   notify → blocked on a human. Pings the manager IMMEDIATELY, no debounce.
 *   clear  → idle.      Pings the manager after a quiet window.
 *
 * permission.asked / permission.replied are opencode bus events; if this build
 * does not deliver them to plugins the mapping quietly degrades to working/idle,
 * which is still enough for the apex manager to track the worker.
 */

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

function resolveScript() {
	const candidates = [];
	try {
		// Alongside this file in a tmux-delta checkout, whether or not the
		// runtime resolved the symlink we were installed as.
		const here = dirname(fileURLToPath(import.meta.url));
		candidates.push(join(here, "..", "..", "scripts", "agent-tmux-status.sh"));
	} catch {}
	candidates.push(join(homedir(), ".local", "scripts", "agent-tmux-status.sh"));
	for (const c of candidates) if (existsSync(c)) return c;
	// README step 2 puts scripts/ on PATH.
	return "agent-tmux-status.sh";
}

const SCRIPT = resolveScript();

function tmuxStatus(action) {
	if (!process.env.TMUX) return;
	execFile(SCRIPT, [action], { env: process.env }, () => {});
}

export const TmuxDeltaStatus = async () => ({
	"tool.execute.before": async () => {
		tmuxStatus("set");
	},
	event: async ({ event }) => {
		switch (event?.type) {
			case "permission.asked":
				tmuxStatus("notify");
				break;
			case "permission.replied":
				tmuxStatus("set");
				break;
			case "session.idle":
			case "session.error":
				tmuxStatus("clear");
				break;
		}
	},
});
