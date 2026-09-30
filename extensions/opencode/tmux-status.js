/**
 * tmux-delta integration for opencode — the opencode equivalent of
 * claude-plugin/.
 *
 * Installed by scripts/install-agent-hooks.sh (a symlink at
 * ~/.config/opencode/plugin/tmux-status.js). Two jobs:
 *
 * 1. Status. Drives the session pill and, for an apex member, tells the
 *    manager when this agent is busy, blocked, or idle (agent-tmux-status.sh):
 *      set    → working.   No ping.
 *      notify → blocked on a human. Pings the manager IMMEDIATELY, no debounce.
 *      clear  → idle.      Pings the manager after a quiet window.
 *    permission.asked / permission.replied are opencode bus events; if this
 *    build does not deliver them to plugins the mapping quietly degrades to
 *    working/idle, which is still enough for the apex manager to track it.
 *
 * 2. Apex manager delivery (apex-manager-notify.sh), mirroring the Claude Code
 *    hooks. On a new session and on every user message it relinks this tmux
 *    session's apex role to this conversation; pings pending for a manager go
 *    into the system prompt of the next model request — which opencode builds
 *    for every step of a turn, so a ping that lands mid-turn is in front of
 *    the very next call. The script prints nothing, and costs one tmux call,
 *    for a session that is not a manager.
 *
 * opencode publishes no session id to child processes, so every call hands it
 * over (DELTA_AGENT_SESSION_ID), and the shell tool's commands get it as
 * OPENCODE_SESSION_ID through the shell.env hook — the name
 * scripts/lib/agent-session.sh reads, so `tmux-apex.sh init` run by an
 * opencode manager records which conversation it belongs to.
 */

import { execFile } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

function resolveScript(name) {
	const candidates = [];
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

const envFor = (sessionId) =>
	sessionId ? { ...process.env, DELTA_AGENT_SESSION_ID: sessionId } : process.env;

function tmuxStatus(action, sessionId) {
	if (!process.env.TMUX) return;
	execFile(STATUS, [action], { env: envFor(sessionId) }, () => {}).stdin?.end();
}

// Pending pings for a manager, or "" — never throws, never takes long.
function pending(point, sessionId) {
	if (!process.env.TMUX) return Promise.resolve("");
	return new Promise((resolve) => {
		const child = execFile(NOTIFY, [point], { env: envFor(sessionId), timeout: 10_000 }, (_err, stdout) =>
			resolve((stdout ?? "").toString().trim()),
		);
		// Nothing to send: close stdin so no hook script waits on it.
		child.stdin?.end();
	});
}

export const TmuxDeltaStatus = async () => {
	// Consumed pings wait here, per conversation, for its next model request.
	const carried = new Map();
	const carry = (id, text) => {
		if (!id || !text) return;
		carried.set(id, [carried.get(id), text].filter(Boolean).join("\n"));
	};

	return {
		"shell.env": async (input, output) => {
			if (input?.sessionID) output.env.OPENCODE_SESSION_ID = input.sessionID;
		},
		"chat.message": async (input) => {
			carry(input?.sessionID, await pending("prompt", input?.sessionID));
		},
		"experimental.chat.system.transform": async (input, output) => {
			const id = input?.sessionID;
			if (!id) return; // title generation and other side calls
			carry(id, await pending("poll", id));
			const text = carried.get(id);
			if (!text) return;
			carried.delete(id);
			output.system.push(text);
		},
		"tool.execute.before": async (input) => {
			tmuxStatus("set", input?.sessionID);
		},
		event: async ({ event }) => {
			const props = event?.properties ?? {};
			const sessionId = props.sessionID ?? props.info?.id;
			switch (event?.type) {
				case "session.created":
					carry(sessionId, await pending("session-start", sessionId));
					break;
				case "permission.asked":
					tmuxStatus("notify", sessionId);
					break;
				case "permission.replied":
					tmuxStatus("set", sessionId);
					break;
				case "session.idle":
				case "session.error":
					tmuxStatus("clear", sessionId);
					break;
			}
		},
	};
};
