# Spike: Claude Code channels as apex delivery (issue #79)

**Status: partial.** The prototype works and Claude Code accepts it as a
channel server. But the only login on the test machine is a **Claude Enterprise**
org without `channelsEnabled`, so Claude Code drops every channel event. That
means questions 1, 2, 3 and 6 could not be watched live, and question 5 has only
the Enterprise answer. Where this doc answers from reading the Claude Code
bundle instead of watching it run, it says **(code-read)**. Treat those answers
as leads to check, not as findings.

- **Version tested:** Claude Code `2.1.332` (Homebrew cask `claude-code@latest`), macOS arm64, tmux.
- **Login tested:** `claude auth status` → `authMethod: claude.ai`, `subscriptionType: enterprise`.
  No Pro/Max login and no Console API key were available.

## Prototype

`spikes/claude-channels/apex-channel.mjs` is a stdio MCP server named `apex`.
It has no dependencies (newline-delimited JSON-RPC, no SDK). It tails a file and
pushes each new complete line as `notifications/claude/channel` with
`meta: { seq }`. It touches none of apex's delivery code.

Run it:

```sh
mkdir -p /tmp/apexch && cd /tmp/apexch
cat > .mcp.json <<EOF
{ "mcpServers": { "apex": { "command": "node",
  "args": ["$REPO/spikes/claude-channels/apex-channel.mjs"] } } }
EOF
claude --dangerously-load-development-channels server:apex
# in another shell (relative to the cwd claude started in):
echo "Reply with the single word PONG." >> /tmp/apexch/apex-channel.in
tail -f /tmp/apexch/apex-channel.log     # every JSON-RPC message in and every event out
```

`APEX_CHANNEL_FILE` and `APEX_CHANNEL_LOG` override the two paths. You can check
the protocol without Claude by piping an `initialize` request and an
`notifications/initialized` notification into `node apex-channel.mjs`, then
appending to the file.

### Handshake evidence (live)

`apex-channel.log`:

```
<- {"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",...
<- {"method":"initialize","params":{"protocolVersion":"2025-11-25",...
<- {"jsonrpc":"2.0","method":"notifications/initialized"}
watching /private/tmp/apexch/apex-channel.in from offset 0
-> event seq=1: Reply with PONG
```

The debug log (`claude --debug`, `~/.claude/debug/<session>.txt`) shows
`Connection established ... "protocolEra":"legacy"`.

**A trap for the real build.** Claude Code first sends a `server/discover` probe
at revision `2026-07-28`. The prototype answers "method not found", so the
client falls back to `initialize` and the connection is `legacy`. The channel
gate (code-read, `wFn`) skips any connection with `protocolEra === "modern"`
because that revision has "no unsolicited notification path". So a server built
on an MCP SDK that negotiates 2026-07-28 would connect fine and still never
register as a channel. The docs warn about this too.

## Answers

### 1. Does an event start a turn in an idle session?

**Not observed.** Under Enterprise policy the event is dropped before it is
queued. **(code-read)** A registered channel's handler calls
`enqueue({mode:"prompt", priority:"next", isMeta:true, origin:{kind:"channel"}, skipSlashCommands:true})`,
the same command queue that a prompt typed while Claude is busy goes into. An idle
session drains that queue, so I expect the event to start a turn by itself.
This is the main thing to confirm on a login where channels work.

### 2. Unsent human text in the input box?

**Not observed.** **(code-read)** The event goes into the command queue, not
the prompt input, so I expect the draft to be left alone: not overwritten and
not submitted. That is the whole advantage over typing keys into the pane. It
still needs a live check.

### 3. Busy: delivered mid-turn or after the turn?

**Not observed.** The docs say events that arrive while Claude is busy "are
delivered together on the next turn". **(code-read)** The event is queued at
`priority:"next"`, and the queue code has mid-turn folding logic for
non-`now` items (`isMidTurnFoldSuspended`, `isFoldInFlight`). So it may be
folded in at a tool boundary, like a message typed while Claude is busy. I could
not tell which from the bundle.

### 4. Can the development-channel consent prompt be passed unattended?

**(code-read, plus live for the Enterprise case)** There is no settings key for
it. The onboarding step in 2.1.332 is roughly:

```js
if (isChannelsOffForSession() || provider !== "firstParty" || isChannelsPolicyBlocked(policySettings))
  return registerDevChannels(), null          // dialog skipped
return <DevChannelsDialog onAccept={...}/>    // "WARNING: Loading development channels"
```

The dialog is skipped only when channels cannot work anyway. That is why the
Enterprise run showed no warning dialog, only the notice
`--dangerously-load-development-channels blocked by org policy (server:apex) · Inbound messages will be silently dropped`.
`skipDangerousModePermissionPrompt` and `bypassPermissions` control a different
dialog (`BypassPermissionsModeDialog`, which runs just before it) and do not
skip this one. The flag is read only when the session is interactive
(`if(!print)`), so `-p` ignores it, as the docs say.

So a spawned worker always needs a keypress. Apex could send that key with
`tmux send-keys` once the dialog is on screen, which is the same kind of TUI
scraping channels were meant to replace. The other dialogs a worker can hit
first can be handled up front: folder trust (pre-trust the worktree) and "New
MCP server found in this project" (`enableAllProjectMcpServers` or
`enabledMcpjsonServers`).

### 5. Pro/Max subscription and API-key login?

- **Enterprise (claude.ai) login: does not work** unless an org Owner sets
  `channelsEnabled: true` (live: debug log
  `MCP server "apex": Channel notifications skipped: channels not enabled by org policy`).
  The development flag does not get around this. **(code-read)** For claude.ai
  logins, the block applies to `team` and `enterprise` tiers when
  `channelsEnabled !== true`.
- **Pro/Max: not tested.** **(code-read)** The policy check passes for non-Team
  and non-Enterprise claude.ai tiers. A server-side feature gate
  (`tengu_harbor` / `allow_channels`) still applies.
- **Console API key: not tested.** Docs and **(code-read)**: allowed unless the
  org deploys managed settings. In that case `channelsEnabled` must be true.

The issue assumes a Pro/Max login. On the machine this spike ran on, the
Claude Code login is Enterprise, so that assumption does not hold here.

### 6. How the event shows up in the TUI and transcript, and can apex read it back?

**Not observed.** No turn ran, so the session wrote no transcript JSONL. Docs:
the TUI shows `← apex: <content>`, and the model sees
`<channel source="apex" seq="1">…</channel>`. **(code-read)** The queued command
carries `isMeta:true` and `origin:{kind:"channel",server:"apex"}`, so it should
land in the JSONL as a meta user message whose content has the `<channel …>`
tag. If so, apex could confirm delivery by grepping the session JSONL for
`source="apex" seq="N"`. Claude Code sends nothing back to the server (the
`await` only means the bytes were written), so the transcript is the only
read-back short of a reply tool.

## Recommendation

**Neither, for now.**

- On this setup channels do not work at all. The login is Enterprise and
  `channelsEnabled` is unset, and Claude Code drops events without any error
  back to the server. Apex would need to spot that from the startup notice or
  the debug log and fall back to typing into the pane anyway.
- Even where channels are allowed, every spawned worker hits a consent dialog
  that no setting or flag can skip. Unattended spawning would need
  `send-keys`, which is the same TUI dependency this spike was meant to remove.
- The protocol-era trap means a server built on a current SDK could stop
  delivering without any warning.

Worth trying again if someone with a Pro/Max or API-key login can run the
commands above and confirm 1–3 and 6. If an event does start a turn in an idle
session without touching the draft, then **the manager only** is a reasonable
use. The manager is launched once by a human, who can press the consent key,
and it is where typing into the input most often clobbers the human's draft.
For **workers**, headless `claude -p --input-format stream-json
--output-format stream-json` remains the better direction. It needs no consent
dialog, no TUI and no allowlist, but it gives up the interactive pane.
