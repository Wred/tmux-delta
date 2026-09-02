# apex-authority.sh — per-repo merge authority for apex mode (github issue #41).
#
# Merge authority used to be a property of the *skill*: the apex agent, in any
# repo, could merge any PR that met a list of mechanical criteria. That grant was
# decided for one repo — single owner, single reviewer, owner asking for it — and
# it does not travel. The criteria are all mechanical (checks green, branch
# current, scope matches, no weakened tests) and none of them can see a team
# norm: that someone expects to review before a change lands, that a release has
# a process, that shared ownership means "the criteria are met" is not the same
# sentence as "this is mine to merge". No amount of strengthening the criteria
# fixes it, because what is repo-scoped is the authority, not the checks.
#
# So the grant is recorded per repo, and it is **fail-closed**: every answer is a
# boolean, the default is not granted, and every way of failing to get an answer
# — no file, unreadable file, malformed JSON, a key nobody has answered, a value
# that is not literally `true` — resolves to *not granted*. Apex then reports a
# qualifying PR as ready-and-ineligible and the human merges it.
#
# Two independent axes, because they are two different questions:
#
#   merge        may apex merge a PR an independent reviewer signed off on?
#   self_review  may it also merge on the strength of its own reading?
#
# The second is gated separately on the repo owner's decision, and the reasoning
# is worth keeping: the skill can only ever *prefer* that apex spawn a reviewer,
# and a preference is advice an agent can talk itself out of, where a gate cannot.
# `self_review` is meaningless without `merge`, so it is refused unless `merge` is
# granted, and revoking `merge` clears it — a stale yes must not come back to life
# the next time someone re-grants the merge axis.
#
# Each axis is a plain boolean and neither is shaped ("my workers' PRs only"):
# that was settled as unnecessary, since apex only merges PRs its own workers
# opened. `apex_authority_get` treats any non-boolean value it does not recognise
# as ungranted, so a future version that writes a shape cannot be read as
# permission by this one.
#
# Storage is one file shared by every manager session:
#
#   $APEX_ROOT/authority.json
#   {"grants": {"<repo-key>": {"merge":true, "self_review":false,
#                              "at":1234, "by":"session", "path":"/…"}}}
#
# Shared rather than per-manager-session because the point is to be answered once
# per repo, not once per session: session names get recycled, killed and
# recreated, and a grant living under $APEX_ROOT/<manager>/ would silently revert
# to the default every time a manager came back under a new name. Nothing caches
# the answer onto a tmux option either — every reader resolves it from this file,
# so `relink` re-derives it for free and there is no second copy to drift.

APEX_AUTHORITY_FILE() { printf '%s/authority.json' "$APEX_ROOT"; }

# apex_repo_key [dir] — stable trust-context identity for a repo.
#
# The origin URL, normalised: user, scheme, trailing .git and case all dropped,
# leaving e.g. `github.com/wred/tmux-delta`. Keyed on the URL rather than on the
# directory name or the main worktree path because a fork and its upstream are
# different trust contexts that share a name — you may well merge in your fork
# and have no business merging in theirs — and because the same repo cloned twice
# (or worked in from a linked worktree, as every apex worker is) should not need
# answering again per clone.
#
# Falls back to `path:<main worktree>` when there is no origin: a local-only repo
# has no upstream to be confused with, and the path is all that identifies it.
# Prints nothing and fails when the directory is not a git repository at all —
# callers must treat that as ungranted rather than as an empty key, since an
# empty key would otherwise collide across every non-repo directory.
apex_repo_key() {
	setopt localoptions no_err_return
	local dir="${1:-$PWD}" url main
	url=$(git -C "$dir" remote get-url origin 2>/dev/null)
	if [[ -n $url ]]; then
		url="${url##*@}"                  # strip user@ (scp form and https creds)
		url="${url##*://}"                # strip scheme://
		# scp-form colon → slash. Written as a split rather than a substitution
		# because zsh reads `\/` in a replacement as a literal backslash, which
		# silently produced keys like `github.com\/wred/repo`.
		[[ $url == *:* ]] && url="${url%%:*}/${url#*:}"
		url="${url%.git}"
		url="${url%/}"
		while [[ $url == *//* ]]; do url="${url//\/\///}"; done
		printf '%s' "${url:l}"
		return 0
	fi
	main=$(git -C "$dir" worktree list 2>/dev/null | awk 'NR==1{print $1}')
	[[ -n $main ]] || return 1
	printf 'path:%s' "${main:A}"
}

# apex_authority_normalise <word> — CLI spelling → stored boolean, or fail.
# Accepts only unambiguous answers; "maybe", "reviewed", "" and anything else
# fail, and a failed parse is an error at the CLI rather than a silent `no`.
apex_authority_normalise() {
	case "${1:l}" in
		yes|y|true|grant|granted|on)   print -r -- yes ;;
		no|n|false|none|revoke|off)    print -r -- no ;;
		*) return 1 ;;
	esac
}

# apex_authority_get <repo-key> [axis] — `yes` or `no`, never anything else.
# axis defaults to `merge`; the other is `self_review`.
#
# Every failure path prints `no`. A missing file, a file we cannot parse, a repo
# nobody has answered for, and a value that is not literally JSON `true` all mean
# "not granted" rather than "assume the permissive thing" — that is the whole
# design of this file, so it is one code path with no exceptions.
#
# `self_review` additionally requires `merge`: the axes are stored independently,
# but a self-review grant on a repo where apex may not merge at all authorises
# nothing, and reading it as authority on its own would be the one way to get a
# merge out of this file that the merge axis never permitted.
apex_authority_get() {
	setopt localoptions no_err_return
	local key="$1" axis="${2:-merge}" f v
	f=$(APEX_AUTHORITY_FILE)
	[[ -n $key && -r $f ]] || { print -r -- no; return 0 }
	# `== true` and not `tostring`/truthiness: jq's equality is type-strict, so
	# the *string* "true", the number 1 and a future shaped grant all compare
	# false here. A truthiness test would read every one of them as permission.
	if [[ $axis == self_review ]]; then
		v=$(jq -r --arg k "$key" \
			'if (.grants[$k].merge == true) and (.grants[$k].self_review == true)
			 then "yes" else "no" end' "$f" 2>/dev/null) || v=no
	else
		v=$(jq -r --arg k "$key" 'if .grants[$k].merge == true then "yes" else "no" end' \
			"$f" 2>/dev/null) || v=no
	fi
	[[ $v == yes ]] && { print -r -- yes; return 0 }
	print -r -- no
}

# Predicate forms, for `if` at call sites.
apex_authority_may_merge()       { [[ $(apex_authority_get "$1") == yes ]] }
apex_authority_may_self_review() { [[ $(apex_authority_get "$1" self_review) == yes ]] }

# apex_authority_answered <repo-key> — true when a human recorded an answer for
# this repo, whichever way it went. Distinct from `get` returning `no`, which is
# also what "nobody has been asked" looks like: `init` needs to know whether to
# ask, and `doctor` needs to say "never granted" differently from "declined".
#
# Keyed on the merge axis only. A repo can have been asked about merging and not
# about self-review (that question is only put once merging is granted), so the
# merge axis is the one that says whether the conversation happened at all.
apex_authority_answered() {
	setopt localoptions no_err_return
	local f v
	f=$(APEX_AUTHORITY_FILE)
	[[ -n $1 && -r $f ]] || return 1
	v=$(jq -r --arg k "$1" '.grants[$k].merge | type' "$f" 2>/dev/null) || return 1
	[[ $v == boolean ]]
}

# _apex_authority_read — the current store, or `{"grants":{}}` if there is none.
#
# Distinguishes *absent* from *unreadable*, which the first cut of this did not:
# it collapsed both to an empty base, so a write landing on a truncated file
# silently discarded every other repo's answer and returned 0. The direction was
# still fail-closed — nothing gained permission — but it destroyed deliberate
# revokes as readily as grants and re-asked the human in repos they had already
# answered, for a feature whose entire value is that their answer is durable.
#
# So a present-but-unparseable file is moved aside and named on stderr before we
# start fresh. That keeps the write working (a corrupt store must not wedge the
# machine) while making the loss loud and recoverable rather than silent.
#
# Corruption means *unparseable*, not *unexpected*. The test is a jq run that
# succeeds, with a non-object result mapped to an empty base — so a file holding
# literal `null` or `false` is read as "no grants recorded" and left in place,
# where both `jq -e .` and a bare `type == "object"` test would have declared it
# corrupt and moved a harmless file aside. Only a file jq cannot parse at all
# produces no output here, and that is the one that gets quarantined.
_apex_authority_read() {
	setopt localoptions no_err_return
	local f="$1" cur aside
	# A zero-byte file is an interrupted write, not a corrupt store: quarantining
	# it would warn about answers it never held and leave a useless file behind.
	# Treated as absent, which is what it is.
	if [[ ! -s $f ]]; then
		print -r -- '{"grants":{}}'
		return 0
	fi
	cur=$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null)
	if [[ -n $cur ]]; then
		print -r -- "$cur"
		return 0
	fi
	aside="${f}.corrupt-$(date +%s)"
	if mv -f "$f" "$aside" 2>/dev/null; then
		print -u2 "tmux-apex: WARNING — $f was unreadable and has been moved to"
		print -u2 "  $aside"
		print -u2 "  Every repo's merge-authority answer in it is lost, so apex has no merge"
		print -u2 "  authority anywhere until those repos are answered again. Nothing gained"
		print -u2 "  authority: the default is not granted. Recover answers from the file above."
	else
		print -u2 "tmux-apex: WARNING — $f is unreadable and could not be moved aside;"
		print -u2 "  it is about to be overwritten and its other answers lost."
	fi
	print -r -- '{"grants":{}}'
}

# apex_authority_set <repo-key> <merge yes|no> [session] [path] [self_review yes|no]
#
# Read-modify-write of a file shared by every manager on the machine, so it takes
# a lock the same way member records do; two managers initialising at once would
# otherwise each write a file missing the other's grant.
#
# A lock timeout does not abort the write — a dropped answer would re-ask the
# human, and the convention in apex-state.sh is one stall then an unlocked write
# — but it is never silent: it emits the same `lock_timeout` event
# `_apex_member_lock` does, so a lost update on the one file where that means a
# wrong permission answer leaves a trace. Needs a session to journal under; with
# none, the fallback says so on stderr instead.
#
# self_review is refused unless merge is granted, and `merge no` clears it: the
# axis authorises nothing on its own, and a stale yes must not spring back to
# life the next time someone re-grants merging.
apex_authority_set() {
	setopt localoptions no_err_return
	# NOT `local path`: in zsh $path is the array tied to $PATH, so declaring it
	# local empties PATH for the rest of the function and every external command
	# in here stops resolving ("command not found: mkdir").
	local key="$1" ans="$2" session="${3:-}" repo_path="${4:-}" self="${5:-}"
	local f lock cur merged rc=0 held=false
	[[ -n $key ]] || return 1
	[[ $ans == yes || $ans == no ]] || return 1
	[[ -z $self || $self == yes || $self == no ]] || return 1
	[[ $self == yes && $ans == no ]] && return 1
	[[ $ans == no ]] && self=no
	f=$(APEX_AUTHORITY_FILE)
	lock="${f:h}/.authority.lock"
	mkdir -p "${f:h}" || return 1

	if apex_lock_acquire "$lock"; then
		held=true
	elif [[ -n $session ]]; then
		apex_event "$session" "$(jq -nc --arg k "$key" \
			'{event:"lock_timeout", file:"authority.json", repo_key:$k}')" 2>/dev/null
	else
		print -u2 "tmux-apex: warning — could not lock $lock; writing unlocked"
	fi

	cur=$(_apex_authority_read "$f")
	# An axis the caller did not speak to keeps whatever it already said, so
	# `--grant` does not quietly reopen a self-review question already answered.
	merged=$(printf '%s' "$cur" | jq -c \
		--arg k "$key" --argjson m "$([[ $ans == yes ]] && print true || print false)" \
		--arg self "$self" \
		--arg by "$session" --arg p "$repo_path" --argjson at "$(date +%s)" \
		'.grants[$k] = ((.grants[$k] // {})
		                + {merge:$m, at:$at, by:$by, path:$p}
		                + (if $self == "" then {} else {self_review: ($self == "yes")} end))
		 | .grants[$k].self_review = (.grants[$k].self_review == true and $m == true)') \
		|| merged=""
	if [[ -n $merged ]]; then
		apex_write_atomic "$f" "$merged" || rc=1
	else
		rc=1
	fi
	$held && apex_lock_release "$lock"
	return $rc
}

# One line for `init`, `status` and `doctor`. The answer alone is not enough to
# act on — an agent reading "no" needs to know that means report-and-stop, not
# that something is broken and wants fixing.
# Takes the merge answer and, optionally, the self-review answer. `unknown` for
# the merge answer means we could not work out which repo was being asked about,
# which is reported distinctly and treated as no authority — see
# _apex_status_authority.
apex_authority_describe() {
	local m="$1" self="${2:-no}"
	case "$m" in
		yes)
			if [[ $self == yes ]]; then
				print -r -- "merge: GRANTED, including on apex's own review"
			else
				print -r -- "merge: GRANTED for reviewer-approved PRs; NOT on apex's own review"
			fi
			;;
		unknown)
			print -r -- "merge: UNKNOWN (cannot tell which repo this manager is for) — treat as not granted"
			;;
		*)
			print -r -- "merge: NOT granted — report PRs ready-and-ineligible, the human merges"
			;;
	esac
}
