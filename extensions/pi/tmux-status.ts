/**
 * tmux-delta integration for pi — the pi equivalent of claude-plugin/.
 *
 * Installed by scripts/install-agent-hooks.sh (a symlink at
 * ~/.pi/agent/extensions/tmux-status.ts). Two jobs:
 *
 * 1. Status. Drives the session pill and, for an apex member, tells the
 *    manager when this agent is busy, blocked, or idle (agent-tmux-status.sh):
 *      set    → working.   No ping.
 *      notify → blocked on a human. Pings the manager IMMEDIATELY, no debounce.
 *      clear  → idle.      Pings the manager after a quiet window.
 *    `notify` must fire only on a genuine "waiting for input" state, never at
 *    the end of every turn — that would defeat the debounce and spam the
 *    manager. ui_prompt_start is exactly that state: it fires around every
 *    blocking ctx.ui.confirm/select/input, such as a permissions extension's
 *    approval prompt. agent_settled (not agent_end) is the idle signal:
 *    agent_end fires before pi has decided whether to continue.
 *
 * 2. Apex manager delivery (apex-manager-notify.sh), mirroring the Claude Code
 *    hooks. On session start and before every prompt it relinks this tmux
 *    session's apex role to this conversation, and whatever pings are pending
 *    for a manager are put into the conversation: before the prompt, after a
 *    turn that ran tools (before the next model call), and at settle, where
 *    they buy one more turn so a worker that finished mid-run is acted on
 *    rather than waiting for the human. The script prints nothing, and costs
 *    one tmux call, for a session that is not a manager.
 *
 * Every call hands over this conversation's id (DELTA_AGENT_SESSION_ID): pi
 * publishes PI_SESSION_ID only to its bash tool's commands, and these scripts
 * run outside any tool call (see scripts/lib/agent-session.sh).
 */

import { execFile } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function resolveScript(name: string): string {
	const candidates: string[] = [];
	try {
		// Alongside this file in the tmux-delta checkout. The installer links
		// it into the agent's extension directory, and runtimes differ on
		// whether import.meta.url names the link or its target, so resolve it.
		const here = dirname(realpathSync(fileURLToPath(import.meta.url)));
		candidates.push(join(here, "..", "..", "scripts", name));
	} catch {}
	candidates.push(join(homedir(), ".local", "scripts", name));
	for (const c of candidates) if (existsSync(c)) return c;
	// README step 2 puts scripts/ on PATH.
	return name;
}

const STATUS = resolveScript("agent-tmux-status.sh");
const NOTIFY = resolveScript("apex-manager-notify.sh");
const CUSTOM_TYPE = "tmux-delta-apex";

type Ctx = { sessionManager: { getSessionId(): string }; isIdle?(): boolean };
const sid = (ctx: Ctx) => {
	try {
		return ctx.sessionManager.getSessionId();
	} catch {
		return undefined;
	}
};
const envFor = (sessionId?: string) =>
	sessionId ? { ...process.env, DELTA_AGENT_SESSION_ID: sessionId } : process.env;

export function tmuxStatus(action: "set" | "notify" | "clear", sessionId?: string) {
	if (!process.env.TMUX) return;
	execFile(STATUS, [action], { env: envFor(sessionId) }, () => {}).stdin?.end();
}

// Pending pings for a manager, or "" — never throws, never takes long.
function pending(point: "session-start" | "prompt" | "poll", sessionId?: string): Promise<string> {
	if (!process.env.TMUX) return Promise.resolve("");
	return new Promise((resolve) => {
		const child = execFile(NOTIFY, [point], { env: envFor(sessionId), timeout: 10_000 }, (_err, stdout) =>
			resolve((stdout ?? "").toString().trim()),
		);
		// Nothing to send: close stdin so no hook script waits on it.
		child.stdin?.end();
	});
}

export default function (pi: ExtensionAPI) {
	// Pings consumed at session start arrive before there is a turn to put
	// them in, so they wait for the first prompt.
	let carried = "";

	pi.on("session_start", async (_e, ctx) => {
		carried = await pending("session-start", sid(ctx));
	});

	pi.on("before_agent_start", async (_e, ctx) => {
		const text = [carried, await pending("prompt", sid(ctx))].filter(Boolean).join("\n");
		carried = "";
		if (!text) return;
		return { message: { customType: CUSTOM_TYPE, content: text, display: true } };
	});

	// After a turn that ran tools, pi calls the model again anyway: pings
	// consumed here are in front of it for that call. A turn with no tools is
	// the last one, and settle below is the place for those.
	pi.on("turn_end", async (e, ctx) => {
		if (!e.toolResults?.length) return;
		const text = await pending("poll", sid(ctx));
		if (!text) return;
		return { entries: [{ type: "custom_message", customType: CUSTOM_TYPE, content: text, display: true }] };
	});

	// One more turn when a ping landed while this run was finishing. Cannot
	// loop: `poll` marks what it prints as delivered, so the next settle
	// finds nothing.
	pi.on("agent_before_settle", async (e, ctx) => {
		if (!e.context?.canContinue) return;
		const text = await pending("poll", sid(ctx));
		if (!text) return;
		return {
			entries: [{ type: "custom_message", customType: CUSTOM_TYPE, content: text, display: true }],
			continue: true,
		};
	});

	pi.on("agent_start", (_e, ctx) => tmuxStatus("set", sid(ctx)));
	pi.on("ui_prompt_start", (_e, ctx) => tmuxStatus("notify", sid(ctx)));
	// A prompt can also be raised while idle (from a /command): answering it
	// must not leave the pill claiming work.
	pi.on("ui_prompt_end", (_e, ctx) => tmuxStatus(ctx.isIdle?.() ? "clear" : "set", sid(ctx)));
	pi.on("agent_settled", (_e, ctx) => tmuxStatus("clear", sid(ctx)));
	pi.on("session_shutdown", (_e, ctx) => tmuxStatus("clear", sid(ctx)));
}
