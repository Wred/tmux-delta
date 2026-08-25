#!/usr/bin/env zsh

# tmux-apex.sh — apex mode for tmux-delta.
#
# One tmux session hosts a "manager" coding agent that spawns, tracks and
# instructs "worker"/"monitor" agent sessions created through the normal
# tmux-delta picker machinery (worktree + session + dev layout).
#
# Transport is tmux itself: per-session @-options carry role metadata,
# send-keys carries messages, and a JSON state tree under
# $XDG_CACHE_HOME/tmux-delta/apex survives agent context compaction.
#
# Subcommands: init stop spawn send event status reap

SELF="${0:A}"
SCRIPTS="${SELF:h}"

source "${SCRIPTS}/lib/apex-state.sh"
source "${SCRIPTS}/lib/pr-cache.sh"

APEX_QUIET_SECS=${APEX_QUIET_SECS:-30}

# ─── tmux helpers ────────────────────────────────────────────────────

_die() { print -u2 "tmux-apex: $*"; exit 1; }

_cur_session() {
	tmux display-message -p '#S' 2>/dev/null
}

_sopt() { tmux show-option -t "$1" -qv "$2" 2>/dev/null; }

_session_alive() { tmux has-session -t="$1" 2>/dev/null; }

_main_tree() {
	git -C "${1:-$PWD}" worktree list 2>/dev/null | awk 'NR==1{print $1}'
}

# The pane running the coding agent for a session (published by tmux-dev-layout.sh).
_agent_pane() { _sopt "$1" @agent_pane; }

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

# ─── facts about a member session ────────────────────────────────────

# _member_facts <session> — emits a JSON object of live, derived state.
_member_facts() {
	local session="$1" wt branch pr_number pr_state pr_draft icons ahead dirty alive
	alive=false
	_session_alive "$session" && alive=true

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

# ─── spawn ───────────────────────────────────────────────────────────

_cmd_spawn() {
	local issue="" review_pr="" role="worker" model="" perm="" mode="autonomous"
	local switch="no-switch" agent=""

	while (( $# )); do
		case "$1" in
			--issue)            issue="$2"; shift 2 ;;
			--review-pr)        review_pr="$2"; shift 2 ;;
			--role)             role="$2"; shift 2 ;;
			--agent)            agent="$2"; shift 2 ;;
			--model)            model="$2"; shift 2 ;;
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

	tmux set-option -t "$session" @apex_role "$role"
	tmux set-option -t "$session" @apex_session "$manager"
	tmux set-option -t "$session" @apex_task "${issue:+issue:$issue}${review_pr:+pr:$review_pr}"

	apex_member_merge "$manager" "$session" "$(jq -nc \
		--arg role "$role" --arg wt "$worktree" --arg model "$model" \
		--arg perm "$perm" --arg mode "$mode" \
		--arg issue "$issue" --arg pr "$review_pr" \
		--argjson t "$(date +%s)" \
		'{role:$role, worktree:$wt, model:$model, permission_mode:$perm,
		  mode:$mode, issue:$issue, review_pr:$pr,
		  status:"starting", seq:0, pinged_seq:-1,
		  spawned_at:$t, updated_at:$t}')"

	apex_event "$manager" "$(jq -nc --arg s "$session" --arg role "$role" \
		--arg issue "$issue" --arg pr "$review_pr" \
		'{event:"spawn", session:$s, role:$role, issue:$issue, review_pr:$pr}')"

	print "Spawned ${role}: $session"
	print "  worktree : $worktree"
	print "  task     : ${issue:+issue #$issue}${review_pr:+PR #$review_pr}"
	print "  model    : ${model:-<default>}   permission-mode: ${perm:-<default>}"
}

# ─── send ────────────────────────────────────────────────────────────

_cmd_send() {
	local target="$1"; shift
	[[ -z $target ]] && _die "send: usage: send <session> <text>"
	local text="$*"
	[[ -z $text ]] && _die "send: empty message"

	_session_alive "$target" || _die "send: session '$target' is not running"

	local pane
	pane=$(_agent_pane "$target")
	[[ -n $pane ]] || _die "send: session '$target' has no @agent_pane (no coding agent split?)"
	_pane_is_agent "$pane" || _die "send: pane $pane of '$target' is not running a coding agent — refusing to send"

	local from
	from=$(_cur_session 2>/dev/null)
	_send_to_pane "$pane" "[apex from:${from:-manager}] ${text}" \
		|| _die "send: delivery failed"

	local manager
	manager=$(_resolve_manager "$target" 2>/dev/null) || manager="$from"
	[[ -n $manager ]] && apex_event "$manager" "$(jq -nc \
		--arg s "$target" --arg from "$from" --arg text "$text" \
		'{event:"send", session:$s, from:$from, text:$text}')"

	print "Delivered to $target ($pane)."
}

# ─── event reporting (called from agent-tmux-status.sh hooks) ────────

# _ping_manager <manager> <session> <status>
_ping_manager() {
	local manager="$1" session="$2" st="$3"
	APEX_SESSION="$manager"

	local pane
	pane=$(_agent_pane "$manager")
	if ! _pane_is_agent "$pane"; then
		apex_event "$manager" "$(jq -nc --arg s "$session" --arg p "${pane:-}" \
			'{event:"ping-skipped", session:$s, pane:$p, reason:"manager pane is not an agent"}')"
		return 1
	fi

	local role task facts summary line
	role=$(_sopt "$session" @apex_role); [[ -z $role ]] && role=worker
	task=$(_sopt "$session" @apex_task)
	facts=$(_member_facts "$session")
	summary=$(_facts_line "$facts")

	line="[apex] session=${session} role=${role} ${task:+task=${task} }status=${st} — ${summary}. Full state: ${SELF} status --json"

	if _send_to_pane "$pane" "$line"; then
		apex_event "$manager" "$(jq -nc --arg s "$session" --arg st "$st" --arg l "$line" \
			'{event:"ping", session:$s, status:$st, message:$l}')"
	else
		apex_event "$manager" "$(jq -nc --arg s "$session" \
			'{event:"ping-failed", session:$s}')"
	fi
}

# event <set|notify|clear> — invoked in the member session's own context.
_cmd_event() {
	local verb="$1"
	local session manager
	session=$(_cur_session) || return 0
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
			# Blocked and waiting on input — tell the manager straight away.
			_ping_manager "$manager" "$session" attention
			;;
		clear)
			# Stop fires at the end of EVERY assistant turn. Only ping once the
			# session has actually settled: re-check the sequence number after a
			# quiet window. run-shell -d defers inside the tmux server, so this
			# outlives the short-lived hook process without a sleeping watcher.
			tmux run-shell -b -d "$APEX_QUIET_SECS" \
				"${SELF} _settle ${(q)session} ${(q)manager} ${seq}" 2>/dev/null
			;;
	esac
}

# _settle <session> <manager> <seq> — internal, fired by run-shell -d.
_cmd_settle() {
	local session="$1" manager="$2" seq="$3"
	APEX_SESSION="$manager"
	[[ $(apex_member_get "$manager" "$session" seq) == "$seq" ]] || return 0
	[[ $(apex_member_get "$manager" "$session" pinged_seq) == "$seq" ]] && return 0
	apex_member_merge "$manager" "$session" "$(jq -nc --argjson seq "$seq" '{pinged_seq:$seq}')"
	_ping_manager "$manager" "$session" idle
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

	local wt
	for s in "${done_members[@]}"; do
		wt=$(apex_member_get "$manager" "$s" worktree)
		if [[ -n $wt && -d $wt ]]; then
			TMUX_DELTA_ASSUME_YES=1 "${SCRIPTS}/tmux-picker.sh" --delete-wt "wt:${wt}" >/dev/null 2>&1
		else
			tmux kill-session -t "$s" 2>/dev/null
		fi
		rm -f "$(apex_member_file "$manager" "$s")"
		apex_event "$manager" "$(jq -nc --arg s "$s" '{event:"reap", session:$s}')"
		print "Reaped $s"
	done
}

# ─── dispatch ────────────────────────────────────────────────────────

case "${1:-}" in
	init)     shift; _cmd_init "$@" ;;
	stop)     shift; _cmd_stop "$@" ;;
	spawn)    shift; _cmd_spawn "$@" ;;
	send)     shift; _cmd_send "$@" ;;
	event)    shift; _cmd_event "$@" ;;
	status)   shift; _cmd_status "$@" ;;
	reap)     shift; _cmd_reap "$@" ;;
	_settle)  shift; _cmd_settle "$@" ;;
	*)
		print "tmux-apex.sh — apex mode for tmux-delta"
		print ""
		print "  init [--force]                 mark this session as the apex manager"
		print "  stop                           leave manager mode (members keep running)"
		print "  spawn --issue N [opts]         spawn a worker on a GitHub issue"
		print "  spawn --review-pr N [opts]     spawn a reviewer on a pull request"
		print "      opts: --role worker|monitor --agent claude|pi|codex|opencode"
		print "            --model M"
		print "            --agent-flags ARGV --mode autonomous|interactive --switch"
		print "  send <session> <text>          message a session's coding agent"
		print "  status [--json]                state of every member"
		print "  reap [--yes]                   clean up finished/dead members"
		[[ -n ${1:-} ]] && exit 1
		;;
esac
