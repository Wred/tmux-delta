# tmux-delta

A tmux plugin providing a unified session/worktree/issue/PR picker and a dynamic dual-status bar with git, GitHub PR, and Kubernetes context awareness.

## Features

- **Picker** (`C-g`): tabbed fzf UI — Sessions, Directories, Worktrees, Issues, PRs, Ready-for-review PRs
- **Session pills**: top status bar with per-session PR status icons and coding-agent activity indicator
- **Git bar**: bottom status bar with repo name, branch (with git host icon), window list, and kube context
- **Git worktree helpers**: `gwta`, `gwtrm`, `gwtl`, `gwtp` shell functions
- **Dev layout**: auto-opens nvim + coding agent split on new sessions
- **PR status daemon**: background refresh of CI/review state every 60 s
- **Apex mode**: one agent session plans work, spawns worker agents in their own worktrees, and tracks who is blocked and what is ready to merge

## Requirements

**Required:**
- tmux ≥ 3.3
- fzf
- git
- zsh (picker and gwt scripts use zsh-specific syntax)

**Soft (features degrade gracefully when absent):**
- [catppuccin/tmux](https://github.com/catppuccin/tmux) v2 — when present, tmux-delta auto-detects it (any load order, any flavor) and matches its active palette exactly; when absent, tmux-delta uses its own built-in palette (Catppuccin Mocha-equivalent by default, fully configurable — see Configuration below)
- `gh` — GitHub CLI (issues, PRs, browser open)
- `jq` — PR/issue formatting
- `kubectl` — Kubernetes context pill
- `direnv` — per-directory KUBECONFIG support (kube pill falls back to global config)
- `nvim` — dev layout left pane
- a coding agent — `claude`, `pi`, `codex`, or `opencode` (see Coding agent below; others work via the fallback adapter)
- Nerd Fonts — icons in status bar

## Installation

### 1. TPM (recommended)

```tmux
set -g @plugin 'Wred/tmux-delta'
```

**Optional:** if you use [catppuccin/tmux](https://github.com/catppuccin/tmux),
load it anywhere in your `tmux.conf` — order no longer matters, tmux-delta
detects it dynamically at render time:

```tmux
run '~/.config/tmux/plugins/tmux/catppuccin.tmux'
run '~/.tmux/plugins/tpm/tpm'
```

### 2. Shell PATH (required for CLI use and send-keys calls)

Add to your `.zshrc`:

```zsh
export PATH="$HOME/.tmux/plugins/tmux-delta/scripts:$PATH"
[[ -f "$HOME/.tmux/plugins/tmux-delta/scripts/gwt.zsh" ]] && \
  source "$HOME/.tmux/plugins/tmux-delta/scripts/gwt.zsh"
```

### 3. Coding-agent hooks (optional — activity pills and apex-mode reporting)

These hooks live outside this repo — in `~/.claude/settings.json`, in each
agent's own extension directory, in `~/.codex/config.toml` — so cloning or
TPM-installing tmux-delta never installs them by itself. `tmux-delta.tmux`
closes that gap automatically: every time tmux (re)loads the plugin it
backgrounds `scripts/install-agent-hooks.sh`, which wires whichever of
Claude Code / pi / opencode / codex it finds installed, using absolute paths
resolved from wherever the repo actually is (TPM's `~/.tmux/plugins/tmux-delta`,
a manual clone elsewhere, doesn't matter). It's upsert-by-marker, so it's a
no-op once wired and self-heals a hook left pointing at a moved clone or a
stale verb; it never touches hook entries it doesn't own (e.g. other
`PreToolUse` hooks already in your `settings.json`). Its output goes to
`~/.cache/tmux-delta/install-agent-hooks.log`, not the terminal, since a
backgrounded `run-shell` has nothing to print to.

Run it by hand if you want to see what it would do before the next reload
does it for you:

```zsh
~/.tmux/plugins/tmux-delta/scripts/install-agent-hooks.sh --dry-run
```

`scripts/agent-tmux-status.sh` drives the per-session activity indicators and,
in apex mode, forwards worker transitions to the manager. It takes one of three
verbs:

| Verb | Meaning | Pill |
|------|---------|------|
| `set` | agent is working | peach robot |
| `notify` | agent is blocked on you | pill turns orange |
| `clear` | agent is idle | reset |

Delivery into the *manager's own* pane is pull-based, not pushed: `set`/
`notify`/`clear` only ever write durable state (`~/.cache/tmux-delta/apex/`),
debounced through `APEX_QUIET_SECS` for `clear`. `scripts/apex-manager-notify.sh`,
wired to four of the manager's own hooks, is what actually surfaces pending
events — it prepends them to the manager's next turn, so nothing ever gets typed
into a live pane out from under you. It takes the delivery point as a required
argument, one per event, because each event needs a different output channel:

| Verb | Hook | Delivers |
|------|------|----------|
| `prompt` | `UserPromptSubmit` | before every human message |
| `session-start` | `SessionStart` | catch-up on startup/resume |
| `post-tools` | `PostToolBatch` | mid-turn, before the next model call |
| `stop` | `Stop` | at the end of an assistant turn |

The last two are what make an *unattended* manager work: `UserPromptSubmit` only
fires on a human message, so without them a manager spawning and polling on its
own goes many turns with no delivery point at all (see
[How reporting works](#how-reporting-works)).

That script also self-heals `@apex_role`/`@apex_session` after a session
restart (see `tmux-apex.sh relink`), so it needs to run for every session, not
just managers.

The installer wires all of this. What follows is the manual/reference form, for
troubleshooting or hand-editing.

**Claude Code** — `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-delta/scripts/agent-tmux-status.sh set" }] }
    ],
    "Notification": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-delta/scripts/agent-tmux-status.sh notify" }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-delta/scripts/agent-tmux-status.sh clear" }] },
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh stop", "timeout": 10 }] }
    ],
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh prompt", "timeout": 10 }] }
    ],
    "SessionStart": [
      { "matcher": "startup|resume", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh session-start", "timeout": 10 }] }
    ],
    "PostToolBatch": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-delta/scripts/apex-manager-notify.sh post-tools", "timeout": 10 }] }
    ]
  }
}
```

`Stop` carries both scripts — `agent-tmux-status.sh clear` for this session's own
pill and idle record, `apex-manager-notify.sh stop` for pings from members it
manages. A session can be both a manager and somebody's worker.

The argument is required and must match the event: it picks the output channel,
and the channels are not interchangeable (plain stdout only reaches the agent on
`UserPromptSubmit` and `SessionStart`). Wired with the wrong argument, or none,
the script delivers nothing — deliberately, rather than writing to a channel
nobody reads — and `tmux-apex.sh doctor` reports that event as missing. Use a
path that will outlive the moment, too: hooks are global config, so a worktree
path here breaks silently once the worktree is gone. The installer handles both
concerns; `doctor` is how you check whatever is actually on disk.

**pi** — symlink the shipped extension, which wires `agent_start` → `set` and
`agent_settled` → `clear`:

```zsh
ln -s ~/.tmux/plugins/tmux-delta/extensions/pi/tmux-status.ts \
      ~/.pi/agent/extensions/tmux-status.ts
```

It deliberately does not fire `notify`, because pi has no single "blocked" event
— the blocking moments are the confirm prompts your own extensions raise. The
extension exports `tmuxStatus` so you can wrap them:

```ts
import { tmuxStatus } from "./tmux-status.ts";

tmuxStatus("notify");
try { choice = await ctx.ui.select(…); } finally { tmuxStatus("set"); }
```

**opencode** — symlink the shipped plugin:

```zsh
mkdir -p ~/.config/opencode/plugin
ln -s ~/.tmux/plugins/tmux-delta/extensions/opencode/tmux-status.js \
      ~/.config/opencode/plugin/tmux-status.js
```

It maps `tool.execute.before` → `set`, `permission.asked` → `notify`,
`permission.replied` → `set`, and `session.idle`/`session.error` → `clear`, so
opencode reports all three states. If a build does not deliver the permission
events to plugins the mapping quietly degrades to working/idle.

**codex** — `~/.codex/config.toml`:

```toml
notify = ["/home/you/.tmux/plugins/tmux-delta/scripts/agent-tmux-status.sh", "clear"]
```

Codex appends a JSON argument, which the script ignores. This is codex's only
hook and it fires on turn completion, so codex gets the idle ping but neither
the working robot nor the orange pill. *(Untested — written from the codex docs,
not verified against an install.)*

### 4. Apex mode skill (optional)

Symlink the shipped skill so Claude Code can find it:

```zsh
ln -s ~/.tmux/plugins/tmux-delta/skills/delta-apex ~/.claude/skills/delta-apex
```

## Configuration

Set these in `tmux.conf` before loading TPM:

```tmux
# Keybind for the picker popup (default: C-g)
set -g @tmux_delta_picker_key 'C-g'

# Right-side status modules (default: catppuccin date+host if loaded, else #H)
set -g @tmux_delta_modules_right '#{?#{@catppuccin_flavor},#{E:@catppuccin_status_date_time} #{E:@catppuccin_status_host},#[fg=default]#{d:} #H}'

# Color palette (only used when catppuccin/tmux is not loaded)
set -g @tmux_delta_color_green     '#a6e3a1'
set -g @tmux_delta_color_crust     '#11111b'
set -g @tmux_delta_color_fg        '#cdd6f4'
set -g @tmux_delta_color_surface_0 '#313244'
set -g @tmux_delta_color_mauve     '#cba6f7'
set -g @tmux_delta_color_peach     '#fab387'
set -g @tmux_delta_color_pink      '#f5c2e7'
set -g @tmux_delta_color_pr_green  '#a6e3a1'
set -g @tmux_delta_color_pr_red    '#f38ba8'
set -g @tmux_delta_color_pr_peach  '#fab387'
set -g @tmux_delta_color_pr_muted  '#6c7086'
set -g @tmux_delta_color_pr_sky    '#89dceb'

# Segment separators (only used when catppuccin/tmux is not loaded)
set -g @tmux_delta_separator_left  ''
set -g @tmux_delta_separator_right ''
```

### Search directories

The picker's Directories tab uses these environment variables (set in your shell):

```zsh
export TMUX_SESSIONIZER_SEARCH_DIRS="$HOME/work"          # find -maxdepth 2
export TMUX_SESSIONIZER_EXTRA_DIRS="$HOME/.config/tmux/plugins/tmux-delta"  # added verbatim
```

### Coding agent

The dev layout (`tmux-dev-layout.sh`) opens a coding agent on the right pane. Override the command via `.envrc` in your project:

```sh
export CODING_AGENT=claude
```

Agents spell the same concepts differently, so the dev layout emits no flags of
its own. It exports neutral inputs and calls an **adapter** —
`scripts/lib/agents/<command>.sh` — chosen by the agent command's basename.
Adapters ship for `claude`, `pi`, `codex`, and `opencode`; anything else falls
back to the claude adapter. Adding one is a single file defining
`delta_agent_argv()`.

| Neutral input | claude | pi | codex | opencode |
|---|---|---|---|---|
| model | `--model` | `--model` (accepts `provider/id`, `:thinking`) | `--model` | `--model` (wants `provider/model`) |
| prompt | positional | positional | positional | `--prompt` |
| system prompt | `--append-system-prompt` | `--append-system-prompt` | *none* — prepended to the prompt | *none* — injected as `instructions` via `OPENCODE_CONFIG_CONTENT` |
| agent flags | `--permission-mode <token>`, or verbatim if it starts with `-` | verbatim (`--approve`, `--tools …`) | verbatim (`--full-auto`, `--sandbox …`) | verbatim (`--auto`) |
| resume | `--continue` | `--continue` | `resume --last` | `--continue` |

Resume is attempted first and falls back to a fresh session when there is
nothing to resume.

Neither codex nor opencode has an `--append-system-prompt`, so the
managed-worker instructions apex mode adds need a workaround. opencode gets a
real one: `OPENCODE_CONFIG_CONTENT` *merges* into the resolved config rather
than replacing it, so the instructions go in as a genuine `instructions` entry
pointing at a file under `~/.cache/tmux-delta/agent-prompts/`. codex has no
equivalent and falls back to prepending them to the prompt, which is weaker —
the model can be talked out of a user message. In both cases the file is kept
out of the worktree deliberately: an `AGENTS.md` written there would land in the
diff the worker commits.

### Apex mode options

```tmux
# Glyph marking the manager session in its pill (default: robot)
set -g @tmux_delta_apex_icon '󰚩'

# Pane commands tmux-apex.sh is allowed to send-keys into. Allowlist, not
# denylist — a shell pane must never receive a message, it would execute it.
# Both Claude Code and pi present as `node`.
set -g @tmux_delta_apex_agent_cmds 'node bun claude codex gemini pi opencode'
```

`APEX_QUIET_SECS` (env, default `30`) is how long a worker must be idle before
its "turn finished" ping reaches the manager.

### Editor

The dev layout opens `nvim` on the left pane by default. Override the command via `.envrc` in your project:

```sh
export DEV_EDITOR="hunk diff --watch"
```

## Key bindings (picker)

| Key | Action |
|-----|--------|
| `C-g` | Open picker |
| `ctrl-h` / `ctrl-l` | Previous / next tab |
| `ctrl-s` | Sessions tab |
| `ctrl-f` | Directories tab |
| `ctrl-w` | Worktrees tab |
| `ctrl-i` | Issues tab |
| `ctrl-p` | PRs tab |
| `ctrl-r` | Ready-for-review PRs tab |
| `ctrl-a` | Autonomous agent (Issues tab) / review all (Ready tab) |
| `ctrl-o` | Open in browser |
| `ctrl-x` | Delete session / worktree |

## Apex mode

Normally each picker-spawned session is independent, so supervising several
parallel agents means cycling through pills by hand. Apex mode designates one
session as the **manager**: it plans work into GitHub issues, spawns worker
sessions through the same picker machinery, tracks their state, and gets pinged
when one finishes a turn or gets blocked.

There is no MCP server and no daemon. tmux is the registry (per-session
`@apex_*` options), and a small JSON tree under
`${XDG_CACHE_HOME:-~/.cache}/tmux-delta/apex/<manager-session>/` is the durable
state that survives the manager's context being compacted.

Ask your agent to "turn on apex mode" (it loads the `delta-apex` skill), or
drive it yourself:

```zsh
tmux-apex.sh init                    # this session is now the manager
tmux-apex.sh profiles                # list available {agent,model,agent-flags} presets
tmux-apex.sh spawn --issue 42 --profile standard
tmux-apex.sh spawn --issue 43 --profile hard
tmux-apex.sh spawn --issue 44 --agent opencode --model anthropic/claude-sonnet-4-6 --agent-flags '--auto'
tmux-apex.sh spawn --review-pr 17 --profile hard --role monitor
tmux-apex.sh send <session> "rebase on main, CI is red"
tmux-apex.sh status                  # or --json
tmux-apex.sh reap --yes              # remove finished/dead members
tmux-apex.sh stop
```

A team can be mixed: `--agent` picks the coding agent per spawn, so a cheap
`pi` worker and an `opus` reviewer can run side by side. `--agent-flags` is
passed to that agent's adapter verbatim (`--permission-mode` is accepted as an
alias, since only claude calls it that). A bare claude token like
`bypassPermissions` combined with a non-claude `--agent` is refused rather than
being handed over as a stray positional.

`spawn` delegates to the picker's existing issue/PR handlers, so worktree
naming, the already-has-an-open-PR check, session labelling and the dev layout
are exactly the same as a manual `C-g` spawn. It defaults to not switching
clients, so the manager keeps focus; pass `--switch` to jump to the new session.

**The manager may not merge or close anything.** It spawns, instructs, kills and
reaps; when work is done it reports "ready to merge" and stops. That boundary
lives in the skill.

### How reporting works

Reporting has two halves, and both need hooks installed: the **worker** records
its transitions, and the **manager** pulls them into its own context.

Worker side — the worker's Claude Code hooks call `agent-tmux-status.sh`, which
updates the pill *and*, for apex-mode members, records the transition to disk:

| Hook | State | Recorded |
|------|-------|----------|
| `PreToolUse` → `set` | `working` | nothing to report yet |
| `Notification` → `notify` | `attention` | immediate — the worker is blocked |
| `Stop` → `clear` | `idle` | after `APEX_QUIET_SECS` of quiet |

`Stop` fires at the end of every assistant turn, so the idle record is debounced
via a sequence counter and `tmux run-shell -d`: several quick turns produce one
event, not one per turn.

Manager side — nothing is ever typed into the manager's pane (it used to be, via
`send-keys`, which could splice into whatever the human was typing; see issue
#5). Delivery is pull-based instead: `apex-manager-notify.sh` runs from the
manager's *own* hooks, calls `tmux-apex.sh pending --mark-delivered`, and hands
the result to the agent as context. Each event is delivered exactly once,
because `--mark-delivered` advances the member's `pinged_seq`.

| Hook | Argument | Closes this gap |
|------|----------|-----------------|
| `UserPromptSubmit` | `prompt` | before every human message |
| `SessionStart` | `session-start` | catch-up after a restart or `--continue` |
| `PostToolBatch` | `post-tools` | mid-turn, before the next model call |
| `Stop` | `stop` | a ping landing as the manager wraps up its turn |

The last two matter more than they look. `UserPromptSubmit` only fires on a
*human* message, so a manager working autonomously — spawn, poll, report — takes
many model turns without one, and a worker that finished during that stretch
stayed invisible until the human typed again (issue #7). `PostToolBatch` and
`Stop` return their text as `hookSpecificOutput.additionalContext`, since plain
stdout only reaches the model on `UserPromptSubmit` and `SessionStart`.

The script exits immediately in any session that isn't an apex manager, so it is
safe to install globally — which it must be, since the manager can be any
session.

`scripts/install-agent-hooks.sh` writes all four (see Installation step 3), and
`tmux-apex.sh doctor` reports which of them are actually wired, argument
included; `init` runs the same check and warns if any are missing. Both halves
are worth having: the installer is what gets a fresh machine working, and
`doctor` is what catches an installer that has drifted from what the script
requires — the state this repo was in when the wiring existed but carried no
argument. A manager with no working wiring looks perfectly healthy from the
inside — `pending` keeps answering correctly for anyone who asks by hand — so
the check is the only thing that makes the failure visible.
Records on disk are the source of truth either way: `tmux-apex.sh status --json`
and `events.jsonl`.

How much of that an agent reports depends on what it exposes (see Installation
step 3): claude, pi, and opencode cover all three transitions, codex only the
idle one.
A worker that reports nothing still shows up in `status` — the manager just has
to poll it rather than being woken.

Manager designation is a tmux *session* option, so it does not survive a tmux
server restart. The on-disk state does; re-run `init` to re-adopt it.

### Sending into a member's pane

The manager's own pane is never typed into, but `send` still delivers into a
*member's* pane with `send-keys`, so it has to cope with whatever is already in
that pane's input box:

- **It clears the box first.** An idle Claude Code box is not reliably empty —
  it paints predictive autosuggestion text into it — and appending to that
  would hand the worker one spliced line. Whatever was cleared is reported on
  stderr and stored as `cleared_input` on the `send` event, so nothing
  disappears silently. `APEX_SEND_CLEAR=0` restores the old append-anyway
  behaviour.
- **It verifies delivery.** tmux wraps a literal send in bracketed paste and
  some agent TUIs drop an Enter that lands mid-paste, so `send` reads the pane
  back, re-sends Enter up to three times, and fails loudly (`send-unsubmitted`
  event) rather than reporting a delivery that never happened.

`status` lists any unsent text it finds in member input boxes, with the caveat
attached: it is usually the agent's own autosuggestion rather than a failed
delivery or stray injection, which is otherwise impossible to tell apart from
outside the pane (issue #10).

### Spawn profiles

`--profile NAME` is shorthand for a named `{agent, model, agent_flags}`
bundle, so the manager doesn't have to reassemble raw flags for every spawn.
Definitions are layered from two JSON files, merged shallowly by profile name
(a user profile fully replaces the repo one of the same name — no
field-by-field splicing between files):

| File | Role |
|------|------|
| `scripts/lib/apex-profiles.json` | repo defaults, checked in |
| `${XDG_CONFIG_HOME:-~/.config}/tmux-delta/apex-profiles.json` | optional user overrides/additions |

Each entry:

```json
"hard": {
  "agent": "claude",
  "model": "opus",
  "agent_flags": "acceptEdits",
  "description": "Tricky refactors, ambiguous specs, anything touching shared/critical code."
}
```

Default tiers ship as `trivial` (haiku) → `easy`/`standard` (sonnet) →
`hard` (opus) → `extreme` (fable), Anthropic's model tiers cheapest/fastest
to most capable/expensive, all on the claude agent. Run `tmux-apex.sh
profiles` to see the current merged set, since these are meant to be edited
freely and the shipped names/models are starting points, not fixed policy —
in particular, model aliases and pricing drift over time and across
providers, so re-verify them periodically rather than trusting this table
indefinitely.

`--profile` only fills the `--agent`/`--model`/`--agent-flags` fields the
`spawn` call didn't already set explicitly — pass any of those three
alongside `--profile` to override just that field for one spawn, e.g.
`spawn --issue 42 --profile hard --agent-flags bypassPermissions`. Omitting
`--profile` entirely is unchanged from before this feature existed — raw
`--agent`/`--model`/`--agent-flags` still work with no profile involved.

### Per-spawn agent configuration

`spawn` sets these in the new session's environment; `tmux-dev-layout.sh` reads
them when launching the agent:

| Variable | Effect |
|----------|--------|
| `CODING_AGENT_MODEL` | `--model` |
| `CODING_AGENT_PERMISSION_MODE` | `--permission-mode` |
| `CODING_AGENT_ROLE` / `CODING_AGENT_APEX_SESSION` | appends a system prompt telling the agent it is managed: report blockers instead of waiting on a human, expect follow-ups, never merge or close |

### Session options

| Option | Set on | Value |
|--------|--------|-------|
| `@apex_role` | manager + members | `manager` \| `worker` \| `monitor` |
| `@apex_session` | members | manager's session name |
| `@apex_task` | members | `issue:42` or `pr:17` |
| `@agent_pane` | any dev-layout session | pane id of the coding-agent split |

## Tests

```bash
tests/apex-delivery.test.sh
```

Covers apex ping delivery: which output channel `apex-manager-notify.sh` picks
per event, that an invocation which cannot deliver also does not *consume*
(pings stay pending), and `doctor`'s wiring detection against fixture settings
files — correctly wired, unwired, wired without the argument, wired with another
event's argument, and malformed JSON. `tmux` and `tmux-apex.sh` are stubbed, so
it needs neither a live agent nor a tmux server.

It also pins the two halves together: `install-agent-hooks.sh` runs into a
throwaway `$HOME` and `doctor` has to accept what it wrote, both from scratch and
on top of a stale argument-less wiring. Those two drifting apart is what
silently un-wires delivery on every machine at once.

## Shell functions (gwt.zsh)

| Command | Description |
|---------|-------------|
| `gwta <branch>` | Create worktree for branch (creates if new, checks out if exists) |
| `gwtrm [-f] <path-or-branch>` | Remove worktree and delete branch |
| `gwtl` | List all worktrees |
| `gwtp` | Prune stale worktree refs |
