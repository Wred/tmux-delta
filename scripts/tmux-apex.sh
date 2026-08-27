#!/usr/bin/env zsh

# tmux-apex.sh — apex mode for tmux-delta.
#
# One tmux session hosts a "manager" coding agent that spawns, tracks and
# instructs "worker"/"monitor" agent sessions created through the normal
# tmux-delta picker machinery (worktree + session + dev layout).
#
# Transport: per-session @-options carry role metadata, and a JSON state
# tree under $XDG_CACHE_HOME/tmux-delta/apex survives agent context
# compaction. send-keys carries worker-directed messages (`send`), but
# status pings to the manager are pull-based, not pushed: the manager's own
# Claude Code hooks (scripts/apex-manager-notify.sh) call `pending` on its
# behalf on every turn and on resume, so nothing ever writes into the
# manager's own pane — see `pending` below for why that matters.
#
# Subcommands: init stop relink spawn send event status pending reap profiles

SELF="${0:A}"
SCRIPTS="${SELF:h}"

source "${SCRIPTS}/lib/apex-state.sh"
source "${SCRIPTS}/lib/apex-profiles.sh"
source "${SCRIPTS}/lib/pr-cache.sh"

APEX_QUIET_SECS=${APEX_QUIET_SECS:-30}

# ─── tmux helpers ────────────────────────────────────────────────────

_die() { print -u2 "tmux-apex: $*"; exit 1; }

_cur_session() {
	tmux display-message -p '#S' 2>/dev/null
}

# Member identity is "<session>:<pane_id>" (e.g. "myworktree:%57"); a manager
# is identified by its bare session name. Tmux session names can't contain
# "%", so "contains :%" reliably distinguishes the two shapes.
_is_member() { [[ $1 == *:%* ]]; }
_member_session() { print -r -- "${1%%:*}"; }
_member_pane() { print -r -- "${1#*:}"; }

# _sopt/_sset resolve to pane-scoped options for a member id, session-scoped
# options for a bare session (manager) name.
_sopt() {
	if _is_member "$1"; then
		tmux show-option -p -t "$(_member_pane "$1")" -qv "$2" 2>/dev/null
	else
		tmux show-option -t "$1" -qv "$2" 2>/dev/null
	fi
}

_sset() {
	local target="$1" key="$2" val="$3"
	if _is_member "$target"; then
		tmux set-option -p -t "$(_member_pane "$target")" "$key" "$val"
	else
		tmux set-option -t "$target" "$key" "$val"
	fi
}

_session_alive() { tmux has-session -t="$1" 2>/dev/null; }

# A member is alive as long as its pane still exists — the session it lives
# in may host other members too, so session liveness alone isn't enough.
_member_alive() {
	if _is_member "$1"; then
		tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$(_member_pane "$1")"
	else
		_session_alive "$1"
	fi
}

# Does any pane in <session> already have a registered apex member on it?
_session_has_apex_member() {
	local p
	for p in ${(f)"$(tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null)"}; do
		[[ -n $(tmux show-option -p -t "$p" -qv @apex_role 2>/dev/null) ]] && return 0
	done
	return 1
}

_main_tree() {
	git -C "${1:-$PWD}" worktree list 2>/dev/null | awk 'NR==1{print $1}'
}

# For a member id the pane IS the identity — no indirection needed.
_agent_pane() {
	if _is_member "$1"; then
		_member_pane "$1"
	else
		_sopt "$1" @agent_pane
	fi
}

# Only ever send keys into a pane that is actually running an interactive agent —
# sending into a shell would execute the message as a command.
_pane_is_agent() {
	local pane="$1" cmd allow
	[[ -n $pane ]] || return 1
	tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$pane" || return 1
	cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
	allow=$(tmux show-option -gqv @tmux_delta_apex_agent_cmds 2>/dev/null)
	[[ -z $allow ]] && allow="node claude codex gemini"
	local -a allowed=(${=allow})
	(( ${allowed[(Ie)$cmd]} ))
}

# _send_to_pane <pane> <text> — one line, literal, then Enter.
_send_to_pane() {
	local pane="$1" text="$2"
	text=${text//$'\n'/ }
	text=${text//$'\r'/ }
	[[ -z $text ]] && return 1
	tmux send-keys -t "$pane" -l -- "$text" || return 1
	# tmux wraps a literal send in bracketed-paste; firing Enter in the same
	# instant lands mid-paste and gets dropped by some agent TUIs (observed
	# with codex — the message sits unsubmitted until a later, separate
	# Enter arrives). Give the pane a tick to finish processing the paste.
	sleep 0.2
	tmux send-keys -t "$pane" Enter
}

# ─── apex identity ──────────────────────────────────────────────────

# Manager session governing the current session (or itself if it is the manager).
_resolve_manager() {
	local s="${1:-$(_cur_session)}" role
	[[ -z $s ]] && return 1
	role=$(_sopt "$s" @apex_role)
	if [[ $role == manager ]]; then
		printf '%s' "$s"
		return 0
	fi
	local m
	m=$(_sopt "$s" @apex_session)
	[[ -n $m ]] && printf '%s' "$m" && return 0
	return 1
}

_require_manager() {
	local m
	m=$(_resolve_manager) || _die "no apex manager for this session. Run: tmux-apex.sh init"
	printf '%s' "$m"
}

# _cur_member — identity of whichever pane/session a hook or command is
# currently running in: the bare session name for a manager or an untracked
# pane, or "session:pane" for a pane registered as an apex member.
_cur_member() {
	local session pane
	session=$(_cur_session) || return 1
	[[ $(_sopt "$session" @apex_role) == manager ]] && { print -r -- "$session"; return 0; }
	pane="$TMUX_PANE"
	if [[ -n $pane ]] && [[ -n $(tmux show-option -p -t "$pane" -qv @apex_role 2>/dev/null) ]]; then
		print -r -- "${session}:${pane}"
		return 0
	fi
	print -r -- "$session"
}

# ─── facts about a member session ────────────────────────────────────

# _member_facts <session> — emits a JSON object of live, derived state.
_member_facts() {
	local session="$1" wt branch pr_number pr_state pr_draft icons ahead dirty alive
	alive=false
	_member_alive "$session" && alive=true

	wt=$(apex_member_get "$APEX_SESSION" "$session" worktree 2>/dev/null)
	[[ -z $wt || ! -d $wt ]] && wt=""

	branch=""; ahead=0; dirty=false
	if [[ -n $wt ]]; then
		branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)
		[[ -n $(git -C "$wt" status --porcelain 2>/dev/null) ]] && dirty=true
		ahead=$(git -C "$wt" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
		[[ -z $ahead ]] && ahead=0
	fi

	pr_number=""; pr_state=""; icons=""; pr_draft=""
	if [[ -n $wt && -n $branch ]]; then
		local rec
		rec=$(pr_cache_read "$wt" "$branch" 2>/dev/null)
		if [[ -n $rec ]]; then
			pr_number=$(printf '%s' "$rec" | jq -r '.pr_number // ""')
			pr_state=$(printf '%s' "$rec"  | jq -r '.state // ""')
			pr_draft=$(printf '%s' "$rec"  | jq -r '.is_draft // ""')
			icons=$(printf '%s' "$rec"     | jq -r '.icons // ""')
		fi
	fi

	local working attention
	working=$(_sopt "$session" @agent_working)
	attention=$(_sopt "$session" @agent_needs_attention)

	jq -nc \
		--arg session "$session" --arg wt "$wt" --arg branch "$branch" \
		--arg pr "$pr_number" --arg pr_state "$pr_state" --arg pr_draft "$pr_draft" \
		--arg icons "$icons" --argjson ahead "${ahead:-0}" \
		--argjson dirty "$dirty" --argjson alive "$alive" \
		--arg working "$working" --arg attention "$attention" \
		'{session:$session, alive:$alive, worktree:$wt, branch:$branch,
		  pr_number:$pr, pr_state:$pr_state, pr_draft:$pr_draft, pr_icons:$icons,
		  commits_ahead:$ahead, dirty:$dirty,
		  agent: (if $attention != "" then "needs-attention"
		          elif $working != "" then "working" else "idle" end)}'
}

# One-line human summary used in pings.
_facts_line() {
	printf '%s' "$1" | jq -r '
		[ (if .branch != "" then "branch=" + .branch else empty end),
		  (if .pr_number != "" then "pr=#" + .pr_number
		     + (if .pr_draft == "true" then "(draft)" else "" end)
		     + (if .pr_state != "" and .pr_state != "OPEN" then "(" + (.pr_state|ascii_downcase) + ")" else "" end)
		   else "pr=none" end),
		  ("commits_ahead=" + (.commits_ahead|tostring)),
		  (if .dirty then "uncommitted-changes" else empty end),
		  (if .alive|not then "SESSION-DEAD" else empty end)
		] | join(" ")'
}

# ─── init / stop ─────────────────────────────────────────────────────

_cmd_init() {
	local force=false a
	for a in "$@"; do [[ $a == --force ]] && force=true; done

	local session main other
	session=$(_cur_session) || _die "not inside tmux"
	main=$(_main_tree) || true
	[[ -z $main ]] && _die "not inside a git repository (run init from the repo you want to manage)"

	if [[ $force != true ]]; then
		for other in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"}; do
			[[ $other == "$session" ]] && continue
			[[ $(_sopt "$other" @apex_role) == manager ]] || continue
			[[ $(_sopt "$other" @apex_repo) == "$main" ]] || continue
			_die "session '$other' is already the apex manager for $main (use --force to take over)"
		done
	fi

	tmux set-option -t "$session" @apex_role manager
	tmux set-option -t "$session" @apex_repo "$main"
	# When init is run by the manager agent itself, $TMUX_PANE is that agent's
	# pane — the most reliable way to learn where to deliver pings.
	[[ -n $TMUX_PANE ]] && tmux set-option -t "$session" @agent_pane "$TMUX_PANE"

	apex_init_dirs "$session"
	apex_write_atomic "$(apex_file "$session")" \
		"$(jq -nc --arg s "$session" --arg r "$main" --arg p "${TMUX_PANE:-}" \
			--argjson t "$(date +%s)" \
			'{session:$s, repo:$r, agent_pane:$p, created_at:$t}')"
	apex_event "$session" "$(jq -nc --arg s "$session" '{event:"manager-init", session:$s}')"

	tmux refresh-client -S 2>/dev/null
	print "Apex manager active."
	print "  session : $session"
	print "  repo    : $main"
	print "  pane    : ${TMUX_PANE:-<unknown>}"
	print "  state   : $(apex_dir "$session")"
}

_cmd_stop() {
	local session
	session=$(_cur_session) || _die "not inside tmux"
	[[ $(_sopt "$session" @apex_role) == manager ]] || _die "this session is not an apex manager"
	tmux set-option -u -t "$session" @apex_role 2>/dev/null
	tmux set-option -u -t "$session" @apex_repo 2>/dev/null
	apex_event "$session" "$(jq -nc '{event:"manager-stop"}')"
	tmux refresh-client -S 2>/dev/null
	print "Apex mode off. Member sessions keep running; state kept at $(apex_dir "$session")"
}

# ─── relink (session-restart recovery) ───────────────────────────────

# relink — re-derive @apex_role/@apex_session/@apex_task/@apex_repo for the
# CURRENT session from durable state.
#
# @-options are tmux session options: they never survive a killed-and-
# recreated session (a crash, `claude --continue` picking the session back
# up, the picker reusing a session name). Durable state under $APEX_ROOT
# does survive, but nothing used to re-attach the two — a resumed manager
# lost its pink robot pill and its ability to resolve itself via
# `_require_manager`, and a resumed worker stopped reporting status at all
# (agent-tmux-status.sh gates on @apex_session being set). Same fragility
# class as the manager-ping bug above, one layer down.
#
# Called unconditionally, for every session, at the top of
# scripts/apex-manager-notify.sh (itself wired to every session's own
# UserPromptSubmit/SessionStart hooks) — ahead of that script's `pending`
# call, since determining whether this session is even a manager is the
# whole point. No-op for a session that already has a role, or that matches
# no durable state at all.
_cmd_relink() {
	local session pane
	session=$(_cur_session) || return 0
	pane="$TMUX_PANE"

	[[ $(_sopt "$session" @apex_role) == manager ]] && return 0   # manager already linked
	[[ -n $pane ]] && [[ -n $(tmux show-option -p -t "$pane" -qv @apex_role 2>/dev/null) ]] && return 0   # member already linked

	# Manager? Only if the most recent manager-init/manager-stop event for
	# this session's own state directory is an init — otherwise the human
	# deliberately ran `stop` on it, and resuming the session (e.g.
	# `--continue`) must not silently undo that. Also cross-check the repo
	# a reused session name could otherwise resurrect the wrong manager.
	if [[ -d "$(apex_dir "$session")" ]]; then
		local repo last
		repo=$(jq -r '.repo // empty' "$(apex_file "$session")" 2>/dev/null)
		last=$(jq -rs '[.[] | select(.event=="manager-init" or .event=="manager-stop")] | last | .event // empty' \
			"$(apex_events_file "$session")" 2>/dev/null)
		if [[ $last == manager-init && ( -z $repo || $repo == "$(_main_tree "$PWD")" ) ]]; then
			tmux set-option -t "$session" @apex_role manager
			[[ -n $repo ]] && tmux set-option -t "$session" @apex_repo "$repo"
			tmux refresh-client -S 2>/dev/null
			return 0
		fi
	fi

	# Worker/reviewer/monitor? Relink runs inside the member's own pane
	# (triggered by that pane's own hooks), so $TMUX_PANE is exactly the pane
	# needing to be re-linked — but after a session is destroyed and
	# recreated, old pane ids are gone, so a durable record's old
	# "session:oldpane" key can't be found by exact match. Match by
	# session-name prefix instead, and only act when unambiguous: more than
	# one member previously registered for this session can't be
	# disambiguated from here, and is left for manual recovery (respawn).
	[[ -z $pane ]] && return 0
	local f wt
	local -a matches=()
	for f in "$APEX_ROOT"/*/members/"${session}:"*.json(N); do
		wt=$(jq -r '.worktree // empty' "$f" 2>/dev/null)
		[[ -n $wt && $wt != "$PWD" ]] && continue
		matches+=("$f")
	done
	(( ${#matches} == 1 )) || return 0

	f="${matches[1]}"
	local manager role issue review_pr task old_key new_key
	manager="${f:h:h:t}"
	role=$(jq -r '.role // "worker"' "$f" 2>/dev/null)
	issue=$(jq -r '.issue // empty' "$f" 2>/dev/null)
	review_pr=$(jq -r '.review_pr // empty' "$f" 2>/dev/null)
	task="${issue:+issue:$issue}${review_pr:+pr:$review_pr}"

	tmux set-option -p -t "$pane" @apex_session "$manager"
	tmux set-option -p -t "$pane" @apex_role "$role"
	[[ -n $task ]] && tmux set-option -p -t "$pane" @apex_task "$task"

	old_key="${f:t:r}"
	new_key="${session}:${pane}"
	[[ $old_key != $new_key ]] && mv -f "$f" "$(apex_member_file "$manager" "$new_key")" 2>/dev/null

	tmux refresh-client -S 2>/dev/null
}

# ─── spawn ───────────────────────────────────────────────────────────

_cmd_spawn() {
	local issue="" review_pr="" role="worker" model="" perm="" mode="autonomous"
	local switch="no-switch" agent="" profile=""

	while (( $# )); do
		case "$1" in
			--issue)            issue="$2"; shift 2 ;;
			--review-pr)        review_pr="$2"; shift 2 ;;
			--role)             role="$2"; shift 2 ;;
			--agent)            agent="$2"; shift 2 ;;
			--model)            model="$2"; shift 2 ;;
			--profile)          profile="$2"; shift 2 ;;
			# --agent-flags is the accurate name: only claude calls this a
			# "permission mode". Both spellings feed the same slot.
			--permission-mode|--agent-flags) perm="$2"; shift 2 ;;
			--mode)             mode="$2"; shift 2 ;;
			--switch)           switch="switch"; shift ;;
			*) _die "spawn: unknown argument '$1'" ;;
		esac
	done

	[[ -n $issue || -n $review_pr ]] || _die "spawn: need --issue N or --review-pr N"
	[[ -n $issue && -n $review_pr ]] && _die "spawn: --issue and --review-pr are mutually exclusive"

	# A named profile fills in whichever of agent/model/agent-flags the caller
	# didn't already set explicitly — explicit flags always win field-by-field.
	# Must run before the bare-token-vs-non-claude-agent guard below, since a
	# profile can supply the very agent/perm values that guard inspects.
	if [[ -n $profile ]]; then
		local pjson rc
		pjson=$(apex_profile_resolve "$profile"); rc=$?
		case $rc in
			0) ;;
			1) _die "spawn: profile file missing: $(apex_profiles_repo_file)" ;;
			2) _die "spawn: malformed JSON in $(apex_profiles_repo_file)" ;;
			3) _die "spawn: malformed JSON in $(apex_profiles_user_file)" ;;
			*) _die "spawn: unknown profile '$profile' (see 'tmux-apex.sh profiles')" ;;
		esac
		[[ -z $agent ]] && agent=$(jq -r '.agent // empty' <<< "$pjson")
		[[ -z $model ]] && model=$(jq -r '.model // empty' <<< "$pjson")
		[[ -z $perm  ]] && perm=$(jq -r '.agent_flags // empty' <<< "$pjson")
	fi

	# Only the claude adapter accepts a bare token here (it prepends
	# --permission-mode). Every other agent gets the value as verbatim argv, so a
	# bare token would arrive as a stray positional and silently derail the
	# spawn. Refuse it loudly instead.
	if [[ -n $perm && $perm != -* && -n $agent && ${agent:t} != claude ]]; then
		_die "spawn: --agent-flags for '${agent}' must be agent-native argv (e.g. --approve, --full-auto), not the claude token '${perm}'"
	fi

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local -a envs=(
		"CODING_AGENT_ROLE=${role}"
		"CODING_AGENT_APEX_SESSION=${manager}"
	)
	[[ -n $agent ]] && envs+=("CODING_AGENT=${agent}")
	[[ -n $model ]] && envs+=("CODING_AGENT_MODEL=${model}")
	[[ -n $perm  ]] && envs+=("CODING_AGENT_PERMISSION_MODE=${perm}")

	local out
	if [[ -n $issue ]]; then
		out=$("${SCRIPTS}/tmux-picker.sh" --spawn-issue "$issue" "$mode" "$switch" "${envs[@]}") || _die "spawn failed"
	else
		local branch
		branch=$(gh pr view "$review_pr" --json headRefName --jq .headRefName 2>/dev/null)
		[[ -z $branch ]] && _die "spawn: could not resolve branch for PR #$review_pr"
		out=$("${SCRIPTS}/tmux-picker.sh" --spawn-pr-review "$branch" "$switch" "${envs[@]}") || _die "spawn failed"
	fi

	local line session worktree
	line=$(printf '%s\n' "$out" | awk -F'\t' '$1=="apex-session"' | tail -1)
	[[ -z $line ]] && { print -r -- "$out"; _die "spawn: picker did not report a session"; }
	session=$(printf '%s' "$line" | cut -f2)
	worktree=$(printf '%s' "$line" | cut -f3)

	# Member registration (pane-scoped @apex_role/@apex_task/@apex_session +
	# apex_member_merge) is no longer done here: the picker only knows a
	# session name at this point, not the agent's actual pane id (the first
	# agent pane in a fresh session is created asynchronously, inside that
	# session, by tmux-dev-layout.sh). Registration happens wherever the
	# pane is actually created — see tmux-apex.sh's `_register-member` and
	# its callers (tmux-dev-layout.sh for a fresh session, tmux-picker.sh's
	# _add_agent_pane for an extra pane in an already apex-tracked session,
	# which registers synchronously and so already reports a full
	# "session:pane" member id in $session here).
	apex_event "$manager" "$(jq -nc --arg s "$session" --arg role "$role" \
		--arg issue "$issue" --arg pr "$review_pr" \
		'{event:"spawn", session:$s, role:$role, issue:$issue, review_pr:$pr}')"

	print "Spawned ${role}: $session"
	print "  worktree : $worktree"
	print "  task     : ${issue:+issue #$issue}${review_pr:+PR #$review_pr}"
	print "  profile  : ${profile:-<none>}"
	print "  model    : ${model:-<default>}   permission-mode: ${perm:-<default>}"
}

# ─── register-member (called from wherever an agent pane is actually
#     created — tmux-dev-layout.sh for the first pane in a fresh session,
#     tmux-picker.sh's _add_agent_pane for an extra pane in an existing one)
#
# _register-member <pane_id> <manager> <role> <task> <worktree> [model] [perm] [mode] [agent] [profile] [issue] [pr]
_cmd_register_member() {
	local pane_id="$1" manager="$2" role="$3" task="$4" worktree="$5"
	local model="$6" perm="$7" mode="$8" agent="${9:-claude}" profile="${10}"
	local issue="${11}" pr="${12}"
	[[ -z $pane_id || -z $manager ]] && _die "_register-member: need <pane_id> <manager>"

	local session member
	session=$(tmux display-message -p -t "$pane_id" '#S' 2>/dev/null)
	[[ -z $session ]] && _die "_register-member: pane '$pane_id' not found"
	member="${session}:${pane_id}"

	tmux set-option -p -t "$pane_id" @apex_role "${role:-worker}"
	tmux set-option -p -t "$pane_id" @apex_session "$manager"
	[[ -n $task ]] && tmux set-option -p -t "$pane_id" @apex_task "$task"

	# Recorded durably (not just as the transient CODING_AGENT env var used to
	# pick an adapter at layout time) so `send` can later tell which agents
	# have a native session-message API — see _send_native.
	apex_member_merge "$manager" "$member" "$(jq -nc \
		--arg role "${role:-worker}" --arg wt "$worktree" --arg model "$model" \
		--arg perm "$perm" --arg mode "$mode" --arg agent "$agent" \
		--arg profile "$profile" --arg issue "$issue" --arg pr "$pr" \
		--argjson t "$(date +%s)" \
		'{role:$role, worktree:$wt, model:$model, permission_mode:$perm,
		  mode:$mode, agent:$agent, profile:$profile, issue:$issue, review_pr:$pr,
		  status:"starting", seq:0, pinged_seq:-1,
		  spawned_at:$t, updated_at:$t}')"

	apex_event "$manager" "$(jq -nc --arg s "$member" --arg role "${role:-worker}" \
		--arg issue "$issue" --arg pr "$pr" \
		'{event:"register", session:$s, role:$role, issue:$issue, review_pr:$pr}')"

	tmux refresh-client -S 2>/dev/null
}

# ─── native message delivery (codex/opencode) ─────────────────────────

# _codex_thread_for <worktree> — newest codex session id whose recorded cwd
# matches <worktree>, or nothing if none found. Codex writes a session_meta
# record as the first line of every rollout file under
# $CODEX_HOME/sessions/**, including the cwd it started in — durable state
# that already exists for free, no capture-at-spawn plumbing needed.
_codex_thread_for() {
	local wt="$1" home f
	[[ -z $wt ]] && return 1
	home="${CODEX_HOME:-$HOME/.codex}"
	for f in "$home"/sessions/*/*/*/rollout-*.jsonl(Nom); do
		jq -e --arg wt "$wt" \
			'select(.type=="session_meta" and .payload.cwd==$wt)' \
			<(head -n1 "$f") >/dev/null 2>&1 || continue
		jq -r '.payload.session_id' <(head -n1 "$f")
		return 0
	done
	return 1
}

# _opencode_session_for <worktree> — most recently updated opencode session
# whose exact starting directory is <worktree>. `opencode session list`
# looked like the obvious way to ask this, but it groups by git project
# (repo root) rather than exact directory — every worktree of the same repo
# gets the identical list back, which is useless here since apex's whole
# model is sibling worktrees of one repo (verified against two real
# worktrees: `session list` was byte-identical from both). opencode's own
# sqlite store does record the exact directory a session was started in
# (the `session.directory` column), so read that directly instead.
_opencode_session_for() {
	local wt="$1" db esc id
	[[ -d $wt ]] || return 1
	db="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
	[[ -f $db ]] || return 1
	esc=${wt//\'/\'\'}
	id=$(sqlite3 -readonly "$db" \
		"select id from session where directory = '${esc}' order by time_updated desc limit 1;" 2>/dev/null)
	[[ -n $id ]] || return 1
	printf '%s' "$id"
}

# _send_native <agent> <worktree> <text> — deliver via the agent's own
# out-of-band session-message API instead of tmux keystrokes, for the two
# agents that have one. Returns 1 (caller falls back to send-keys) for any
# other agent, or when no session id can be resolved for <worktree>.
#
# codex: `queue` hands the message to the shared app-server daemon and
# returns immediately — verified live against a running interactive codex
# session: a queued message showed up as a new turn in the same pane and
# was acted on, no keystrokes involved. Runs synchronously with a short
# timeout and reports failure honestly on a non-zero exit.
#
# opencode: `run -s ID -c` was verified live the same way, with one real
# caveat — it does append to the *same* session (confirmed via opencode's
# own sqlite store: one session, messages in order) and the agent does act
# on it (asked to recall its reply, it could), but the already-running
# interactive TUI in the worker's pane never visually refreshes to render
# that exchange — a human tmux-attaching to the pane right after a `send`
# will not see it there, only in `status --json`'s events, until they
# interact with that TUI again themselves. Also, unlike codex's queue,
# `run` most likely blocks for the full agent turn rather than just
# enqueuing, so it's backgrounded rather than run synchronously — this can
# only confirm the message was handed off, not that it was acted on, same
# as the send-keys path it replaces.
_send_native() {
	local agent="$1" wt="$2" text="$3" id
	case "$agent" in
		codex)
			id=$(_codex_thread_for "$wt") || return 1
			timeout 8 codex queue --thread "$id" --message "$text" >/dev/null 2>&1
			;;
		opencode)
			id=$(_opencode_session_for "$wt") || return 1
			( cd "$wt" && opencode run -s "$id" -c "$text" >/dev/null 2>&1 &! )
			;;
		*) return 1 ;;
	esac
}

# ─── send ────────────────────────────────────────────────────────────

_cmd_send() {
	local target="$1"; shift
	[[ -z $target ]] && _die "send: usage: send <session> <text>"
	local text="$*"
	[[ -z $text ]] && _die "send: empty message"

	_member_alive "$target" || _die "send: session '$target' is not running"

	local from full
	from=$(_cur_session 2>/dev/null)
	full="[apex from:${from:-manager}] ${text}"

	# Native delivery only applies to a tracked apex member — anything else
	# (a hand-run session, or an agent with no native API) falls straight
	# through to the tmux send-keys path exactly as before.
	local manager agent wt pane delivered=false
	manager=$(_resolve_manager "$target" 2>/dev/null)
	if [[ -n $manager ]]; then
		agent=$(apex_member_get "$manager" "$target" agent)
		wt=$(apex_member_get "$manager" "$target" worktree)
		_send_native "$agent" "$wt" "$full" && delivered=true
	fi

	if ! $delivered; then
		pane=$(_agent_pane "$target")
		[[ -n $pane ]] || _die "send: session '$target' has no @agent_pane (no coding agent split?)"
		_pane_is_agent "$pane" || _die "send: pane $pane of '$target' is not running a coding agent — refusing to send"
		_send_to_pane "$pane" "$full" || _die "send: delivery failed"
	fi

	[[ -z $manager ]] && manager="$from"
	[[ -n $manager ]] && apex_event "$manager" "$(jq -nc \
		--arg s "$target" --arg from "$from" --arg text "$text" \
		'{event:"send", session:$s, from:$from, text:$text}')"

	if $delivered; then
		print "Delivered to $target (native: $agent)."
	else
		print "Delivered to $target ($pane)."
	fi
}

# ─── event reporting (called from agent-tmux-status.sh hooks) ────────

# _record_status <manager> <session> <status>
#
# Durable log entry only — this never touches the manager's pane. Delivery
# into the manager's own context is pull-based: see `pending` below and
# scripts/apex-manager-notify.sh, wired to the manager's own
# UserPromptSubmit/SessionStart hooks. That split is the fix for the
# manager-pane collision bug (issue #5) — a keystroke injected here could
# splice into a human's in-flight input (or ghost autosuggestion text) with
# no way to tell the two apart from outside the pane, so nothing here ever
# writes to one.
_record_status() {
	local manager="$1" session="$2" st="$3"
	local role task facts summary
	role=$(_sopt "$session" @apex_role); [[ -z $role ]] && role=worker
	task=$(_sopt "$session" @apex_task)
	facts=$(_member_facts "$session")
	summary=$(_facts_line "$facts")

	apex_event "$manager" "$(jq -nc --arg s "$session" --arg st "$st" --arg sum "$summary" \
		'{event:"status", session:$s, status:$st, summary:$sum}')"
}

# event <set|notify|clear> — invoked in the member session's own context.
_cmd_event() {
	local verb="$1"
	local session manager
	session=$(_cur_member) || return 0
	manager=$(_sopt "$session" @apex_session)
	[[ -n $manager ]] || return 0            # not an apex member; nothing to do
	APEX_SESSION="$manager"

	local seq st
	seq=$(apex_member_bump_seq "$manager" "$session")

	case "$verb" in
		set)    st=working ;;
		notify) st=attention ;;
		clear)  st=idle ;;
		*)      return 0 ;;
	esac

	apex_member_merge "$manager" "$session" "$(jq -nc \
		--arg st "$st" --argjson seq "$seq" --argjson t "$(date +%s)" \
		'{status:$st, seq:$seq, updated_at:$t}')"

	case "$verb" in
		notify)
			# Blocked and waiting on input — record it now. The manager isn't
			# pushed this; it picks it up via `pending` on its next turn or on
			# resume (see scripts/apex-manager-notify.sh).
			_record_status "$manager" "$session" attention
			;;
		clear)
			# Stop fires at the end of EVERY assistant turn. Only record once the
			# session has actually settled: re-check the sequence number after a
			# quiet window. run-shell -d defers inside the tmux server, so this
			# outlives the short-lived hook process without a sleeping watcher.
			tmux run-shell -b -d "$APEX_QUIET_SECS" \
				"${SELF} _settle ${(q)session} ${(q)manager} ${seq}" 2>/dev/null
			;;
	esac
}

# _settle <session> <manager> <seq> — internal, fired by run-shell -d.
#
# settled_seq dedupes this specific durable write (avoids one events.jsonl
# entry per settle callback if several were scheduled back to back). It is
# deliberately a separate field from pinged_seq: pinged_seq now tracks what
# the manager has actually pulled via `pending`, not what this function has
# attempted to record.
_cmd_settle() {
	local session="$1" manager="$2" seq="$3"
	APEX_SESSION="$manager"
	[[ $(apex_member_get "$manager" "$session" seq) == "$seq" ]] || return 0
	[[ $(apex_member_get "$manager" "$session" settled_seq) == "$seq" ]] && return 0
	apex_member_merge "$manager" "$session" "$(jq -nc --argjson seq "$seq" '{settled_seq:$seq}')"
	_record_status "$manager" "$session" idle
}

# ─── status ──────────────────────────────────────────────────────────

_cmd_status() {
	local as_json=false a
	for a in "$@"; do [[ $a == --json ]] && as_json=true; done

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local -a rows=()
	local s facts stored merged
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		facts=$(_member_facts "$s")
		stored=$(cat "$(apex_member_file "$manager" "$s")" 2>/dev/null)
		[[ -z $stored ]] && stored='{}'
		merged=$(printf '%s\n%s\n' "$stored" "$facts" | jq -s '.[0] * .[1]')
		rows+=("$merged")
	done

	if $as_json; then
		local events
		events=$(tail -n 40 "$(apex_events_file "$manager")" 2>/dev/null | jq -sc '.' 2>/dev/null)
		[[ -z $events ]] && events='[]'
		printf '%s\n' "${rows[@]}" \
			| jq -s --arg m "$manager" --argjson ev "$events" \
				'{manager:$m, members:., recent_events:$ev}'
		return
	fi

	print "Apex manager: $manager"
	print "State: $(apex_dir "$manager")"
	if (( ${#rows} == 0 )); then
		print "\nNo members yet. Spawn one with: ${SELF##*/} spawn --issue N"
		return
	fi
	print ""
	printf '%-34s %-8s %-10s %-12s %s\n' SESSION ROLE AGENT TASK STATE
	local r
	for r in "${rows[@]}"; do
		printf '%s' "$r" | jq -r '
			[ .session,
			  (.role // "?"),
			  (if .alive then (.agent // "?") else "dead" end),
			  ((if .issue != "" and .issue != null then "issue#" + .issue
			    elif .review_pr != "" and .review_pr != null then "pr#" + .review_pr
			    else "-" end)),
			  ([ (if .branch != "" then .branch else empty end),
			     (if .pr_number != "" then "PR#" + .pr_number
			        + (if .pr_draft == "true" then " draft" else "" end)
			        + (if .pr_state != "" and .pr_state != "OPEN" then " " + (.pr_state|ascii_downcase) else "" end)
			      else empty end),
			     (if .commits_ahead > 0 then (.commits_ahead|tostring) + " ahead" else empty end),
			     (if .dirty then "dirty" else empty end) ] | join(", "))
			] | @tsv' \
		| while IFS=$'\t' read -r c1 c2 c3 c4 c5; do
			printf '%-34s %-8s %-10s %-12s %s\n' "$c1" "$c2" "$c3" "$c4" "$c5"
		done
	done
	print "\nRecent events:"
	tail -n 8 "$(apex_events_file "$manager")" 2>/dev/null \
		| jq -r '"  " + (.at|todate) + "  " + .event + "  " + (.session // "")' 2>/dev/null
}

# ─── pending ─────────────────────────────────────────────────────────

# pending [--mark-delivered] — one summary line per member whose current
# idle/attention status hasn't been delivered to the manager yet.
#
# This is the entire delivery mechanism for manager pings (see `_record_status`
# above): scripts/apex-manager-notify.sh calls this from the manager's own
# UserPromptSubmit/SessionStart hooks and hands the output to Claude as
# context, so a human can run it by hand for the same view the manager gets.
# Read-only unless --mark-delivered is passed, in which case each reported
# member's pinged_seq is advanced to its current seq so it isn't reported
# again next time.
#
# Only idle/attention are ever reported — a member mid-turn ("working" or
# "starting") has nothing actionable to say yet, and reporting on every seq
# bump would spam every intermediate transition instead of just the state
# that matters when the manager actually looks.
_cmd_pending() {
	local mark=false a
	for a in "$@"; do [[ $a == --mark-delivered ]] && mark=true; done

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local s st seq pinged role task facts summary
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		st=$(apex_member_get "$manager" "$s" status)
		[[ $st == idle || $st == attention ]] || continue

		seq=$(apex_member_get "$manager" "$s" seq); [[ -z $seq ]] && seq=0
		pinged=$(apex_member_get "$manager" "$s" pinged_seq); [[ -z $pinged ]] && pinged=-1
		(( seq == pinged )) && continue

		role=$(_sopt "$s" @apex_role); [[ -z $role ]] && role=worker
		task=$(_sopt "$s" @apex_task)
		facts=$(_member_facts "$s")
		summary=$(_facts_line "$facts")

		print "[apex] session=${s} role=${role} ${task:+task=${task} }status=${st} — ${summary}. Full state: ${SELF} status --json"

		$mark && apex_member_merge "$manager" "$s" "$(jq -nc --argjson seq "$seq" '{pinged_seq:$seq}')"
	done
}

# ─── reap ────────────────────────────────────────────────────────────

_cmd_reap() {
	local yes=false a
	for a in "$@"; do [[ $a == --yes ]] && yes=true; done

	local manager
	manager=$(_require_manager)
	APEX_SESSION="$manager"

	local -a done_members=()
	local s facts alive pr_state
	for s in ${(f)"$(apex_members "$manager")"}; do
		[[ -z $s ]] && continue
		facts=$(_member_facts "$s")
		alive=$(printf '%s' "$facts" | jq -r '.alive')
		pr_state=$(printf '%s' "$facts" | jq -r '.pr_state')
		if [[ $alive == false || $pr_state == MERGED || $pr_state == CLOSED ]]; then
			done_members+=("$s")
			print "  $s  — $(_facts_line "$facts")"
		fi
	done

	if (( ${#done_members} == 0 )); then
		print "Nothing to reap."
		return
	fi

	if ! $yes; then
		print "\n${#done_members} member(s) finished. Re-run with --yes to remove their worktrees and sessions."
		return
	fi

	local wt session
	for s in "${done_members[@]}"; do
		wt=$(apex_member_get "$manager" "$s" worktree)
		session=$(_member_session "$s")

		tmux kill-pane -t "$(_member_pane "$s")" 2>/dev/null
		rm -f "$(apex_member_file "$manager" "$s")"
		apex_event "$manager" "$(jq -nc --arg s "$s" '{event:"reap", session:$s}')"
		print "Reaped $s"

		# Only clean up the shared worktree/session once no other apex member
		# (e.g. a worker, if we just reaped a reviewer) still owns a pane there.
		_session_has_apex_member "$session" && continue
		if [[ -n $wt && -d $wt ]]; then
			TMUX_DELTA_ASSUME_YES=1 "${SCRIPTS}/tmux-picker.sh" --delete-wt "wt:${wt}" >/dev/null 2>&1
		else
			tmux kill-session -t "$session" 2>/dev/null
		fi
	done
}

_cmd_profiles() {
	local rows rc
	rows=$(apex_profiles_list); rc=$?
	case $rc in
		0) ;;
		1) _die "profiles: missing $(apex_profiles_repo_file)" ;;
		2) _die "profiles: malformed JSON in $(apex_profiles_repo_file)" ;;
		3) _die "profiles: malformed JSON in $(apex_profiles_user_file)" ;;
	esac
	[[ -z $rows ]] && { print "No profiles defined."; return; }
	print -r -- "$rows" | awk -F'\t' '{printf "  %-10s agent=%-9s model=%-16s flags=%-20s %s\n", $1, $2, $3, $4, $5}'
}

# ─── dispatch ────────────────────────────────────────────────────────

case "${1:-}" in
	init)     shift; _cmd_init "$@" ;;
	stop)     shift; _cmd_stop "$@" ;;
	relink)   shift; _cmd_relink "$@" ;;
	spawn)    shift; _cmd_spawn "$@" ;;
	send)     shift; _cmd_send "$@" ;;
	event)    shift; _cmd_event "$@" ;;
	status)   shift; _cmd_status "$@" ;;
	pending)  shift; _cmd_pending "$@" ;;
	reap)     shift; _cmd_reap "$@" ;;
	profiles) shift; _cmd_profiles "$@" ;;
	_settle)  shift; _cmd_settle "$@" ;;
	_register-member) shift; _cmd_register_member "$@" ;;
	*)
		print "tmux-apex.sh — apex mode for tmux-delta"
		print ""
		print "  init [--force]                 mark this session as the apex manager"
		print "  stop                           leave manager mode (members keep running)"
		print "  relink                         re-derive role/linkage after a session restart"
		print "  spawn --issue N [opts]         spawn a worker on a GitHub issue"
		print "  spawn --review-pr N [opts]     spawn a reviewer on a pull request"
		print "      opts: --profile NAME       named {agent,model,agent-flags} preset (see 'profiles')"
		print "            --role worker|monitor --agent claude|pi|codex|opencode"
		print "            --model M"
		print "            --agent-flags ARGV --mode autonomous|interactive --switch"
		print "  send <session> <text>          message a session's coding agent"
		print "  status [--json]                state of every member"
		print "  pending [--mark-delivered]     members not yet delivered to the manager"
		print "  reap [--yes]                   clean up finished/dead members"
		print "  profiles                       list available spawn profiles"
		[[ -n ${1:-} ]] && exit 1
		;;
esac
