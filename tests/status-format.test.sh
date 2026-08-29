#!/usr/bin/env zsh
# Static checks on the status-bar format assembly in tmux-delta.tmux.
#
# The format strings are built from shell variables and only ever evaluated by a
# live tmux server, where an unset one expands to nothing instead of failing —
# a dropped assignment silently emits `#[fg= bg=]` and the pill loses its
# styling. This test catches that class of typo without needing a tmux server.
#
# Run: tests/status-format.test.sh

set -u
emulate -L zsh
setopt err_return

PLUGIN="${0:A:h:h}/tmux-delta.tmux"

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }

# ── every variable used in a format string is assigned ───────────────
print "format variable references"

typeset -a fmt_lines
fmt_lines=( ${(f)"$(grep -n '^\(status_fmt[01]\|modules_right\)=' "$PLUGIN")"} )
[[ ${#fmt_lines} -ge 2 ]] && ok "found the format assignments" \
	|| bad "found the format assignments" "expected status_fmt0/status_fmt1, got: ${fmt_lines}"

typeset -a missing
missing=()
for var in ${(u)${(f)"$(grep -o '\${[A-Z_][A-Z0-9_]*}' "$PLUGIN" | tr -d '${}')"}}; do
	# Assignments are sometimes several to a line (`C_FG=$(...); C_CRUST=$(...)`).
	grep -qE "(^|[[:space:];])${var}=" "$PLUGIN" || missing+=( "$var" )
done
# Variables the plugin legitimately inherits rather than assigns.
missing=( ${missing:#(HOME|PATH|TMUX|BASH_SOURCE)} )

if [[ ${#missing} -eq 0 ]]; then
	ok "every \${VAR} in tmux-delta.tmux is assigned in it"
else
	bad "every \${VAR} in tmux-delta.tmux is assigned in it" \
		"unassigned: ${missing}"
fi

# ── the pill has both icon slots, in both branches ───────────────────
# Regression guard for issue #15: the apex marker and the per-agent icons are
# independent, and the selected pill draws the outline variants.
print "pill icon slots"

fmt0=$(grep '^status_fmt0=' "$PLUGIN")

check() {
	if [[ $2 == *$3* ]]; then ok "$1"; else bad "$1" "missing: $3"; fi
}
check "unselected pill draws the apex marker"   "$fmt0" '${APEX_ICON}'
check "selected pill draws the apex marker"     "$fmt0" '${APEX_ICON_ACTIVE}'
check "unselected pill draws filled agent icons"  "$fmt0" '#{@agent_icons}'
check "selected pill draws outline agent icons"   "$fmt0" '#{@agent_icons_outline}'

n=$(print -r -- "$fmt0" | grep -o '@agent_needs_attention' | grep -c . || true)
[[ $n -eq 0 ]] && ok "the pill no longer keys its background off @agent_needs_attention" \
	|| bad "the pill no longer keys its background off @agent_needs_attention" \
		"still referenced $n time(s)"

print ""
print "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
