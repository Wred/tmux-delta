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
# So the grant is recorded per repo, and it is **fail-closed**: the answer is a
# boolean, the default is not granted, and every way of failing to get an answer
# — no file, unreadable file, malformed JSON, a key nobody has answered, a value
# that is not literally `true` — resolves to *not granted*. Apex then reports a
# qualifying PR as ready-and-ineligible and the human merges it.
#
# Boolean deliberately, not because a shaped grant is wrong but because whether
# it should be shaped is a policy question for the repo's owner, not a mechanical
# one this file gets to settle (see the PR for #41). A shaped grant would be
# stored under the same key; `apex_authority_get` treats any non-boolean value it
# does not recognise as ungranted, so a future version that writes a shape cannot
# be read as permission by this one.
#
# Storage is one file shared by every manager session:
#
#   $APEX_ROOT/authority.json
#   {"grants": {"<repo-key>": {"merge":true,"at":1234,"by":"session","path":"/…"}}}
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

# apex_authority_get <repo-key> — `yes` or `no`, never anything else.
#
# Every failure path prints `no`. A missing file, a file we cannot parse, a repo
# nobody has answered for, and a value that is not literally JSON `true` all mean
# "not granted" rather than "assume the permissive thing" — that is the whole
# design of this file, so it is one code path with no exceptions.
apex_authority_get() {
	setopt localoptions no_err_return
	local key="$1" f v
	f=$(APEX_AUTHORITY_FILE)
	[[ -n $key && -r $f ]] || { print -r -- no; return 0 }
	# `== true` and not `tostring`/truthiness: jq's equality is type-strict, so
	# the *string* "true", the number 1 and a future shaped grant all compare
	# false here. A truthiness test would read every one of them as permission.
	v=$(jq -r --arg k "$key" 'if .grants[$k].merge == true then "yes" else "no" end' \
		"$f" 2>/dev/null) || v=no
	[[ $v == yes ]] && { print -r -- yes; return 0 }
	print -r -- no
}

# apex_authority_may_merge <repo-key> — predicate form, for `if` at call sites.
apex_authority_may_merge() { [[ $(apex_authority_get "$1") == yes ]] }

# apex_authority_answered <repo-key> — true when a human recorded an answer for
# this repo, whichever way it went. Distinct from `get` returning `no`, which is
# also what "nobody has been asked" looks like: `init` needs to know whether to
# ask, and `doctor` needs to say "never granted" differently from "declined".
apex_authority_answered() {
	setopt localoptions no_err_return
	local f v
	f=$(APEX_AUTHORITY_FILE)
	[[ -n $1 && -r $f ]] || return 1
	v=$(jq -r --arg k "$1" '.grants[$k].merge | type' "$f" 2>/dev/null) || return 1
	[[ $v == boolean ]]
}

# apex_authority_set <repo-key> <yes|no> [session] [path] — record an answer.
#
# Read-modify-write of a file shared by every manager on the machine, so it takes
# a lock the same way member records do; two managers initialising at once would
# otherwise each write a file missing the other's grant. A lock timeout is not a
# reason to drop the answer — the worst case of writing unlocked here is losing a
# *different* repo's grant, and a lost grant asks the human again rather than
# granting something nobody granted.
apex_authority_set() {
	setopt localoptions no_err_return
	# NOT `local path`: in zsh $path is the array tied to $PATH, so declaring it
	# local empties PATH for the rest of the function and every external command
	# in here stops resolving ("command not found: mkdir").
	local key="$1" ans="$2" session="${3:-}" repo_path="${4:-}" f lock cur merged rc=0 held=false
	[[ -n $key ]] || return 1
	[[ $ans == yes || $ans == no ]] || return 1
	f=$(APEX_AUTHORITY_FILE)
	lock="${f:h}/.authority.lock"
	mkdir -p "${f:h}" || return 1

	apex_lock_acquire "$lock" && held=true
	cur=$(jq -e . "$f" 2>/dev/null) || cur='{"grants":{}}'
	merged=$(printf '%s' "$cur" | jq -c \
		--arg k "$key" --argjson m "$([[ $ans == yes ]] && print true || print false)" \
		--arg by "$session" --arg p "$repo_path" --argjson at "$(date +%s)" \
		'.grants[$k] = {merge:$m, at:$at, by:$by, path:$p}') || merged=""
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
apex_authority_describe() {
	if [[ $1 == yes ]]; then
		print -r -- "merge: GRANTED for this repo"
	else
		print -r -- "merge: NOT granted — report PRs ready-and-ineligible, the human merges"
	fi
}
