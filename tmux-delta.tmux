#!/usr/bin/env bash
# tmux-delta.tmux — TPM plugin entry point
#
# catppuccin/tmux is optional: if loaded (any order, any flavor), tmux-delta
# auto-detects it and matches its active palette exactly; if absent, it falls
# back to its own built-in palette (Catppuccin Mocha-equivalent by default).
#
# User options (set in tmux.conf before loading TPM):
#   @tmux_delta_picker_key       — keybind for the picker popup (default: C-g)
#   @tmux_delta_modules_right    — right-side status modules (default: date+host)
#   @tmux_delta_color_*          — palette used when catppuccin is absent
#   @tmux_delta_separator_left   — left segment separator when catppuccin is absent
#   @tmux_delta_separator_right  — right segment separator when catppuccin is absent

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

# ─── Internal color palette (fallback when catppuccin/tmux is absent) ────────
# Each option below is user-overridable and defaults to Catppuccin Mocha, so
# existing catppuccin users see no visual change. When catppuccin/tmux IS
# loaded, the format strings below defer to its @thm_*/@catppuccin_* tokens
# instead (see resolve() below) — resolved dynamically at render time so it
# stays correct regardless of load order or later @catppuccin_flavor changes.
for _delta_default in \
    green:'#a6e3a1' crust:'#11111b' fg:'#cdd6f4' surface_0:'#313244' \
    mauve:'#cba6f7' peach:'#fab387' pink:'#f5c2e7' \
    pr_green:'#a6e3a1' pr_red:'#f38ba8' pr_peach:'#fab387' \
    pr_muted:'#6c7086' pr_sky:'#89dceb'; do
  _delta_key="${_delta_default%%:*}"
  _delta_val="${_delta_default#*:}"
  _delta_existing=$(tmux show-option -gqv "@tmux_delta_color_${_delta_key}" 2>/dev/null)
  [[ -z "$_delta_existing" ]] && tmux set-option -g "@tmux_delta_color_${_delta_key}" "$_delta_val"
done
unset _delta_default _delta_key _delta_val _delta_existing

_delta_existing=$(tmux show-option -gqv @tmux_delta_separator_left 2>/dev/null)
[[ -z "$_delta_existing" ]] && tmux set-option -g @tmux_delta_separator_left ''
_delta_existing=$(tmux show-option -gqv @tmux_delta_separator_right 2>/dev/null)
[[ -z "$_delta_existing" ]] && tmux set-option -g @tmux_delta_separator_right ''
unset _delta_existing

# When catppuccin IS present, snapshot its active flavor's colors into the PR
# status daemon's palette so tmux-pr-status-refresh.sh (a standalone script,
# outside tmux's format-string engine) matches it too. Known limitation:
# changing @catppuccin_flavor without reloading tmux-delta won't repaint the
# PR icon colors until the next reload.
if [[ -n "$(tmux show-option -gqv @catppuccin_flavor 2>/dev/null)" ]]; then
  for _delta_pr_pair in green:pr_green red:pr_red peach:pr_peach \
      overlay0:pr_muted sky:pr_sky; do
    _delta_thm="${_delta_pr_pair%%:*}"
    _delta_dst="${_delta_pr_pair##*:}"
    _delta_val=$(tmux show-option -gqv "@thm_${_delta_thm}" 2>/dev/null)
    [[ -n "$_delta_val" ]] && tmux set-option -g "@tmux_delta_color_${_delta_dst}" "$_delta_val"
  done
  unset _delta_pr_pair _delta_thm _delta_dst _delta_val
fi

# resolve <name> — emits a tmux format-string ternary that prefers catppuccin's
# @thm_<name> when catppuccin is loaded, else falls back to
# @tmux_delta_color_<name>.
resolve() { printf '#{?#{@catppuccin_flavor},#{@thm_%s},#{@tmux_delta_color_%s}}' "$1" "$1"; }
resolve_sep_left()  { printf '#{?#{@catppuccin_flavor},#{@catppuccin_status_left_separator},#{@tmux_delta_separator_left}}'; }
resolve_sep_right() { printf '#{?#{@catppuccin_flavor},#{@catppuccin_status_right_separator},#{@tmux_delta_separator_right}}'; }

C_GREEN=$(resolve green); C_CRUST=$(resolve crust); C_FG=$(resolve fg)
C_SURFACE0=$(resolve surface_0); C_MAUVE=$(resolve mauve)
C_PEACH=$(resolve peach); C_PINK=$(resolve pink)
SEP_L=$(resolve_sep_left); SEP_R=$(resolve_sep_right)

# ─── Catppuccin kube module override ─────────────────────────────────────────
# Reads direnv-aware cache populated by tmux-kube-status-refresh.sh instead of
# tmux-kubectx's #{kubectx_*} tokens — this is what makes per-directory
# direnv KUBECONFIG overrides work correctly. Only meaningful when catppuccin
# (which owns @catppuccin_kube_text) is loaded; inert otherwise.
tmux set-option -gF @catppuccin_kube_text \
  "#{?#{@catppuccin_flavor}, #{l:#[fg=#{@catppuccin_kube_context_color}]#{@kube_context_cache}#[fg=default]:#[fg=#{@catppuccin_kube_namespace_color}]#{@kube_namespace_cache}},}"

# ─── Catppuccin git branch module ────────────────────────────────────────────
# Icon (#{@git_icon_cache}) is set dynamically based on the remote hostname;
# branch (#{@git_branch_cache}) is the current branch. Both populated by
# tmux-git-status-refresh.sh.
tmux set-option -gF  @catppuccin_status_git "#[fg=${C_GREEN}]#[bg=default]${SEP_L}#[fg=${C_CRUST},bg=${C_GREEN}]"
tmux set-option -ag  @catppuccin_status_git '#{@git_icon_cache} '
tmux set-option -agF @catppuccin_status_git "#[fg=${C_FG},bg=${C_SURFACE0}] "
tmux set-option -ag  @catppuccin_status_git '#{@git_branch_cache}'
tmux set-option -agF @catppuccin_status_git "#[fg=${C_SURFACE0}]#[bg=default]${SEP_R}"

# ─── Catppuccin repo name module ─────────────────────────────────────────────
# Displays the main worktree name (repo root folder), hidden when not in a git
# repo. Populated by tmux-git-status-refresh.sh into @git_repo_cache.
tmux set-option -gF  @catppuccin_status_repo "#[fg=${C_GREEN}]#[bg=default]${SEP_L}#[fg=${C_CRUST},bg=${C_GREEN}]"
tmux set-option -ag  @catppuccin_status_repo '#{@git_icon_cache} '
tmux set-option -agF @catppuccin_status_repo "#[fg=${C_FG},bg=${C_SURFACE0}] "
tmux set-option -ag  @catppuccin_status_repo '#{@git_repo_cache}'
tmux set-option -agF @catppuccin_status_repo "#[fg=${C_SURFACE0}]#[bg=default]${SEP_R}"

# ─── Catppuccin PR number module ─────────────────────────────────────────────
# Shown only when the current branch has an open PR. Populated by
# tmux-git-status-refresh.sh into @git_pr_number_cache.
tmux set-option -gF  @catppuccin_status_pr_number "#[fg=${C_GREEN}]#[bg=default]${SEP_L}#[fg=${C_CRUST},bg=${C_GREEN}]"
tmux set-option -ag  @catppuccin_status_pr_number '# '
tmux set-option -agF @catppuccin_status_pr_number "#[fg=${C_FG},bg=${C_SURFACE0}] "
tmux set-option -ag  @catppuccin_status_pr_number '#{@git_pr_number_cache}'
tmux set-option -agF @catppuccin_status_pr_number "#[fg=${C_SURFACE0}]#[bg=default]${SEP_R}"

# ─── Catppuccin PR title / branch module ─────────────────────────────────────
# Shows the current branch's open PR title, falling back to the raw branch
# name when there's no PR. Populated by tmux-git-status-refresh.sh into
# @git_pr_title_cache.
tmux set-option -gF  @catppuccin_status_pr_title "#[fg=${C_GREEN}]#[bg=default]${SEP_L}#[fg=${C_CRUST},bg=${C_GREEN}]"
tmux set-option -ag  @catppuccin_status_pr_title '󰘬 '
tmux set-option -agF @catppuccin_status_pr_title "#[fg=${C_FG},bg=${C_SURFACE0}] "
tmux set-option -ag  @catppuccin_status_pr_title '#{@git_pr_title_cache}'
tmux set-option -agF @catppuccin_status_pr_title "#[fg=${C_SURFACE0}]#[bg=default]${SEP_R}"

# ─── Status right ────────────────────────────────────────────────────────────
# The leading #() is a polling fallback: tmux re-runs it on every
# status-interval tick, keeping caches fresh when context/branch changes
# while staying in the same pane (e.g. `git switch`, `kubectl use-context`).
modules_right=$(tmux show-option -gqv @tmux_delta_modules_right 2>/dev/null)
[[ -z "$modules_right" ]] && modules_right='#{?#{@catppuccin_flavor},#{E:@catppuccin_status_date_time} #{E:@catppuccin_status_host},#[fg=default]#{d:} #H}'

tmux set-option -g status-left-length 100
tmux set-option -g status-right-length 100
tmux set-option -g status-right "#(${SCRIPTS}/tmux-kube-status-refresh.sh >/dev/null 2>&1; ${SCRIPTS}/tmux-git-status-refresh.sh >/dev/null 2>&1; echo)${modules_right}"

# ─── Dual status bar ─────────────────────────────────────────────────────────
# Top bar  (format[0]): session pills on left, right-side modules on right.
# Bottom bar (format[1]): repo pill + window list on left, kube context on right.
tmux set-option -g status 2
status_fmt0="#{S/n:#[range=session|#{session_id}]#[fg=${C_SURFACE0}]#[bg=default]${SEP_L}#[fg=${C_FG} bg=${C_SURFACE0}]#{?#{==:#{@session_type},folder},󰉋,#{?#{==:#{@session_type},worktree},󰘬,󰊢}} #{?#{@session_label},#{@session_label},#{session_name}}#{?#{@pr_icons}, #{@pr_icons},}#{?#{@agent_working}, #[fg=${C_PEACH}]󰚩#[fg=${C_FG}],} #[fg=${C_SURFACE0}]#[bg=default]${SEP_R}#[fg=default bg=default]#[norange] ,#[range=session|#{session_id}]#[fg=${C_MAUVE}]#[bg=default]${SEP_L}#[fg=${C_CRUST} bg=${C_MAUVE}]#{?#{==:#{@session_type},folder},󰉋,#{?#{==:#{@session_type},worktree},󰘬,󰊢}} #{?#{@session_label},#{@session_label},#{session_name}}#{?#{@pr_icons}, #{@pr_icons},}#{?#{@agent_working}, #[fg=${C_PEACH}]󰚩#[fg=${C_CRUST}],} #[fg=${C_MAUVE}]#[bg=default]${SEP_R}#[fg=default bg=default]#[norange] }#[align=right]#{E:status-right}"
tmux set-option -g 'status-format[0]' "$status_fmt0"
tmux set-option -g 'status-format[1]' '#{?#{!=:#{@git_repo_cache},},#{E:@catppuccin_status_repo},}#{?#{!=:#{@git_pr_number_cache},},#{E:@catppuccin_status_pr_number},}#{?#{!=:#{@git_pr_title_cache},},#{E:@catppuccin_status_pr_title},} #{W:#[range=window|#{window_index}]#{E:window-status-format}#[norange default] ,#[range=window|#{window_index}]#{E:window-status-current-format}#[norange default] }#[align=right]#{?#{!=:#{@kube_context_cache},},#{E:@catppuccin_status_kube},}'

# ─── Post-load style overrides ───────────────────────────────────────────────
# Must come after catppuccin/TPM to win; catppuccin sets these on load.
tmux set-option -g pane-active-border-style "fg=${C_PINK}"
tmux set-option -g status-style bg=black
[[ -n "$(tmux show-option -gqv @catppuccin_flavor 2>/dev/null)" ]] && \
  tmux set-option -gF @_ctp_status_bg 'black'

# ─── PR status background daemon ─────────────────────────────────────────────
# Refreshes all sessions every 60 s. Safe to call on every config reload —
# exits immediately if already running.
tmux run-shell -b "${SCRIPTS}/tmux-pr-status-bg.sh"
