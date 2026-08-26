# apex-profiles.sh — named spawn profiles ({agent, model, agent_flags} bundles).
#
# Layered config: repo defaults + optional user overrides, JSON via jq
# (already a hard dependency). Merge is shallow top-level `+`: a user
# profile of the same name fully replaces the repo one — no field-level
# splicing between files, so a profile is never a stale mix of two
# authors' intent. (Per-field override against a single spawn's explicit
# CLI flags is a separate, later step — see _cmd_spawn in tmux-apex.sh.)
#
# Sourced by tmux-apex.sh (zsh).

APEX_PROFILES_LIBDIR="${0:A:h}"
APEX_PROFILES_REPO_FILE="${APEX_PROFILES_LIBDIR}/apex-profiles.json"
APEX_PROFILES_USER_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-delta/apex-profiles.json"

apex_profiles_repo_file() { printf '%s' "$APEX_PROFILES_REPO_FILE"; }
apex_profiles_user_file() { printf '%s' "$APEX_PROFILES_USER_FILE"; }

# apex_profiles_merged — prints the merged {name: {...}, ...} map.
# rc: 0 ok, 1 repo file missing/unreadable, 2 repo file malformed,
#     3 user file malformed (only checked if present).
apex_profiles_merged() {
	local repo="$APEX_PROFILES_REPO_FILE" user="$APEX_PROFILES_USER_FILE"
	[[ -r $repo ]] || return 1
	jq -e 'type == "object"' "$repo" >/dev/null 2>&1 || return 2

	local user_json='{}'
	if [[ -r $user ]]; then
		jq -e 'type == "object"' "$user" >/dev/null 2>&1 || return 3
		user_json=$(<"$user")
	fi

	jq -c --argjson user "$user_json" '. + $user' "$repo"
}

# apex_profile_resolve <name> — prints the merged profile object for <name>.
# rc: as apex_profiles_merged, plus 4 = name not found.
apex_profile_resolve() {
	local name="$1" merged rc
	merged=$(apex_profiles_merged); rc=$?
	(( rc == 0 )) || return $rc
	jq -e --arg n "$name" '.[$n] // empty' <<< "$merged" || return 4
}

# apex_profiles_list — one TSV line per merged profile: name, agent, model,
# agent_flags, description. Sorted by name.
apex_profiles_list() {
	local merged rc
	merged=$(apex_profiles_merged); rc=$?
	(( rc == 0 )) || return $rc
	jq -r '
		to_entries[] |
		[.key, (.value.agent // "claude"), (.value.model // "-"),
		 (.value.agent_flags // "-"), (.value.description // "")] | @tsv
	' <<< "$merged" | sort
}
