/**
 * PROTOTYPE — spike for issue #80, NOT wired into scripts/ or the installer.
 * Companion to docs/opencode-delivery-spike.md.
 *
 * Shows an opencode plugin injecting a message into its own TUI session
 * in-process: it watches the file $DELTA_INBOX, and whenever the file gains
 * content it sends it to the session the plugin last saw activity in, then
 * truncates the file.
 *
 * Try it (no server flag needed):
 *   DELTA_INBOX=/tmp/inbox.txt opencode   # with this file in .opencode/plugin/
 *   echo "hello from outside" >> /tmp/inbox.txt
 *
 * shortcuts: "the session" is just the last one seen in a chat.message or
 * session.created event (subagent sessions skipped) — good enough to prove
 * delivery, not to pick the right session when the human switches sessions.
 */
import { watch, readFileSync, writeFileSync, existsSync } from "node:fs";

export const InboxSpike = async ({ client }) => {
	const inbox = process.env.DELTA_INBOX;
	let sessionID = null;

	const flush = async () => {
		if (!sessionID || !existsSync(inbox)) return;
		const text = readFileSync(inbox, "utf8").trim();
		if (!text) return;
		writeFileSync(inbox, ""); // truncate before sending so a re-fire cannot double-deliver
		// promptAsync = POST /session/:id/prompt_async — returns once queued (204).
		await client.session.promptAsync({
			path: { id: sessionID },
			body: { parts: [{ type: "text", text }] },
		});
	};

	if (inbox) {
		if (!existsSync(inbox)) writeFileSync(inbox, "");
		watch(inbox, () => flush().catch(() => {}));
	}

	return {
		"chat.message": async (input) => {
			sessionID = input?.sessionID ?? sessionID;
			flush().catch(() => {}); // anything that arrived before we knew the session
		},
		event: async ({ event }) => {
			const info = event?.properties?.info;
			if (event?.type === "session.created" && !info?.parentID) sessionID = info.id;
		},
	};
};
