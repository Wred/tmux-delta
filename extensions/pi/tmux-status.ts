/**
 * tmux-delta status reporting for pi.
 *
 * The pi equivalent of the Claude Code hook block in tmux-delta's README:
 * drives the session pill, and — for sessions spawned in apex mode —
 * feeds tmux-apex.sh so the manager learns when this worker is busy, blocked,
 * or idle.
 *
 * Install:
 *   ln -s ~/.tmux/plugins/tmux-delta/extensions/pi/tmux-status.ts \
 *         ~/.pi/agent/extensions/tmux-status.ts
 *
 * Event mapping (the semantics matter — see scripts/tmux-apex.sh):
 *   set    → working.   No ping.
 *   notify → blocked on a human. Pings the manager IMMEDIATELY, no debounce.
 *   clear  → idle.      Pings the manager after a quiet window.
 *
 * So `notify` must fire only on a genuine "waiting for input" state, never at
 * the end of every turn — that would defeat the debounce and spam the manager.
 * agent_settled (not agent_end) is the idle signal: agent_end fires before tool
 * execution has finished.
 *
 * To fire `notify`, call tmuxStatus("notify") before any blocking prompt your
 * other extensions raise (e.g. a permissions confirm) and tmuxStatus("set")
 * after it resolves.
 */

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function resolveScript(): string {
	const candidates: string[] = [];
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

// pi publishes PI_SESSION_ID only to its bash tool's commands, and these
// scripts run outside any tool call, so the id is handed over explicitly —
// it is how apex knows which conversation to resume this worker into
// (scripts/lib/agent-session.sh).
export function tmuxStatus(action: "set" | "notify" | "clear", sessionId?: string) {
	if (!process.env.TMUX) return;
	const env = sessionId ? { ...process.env, DELTA_AGENT_SESSION_ID: sessionId } : process.env;
	execFile(SCRIPT, [action], { env }, () => {});
}

type Ctx = { sessionManager: { getSessionId(): string } };
const sid = (ctx: Ctx) => {
	try {
		return ctx.sessionManager.getSessionId();
	} catch {
		return undefined;
	}
};

export default function (pi: ExtensionAPI) {
	pi.on("agent_start", (_e, ctx) => tmuxStatus("set", sid(ctx)));
	pi.on("agent_settled", (_e, ctx) => tmuxStatus("clear", sid(ctx)));
	pi.on("session_shutdown", (_e, ctx) => tmuxStatus("clear", sid(ctx)));
}
