#!/usr/bin/env zsh
# Tests for in-process apex delivery in the pi extension (issue #78):
# extensions/pi/tmux-status.ts, driven by a fake pi under node.
#
# The extension finds its scripts at ../../scripts relative to itself, so it is
# copied into a temp tree next to stub scripts; tmux is a stub on PATH. The
# fake pi records every sendMessage, and the fake ctx lets each case set
# whether the agent is idle and what is in the editor.
#
# Needs node >= 22.6 (type stripping). Run: tests/pi-extension.test.sh

set -u
emulate -L zsh
setopt err_return

ROOT="${0:A:h:h}"
T=$(mktemp -d "${TMPDIR:-/tmp}/pi-extension-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/extensions/pi" "$T/scripts" "$T/bin"
cp "$ROOT/extensions/pi/tmux-status.ts" "$T/extensions/pi/"
# A package.json-free .ts file is ambiguous to node; say it is ESM.
print '{"type":"module"}' > "$T/package.json"

# tmux: identity from $IDENT ("session<TAB>pane<TAB>role<TAB>manager<TAB>wake"),
# everything else logged.
cat > "$T/bin/tmux" <<'STUB'
#!/usr/bin/env zsh
case "$1" in
	display-message) print -r -- "$IDENT" ;;
	*) print -r -- "$*" >> "$LOG/tmux" ;;
esac
STUB
# pending: prints $LOG/pending (unconsumed). check: prints and empties the inbox stub.
cat > "$T/scripts/tmux-apex.sh" <<'STUB'
#!/usr/bin/env zsh
print -r -- "$*" >> "$LOG/apex"
case "$1" in
	pending) cat "$LOG/pending" 2>/dev/null ;;
	check)   cat "$LOG/inbox" 2>/dev/null; : > "$LOG/inbox" ;;
esac
STUB
# poll consumes what it prints, like the real one.
cat > "$T/scripts/apex-manager-notify.sh" <<'STUB'
#!/usr/bin/env zsh
print -r -- "$*" >> "$LOG/notify"
[[ -e $LOG/slow ]] && sleep 1
if [[ ( $1 == poll || $1 == prompt ) && -s $LOG/pending ]]; then
	print "[apex] pending events since you last checked:"; cat "$LOG/pending"; : > "$LOG/pending"
fi
STUB
print '#!/bin/sh' > "$T/scripts/agent-tmux-status.sh"
chmod +x "$T/bin/tmux" "$T/scripts/"*.sh

cat > "$T/run.mjs" <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, rmSync, writeFileSync, readFileSync, utimesSync } from "node:fs";
import { join } from "node:path";

const T = process.env.T, LOG = process.env.LOG;
const ext = await import(join(T, "extensions/pi/tmux-status.ts"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Positive outcomes are awaited, not slept for: a tick spawns processes, and a
// loaded CI runner can take longer than any fixed slack.
const until = async (pred, ms = 6000) => { for (const end = Date.now() + ms; !pred() && Date.now() < end; ) await sleep(50); };
let pass = 0, fail = 0;
const ok = (name, fn) => { try { fn(); console.log(`  ok   ${name}`); pass++; } catch (e) { console.error(`  FAIL ${name}\n       ${e.message}`); fail++; } };
const read = (f) => { try { return readFileSync(join(LOG, f), "utf8"); } catch { return ""; } };
const members = join(process.env.XDG_CACHE_HOME, "tmux-delta/apex/mgr/members");
mkdirSync(members, { recursive: true });
let bump = 1;
const touchMembers = () => { bump++; utimesSync(members, bump, bump); };

// start(ident) → a live extension instance with a controllable ctx.
async function start(ident) {
	rmSync(LOG, { recursive: true, force: true });
	mkdirSync(LOG, { recursive: true });
	process.env.IDENT = ident;
	const handlers = {}, sent = [], statuses = [];
	const state = { idle: true, editor: "", stale: false };
	const pi = {
		on: (ev, fn) => { handlers[ev] = fn; },
		// A `pi` used after its session was replaced throws (pi docs).
		sendMessage: (message, options) => {
			if (state.stale) throw new Error("stale pi");
			sent.push({ message, options });
		},
	};
	const ctx = {
		sessionManager: { getSessionId: () => "sess-1" },
		isIdle: () => state.idle,
		ui: { getEditorText: () => state.editor, setStatus: (_k, v) => statuses.push(v) },
	};
	ext.default(pi);
	await handlers.session_start({}, ctx);
	return { handlers, sent, statuses, state, ctx,
		stop: async () => { await handlers.session_shutdown({}, ctx); state.stale = true; } };
}
const PING = "[apex] session=w:%5 role=worker status=idle — branch=b.\n";
const TICK = 1400;

// ── pure decision ──
console.log("mayWake");
ok("default wake mode is polite", () => assert.equal(ext.wakeMode(""), "polite"));
ok("unknown wake mode is polite", () => assert.equal(ext.wakeMode("loud"), "polite"));
ok("quiet never wakes", () => assert.equal(ext.mayWake("quiet", true, ""), false));
ok("polite waits for an empty editor", () => assert.equal(ext.mayWake("polite", true, "draft"), false));
ok("polite waits for idle", () => assert.equal(ext.mayWake("polite", false, ""), false));
ok("polite wakes idle with an empty editor", () => assert.equal(ext.mayWake("polite", true, ""), true));
ok("eager wakes over a draft", () => assert.equal(ext.mayWake("eager", true, "draft"), true));
ok("eager waits for idle", () => assert.equal(ext.mayWake("eager", false, ""), false));

// ── advertisement ──
console.log("advertisement");
{
	const x = await start("mgr\t%1\tmanager\t\t");
	ok("session_start advertises the pane", () =>
		assert.match(read("tmux"), new RegExp(`set-option -p -t %1 @apex_native_delivery ${process.pid}`)));
	await x.stop();
	ok("session_shutdown withdraws it", () => assert.match(read("tmux"), /set-option -p -u -t %1 @apex_native_delivery/));
}

// ── manager, polite (the default) ──
console.log("manager: polite");
{
	const x = await start("mgr\t%1\tmanager\t\t");
	x.state.idle = false;
	writeFileSync(join(LOG, "pending"), PING); touchMembers();
	await until(() => x.statuses.at(-1) === "apex: 1 pending");
	await sleep(TICK);
	ok("busy: no turn is started", () => assert.equal(x.sent.length, 0));
	ok("busy: nothing is consumed", () => assert.doesNotMatch(read("notify"), /poll/));
	ok("the pending count is shown", () => assert.equal(x.statuses.at(-1), "apex: 1 pending"));
	x.state.idle = true; x.state.editor = "half a thought";
	await sleep(TICK);
	ok("idle with a draft: no turn is started", () => assert.equal(x.sent.length, 0));
	x.state.editor = "";
	await until(() => x.sent.length > 0);
	ok("idle and empty: delivered once", () => assert.equal(x.sent.length, 1));
	ok("…starting a turn", () => assert.deepEqual(x.sent[0].options, { deliverAs: "followUp", triggerTurn: true }));
	ok("…with the pending text", () => assert.match(x.sent[0].message.content, /session=w:%5/));
	ok("…through the consuming path", () => assert.match(read("notify"), /^poll$/m));
	ok("…and the count is cleared", () => assert.equal(x.statuses.at(-1), undefined));
	await sleep(TICK);
	ok("not delivered twice", () => assert.equal(x.sent.length, 1));
	await x.stop();
}

// ── manager, quiet ──
console.log("manager: quiet");
{
	const x = await start("mgr\t%1\tmanager\t\tquiet");
	writeFileSync(join(LOG, "pending"), PING); touchMembers();
	await until(() => x.statuses.at(-1) === "apex: 1 pending");
	await sleep(TICK);
	ok("idle and empty: still no turn", () => assert.equal(x.sent.length, 0));
	ok("nothing is consumed", () => assert.doesNotMatch(read("notify"), /poll/));
	ok("the pending count is shown", () => assert.equal(x.statuses.at(-1), "apex: 1 pending"));
	const r = await x.handlers.before_agent_start({}, x.ctx);
	ok("delivered with the next human message", () => assert.match(r.message.content, /session=w:%5/));
	await x.stop();
}

// ── manager, eager ──
console.log("manager: eager");
{
	const x = await start("mgr\t%1\tmanager\t\teager");
	x.state.idle = false; x.state.editor = "draft";
	writeFileSync(join(LOG, "pending"), PING); touchMembers();
	await until(() => x.statuses.at(-1) === "apex: 1 pending");
	await sleep(TICK);
	ok("busy: no turn is started", () => assert.equal(x.sent.length, 0));
	x.state.idle = true;
	await until(() => x.sent.length > 0);
	ok("idle: a turn is started, draft or not", () =>
		assert.deepEqual(x.sent.map((s) => s.options), [{ deliverAs: "followUp", triggerTurn: true }]));
	await x.stop();
}

// ── session replaced mid-delivery ──
console.log("session replaced mid-delivery");
{
	const x = await start("mgr\t%1\tmanager\t\t");
	writeFileSync(join(LOG, "slow"), "");
	writeFileSync(join(LOG, "pending"), PING); touchMembers();
	await until(() => /^poll$/m.test(read("notify"))); // a slow `poll` is in flight
	ok("poll is in flight", () => assert.match(read("notify"), /^poll$/m));
	await x.stop();
	await sleep(1500);
	ok("nothing is sent into the replaced session", () => assert.equal(x.sent.length, 0));
	ok("…and pi survives it", () => assert.ok(true));
}
{
	const x = await start("mgr\t%1\tmanager\t\t");
	x.state.stale = true;
	writeFileSync(join(LOG, "pending"), PING); touchMembers();
	await until(() => /^poll$/m.test(read("notify")));
	await sleep(500);
	ok("a throwing sendMessage does not crash pi", () => assert.ok(true));
	await x.handlers.session_shutdown({}, x.ctx);
}

// ── member inbox ──
console.log("member inbox");
{
	const inbox = join(process.env.XDG_CACHE_HOME, "tmux-delta/apex/mgr/inbox");
	mkdirSync(inbox, { recursive: true });
	const x = await start("w\t%5\tworker\tmgr\t");
	x.state.idle = false;
	writeFileSync(join(LOG, "inbox"),
		JSON.stringify({ at: 1, from: "mgr", text: "[apex from:mgr] one" }) + "\n" +
		JSON.stringify({ at: 2, from: "mgr", text: "[apex from:mgr] two" }) + "\n");
	writeFileSync(join(inbox, "w:%5.jsonl"), "x\n");
	await until(() => x.sent.length >= 2);
	ok("reads its own inbox through check", () => assert.match(read("apex"), /^check --json w:%5$/m));
	ok("injects each message, oldest first", () =>
		assert.deepEqual(x.sent.map((s) => s.message.content), ["[apex from:mgr] one", "[apex from:mgr] two"]));
	ok("as queue-only follow-ups", () =>
		assert.ok(x.sent.every((s) => s.options.deliverAs === "followUp" && s.options.triggerTurn === true)));
	await sleep(TICK);
	ok("an unchanged inbox is not re-read", () => assert.equal(read("apex").match(/check/g).length, 1));
	ok("a member never pulls manager pings", () => assert.equal(read("notify").match(/poll/g), null));
	await x.stop();
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
JS

export T LOG="$T/log" XDG_CACHE_HOME="$T/cache" TMUX=fake TMUX_PANE=%1
export PATH="$T/bin:$PATH"
node --experimental-strip-types --no-warnings "$T/run.mjs"
