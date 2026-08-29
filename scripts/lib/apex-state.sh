# apex-state.sh — on-disk state for apex mode.
#
# Layout:
#   $APEX_ROOT/<manager-session>/
#     apex.json            manager metadata
#     members/<session>.json  one per managed session
#     events.jsonl            append-only transition log
#
# Sourced by tmux-apex.sh (zsh). Writes are atomic (mktemp in-dir + mv),
# matching the convention in lib/pr-cache.sh.

APEX_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-delta/apex"

apex_dir()          { printf '%s/%s' "$APEX_ROOT" "$1"; }
apex_file() { printf '%s/%s/apex.json' "$APEX_ROOT" "$1"; }
apex_members_dir()  { printf '%s/%s/members' "$APEX_ROOT" "$1"; }
apex_member_file()  { printf '%s/%s/members/%s.json' "$APEX_ROOT" "$1" "$2"; }
apex_events_file()  { printf '%s/%s/events.jsonl' "$APEX_ROOT" "$1"; }

apex_init_dirs() {
	mkdir -p "$(apex_members_dir "$1")"
}

# apex_write_atomic <file> <content>
apex_write_atomic() {
	local file="$1" content="$2" dir tmp
	dir="${file%/*}"
	mkdir -p "$dir"
	tmp=$(mktemp "${dir}/.tmp.XXXXXX") || return 1
	printf '%s\n' "$content" > "$tmp"
	mv "$tmp" "$file"
}

# ─── per-member mutex ────────────────────────────────────────────────
#
# Every write to a member record is a read-modify-write: read the file, merge a
# patch, mv the result into place. The mv is atomic so a record is never torn,
# but two processes that read the same starting state each write a result
# missing the other's fields and the last mv silently wins. That was harmless
# while every writer only touched its own member record; the paired fix/review
# loop broke that assumption — `_pair_advance` writes {pair_round, pair_turn}
# onto the *partner's* record while the partner's own hooks merge {status, seq}
# into it. A lost pair_turn flip stalls the round with nothing logged.
#
# mkdir is the mutex: it is atomic on every filesystem we care about and needs
# no helper binary, which matters because macOS ships no flock(1).
APEX_LOCK_WAIT="${APEX_LOCK_WAIT:-5}"     # seconds to wait before giving up
APEX_LOCK_STALE="${APEX_LOCK_STALE:-30}"  # seconds before a held lock is stale

# _apex_mtime <path> — prints the file's mtime as a unix timestamp, or nothing.
_apex_mtime() {
	local -a st
	zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
	zstat -A st +mtime "$1" 2>/dev/null || return 1
	printf '%s' "$st[1]"
}

# apex_lock_acquire <lockdir> — 0 when held, 1 when it gave up waiting.
#
# A lock whose directory is older than $APEX_LOCK_STALE is stolen: hook
# processes are killed freely (tmux teardown, ^C), and a crashed writer must
# not wedge a member record for the rest of the session.
#
# Contending here is entirely normal, and so is losing a race inside the wait
# loop (the lock we were about to stat is released before we get to it). Under a
# caller's err_return that first stray non-zero would abort the waiter mid-loop
# and its write would be skipped — the exact silent loss this lock exists to
# prevent. Every function that can be entered while another writer holds the
# lock disables it locally; each one reports through its own return code.
apex_lock_acquire() {
	setopt localoptions no_err_return
	local lock="$1" deadline now mt
	mkdir -p "${lock%/*}" 2>/dev/null
	deadline=$(( $(date +%s) + APEX_LOCK_WAIT ))
	while true; do
		if mkdir "$lock" 2>/dev/null; then
			printf '%s\n' "$$" > "$lock/pid" 2>/dev/null
			return 0
		fi
		mt=$(_apex_mtime "$lock") || mt=""
		now=$(date +%s)
		if [[ -n "$mt" ]] && (( now - mt > APEX_LOCK_STALE )); then
			_apex_lock_scrub "$lock"
			continue
		fi
		if (( now >= deadline )); then
			return 1
		fi
		sleep 0.05
	done
}

# _apex_lock_scrub <lockdir> — drop a lock with no window a second holder can
# fall into. `rm -rf` is not safe here: it unlinks the pid file first, and a
# waiter that wins mkdir in that gap gets its brand-new directory rmdir'd out
# from under it, leaving two processes believing they hold the lock. Renaming
# the directory is a single atomic step — the name is either taken or free.
_apex_lock_scrub() {
	setopt localoptions no_err_return
	local lock="$1" trash="$1.dead.$$"
	rm -rf "$trash" 2>/dev/null
	mv "$lock" "$trash" 2>/dev/null || return 1
	rm -rf "$trash" 2>/dev/null
}

apex_lock_release() { _apex_lock_scrub "$1" }

# apex_member_lockdir <manager> <session>
apex_member_lockdir() { printf '%s/%s/members/.%s.lock' "$APEX_ROOT" "$1" "$2"; }

# _apex_member_lock <manager> <session>
# Acquires the record's lock, or logs the timeout and proceeds unlocked — a
# dropped state update is worse than a racy one, and the whole point of this
# issue is that losing a write must not be silent.
_apex_member_lock() {
	setopt localoptions no_err_return
	local lock
	lock=$(apex_member_lockdir "$1" "$2")
	if apex_lock_acquire "$lock"; then
		printf '%s' "$lock"
		return 0
	fi
	apex_event "$1" "$(jq -nc --arg s "$2" \
		'{event:"lock_timeout", session:$s}')" 2>/dev/null
	return 1
}

# _apex_member_write <file> <patch> [<extra-jq-filter>]
# Read-merge-write of an already-locked member file.
_apex_member_write() {
	setopt localoptions no_err_return
	local file="$1" patch="$2" filter="${3:-.}" base merged
	base='{}'
	if [[ -f "$file" ]]; then base=$(cat "$file"); fi
	merged=$(printf '%s\n%s\n' "$base" "$patch" | jq -s ".[0] * .[1] | ${filter}") || return 1
	apex_write_atomic "$file" "$merged"
}

# apex_member_merge <manager> <session> <json-object>
# Shallow-merges the object into the member record, creating it if absent.
apex_member_merge() {
	setopt localoptions no_err_return
	local manager="$1" session="$2" patch="$3" file lock rc
	file=$(apex_member_file "$manager" "$session")
	lock=$(_apex_member_lock "$manager" "$session") || lock=""
	_apex_member_write "$file" "$patch"
	rc=$?
	if [[ -n "$lock" ]]; then apex_lock_release "$lock"; fi
	return $rc
}

# apex_member_merge_bump <manager> <session> <json-object>
# Merges the patch and increments seq in the same critical section, printing the
# new seq. Bumping outside the lock let two hook processes read the same seq and
# both claim it, so a settle callback armed for one turn could match another's.
apex_member_merge_bump() {
	setopt localoptions no_err_return
	local manager="$1" session="$2" patch="$3" file lock rc seq
	file=$(apex_member_file "$manager" "$session")
	lock=$(_apex_member_lock "$manager" "$session") || lock=""
	if _apex_member_write "$file" "$patch" '.seq = ((.seq // 0) + 1)'; then
		rc=0
		# Read back inside the critical section: outside it, a concurrent bump
		# could land first and we would report a seq we do not own.
		seq=$(jq -r '.seq' "$file" 2>/dev/null)
	else
		rc=1
	fi
	if [[ -n "$lock" ]]; then apex_lock_release "$lock"; fi
	if (( rc == 0 )); then printf %s "$seq"; fi
	return $rc
}

# apex_member_merge_cas <manager> <session> <json-object> <key> <expected>
# Merges only while <key> still holds <expected>, re-read under the lock.
# Returns 1 without writing when it has changed — for writers whose correctness
# depends on a value they read earlier (`pending --mark-delivered` advancing
# pinged_seq to a seq that may already be stale).
apex_member_merge_cas() {
	setopt localoptions no_err_return
	local manager="$1" session="$2" patch="$3" key="$4" want="$5"
	local file lock rc cur
	file=$(apex_member_file "$manager" "$session")
	lock=$(_apex_member_lock "$manager" "$session") || lock=""
	cur=$(jq -r --arg k "$key" '.[$k] // "" | tostring' "$file" 2>/dev/null)
	if [[ "$cur" == "$want" ]]; then
		_apex_member_write "$file" "$patch"
		rc=$?
	else
		rc=1
	fi
	if [[ -n "$lock" ]]; then apex_lock_release "$lock"; fi
	return $rc
}

# apex_member_get <manager> <session> <key>
# Prints the raw value ("" when absent or null).
apex_member_get() {
	local file
	file=$(apex_member_file "$1" "$2")
	[[ -f "$file" ]] || return 1
	jq -r --arg k "$3" '.[$k] // "" | tostring' "$file" 2>/dev/null
}

# apex_event <manager> <json-object>
# Appends one event, stamped with wall-clock time.
apex_event() {
	local manager="$1" obj="$2" file line
	file=$(apex_events_file "$manager")
	mkdir -p "${file%/*}"
	line=$(printf '%s' "$obj" | jq -c --argjson t "$(date +%s)" '. + {at: $t}') || return 1
	printf '%s\n' "$line" >> "$file"
}

# apex_members <manager> — prints one session name per line
apex_members() {
	local dir f
	dir=$(apex_members_dir "$1")
	[[ -d "$dir" ]] || return 0
	for f in "$dir"/*.json(N); do
		f="${f##*/}"
		printf '%s\n' "${f%.json}"
	done
}

# apex_manager_of <session> — the manager session governing <session>, via tmux option
apex_manager_of() {
	tmux show-option -t "$1" -qv @apex_session 2>/dev/null
}
