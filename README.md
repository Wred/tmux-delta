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

| Verb | Meaning | Unselected pill | Selected pill |
|------|---------|-----------------|---------------|
| `set` | agent is working | green 󱚣 `md-robot_excited` | 󱚤 `md-robot_excited_outline` |
| `notify` | agent is blocked on you | peach 󱚟 `md-robot_confused` | 󱚠 `md-robot_confused_outline` |
| `clear` | agent is idle | muted 󰚩 `md-robot` | 󱙺 `md-robot_outline` |

The pill for the **selected** session draws the outline variant of whichever
glyph is showing (and the dark pill foreground for idle, since the muted grey is
unreadable on mauve).

Beyond `@tmux_delta_agent_icons_max` agents (default 4) the remainder collapses
into a `+N` counter, coloured by the most urgent state hidden behind it, so a
blocked agent in the overflow still shows up. An *idle* pane whose foreground
command is no longer an agent (`@tmux_delta_apex_agent_cmds`) is dropped — pane
options outlive the agent process, and without that check an exited agent would
leave an idle robot on the pill forever.

A pane that has an apex role but has never fired a hook event is exempt from
that check: it was registered a moment ago and the agent is still launching, so
the pane is typically still showing the shell it was spawned from. Nothing has
been heard from it yet, so there is no stale presence to guard against, and the
icon appears at registration instead of a second later.

A pane reporting *working* or *blocked* is believed even when the foreground
command isn't an agent, since the agent's own tool call can put `git` or
anything else there and second-guessing it would blink the icon out mid-turn.
The one exception is an interactive login shell — `zsh`, `bash` or `fish`, and
only those three: nothing is running in the pane, so no tool call can be in
flight and the agent is gone. `sh` and `dash` are left out on purpose, since
they are routinely the foreground command *during* real work (a build script, a
`#!/bin/sh` git hook) and would flicker the icon out mid-turn.
That matters because an agent killed or crashed mid-turn never fires `clear`,
so its state flags — pane *and* session-level — stay set for the life of the
pane.

Switching into a session clears the "blocked" flag for the panes of that
session's **current window** only: attention is per-agent now, and an agent
blocked in a window you never looked at has not been seen.

The icons are **per agent**, not per session: one glyph per pane that hosts an
agent, each in its own state, so a worktree running a worker and a reviewer
shows two. Presence is what puts a glyph in the pill — an idle agent still
shows — and it is independent of the apex marker, so a manager session that
also runs an agent shows both. Beyond four agents the rest collapse into `+N`.

`scripts/agent-icons-refresh.sh` builds both strings into the per-session
`@agent_icons` / `@agent_icons_outline` options (tmux formats can iterate sessions but not the panes
inside one, so the walk has to happen in a script). It runs on every hook
event, on focus change, and on apex member registration.

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
set -g @tmux_delta_color_agent_idle      '#6c7086'
set -g @tmux_delta_color_agent_working   '#a6e3a1'
set -g @tmux_delta_color_agent_attention '#fab387'
set -g @tmux_delta_color_agent_idle_active '#11111b'

# Most agent icons drawn in one pill before the rest collapse into "+N"
set -g @tmux_delta_agent_icons_max 4

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
# Glyph marking the manager session in its pill. Separate from the per-agent
# icons, which are drawn next to it.
set -g @tmux_delta_apex_icon '󱇖'

# Variant used on the selected pill. Material Design ships no outline form of
# md-strategy, so it defaults to the same glyph.
set -g @tmux_delta_apex_icon_outline '󱇖'

# Pane commands tmux-apex.sh is allowed to send-keys into. Allowlist, not
# denylist — a shell pane must never receive a message, it would execute it.
# Both Claude Code and pi present as `node`.
set -g @tmux_delta_apex_agent_cmds 'node bun claude codex gemini pi opencode'
```

`APEX_QUIET_SECS` (env, default `30`) is how long a worker must be idle before
its "turn finished" ping reaches the manager.

`APEX_PAIR_MAX_ROUNDS` (env, default `5`) is the default `--max-rounds` cap for
a linked pair's fix/re-review loop.

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
tmux-apex.sh authority               # may apex merge in this repo? (default: no)
tmux-apex.sh authority --self-review yes  # ...on its own review too (needs --grant)
tmux-apex.sh profiles                # list available {agent,model,agent-flags} presets
tmux-apex.sh spawn --issue 42 --profile standard
tmux-apex.sh spawn --issue 43 --profile hard
tmux-apex.sh spawn --issue 44 --agent opencode --model anthropic/claude-sonnet-4-6 --agent-flags '--auto'
tmux-apex.sh spawn --review-pr 17 --profile hard --role monitor
tmux-apex.sh send <session> "rebase on main, CI is red"
tmux-apex.sh link --worker wt:%3 --reviewer wt:%7   # automatic fix/re-review loop
tmux-apex.sh status                  # or --json
tmux-apex.sh reap --yes              # remove finished/dead members
tmux-apex.sh reap --yes --force      # ...including ones with unpushed work
tmux-apex.sh recover                 # dry run: what a tmux crash took out
tmux-apex.sh recover --yes           # recreate those panes, resuming their conversations
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

**The manager may not close anything, and may not merge unless you have said it
may — per repo.** It spawns, instructs, kills and reaps; when work is done it
reports "ready to merge" and stops. That boundary lives in the skill.

Merge authority is a separate, deliberately fail-closed switch, because it is
the one decision no mechanical check can stand in for: the criteria in the skill
can tell you CI is green and the diff is in scope, but not that a teammate
expected to review it first. So it defaults to **not granted** in every repo,
and stays that way until you say otherwise:

```zsh
tmux-apex.sh authority                 # what is in force here, and how it was decided
tmux-apex.sh authority --grant         # yes, apex may merge reviewer-approved PRs here
tmux-apex.sh authority --revoke        # no (also the default, and what silence means)
tmux-apex.sh authority --self-review yes   # ...and on its own review, with no second agent
tmux-apex.sh init --merge yes|no [--self-review yes|no]   # answer it at init time
```

There are two axes, because they are two questions. `--grant` says merging here
is apex's to do. `--self-review` says it is apex's to do *without a second agent
having looked* — apex can review a PR either by spawning an independent reviewer
or by reading it itself, and its own reading is the weakest leg in the criteria
list. Many repos will want the first and not the second, which is the default
pairing: granted, apex merges what a reviewer signed off on and reports anything
it only reviewed itself as ready-and-ineligible. Self-review authorises nothing
on its own and is refused unless merging is granted; revoking merge clears it,
so a stale yes cannot come back to life the next time someone re-grants merging.

`init` asks both questions once, interactively, only when there is a terminal on
the other end — it also runs from Claude Code hooks and on session recreation,
and a prompt that hangs an unattended start would be worse than not having the
feature. An unasked repo simply has no authority. `status` and `doctor` both
report what is in force, so an agent cannot quietly forget it lacks the grant.

Granting requires a terminal at both ends; revoking works from anywhere. The
asymmetry is the point: the grant is yours to give, and an agent invoking the
script from a tool call is not you, while nothing should make taking authority
away harder than giving it. Set `APEX_AUTHORITY_UNATTENDED_GRANT=1` when a
provisioning script is carrying your decision. It is a speed bump against an
agent granting itself authority in passing, not a security boundary — an agent
that sets that variable has bypassed it, and claiming otherwise would be the
more dangerous claim.

The answer is stored once per repo in
`${XDG_CACHE_HOME:-~/.cache}/tmux-delta/apex/authority.json`, keyed on the
normalised origin URL rather than the directory name so that a fork and its
upstream are different trust contexts, and so that every worker worktree
resolves to the same answer as the main tree. Anything unreadable, missing or
unrecognised there reads as *not granted*. If that file is ever found corrupt it
is moved aside to `authority.json.corrupt-<epoch>` and named on stderr rather
than silently rewritten, so answers you gave are recoverable — every repo falls
back to *not granted* in the meantime.

### Linked pairs: automatic fix/re-review loop

A worker and a reviewer on the same PR are, by default, two unrelated member
records. Driving them means the manager reads the reviewer's comments, decides
what to relay, tells the worker, waits, re-invokes the reviewer, and repeats —
shuttling messages between two agents that could resolve it themselves.

`link` records the relationship on both sides and hands the round-trip to the
agents:

```zsh
tmux-apex.sh status                                  # get the two member keys
tmux-apex.sh link --worker wt:%3 --reviewer wt:%7    # --pr N is inferred
tmux-apex.sh link --worker wt:%3 --reviewer wt:%7 --max-rounds 3
tmux-apex.sh unlink wt:%3
tmux-apex.sh pair-resume wt:%3                       # restart a stuck loop
tmux-apex.sh pair-resume wt:%3 --max-rounds 8        # ...one stuck at the cap
```

From then on each idle transition is relayed instead of surfacing:

| Idle member | Verdict | What happens |
|-------------|---------|--------------|
| reviewer | `N > 0` findings | worker is told to read and fix them; round `++` |
| worker | — | reviewer is re-invoked on the updated PR |
| reviewer | `0` findings | `gh pr ready`, then the manager is pinged **once** |

The termination signal is a structured record, not a text-scrape of the review
prose. The reviewer is required to run, before it stops:

```zsh
tmux-apex.sh verdict --findings 2 --note 'unquoted vars in the new helper'
tmux-apex.sh verdict --none          # nothing left worth fixing
```

`link` briefs the reviewer on that protocol, since it is already running its own
review prompt by then. A reviewer that goes idle *without* recording a verdict
halts the loop and escalates: "no verdict" and "no findings" are different
states, and guessing between them silently flips a PR to ready-for-review.

The loop escalates rather than spinning whenever it cannot make progress on its
own — the round cap is hit (worker and reviewer are not converging), no verdict
was recorded, the partner's pane is gone, or the relay could not be delivered.
Only then does the manager get a ping, and the message says which of those it
is. `pair-resume` on a loop that stuck *at the cap* requires a higher
`--max-rounds`: resuming at `round == max` would burn a full review turn and
re-escalate on the reviewer's first finding. Resuming also clears the reviewer's
last verdict, so a stale one cannot pass for the resumed round's. The terminal
ping is framed as the decision that is actually the human's — the merge call —
not as a generic "a member went idle".

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

All four hooks are still *manager-driven*: they fire on the manager's own turns,
never on a worker's transition. So between two manager turns the manager is
blind — a worker can go `attention` and sit there indefinitely while `pending`
would have reported it correctly the whole time (issue #14). `tmux-apex.sh
watch` closes that gap. It is a plain background process, not an agent turn:
one tick reads the member state files and nothing else (no `git`, no `gh`), so
it runs at ~1s, and it costs the manager nothing until there is something to
deliver. When there is, it types one short nudge into the manager's pane, which
fires `UserPromptSubmit`, which attaches the real `pending` output as context —
so the watcher never formats or dedupes a ping itself.

The tick's one job is to answer the same question `pending` answers, cheaply.
That predicate is not just "went idle": a pair escalation is reported on its own
merit regardless of the `status` it forces (see the pairing section), so a
terminal `READY FOR HUMAN REVIEW` can land while the member still reads as
`working`. The gate mirrors that — including the one-shot `seq`/`pinged_seq`
ledger — from a single `jq` definition spliced into both its slurped path and
its per-file fallback, so the two cannot drift apart and quietly disagree with
`pending` about the handoff that most wants a human.

`init` starts it, `stop` retires it, and `relink` restarts it — on *every*
manager hook, not just after a session restart, so a watcher that died for any
other reason (a crash, an OOM kill, a stray `kill`) comes back on the manager's
next turn. `watch --status` / `--stop` drive it by hand, and `watch --once` runs
a single tick and says what it decided.

`watch` returns as soon as the poller is up; the blocking loop is `watch
--daemon`, which is what `run-shell` invokes. That split matters because `watch`
is something the manager agent runs in a tool call, and a blocking loop there
hangs the manager's own turn until the harness times out.

Writing into the manager's pane is exactly what the pull design refuses to do,
so the watcher is guarded rather than trusted:

| Guard | Why |
|-------|-----|
| pane must be running an agent | typing into a shell would *execute* the nudge |
| unsent input defers the nudge | never clobber a human mid-draft (issue #5) |
| a box quiet for `APEX_WATCH_BOX_GRACE` is cleared anyway | Claude Code's ghost autosuggestion (issue #10) never moves, and deferring to it forever would restore the very blindness this fixes |
| one nudge per distinct pending set, re-sent at most every `APEX_WATCH_RENUDGE` | a nudge queued behind a long manager turn must not turn into one duplicate per second |
| an unparseable state file is reset and the tick skipped | every key then reads `""`, and `""` is not a safe default anywhere: it makes the debounce stop debouncing and the grace window expire instantly, i.e. a nudge per second that clears the box each time |
| one unparseable *member* file only loses its own member | the cheap gate slurps every member file in one `jq`, and a slurp aborts on the first bad document — returning "nothing pending" for the whole set, from a poller that keeps reporting itself healthy |

"Quiet" is not only a timer. `client_activity` is a per-client attribute — the
last time that client sent input — and it stays frozen while a pane emits output
with nobody typing, so recent input from a client *looking at the manager's
pane* pushes the clock forward and a human pausing mid-draft keeps their draft.
Scoped to that pane on purpose: read across the whole session it would count
typing in a sibling shell, a window switch or a scroll as evidence of a draft,
and defer for as long as anyone worked next door. It is also capped at twice the
grace window measured from when the box was first seen, so the window closes on
schedule whatever the signal says — ghost text delays delivery, it never blocks
it, unconditionally rather than only once the human stops. The signal is treated
as a reason to defer and never as permission to clear; the timer is what
guarantees delivery.

Tunable with `APEX_WATCH_INTERVAL` (1s), `APEX_WATCH_BOX_GRACE` (60s) and
`APEX_WATCH_RENUDGE` (60s); all three are validated as numbers before the loop
starts, because a non-numeric interval makes `sleep` fail instantly and the loop
cannot tell that from a slept second. They travel on the `run-shell` command
line, since it executes in the *tmux server's* environment rather than the
caller's, and the daemon records the values it actually started with so
`watch --status` and `doctor` report those rather than the reader's own defaults.

This deliberately is not `/loop 1s`: a `/loop` tick spends a full manager turn
whether or not anything happened, which is why that fallback has to be slow.
Here the polling is free and only the events cost.

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

- **It tries to clear the box first.** An idle Claude Code box is not reliably
  empty — it paints predictive autosuggestion text into it — and appending to
  that would hand the worker one spliced line. Whatever was cleared is
  reported on stderr and stored as `cleared_input` on the `send` event, so
  nothing disappears silently. Clearing is best effort and verified rather
  than assumed: if the box will not drain, `send` says so on stderr and
  splices rather than claiming a clear it did not achieve.
  `APEX_SEND_CLEAR=0` restores the old append-anyway behaviour.
- **It verifies delivery.** tmux wraps a literal send in bracketed paste and
  some agent TUIs drop an Enter that lands mid-paste, so `send` reads the pane
  back, retries up to three times, and fails loudly (`send-unsubmitted` event,
  which records the text) rather than reporting a delivery that never
  happened. Retries clear and retype rather than firing a bare Enter — a bare
  Enter would submit whatever the box happens to hold, which after a
  successful send is often a fresh autosuggestion, i.e. the very thing this
  is here to prevent.
- **It pins the locale for the check.** The box edges it matches on are
  multibyte, so under a single-byte locale (`LC_ALL=C`, which hooks and cron
  hand it often enough) every box would read as empty and the clearing step
  would quietly stop happening. It runs the match under a UTF-8 locale of its
  own choosing, scoped to the call.

A linked pair's relays go through the same path and get the same treatment, on
the `pair-relay` and `pair-relay-failed` events. That matters more there than
for `send`: a relay fires from a background `run-shell` with no operator
attached, so the stderr report is unread and the event is the only surviving
record — including when the delivery that displaced the text then failed, since
the draft is gone either way.

Because the event is the sole record there, it distinguishes the two outcomes
that stderr distinguishes and a bare `cleared_input` would not. `cleared_input`
is the pre-send box read: whatever the box held before the delivery. On its own
it means the box then drained and that text was discarded. `spliced_onto`
alongside it means the clear did not take — the delivery was appended instead,
and the receiving agent got `<draft><message>` as one garbled instruction; the
value is that combined line, so the two keys hold different text. The splice is
the worse outcome and the one you want to find in the log, so it gets its own
key rather than reading identically to a clean discard. Filter on
`spliced_onto` first: `cleared_input` alone is only a clean discard when
`spliced_onto` is absent. `send` reports both the same way.

A splice does not by itself count as a failed delivery — the message did go in,
garbled onto the draft — so it is recorded and nothing escalates on it. The
submit check does see past it, though: because the box reads
`<draft><message>`, it is told what the draft was and strips it before matching
its own text, so a spliced delivery whose Enter was *swallowed* reports as
unsubmitted like any other rather than as a success (issue #22). Before that,
the mismatch read as "our text is gone, so it was submitted", and a garbled,
unsent relay advanced the round.

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
| `@agent_present` | agent panes (pane-scoped) | `1` once a hook has fired there |
| `@agent_working` / `@agent_needs_attention` | agent panes + session aggregate | `1` |
| `@agent_icons` | any session | rendered per-agent icon string |
| `@agent_icons_outline` | any session | same, outline glyphs, for the selected pill |

### Crash recovery

Members are pane-scoped, so a tmux server crash (or `kill-server`) takes every
worker with it while the durable member records under
`$XDG_CACHE_HOME/tmux-delta/apex/<manager>/members/` survive. `recover` walks
those records, and for each one whose pane is gone it recreates the session and
pane and restarts the agent **on its original conversation** rather than from a
blank context.

It can do that because registration records an `agent_session_id` field: the
Claude Code conversation id, discovered from the transcript under
`~/.claude/projects/<mangled-worktree>/<id>.jsonl` by matching `cwd` plus the
opening task prompt (a worker and its reviewer share a worktree, so the prompt
is the only thing that tells them apart — hence the single copy of that text in
`scripts/lib/agent-prompts.sh`). A slash command is stored expanded rather than
verbatim, so a reviewer's `/my-pr-review 17` is folded back from its
`<command-name>`/`<command-args>` form before matching. The marker has to be
followed by end-of-line or a space: `/my-pr-review 4` is a prefix of
`/my-pr-review 43`, and resuming the wrong PR's review looks like it worked. The
id only exists after the member's first turn, so it is filled in on the member's
first `event` call, not at spawn.

The record is a cache; the transcript is the authority. `recover` re-resolves the
id every time and says so when a recorded one no longer resolves, so a record
that went stale (or was written empty because nothing resolved) self-heals rather
than pinning recovery to a dead conversation. Registration writes the field
unconditionally — a member is born there, so there is nothing to inherit from a
recycled pane id. When registration does find a stale record on a pane id tmux
reused, it replaces it and writes a `stale-record-replaced` entry to
`events.jsonl`: the real call sites redirect stderr to `/dev/null`, so a warning
alone would never be seen.

**Run `recover` before `reap`, never the other way round.** `reap` force-removes
the worktree and deletes the branch, so a crashed member's uncommitted or
unpushed work is gone for good — and `recover` cannot help afterwards, because it
skips members whose worktree is missing. `reap` therefore holds back any member
with uncommitted changes or commits no remote has, printing `HOLD:` and the
reason instead of taking it; `--force` overrides that. The check asks
`git rev-list --count HEAD --not --remotes` rather than reading `commits_ahead`,
because a branch that was never pushed has no upstream and so reports zero
commits ahead — exactly the member whose work is at stake.

`--force` genuinely takes a dirty worktree: `gwtrm`'s `-f` used to skip only the
first confirmation and prompt again for uncommitted changes, which with no tty
failed into an "Aborted." path that returned success for a worktree it had not
removed. `-f` now covers both prompts (the picker shows the dirty-file warning
itself, so an interactive delete loses nothing), the picker reports a worktree
that survived, and `reap` removes the worktree *before* deleting the member
record — so if cleanup fails anyway it says `worktree survived cleanup` and
keeps the record, which is the only thing `recover` can act on.

`recover` is a dry run by default, like `reap`; `--yes` acts. Pass member keys
to limit it. It skips members whose worktree is gone, and members whose task is
already live in a pane. When no conversation can be resumed it says so and
starts a fresh one on the same task. Non-claude agents always restart fresh —
their thread ids are recorded but not yet wired to a resume flag.


## Tests

```bash
tests/apex-delivery.test.sh
tests/apex-send.test.sh
tests/apex-pair.test.sh
tests/apex-watch.test.sh
tests/apex-recover.test.sh
tests/apex-lock.test.sh
tests/agent-icons.test.sh
tests/status-format.test.sh
```

None of them needs a tmux server or a live agent — seven stub `tmux`, and
`apex-lock.test.sh` never calls it.

Covers apex ping delivery: which output channel `apex-manager-notify.sh` picks
per event, that an invocation which cannot deliver also does not *consume*
(pings stay pending), and `doctor`'s wiring detection against fixture settings
files — correctly wired, unwired, wired without the argument, wired with another
event's argument, and malformed JSON. `tmux` and `tmux-apex.sh` are stubbed, so
it needs neither a live agent nor a tmux server.

`apex-pair.test.sh` covers the linked-pair state machine: the relay in both
directions, the round cap, a missing verdict, an unreachable or dead partner, a
failed `gh pr ready`, and the two properties the feature exists for — no manager
ping on an intermediate round, exactly one on termination. It also pins down the
option parsers: zsh's `shift 2` with a missing value leaves `$#` unchanged, so
every two-argument flag is asserted to fail fast rather than spin. tmux is a
file-backed option-store stub and `gh` records its argv, so member state is the
real thing but nothing touches a live PR.

It also pins the two halves together: `install-agent-hooks.sh` runs into a
throwaway `$HOME` and `doctor` has to accept what it wrote, both from scratch and
on top of a stale argument-less wiring. Those two drifting apart is what
silently un-wires delivery on every machine at once.

`apex-watch.test.sh` covers the fast poller: that the tick's gate stays cheap
and matches `pending`'s predicate, that one event produces exactly one nudge,
and — the part that makes writing into the manager's pane defensible — that a
draft still being typed is never clobbered while a box frozen past the grace
window still gets delivery. One tick is a pure function of the state files, the
captured pane and its own saved state, so a fake `tmux` covers all of it; no
daemon and no live agent are involved.

It also pins the degraded paths, which is where a poller fails *silently*: a
garbage state file must cost at most one duplicate nudge rather than one per
tick and must never clear a draft, one unparseable member file must not hide
every other member's pending event, a comma in a session name must not misalign
names against documents, and a stale pidfile whose pid now belongs to something
else must read as not-running rather than as a healthy watcher.

`agent-icons.test.sh` covers the session pills' per-agent icons: one glyph per
agent pane in its own state, outline variants for the selected pill, presence
that survives an idle turn but not an exited agent, the `+N` overflow and its
urgency colour, and that `--ack` reaches the current window's panes only.

`status-format.test.sh` is a static check on `tmux-delta.tmux`: every `${VAR}`
used in a format string is actually assigned (an unset one expands to nothing in
tmux and silently unstyles a pill), and both icon slots are present in both
pill branches.

`tests/apex-recover.test.sh` covers crash recovery: picking a worker's own
conversation out of a worktree it shares with its reviewer, `--resume` argv
construction and its fresh-start fallback, `recover`'s dry run / `--yes` /
idempotency, a recycled pane id neither faking a live member nor corrupting an
existing member's record, one
task per member (never `issue:42pr:43`), and an apex spawn into a session that
already has a member landing in its own new pane without rewriting that
session's `CODING_AGENT_*` env, and colliding task numbers (PR 4 vs 43, issue 4
vs 42) not matching each other's transcripts. `tmux`, `gh` and `git` are stubbed.

`apex-lock.test.sh` covers the per-member mutex (see below). It is the one suite
that runs real concurrent processes, because the claim being tested is a
concurrency claim: sixteen writers of disjoint fields must all survive, the pair
race must keep both halves, four contending processes must never overlap in the
critical section (each holder checks for itself and fails loudly), a SIGKILLed
holder's lock must come free, twelve concurrent seq bumps must hand out twelve
distinct numbers, and a compare-and-set on a value that moved must refuse rather
than write. It also pins the degraded paths — the lockdir fallback, and a lock
that cannot be taken at all still writing but logging `lock_timeout`.

### Writing member records

Every member record write is a read-modify-write: read the JSON, merge a patch,
`mv` the result into place. The `mv` is atomic, so a record is never torn, but
two processes that read the same starting state each write a result missing the
other's fields and the last `mv` silently wins. That was harmless while every
writer only touched its own record. Linked pairs broke the assumption:
`_pair_advance` writes `{pair_round, pair_turn}` onto the *partner's* record and
then relays into its pane, which wakes the partner agent whose own hooks merge
`{status, seq}` into that same record. A lost `pair_turn` flip stalls the round
with nothing logged and no escalation.

So `apex_member_merge` holds a per-record mutex on `members/.<session>.lock`,
taken with `zsystem flock` from zsh/system — a real advisory lock, held on an
open descriptor. The kernel drops it when the holder exits, and that is the whole
reason to prefer it over a lockfile protocol of our own: hook processes are
killed freely (tmux teardown, `^C`, a crash mid-write), so any lock we release
ourselves needs a staleness rule, and a staleness rule has no safe
implementation. Stealing a stale lock means removing it and creating your own,
and two waiters that saw the same stale lock will each do that and each believe
they won — a pid file does not settle it either, because `$$` is shared by every
zsh subshell forked from one shell. The kernel already knows what we would be
guessing at.

Two knobs: `$APEX_LOCK_WAIT` (5s) before giving up, and `$APEX_LOCK_POLL`
(0.02s) between retries. The second is not cosmetic — `zsystem flock` retries
once a second by default, and a critical section here is two `jq` forks, so a
waiter on that cadence is running a lottery it usually loses. Giving up writes
anyway and logs `lock_timeout` to `events.jsonl`: dropping a state update is
worse than a racy one, and the point of the lock is that a lost write is never
silent.

A zsh built without zsh/system falls back to `mkdir` of a sibling `.lock.d`.
`mkdir` is a sound create-exclusive; what it cannot do safely is recover a lock
whose holder died, so the fallback never steals one. A wedged lock costs each
later writer one `$APEX_LOCK_WAIT` stall and then an unlocked, logged write —
degraded and noisy, never wedged, and never two holders except behind a critical
section that has already stalled past `$APEX_LOCK_STALE`. The directory is cleared
only once a writer has already given up, so nobody ever claims a lock they
stole — but a holder that is live and stalled for 30s does get its directory
removed under it, and the next writer then runs alongside it. That is the one
multi-holder path left, and it needs a two-`jq`-fork critical section to hang for
half a minute.

`reap`, `relink` and `recover` re-keying call `apex_member_lock_forget`, since a
record that is destroyed or re-keyed leaves behind a lock nothing will ever take
again.

Two writers need more than a merge. `apex_member_merge_bump` increments `seq` in
the same critical section as the status write, because `_settle` arms a callback
keyed on the number it was handed — two hooks claiming one `seq` means a callback
can fire for a turn that is already over. And `pending --mark-delivered`
compare-and-sets on `seq` (`apex_member_merge_cas`), since it is the one writer
whose correctness depends on a value it just read: if the member transitioned in
between, marking that `seq` delivered would swallow a transition the manager
never saw. A refused CAS re-reports the member on the next pull, which is the
safe direction and self-heals in one round-trip.

## Shell functions (gwt.zsh)

| Command | Description |
|---------|-------------|
| `gwta <branch>` | Create worktree for branch (creates if new, checks out if exists) |
| `gwtrm [-f] <path-or-branch>` | Remove worktree and delete branch |
| `gwtl` | List all worktrees |
| `gwtp` | Prune stale worktree refs |
