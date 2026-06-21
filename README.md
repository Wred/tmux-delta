# tmux-delta

A tmux plugin providing a unified session/worktree/issue/PR picker and a dynamic dual-status bar with git, GitHub PR, and Kubernetes context awareness.

## Features

- **Picker** (`C-g`): tabbed fzf UI — Sessions, Directories, Worktrees, Issues, PRs, Ready-for-review PRs
- **Session pills**: top status bar with per-session PR status icons and coding-agent activity indicator
- **Git bar**: bottom status bar with repo name, branch (with git host icon), window list, and kube context
- **Git worktree helpers**: `gwta`, `gwtrm`, `gwtl`, `gwtp` shell functions
- **Dev layout**: auto-opens nvim + coding agent split on new sessions
- **PR status daemon**: background refresh of CI/review state every 60 s

## Requirements

**Required:**
- tmux ≥ 3.3
- [catppuccin/tmux](https://github.com/catppuccin/tmux) v2 (loaded before TPM — see below)
- fzf
- git
- zsh (picker and gwt scripts use zsh-specific syntax)

**Soft (features degrade gracefully when absent):**
- `gh` — GitHub CLI (issues, PRs, browser open)
- `jq` — PR/issue formatting
- `kubectl` — Kubernetes context pill
- `direnv` — per-directory KUBECONFIG support (kube pill falls back to global config)
- `nvim` — dev layout left pane
- Nerd Fonts — icons in status bar

## Installation

### 1. TPM (recommended)

```tmux
set -g @plugin 'Wred/tmux-delta'
```

**Important:** catppuccin must be loaded before TPM so its theme variables are
defined when tmux-delta runs. Add this to your `tmux.conf` before `run tpm`:

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

## Configuration

Set these in `tmux.conf` before loading TPM:

```tmux
# Keybind for the picker popup (default: C-g)
set -g @tmux_delta_picker_key 'C-g'

# Right-side status modules (default: catppuccin date + host)
set -g @tmux_delta_modules_right '#{E:@catppuccin_status_date_time}#{E:@catppuccin_status_host}'
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

## Shell functions (gwt.zsh)

| Command | Description |
|---------|-------------|
| `gwta <branch>` | Create worktree for branch (creates if new, checks out if exists) |
| `gwtrm [-f] <path-or-branch>` | Remove worktree and delete branch |
| `gwtl` | List all worktrees |
| `gwtp` | Prune stale worktree refs |
