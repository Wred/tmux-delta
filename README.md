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
