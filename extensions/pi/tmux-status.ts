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
 * 3. In-process apex delivery (issue #78), so nothing is typed into this pane.
 *    At session start the extension sets the pane option @apex_native_delivery
 *    to its pid, which tells tmux-apex.sh to keep its keystrokes out:
 *      manager → `watch` stops nudging. A 1s in-process tick watches the
 *                member records and, per tmux option @apex_wake_mode (default
 *                polite), delivers pending pings with pi.sendMessage:
 *                  quiet  never starts a turn; footer count, delivered with
 *                         the next human message
 *                  polite starts one only when idle with an empty editor
 *                  eager  starts one as soon as the agent is idle
 *      member  → `send` and pair relays land in this member's inbox, which the
 *                tick drains with `tmux-apex.sh check` and injects as
 *                follow-ups (a turn starts only when idle).
 *
 * Every call hands over this conversation's id (DELTA_AGENT_SESSION_ID): pi
 * publishes PI_SESSION_ID only to its bash tool's commands, and these scripts
 * run outside any tool call (see scripts/lib/agent-session.sh).
 */

import { execFile } from "node:child_process";
import { existsSync, realpathSync, statSync } from "node:fs";
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
const APEX = resolveScript("tmux-apex.sh");
const CUSTOM_TYPE = "tmux-delta-apex";
const APEX_ROOT = join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "tmux-delta", "apex");
// Re-read state this often even when nothing on disk changed: a stale
// `attention` member is reported on time alone, not on a write.
const RESCAN_MS = 30_000;

type Ctx = {
	sessionManager: { getSessionId(): string };
	isIdle?(): boolean;
	ui?: { getEditorText?(): string; setStatus?(key: string, text: string | undefined): void };
};
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

// stdout of a helper, or "" — never throws, never takes long.
function run(file: string, args: string[], sessionId?: string): Promise<string> {
	if (!process.env.TMUX) return Promise.resolve("");
	return new Promise((resolve) => {
		const child = execFile(file, args, { env: envFor(sessionId), timeout: 10_000 }, (_err, stdout) =>
			resolve((stdout ?? "").toString().trim()),
		);
		// Nothing to send: close stdin so no hook script waits on it.
		child.stdin?.end();
	});
}

// Pending pings for a manager, or "" (marks what it returns delivered).
const pending = (point: "session-start" | "prompt" | "poll", sessionId?: string) => run(NOTIFY, [point], sessionId);

export type WakeMode = "quiet" | "polite" | "eager";
export const wakeMode = (v?: string): WakeMode => (v === "quiet" || v === "eager" ? v : "polite");
// May a manager start a turn for pending pings right now?
export function mayWake(mode: WakeMode, idle: boolean, editorText: string): boolean {
	if (mode === "quiet" || !idle) return false;
	return mode === "eager" || editorText.trim() === "";
}

const mtime = (p: string) => {
	try {
		const st = statSync(p);
		return `${st.mtimeMs}:${st.size}`;
	} catch {
		return "";
	}
};

type Ident = { role: string; manager: string; member: string; wake: WakeMode };
// Who this pane is in apex: one tmux call. #{@opt} resolves pane, then
// session, then global, which is the lookup each of these options wants.
async function whoami(): Promise<Ident | undefined> {
	const pane = process.env.TMUX_PANE;
	if (!pane) return;
	const out = await run("tmux", [
		"display-message", "-p", "-t", pane,
		"#{session_name}\t#{pane_id}\t#{@apex_role}\t#{@apex_session}\t#{@apex_wake_mode}",
	]);
	const [session = "", paneId = "", role = "", mgr = "", wake = ""] = out.split("\t");
	if (role === "manager") return { role, manager: session, member: "", wake: wakeMode(wake) };
	if (role && mgr) return { role, manager: mgr, member: `${session}:${paneId}`, wake: wakeMode(wake) };
	return;
}

export default function (pi: ExtensionAPI) {
	// Pings consumed at session start arrive before there is a turn to put
	// them in, so they wait for the first prompt.
	let carried = "";

	// ── in-process delivery tick ──
	let ctxRef: Ctx | undefined;
	let timer: ReturnType<typeof setInterval> | undefined;
	let ticking = false;
	let ident: Ident | undefined;
	let identAt = 0;
	let seen = "";
	let scannedAt = 0;
	let waiting = 0;

	const idle = () => {
		try {
			return ctxRef?.isIdle?.() ?? false;
		} catch {
			return false;
		}
	};
	const editor = () => {
		try {
			return ctxRef?.ui?.getEditorText?.() ?? "";
		} catch {
			return "";
		}
	};
	const status = (text: string | undefined) => {
		try {
			ctxRef?.ui?.setStatus?.(CUSTOM_TYPE, text);
		} catch {}
	};
	// Re-read state only when its file changed, or every RESCAN_MS.
	const changed = (path: string, now: number) => {
		const m = mtime(path);
		if (m === seen && now - scannedAt < RESCAN_MS) return false;
		seen = m;
		scannedAt = now;
		return true;
	};

	async function managerTick(id: Ident, now: number) {
		if (changed(join(APEX_ROOT, id.manager, "members"), now)) {
			const out = await run(APEX, ["pending"], ctxRef && sid(ctxRef));
			waiting = out.split("\n").filter((l) => l.startsWith("[apex] ")).length;
		}
		status(waiting ? `apex: ${waiting} pending` : undefined);
		if (!waiting || !mayWake(id.wake, idle(), editor())) return;
		const text = await pending("poll", ctxRef && sid(ctxRef));
		waiting = 0;
		status(undefined);
		if (!text) return;
		// The human may have started typing while `poll` ran: then it waits
		// for their message rather than starting a turn over the draft.
		const message = { customType: CUSTOM_TYPE, content: text, display: true };
		if (mayWake(id.wake, idle(), editor())) pi.sendMessage(message, { deliverAs: "followUp", triggerTurn: true });
		else if (!idle()) pi.sendMessage(message, { deliverAs: "followUp" });
		else pi.sendMessage(message, { deliverAs: "nextTurn" });
	}

	async function memberTick(id: Ident, now: number) {
		if (!changed(join(APEX_ROOT, id.manager, "inbox", `${id.member}.jsonl`), now)) return;
		const out = await run(APEX, ["check", "--json", id.member]);
		for (const line of out.split("\n")) {
			let text: unknown;
			try {
				text = JSON.parse(line).text;
			} catch {
				continue;
			}
			// Queue-only: a follow-up while busy, a new turn only when idle.
			if (typeof text === "string" && text)
				pi.sendMessage({ customType: CUSTOM_TYPE, content: text, display: true }, { deliverAs: "followUp", triggerTurn: true });
		}
	}

	async function tick() {
		if (ticking || !ctxRef) return;
		ticking = true;
		try {
			const now = Date.now();
			// Roles are assigned after pi starts (init, member registration).
			if (now - identAt >= 5_000) {
				const next = await whoami();
				if (next?.manager !== ident?.manager || next?.member !== ident?.member) seen = "";
				ident = next;
				identAt = now;
			}
			if (ident?.role === "manager") await managerTick(ident, now);
			else if (ident?.member) await memberTick(ident, now);
		} finally {
			ticking = false;
		}
	}

	pi.on("session_start", async (_e, ctx) => {
		ctxRef = ctx;
		if (process.env.TMUX && process.env.TMUX_PANE) {
			await run("tmux", ["set-option", "-p", "-t", process.env.TMUX_PANE, "@apex_native_delivery", String(process.pid)]);
			timer ??= setInterval(() => void tick(), 1_000);
			timer.unref?.();
		}
		carried = await pending("session-start", sid(ctx));
	});

	pi.on("before_agent_start", async (_e, ctx) => {
		ctxRef = ctx;
		waiting = 0;
		status(undefined);
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
	pi.on("session_shutdown", async (_e, ctx) => {
		tmuxStatus("clear", sid(ctx));
		if (timer) clearInterval(timer);
		timer = undefined;
		ctxRef = undefined;
		if (process.env.TMUX && process.env.TMUX_PANE)
			await run("tmux", ["set-option", "-p", "-u", "-t", process.env.TMUX_PANE, "@apex_native_delivery"]);
	});
}
