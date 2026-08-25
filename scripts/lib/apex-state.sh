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

# apex_member_merge <manager> <session> <json-object>
# Shallow-merges the object into the member record, creating it if absent.
apex_member_merge() {
	local manager="$1" session="$2" patch="$3" file base merged
	file=$(apex_member_file "$manager" "$session")
	base='{}'
	[[ -f "$file" ]] && base=$(cat "$file")
	merged=$(printf '%s\n%s\n' "$base" "$patch" | jq -s '.[0] * .[1]') || return 1
	apex_write_atomic "$file" "$merged"
}

# apex_member_get <manager> <session> <key>
# Prints the raw value ("" when absent or null).
apex_member_get() {
	local file
	file=$(apex_member_file "$1" "$2")
	[[ -f "$file" ]] || return 1
	jq -r --arg k "$3" '.[$k] // "" | tostring' "$file" 2>/dev/null
}

# apex_member_bump_seq <manager> <session>
# Increments seq and prints the new value.
apex_member_bump_seq() {
	local cur
	cur=$(apex_member_get "$1" "$2" seq)
	[[ -n "$cur" && "$cur" != "null" ]] || cur=0
	printf '%s' $(( cur + 1 ))
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
