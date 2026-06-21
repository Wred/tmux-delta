#!/usr/bin/env bash
# tmux-delta.tmux — TPM plugin entry point
#
# Requires: catppuccin/tmux loaded BEFORE TPM (so theme vars are defined when
# this script runs). In your tmux.conf, put:
#   run '~/.config/tmux/plugins/tmux/catppuccin.tmux'
#   run '~/.tmux/plugins/tpm/tpm'
#
# User options (set in tmux.conf before loading TPM):
#   @tmux_delta_picker_key      — keybind for the picker popup (default: C-g)
#   @tmux_delta_modules_right   — right-side status modules (default: date+host)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${CURRENT_DIR}/scripts"

# Export for scripts that need to find siblings at runtime
tmux set-environment -g TMUX_DELTA_SCRIPTS "$SCRIPTS"
tmux set-option -g @tmux_delta_scripts "$SCRIPTS"

# ─── Hooks ───────────────────────────────────────────────────────────────────
# Refresh git, kube, and PR caches on every focus change.
# run-shell -b spawns in the background so hooks never block input.
hook_cmd="run-shell -b '${SCRIPTS}/tmux-kube-status-refresh.sh'; \
run-shell -b '${SCRIPTS}/tmux-git-status-refresh.sh'; \
run-shell -b '${SCRIPTS}/tmux-pr-status-refresh.sh --current'"
tmux set-hook -g after-select-pane      "$hook_cmd"
tmux set-hook -g after-select-window    "$hook_cmd"
tmux set-hook -g client-session-changed "$hook_cmd"

# ─── Picker keybind ──────────────────────────────────────────────────────────
is_ssh="ps -o comm= -t '#{pane_tty}' | grep -iqE '^ssh$'"
picker_key=$(tmux show-option -gqv @tmux_delta_picker_key 2>/dev/null)
[[ -z "$picker_key" ]] && picker_key="C-g"
tmux bind -n "$picker_key" \
  if-shell "$is_ssh" "send-keys $picker_key" \
  "display-popup -EE -d '#{pane_current_path}' '${SCRIPTS}/tmux-picker.sh'"

# ─── Catppuccin kube module override ─────────────────────────────────────────
# Reads direnv-aware cache populated by tmux-kube-status-refresh.sh instead of
# tmux-kubectx's #{kubectx_*} tokens — this is what makes per-directory
# direnv KUBECONFIG overrides work correctly.
tmux set-option -gF @catppuccin_kube_text \
  ' #{l:#[fg=#{@catppuccin_kube_context_color}]#{@kube_context_cache}#[fg=default]:#[fg=#{@catppuccin_kube_namespace_color}]#{@kube_namespace_cache}}'

# ─── Catppuccin git branch module ────────────────────────────────────────────
# Icon (#{@git_icon_cache}) is set dynamically based on the remote hostname;
# branch (#{@git_branch_cache}) is the current branch. Both populated by
# tmux-git-status-refresh.sh.
tmux set-option -gF  @catppuccin_status_git '#[fg=#{@thm_green}]#[bg=default]#{@catppuccin_status_left_separator}#[fg=#{@thm_crust},bg=#{@thm_green}]'
tmux set-option -ag  @catppuccin_status_git '#{@git_icon_cache} '
tmux set-option -agF @catppuccin_status_git '#[fg=#{@thm_fg},bg=#{@thm_surface_0}] '
tmux set-option -ag  @catppuccin_status_git '#{@git_branch_cache}'
tmux set-option -agF @catppuccin_status_git '#[fg=#{@thm_surface_0}]#[bg=default]#{@catppuccin_status_right_separator}'

# ─── Catppuccin repo name module ─────────────────────────────────────────────
# Displays the main worktree name (repo root folder), hidden when not in a git
# repo. Populated by tmux-git-status-refresh.sh into @git_repo_cache.
tmux set-option -gF  @catppuccin_status_repo '#[fg=#{@thm_green}]#[bg=default]#{@catppuccin_status_left_separator}#[fg=#{@thm_crust},bg=#{@thm_green}]'
tmux set-option -ag  @catppuccin_status_repo '#{@git_icon_cache} '
tmux set-option -agF @catppuccin_status_repo '#[fg=#{@thm_fg},bg=#{@thm_surface_0}] '
tmux set-option -ag  @catppuccin_status_repo '#{@git_repo_cache}'
tmux set-option -agF @catppuccin_status_repo '#[fg=#{@thm_surface_0}]#[bg=default]#{@catppuccin_status_right_separator}'

# ─── Status right ────────────────────────────────────────────────────────────
# The leading #() is a polling fallback: tmux re-runs it on every
# status-interval tick, keeping caches fresh when context/branch changes
# while staying in the same pane (e.g. `git switch`, `kubectl use-context`).
modules_right=$(tmux show-option -gqv @tmux_delta_modules_right 2>/dev/null)
[[ -z "$modules_right" ]] && modules_right='#{E:@catppuccin_status_date_time} #{E:@catppuccin_status_host}'

tmux set-option -g status-left-length 100
tmux set-option -g status-right-length 100
tmux set-option -g status-right "#(${SCRIPTS}/tmux-kube-status-refresh.sh >/dev/null 2>&1; ${SCRIPTS}/tmux-git-status-refresh.sh >/dev/null 2>&1; echo)${modules_right}"

# ─── Dual status bar ─────────────────────────────────────────────────────────
# Top bar  (format[0]): session pills on left, right-side modules on right.
# Bottom bar (format[1]): repo pill + window list on left, kube context on right.
tmux set-option -g status 2
tmux set-option -g 'status-format[0]' '#{S/n:#[fg=#{@thm_surface_0}]#[bg=default]#{@catppuccin_status_left_separator}#[fg=#{@thm_fg} bg=#{@thm_surface_0}] #{?#{@session_label},#{@session_label},#{session_name}}#{?#{@pr_icons}, #{@pr_icons},}#{?#{@agent_working}, #[fg=#{@thm_peach}]󰚩#[fg=#{@thm_fg}],} #[fg=#{@thm_surface_0}]#[bg=default]#{@catppuccin_status_right_separator}#[fg=default bg=default] ,#[fg=#{@thm_mauve}]#[bg=default]#{@catppuccin_status_left_separator}#[fg=#{@thm_crust} bg=#{@thm_mauve}] #{?#{@session_label},#{@session_label},#{session_name}}#{?#{@pr_icons}, #{@pr_icons},}#{?#{@agent_working}, #[fg=#{@thm_peach}]󰚩#[fg=#{@thm_crust}],} #[fg=#{@thm_mauve}]#[bg=default]#{@catppuccin_status_right_separator}#[fg=default bg=default] }#[align=right]#{E:status-right}'
tmux set-option -g 'status-format[1]' '#{?#{!=:#{@git_repo_cache},},#{E:@catppuccin_status_repo},}#{W:#[range=window|#{window_index}]#{E:window-status-format}#[norange default] ,#[range=window|#{window_index}]#{E:window-status-current-format}#[norange default] }#[align=right]#{?#{!=:#{@kube_context_cache},},#{E:@catppuccin_status_kube},}'

# ─── Post-load style overrides ───────────────────────────────────────────────
# Must come after catppuccin/TPM to win; catppuccin sets these on load.
tmux set-option -g pane-active-border-style 'fg=#{@thm_pink}'
tmux set-option -g status-style bg=black
tmux set-option -gF @_ctp_status_bg 'black'

# ─── PR status background daemon ─────────────────────────────────────────────
# Refreshes all sessions every 60 s. Safe to call on every config reload —
# exits immediately if already running.
tmux run-shell -b "${SCRIPTS}/tmux-pr-status-bg.sh"
