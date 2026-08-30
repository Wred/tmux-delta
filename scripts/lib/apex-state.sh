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
# The mutex is `zsystem flock` from zsh/system: a real advisory lock, held on an
# open descriptor, which the kernel drops when the holder exits. That last part
# is why it is worth reaching for rather than rolling our own. Hook processes are
# killed freely — tmux teardown, ^C, a crash mid-write — so any lock we have to
# release ourselves needs a staleness rule, and a staleness rule has no safe
# implementation on top of mkdir. Stealing a lock means removing it and creating
# your own, and two waiters that saw the same stale lock will each do that and
# each believe they won; adding a pid file does not settle it, because $$ is
# shared by every zsh subshell forked from one shell. The kernel has the
# liveness information we would be guessing at.
APEX_LOCK_WAIT="${APEX_LOCK_WAIT:-5}"     # seconds to wait before giving up
APEX_LOCK_POLL="${APEX_LOCK_POLL:-0.02}"  # how often a waiter retries
APEX_LOCK_STALE="${APEX_LOCK_STALE:-30}"  # fallback only: when a lockdir is junk

typeset -gA APEX_LOCK_FD                  # lockpath -> descriptor we hold it on

# _apex_have_flock — 0 when zsh/system can lock for us. Answer is cached.
_apex_have_flock() {
	setopt localoptions no_err_return
	if [[ -z ${APEX_HAVE_FLOCK-} ]]; then
		APEX_HAVE_FLOCK=1
		if zmodload zsh/system 2>/dev/null && zsystem supports flock 2>/dev/null; then
			APEX_HAVE_FLOCK=0
		fi
	fi
	return $APEX_HAVE_FLOCK
}

# _apex_mtime <path> — prints the file's mtime as a unix timestamp, or nothing.
_apex_mtime() {
	local -a st
	zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
	zstat -A st +mtime "$1" 2>/dev/null || return 1
	printf '%s' "$st[1]"
}

# apex_lock_acquire <lockpath> — 0 when held, 1 when it gave up waiting.
#
# The lock lives on a descriptor, so acquire, critical section and release must
# all run in the SAME shell. A subshell is fine as long as it contains all three
# — `seq=$(apex_member_merge_bump …)` is correct, because the whole section
# happens inside that command substitution. What is not fine is taking the lock
# in a subshell and doing the work outside it: the descriptor closes when the
# subshell exits, so the lock is gone before the section starts.
#
# One acquire per path per shell, too. APEX_LOCK_FD[$lock] is overwritten rather
# than guarded, and flock does not self-conflict across two descriptors in one
# process, so a nested acquire of the same path would leak the first descriptor
# and silently fail to exclude. No caller does this today.
#
# -i matters as much as -t here. zsystem flock retries once a second by default,
# and a critical section is two jq forks — tens of milliseconds. A waiter polling
# on that cadence is running a lottery it mostly loses, which showed up as most
# of a 16-writer fan-out timing out and writing unlocked.
apex_lock_acquire() {
	setopt localoptions no_err_return
	local lock="$1" fd
	mkdir -p "${lock%/*}" 2>/dev/null
	if _apex_have_flock; then
		: >> "$lock" 2>/dev/null || return 1
		zsystem flock -t "$APEX_LOCK_WAIT" -i "$APEX_LOCK_POLL" -f fd "$lock" \
			2>/dev/null || return 1
		APEX_LOCK_FD[$lock]=$fd
		return 0
	fi
	_apex_lockdir_acquire "$lock.d"
}

# apex_lock_release <lockpath>
apex_lock_release() {
	setopt localoptions no_err_return
	local lock="$1" fd="${APEX_LOCK_FD[$1]-}"
	if [[ -n "$fd" ]]; then
		unset "APEX_LOCK_FD[$lock]"
		zsystem flock -u "$fd" 2>/dev/null
		return 0
	fi
	rmdir "$lock.d" 2>/dev/null
}

# _apex_lockdir_acquire <lockdir> — fallback for a zsh built without zsh/system.
#
# mkdir is an atomic create-exclusive, so the acquire itself is sound; what it
# cannot do safely is recover a lock whose holder died, for the reason in the
# block comment above. So it never steals one. A wedged lock therefore costs
# each later writer one $APEX_LOCK_WAIT stall and then an unlocked write with a
# `lock_timeout` event (see _apex_member_lock) — degraded and noisy, never
# wedged. Only once we have already given up, and only if the directory has sat
# there far longer than any real critical section, is it cleared so the *next*
# writer starts clean; we do not claim it ourselves, which is precisely the step
# that cannot be made single-winner. That clear is the one remaining way to get
# two holders here: a live-but-stalled holder past $APEX_LOCK_STALE has its
# directory removed under it, and the next writer then mkdirs alongside it. It
# needs a critical section two jq forks long to hang for 30s, so it trades the
# ordinary crash path for a pathological one.
_apex_lockdir_acquire() {
	setopt localoptions no_err_return
	local lock="$1" deadline now mt
	deadline=$(( $(date +%s) + APEX_LOCK_WAIT ))
	while true; do
		mkdir "$lock" 2>/dev/null && return 0
		now=$(date +%s)
		if (( now >= deadline )); then
			mt=$(_apex_mtime "$lock") || mt=""
			if [[ -n "$mt" ]] && (( now - mt > APEX_LOCK_STALE )); then
				rmdir "$lock" 2>/dev/null
			fi
			return 1
		fi
		sleep "$APEX_LOCK_POLL"
	done
}

# apex_member_lockpath <manager> <session>
apex_member_lockpath() { printf '%s/%s/members/.%s.lock' "$APEX_ROOT" "$1" "$2"; }

# apex_member_lock_forget <manager> <session>
# Drops the lock state for a record that is being destroyed or re-keyed. The
# glob catches the fallback's `.lock.d` too, so nothing is left behind.
#
# Unlinking a lock file does not release a flock held on its inode, so a live
# holder plus a later acquirer of the same path would end up on two different
# inodes and exclude nothing. That is safe here only because this is called
# exactly when the key stops existing: reap and recover destroy the record,
# relink has already mv'd it to the new key. There is no next writer for this
# path, and a write racing the re-key was going to land on an orphaned file
# either way. Do not call it on a key that is still in use.
apex_member_lock_forget() {
	setopt localoptions no_err_return
	local lock
	lock=$(apex_member_lockpath "$1" "$2")
	rm -rf "$lock" "$lock".*(N) 2>/dev/null
}

# _apex_member_lock <manager> <session>
# Acquires the record's lock, or logs the timeout and lets the caller proceed
# unlocked — a dropped state update is worse than a racy one, and the whole
# point of this issue is that losing a write must not be silent.
#
# The caller must release in the same shell that called this: see apex_lock_acquire.
_apex_member_lock() {
	setopt localoptions no_err_return
	apex_lock_acquire "$(apex_member_lockpath "$1" "$2")" && return 0
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
	local manager="$1" session="$2" patch="$3" file lock rc held
	file=$(apex_member_file "$manager" "$session")
	lock=$(apex_member_lockpath "$manager" "$session")
	_apex_member_lock "$manager" "$session" && held=0 || held=1
	_apex_member_write "$file" "$patch"
	rc=$?
	if (( held == 0 )); then apex_lock_release "$lock"; fi
	return $rc
}

# apex_member_merge_bump <manager> <session> <json-object>
# Merges the patch and increments seq in the same critical section, printing the
# new seq. Bumping outside the lock let two hook processes read the same seq and
# both claim it, so a settle callback armed for one turn could match another's.
apex_member_merge_bump() {
	setopt localoptions no_err_return
	local manager="$1" session="$2" patch="$3" file lock rc seq held
	file=$(apex_member_file "$manager" "$session")
	lock=$(apex_member_lockpath "$manager" "$session")
	_apex_member_lock "$manager" "$session" && held=0 || held=1
	if _apex_member_write "$file" "$patch" '.seq = ((.seq // 0) + 1)'; then
		rc=0
		# Read back inside the critical section: outside it, a concurrent bump
		# could land first and we would report a seq we do not own.
		seq=$(jq -r '.seq' "$file" 2>/dev/null)
	else
		rc=1
	fi
	if (( held == 0 )); then apex_lock_release "$lock"; fi
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
	local file lock rc cur held
	file=$(apex_member_file "$manager" "$session")
	lock=$(apex_member_lockpath "$manager" "$session")
	_apex_member_lock "$manager" "$session" && held=0 || held=1
	cur=$(jq -r --arg k "$key" '.[$k] // "" | tostring' "$file" 2>/dev/null)
	if [[ "$cur" == "$want" ]]; then
		_apex_member_write "$file" "$patch"
		rc=$?
	else
		rc=1
	fi
	if (( held == 0 )); then apex_lock_release "$lock"; fi
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
