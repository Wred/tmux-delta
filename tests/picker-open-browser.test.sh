set -u
emulate -L zsh
setopt err_return

PICKER="${0:A:h:h}/scripts/tmux-picker.sh"

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }

# The picker is an entry point, so only the open-in-browser block is sourced —
# from _picker_notify down to the next section banner.
typeset BLOCK
BLOCK=$(sed -n '/^_picker_notify() {/,/^# ─── Shared confirm helper/p' "$PICKER" | sed '$d')
[[ $BLOCK == *_open_browser* ]] && ok "extracted the open-in-browser block" \
	|| bad "extracted the open-in-browser block" "sed range did not reach _open_browser"

# One notification sink and one gh stub per case, so the assertions can read
# what the handler would have shown the human.
run_case() {
	local desc="$1" ghrc="$2" ghout="$3" gherr="$4"
	zsh -c '
		set -u
		emulate -L zsh
		'"$BLOCK"'
		pr_cache_read() { : }
		tmux() { return 0 }
		open() { print -r -- "OPEN: $1" }
		xdg-open() { print -r -- "OPEN: $1" }
		gh() {
			[[ -n '"${(q)ghout}"' ]] && print -r -- '"${(q)ghout}"'
			[[ -n '"${(q)gherr}"' ]] && print -ru2 -- '"${(q)gherr}"'
			return '"$ghrc"'
		}
		'"$5"'
	' 2>&1 </dev/null
}

print "an unreachable host reports instead of doing nothing"

out=$(run_case "pr" 1 "" "error connecting to code.devsnc.com" \
	'_browse_or_report "pr:42"') || :
[[ $out == *"⚠"*"PR #42"*"code.devsnc.com"* ]] \
	&& ok "a failing \`gh pr view\` notifies with gh's own message" \
	|| bad "a failing \`gh pr view\` notifies with gh's own message" "got: $out"

out=$(run_case "issue" 1 "" "error connecting to code.devsnc.com" \
	'_browse_or_report "issue:7"') || :
[[ $out == *"⚠"*"issue #7"*"code.devsnc.com"* ]] \
	&& ok "a failing \`gh issue view\` notifies" \
	|| bad "a failing \`gh issue view\` notifies" "got: $out"

BRANCH=$(git -C "${0:A:h:h}" branch --show-current)
out=$(run_case "branch" 1 "" "error connecting to code.devsnc.com" \
	'_browse_or_report "dir:$PWD"') || :
[[ $out == *"⚠"*"$BRANCH"*"code.devsnc.com"* ]] \
	&& ok "a branch with no resolvable URL notifies" \
	|| bad "a branch with no resolvable URL notifies" "got: $out"

# gh can also exit 0 with nothing to say; that is still nothing to open.
out=$(run_case "silent" 0 "" "" '_browse_or_report "pr:42"') || :
[[ $out == *"⚠"*"PR #42"* ]] \
	&& ok "an empty but successful gh run still notifies" \
	|| bad "an empty but successful gh run still notifies" "got: $out"

print "a reachable host still opens the page"

out=$(run_case "ok" 0 "https://github.com/o/r/pull/42" "" '_browse_or_report "pr:42"') || :
[[ $out == *"OPEN: https://github.com/o/r/pull/42"* && $out != *⚠* ]] \
	&& ok "a resolved PR url opens, and reports nothing" \
	|| bad "a resolved PR url opens, and reports nothing" "got: $out"

out=$(run_case "branchpr" 0 $'42\thttps://github.com/o/r/pull/42' "" \
	'_browse_or_report "dir:$PWD"') || :
[[ $out == *"OPEN: https://github.com/o/r/pull/42"* && $out != *⚠* ]] \
	&& ok "_browse_repo splits the number+url lookup correctly" \
	|| bad "_browse_repo splits the number+url lookup correctly" "got: $out"

# The popup dies with the script, so the report is only readable if it waits.
out=$(run_case "wait" 1 "" "error connecting to code.devsnc.com" \
	'_browse_or_report "pr:42"') || :
[[ $out == *"press any key"* ]] \
	&& ok "the report waits before letting the popup close" \
	|| bad "the report waits before letting the popup close" "got: $out"

print ""
print "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
