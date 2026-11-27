# Spike: delivering messages into an open opencode TUI (issue #80)

**Version tested:** opencode 1.19.6 (`opencode --version`), macOS, real interactive TUI inside tmux (private socket `tmux -L spike`, 120x35 pane, output read with `tmux capture-pane -p`).

**Model backend.** The free `opencode/*` models answered `Free usage exceeded` and the only `OPENAI_API_KEY` was rejected, so the agent was a ~40-line mock OpenAI-compatible server (streaming `chat/completions`, `SLOW` in the prompt = 20 s delay, `TOOL` = emit a `bash` tool call), wired in with `OPENCODE_CONFIG` (`@ai-sdk/openai-compatible`, `permission.bash = ask`). The real TUI, server, session store, event bus and plugin loader are all genuine opencode; only the LLM is fake. A real model changes the turn length, not the delivery behaviour. Nothing here ran against a real model.

## Answers

### 1. Can an external process post into the session the TUI is showing?

**Yes, but only if the TUI has an HTTP server, and a plain `opencode` has none.**

```
$ tmux -L spike new-session -d -s a "opencode"                 # plain TUI
$ lsof -nP -a -p <pid of a> -iTCP -sTCP:LISTEN                  # → nothing
$ tmux -L spike new-session -d -s b "opencode --port 4400"
$ lsof -nP -iTCP -sTCP:LISTEN | grep opencode
opencode  93946 …  TCP 127.0.0.1:4400 (LISTEN)
```

Two ways to get a server (both tested):

- `opencode --port N` — the TUI itself serves the full API on `127.0.0.1:N` (`--hostname` to change).
- `opencode serve --port N` plus `opencode attach http://127.0.0.1:N` in the pane. The pane is then a thin client and the agent lives in the `serve` process.

The API is documented at `GET /doc` (OpenAPI). Relevant routes: `POST /session/{id}/prompt_async`, `POST /session/{id}/message`, `GET /session`, `GET /session/status`, `GET /event`, `GET /permission`, `POST /permission/{id}/reply`.

Finding the session: the session row is created on the first prompt, not when the TUI starts (before it, `GET /session` only lists older sessions). `GET /session` returns `directory` and `time.updated`, same as the sqlite lookup in `_opencode_session_for`. There is **no endpoint that says which session the TUI is currently displaying** (`GET /api/session/active` returned `{"data":{}}` with a session open). If the human switches sessions in the TUI, "most recently updated in this directory" can be wrong.

### 2. Does the open TUI redraw?

**Yes, via the server; no, via `opencode run -s`.** After `POST /session/$S/prompt_async` to `:4400`:

```
  ┃  external msg via prompt_async
  ┃
     MOCKREPLY to: external msg via prompt_async
     ▣  Build · mock · 16ms
```

Same on the `serve` + `attach` pane. The current apex path does not:

```
$ opencode run -s $S "via run -s NOATTACH SLOW"     # separate process, same sqlite db
$ tmux capture-pane -p -t b | grep -c NOATTACH
0
```

The reply was stored (the session has it) but the TUI never showed it. `opencode run --attach http://127.0.0.1:4400 -s $S "…"` does redraw, because it goes through the TUI's server.

### 3. Does the call return when queued, or after the turn?

| Call | Returns | Measured |
|---|---|---|
| `POST /session/{id}/prompt_async` | `204` once queued | 25–40 ms, with a 20 s turn pending |
| `POST /session/{id}/message` | `200` + the assistant message, after the turn | 20.1 s for a `SLOW` turn |
| `opencode run -s ID -c TEXT` (current apex path) | after the turn | 20.9 s for a `SLOW` turn |
| `opencode run --attach URL -s ID TEXT` | after the turn | after the turn (0.38 s for a fast turn; not timed with `SLOW`) |

So the guess in `_send_native` was right: `run` blocks for the whole turn (which is why it is backgrounded), and `prompt_async` is the queue-and-return call.

### 4. Message sent while the agent is busy

**Queued, in order, no interrupt.** Sent `msgA SLOW`, then 3 s later `msgB while busy`:

```
POST prompt_async msgA → 204       GET /session/status → {"ses_…":{"type":"busy"}}
POST prompt_async msgB → 204 (25 ms)
```

The TUI showed `msgB while busy` with a `QUEUED` badge under the running turn. The mock saw the model requests at `14:32:39 msgA SLOW`, then `14:32:59 msgB while busy` — B only started after A's 20 s turn finished, and both got their own reply. Interrupting is a separate call (`POST /session/{id}/abort`), so a plain delivery never does it.

### 5. Can a plugin inject into its own session in-process?

**Yes, with no server and no `--port`.** Plugins are loaded in the TUI process (global `~/.config/opencode/plugin/*.js`, `.opencode/plugin/`, or `plugin: [...]` in config; `--pure` disables them). The plugin factory receives (logged from a probe plugin):

```
keys: client, project, worktree, directory, experimental_workspace, serverUrl, $
client keys: _client, global, project, pty, config, tool, instance, path, vcs, session, command, provider, find, file, app, mcp, lsp, formatter, tui, auth, event  (the opencode SDK client)
```

`serverUrl` reads `http://localhost:4096/` but nothing listens there in a plain TUI (`lsof` showed no listener): `client` talks to the in-process server directly. Hooks used: `chat.message` (gives `input.sessionID`), `event` (every bus event, incl. `session.created`), plus the ones `extensions/opencode/tmux-status.js` already uses.

Prototype `docs/opencode-delivery-spike-plugin.js` (not wired into anything): `fs.watch`es `$DELTA_INBOX`, then calls

```js
client.session.promptAsync({ path: { id: sessionID }, body: { parts: [{ type: "text", text }] } })
```

Run in a plain `opencode` TUI (no `--port`):

```
$ echo "hello from the inbox file" >> /tmp/inbox.txt
  ┃  hello from the inbox file
     MOCKREPLY to: hello from the inbox file
     ▣  Build · mock · 346ms
$ wc -c /tmp/inbox.txt     → 0
```

The TUI rendered the message and the reply, and the mock confirmed the model request. This is the opencode equivalent of `pi.sendMessage`. Not tested: the plugin delivering while a turn is busy (it uses the same `prompt_async`, so it should queue as in Q4), and a plugin in a TUI where the human has switched sessions (the prototype just uses the last session it saw).

### 6. Event stream

`GET /event` is SSE (`data: {"id","type","properties"}`, first event `server.connected`, `server.heartbeat` every few seconds). `GET /global/event` is the cross-project version. Observed types: `session.created/updated/status/idle/diff`, `message.updated`, `message.part.updated/delta`, `permission.asked`, `permission.replied`, `server.heartbeat`.

- **Turn start/end:** `session.status` with `status.type` `busy` → `idle` (also a legacy `session.idle`). A provider failure shows as `{"type":"retry", "message": …}` (seen with the exhausted free tier). `GET /session/status` is the polling form: `{"<id>":{"type":"busy"}}` while working, `{}` when idle.
- **Waiting on a permission prompt:** `permission.asked` carries the request (`id`, `sessionID`, `permission:"bash"`, `patterns`, `metadata.command`); `permission.replied` ends it. `GET /permission` lists pending ones, so state can be recovered after a missed event. A `bash` call with `permission.bash = ask` produced the TUI's `△ Permission required` dialog, and `POST /permission/{id}/reply {"reply":"once"}` answered it and the turn finished (the TUI dialog closed, the reply rendered). `GET /question` and `question.*` routes exist for agent questions (not exercised).
- The same events reach plugins through the `event` hook; that is how `extensions/opencode/tmux-status.js` already maps `permission.asked`, `session.idle` and `session.error` to status, without any server.

## Recommendation

**Deliver through the plugin, not `opencode run -s`.**

Why the plugin over `--port` + HTTP:

- It needs no change to how the member is launched and no port to allocate, record, or secure. `opencode --port` serves an **unauthenticated** API on localhost (`Warning: OPENCODE_SERVER_PASSWORD is not set; server is unsecured`), so any local process could inject prompts or answer permission prompts.
- It already knows its session id (`chat.message`, `event`), which removes the `_opencode_session_for` guess ("latest session in this directory") and its wrong-session risk when the human switches sessions.
- `extensions/opencode/tmux-status.js` is already installed for every opencode member, already runs apex hooks, and already forwards events to `agent-tmux-status.sh`.
- It is the same shape as the pi extension, so the apex side stays "write to a per-member inbox".

What replacing `opencode run -s` takes (not done here; this spike changes no delivery path):

1. In `extensions/opencode/tmux-status.js`, add the inbox watcher from the prototype: a per-member inbox file/dir (path from an env var or derived from the tmux session), and `client.session.promptAsync` for the session the plugin tracks. Use a rename-then-read or lock rather than the prototype's read-then-truncate, so an append between read and truncate is not lost. Skip subagent sessions (`parentID`) and handle a human switching sessions (track the last session with a user `chat.message`).
2. In `_send_native` (`scripts/tmux-apex.sh`, `opencode)` case): append `$text` to that inbox and return 0, instead of backgrounding `opencode run`. Return 1 (fall back to send-keys) if the member's plugin is not installed, which can be checked with the existing `install-agent-hooks.sh` link test near `tmux-apex.sh:5671`.
3. Update the `_send_native` comment and `tests/apex-delivery.test.sh` (the `opencode run -s` stub) to the inbox write.
4. Optional, later: for turn/permission state read `GET /event` or `GET /session/status` only if the pane is started with `--port`; otherwise keep using the plugin's existing `event` hook → `agent-tmux-status.sh`, which already covers busy/idle/blocked.

Fallback if the plugin route proves unreliable: launch members as `opencode --port <unique> ` with `OPENCODE_SERVER_PASSWORD` set, record the port in the member record, and `curl -u opencode:$PW -X POST …/session/$ID/prompt_async`. It works (Q1–Q4) and is the only option for a non-plugin sender, but costs port bookkeeping and the session-selection problem in Q1.

## Not checked

- Any real model; the mock stands in for turn length and tool calls.
- Plugin delivery during a busy turn; session switching in the TUI; two TUIs in one directory.
- Why `opencode models` hung (no output) without `--pure` in `/tmp/ocspike` on this machine, but worked with `--pure`. The user's `tmux-status.js` plugin and the global config were loaded in the hanging case; cause not investigated.
- opencode versions other than 1.19.6.
