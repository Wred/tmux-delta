#!/usr/bin/env zsh

# Per-repo merge authority (github issue #41).
#
# The property under test is fail-closed: apex has no merge authority anywhere
# until a human says otherwise for that specific repo, and *every* way of not
# getting an answer resolves to "not granted" rather than to the permissive
# reading. So most of this suite is the negative space — a missing file, a
# truncated one, a value written by some future version that shapes the grant,
# a repo nobody has been asked about, a question that could not be asked because
# nobody was watching. Each of those has to come back `no`.
#
# The rest is the key. A grant belongs to a trust context, not to a directory
# name: a fork and its upstream must not share one, two clones of the same repo
# must, and a linked worktree (which is what every apex worker runs in) must
# resolve to the same key as its main tree or the human would be re-asked per
# worker.
#
# No tmux server and no agent: the library is sourced directly, and tmux-apex.sh
# is sourced with no arguments (its dispatch prints usage and falls through,
# leaving the functions defined).

set -u
emulate -L zsh
setopt err_return

ROOT="${0:A:h:h}"
SCRIPTS="$ROOT/scripts"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/apex-authority-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

typeset -i PASS=0 FAIL=0
ok()  { print -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad() { print -u2 -- "  FAIL $1"; print -u2 -- "       $2"; FAIL=$(( FAIL + 1 )) }
eq() {
	if [[ $2 == $3 ]]; then ok "$1"
	else bad "$1" "expected: ${(qqq)2}
       actual  : ${(qqq)3}"; fi
}
ne() {
	if [[ $2 != $3 ]]; then ok "$1"
	else bad "$1" "expected anything but: ${(qqq)2}"; fi
}
# `setopt err_return` aborts a $(...) subshell the moment a command in it fails,
# so `$(cmd; print $?)` never reaches the print when cmd fails — which is exactly
# the case most of this suite is about. Capture exit codes through here instead.
rc() { setopt localoptions no_err_return; "$@" >/dev/null 2>&1; print $? }

contains() {
	if [[ $3 == *$2* ]]; then ok "$1"
	else bad "$1" "expected to contain: ${(qqq)2}
       actual             : ${(qqq)3}"; fi
}

export XDG_CACHE_HOME="$TMPROOT/cache"
export APEX_ASSUME_NONINTERACTIVE=1
# Granting needs a terminal, which a test run does not have. This is the same
# opt-out a provisioning script uses; section 4 unsets it to test the gate.
export APEX_AUTHORITY_UNATTENDED_GRANT=1
export GIT_CONFIG_GLOBAL="$TMPROOT/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"

APEX_ROOT="$XDG_CACHE_HOME/tmux-delta/apex"
source "$SCRIPTS/lib/apex-state.sh"
source "$SCRIPTS/lib/apex-authority.sh"
AUTH_FILE=$(APEX_AUTHORITY_FILE)

# A repo with a remote, and one without.
mkrepo() {
	local dir="$TMPROOT/$1"; shift
	mkdir -p "$dir"
	git -C "$dir" init -q
	[[ $# -gt 0 ]] && git -C "$dir" remote add origin "$1"
	print -r -- "$dir"
}

# ─── 1. fail-closed ──────────────────────────────────────────────────

print "fail-closed"

KEY=github.com/wred/tmux-delta

rm -f "$AUTH_FILE"
eq "no state file at all means no authority"     no "$(apex_authority_get "$KEY")"
eq "…and reads as never answered"                1  "$(rc apex_authority_answered "$KEY")"

mkdir -p "${AUTH_FILE:h}"
print -r -- 'this is not json' > "$AUTH_FILE"
eq "an unparseable state file means no authority" no "$(apex_authority_get "$KEY")"
eq "…and does not claim to be an answer"          1 "$(rc apex_authority_answered "$KEY")"

print -r -- '{"grants":{}}' > "$AUTH_FILE"
eq "a valid file with no grant for this repo"      no "$(apex_authority_get "$KEY")"

print -r -- '{"grants":{"'"$KEY"'":{"merge":false}}}' > "$AUTH_FILE"
eq "an explicit no is a no"                        no "$(apex_authority_get "$KEY")"
eq "…but it IS an answer"                          0 "$(rc apex_authority_answered "$KEY")"

# The forward-compatibility case. If a later version decides the grant should be
# shaped ("my workers' PRs only") it will write something other than a boolean
# under this key. This version must read that as no permission at all rather
# than as truthy-therefore-granted.
print -r -- '{"grants":{"'"$KEY"'":{"merge":"workers-only"}}}' > "$AUTH_FILE"
eq "a shaped grant this version cannot read is no" no "$(apex_authority_get "$KEY")"
eq "…and is not counted as answered either"        1 "$(rc apex_authority_answered "$KEY")"

print -r -- '{"grants":{"'"$KEY"'":{"merge":1}}}' > "$AUTH_FILE"
eq "a truthy non-boolean is still no"              no "$(apex_authority_get "$KEY")"
print -r -- '{"grants":{"'"$KEY"'":{"merge":"true"}}}' > "$AUTH_FILE"
eq "the *string* \"true\" is not the boolean true" no "$(apex_authority_get "$KEY")"

# An empty key is what apex_repo_key returns on failure, and it must never be
# able to collect a grant — otherwise every non-repo directory would share one.
print -r -- '{"grants":{"":{"merge":true}}}' > "$AUTH_FILE"
eq "an empty key never resolves to granted"        no "$(apex_authority_get "")"
eq "setting an empty key is refused"               1 "$(rc apex_authority_set "" yes)"

# The second axis (issue #41, Q2) is fail-closed on the same terms, and closed
# twice over: it never grants anything unless the merge axis is also granted.
print -r -- '{"grants":{"'"$KEY"'":{"merge":false,"self_review":true}}}' > "$AUTH_FILE"
eq "self-review without merge authorises nothing" no \
	"$(apex_authority_get "$KEY" self_review)"
eq "…and the predicate agrees"                     1 "$(rc apex_authority_may_self_review "$KEY")"
print -r -- '{"grants":{"'"$KEY"'":{"merge":true,"self_review":"yes"}}}' > "$AUTH_FILE"
eq "a non-boolean self_review is no"               no "$(apex_authority_get "$KEY" self_review)"
eq "…while merge itself still reads true"          yes "$(apex_authority_get "$KEY")"
print -r -- '{"grants":{"'"$KEY"'":{"merge":true}}}' > "$AUTH_FILE"
eq "a missing self_review is no"                   no "$(apex_authority_get "$KEY" self_review)"

rm -f "$AUTH_FILE"
eq "only yes/no are storable"                      1 "$(rc apex_authority_set "$KEY" reviewed)"
eq "…so a rejected write records nothing"          1 "$(rc apex_authority_answered "$KEY")"

# ─── 2. round trip ───────────────────────────────────────────────────

print "\nrecording an answer"

rm -f "$AUTH_FILE"
apex_authority_set "$KEY" yes sess-a /some/path
eq "a grant reads back as granted"   yes "$(apex_authority_get "$KEY")"
eq "…and as answered"                0   "$(rc apex_authority_answered "$KEY")"
eq "the predicate form agrees"       0   "$(rc apex_authority_may_merge "$KEY")"
eq "merge is stored as a JSON boolean" boolean \
	"$(jq -r --arg k "$KEY" '.grants[$k].merge | type' "$AUTH_FILE")"
eq "the answering session is recorded" sess-a \
	"$(jq -r --arg k "$KEY" '.grants[$k].by' "$AUTH_FILE")"

apex_authority_set "$KEY" no sess-b /some/path
eq "revoking flips it back"          no  "$(apex_authority_get "$KEY")"
eq "…and stays an answer"            0   "$(rc apex_authority_answered "$KEY")"
eq "the predicate form agrees too"   1   "$(rc apex_authority_may_merge "$KEY")"

# One repo's answer must never leak into another's — the whole point is that the
# decision is per repo.
apex_authority_set "$KEY" yes sess-a /some/path
apex_authority_set github.com/other/tmux-delta no sess-a /other
eq "a second repo's answer leaves the first alone" yes "$(apex_authority_get "$KEY")"
eq "…and is itself independent"  no "$(apex_authority_get github.com/other/tmux-delta)"
eq "a repo not in the file is unaffected by both"  no \
	"$(apex_authority_get github.com/third/repo)"

# The second axis round-trips independently, and cannot outlive the first.
rm -f "$AUTH_FILE"
apex_authority_set "$KEY" yes sess-a /p yes
eq "both axes can be granted at once"  yes "$(apex_authority_get "$KEY" self_review)"
eq "self_review is stored as a JSON boolean" boolean \
	"$(jq -r --arg k "$KEY" '.grants[$k].self_review | type' "$AUTH_FILE")"
apex_authority_set "$KEY" yes sess-a /p
eq "a write that omits the axis leaves it alone" yes "$(apex_authority_get "$KEY" self_review)"
apex_authority_set "$KEY" yes sess-a /p no
eq "…and it can be dropped without touching merge" no \
	"$(apex_authority_get "$KEY" self_review)"
eq "…merge survives that"  yes "$(apex_authority_get "$KEY")"

# Revoking merge must clear self-review rather than leave it stored: a stale yes
# springing back to life on the next re-grant is the failure mode.
apex_authority_set "$KEY" yes sess-a /p yes
apex_authority_set "$KEY" no sess-a /p
eq "revoking merge clears self-review in the store" false \
	"$(jq -r --arg k "$KEY" '.grants[$k].self_review' "$AUTH_FILE")"
apex_authority_set "$KEY" yes sess-a /p
eq "…so re-granting merge alone does not revive it" no \
	"$(apex_authority_get "$KEY" self_review)"
eq "self-review yes with merge no is refused outright" 1 \
	"$(rc apex_authority_set "$KEY" no sess-a /p yes)"

# A write landing on a corrupt store used to discard every other repo's answer
# silently. It still starts fresh — a broken file must not wedge the machine —
# but the old file is kept and named, so deliberate answers are recoverable.
rm -f "$AUTH_FILE"
apex_authority_set github.com/wred/other yes sess-a /p
print -r -- '{"grants":{"a":' > "$AUTH_FILE"
err=$(apex_authority_set "$KEY" yes sess-a /p 2>&1 >/dev/null) || true
eq "a write onto a corrupt store still records the answer" yes "$(apex_authority_get "$KEY")"
contains "…and says so on stderr"  "unreadable" "$err"
eq "…keeping the unreadable file aside"  1 \
	"$(print -r -- "${AUTH_FILE}".corrupt-*(N) | wc -l | tr -d ' ')"
contains "…naming where it went"  ".corrupt-" "$err"
rm -f "${AUTH_FILE}".corrupt-*(N)

# Literal `null` and `false` are parseable JSON, so they are not corruption —
# they are just a file with no grants in it, and must not be moved aside.
print -r -- 'null' > "$AUTH_FILE"
apex_authority_set "$KEY" yes sess-a /p
eq "a file holding literal null is treated as empty, not corrupt" "" \
	"$(print -r -- "${AUTH_FILE}".corrupt-*(N))"
eq "…and the write lands"  yes "$(apex_authority_get "$KEY")"

# The grant has to outlive the manager session that recorded it: session names
# are recycled and recreated, which is exactly what made per-session storage the
# wrong home for this.
eq "state lives outside any manager session directory" "" \
	"$(print -r -- "$APEX_ROOT"/*/authority.json(N))"
eq "…at one shared path"  "$APEX_ROOT/authority.json" "$AUTH_FILE"

# ─── 3. the repo key ─────────────────────────────────────────────────

print "\nrepo identity"

SCP=$(mkrepo scp git@github.com:Wred/Tmux-Delta.git)
eq "scp-form remotes normalise to host/owner/repo" github.com/wred/tmux-delta \
	"$(apex_repo_key "$SCP")"
# The bug this pins: zsh reads `\/` in a ${x/a/b} replacement as a literal
# backslash, which silently produced keys like `github.com\/wred/tmux-delta`.
ne "…with no stray backslash in the key" '*\\*' "$(apex_repo_key "$SCP")"

HTTPS=$(mkrepo https 'https://token@GitHub.com/Wred/tmux-delta.git')
eq "https remotes with credentials normalise the same" github.com/wred/tmux-delta \
	"$(apex_repo_key "$HTTPS")"
eq "two clones of one repo share a key" "$(apex_repo_key "$SCP")" "$(apex_repo_key "$HTTPS")"

FORK=$(mkrepo fork git@github.com:someone-else/tmux-delta.git)
ne "a fork does not inherit the upstream's key" "$(apex_repo_key "$SCP")" \
	"$(apex_repo_key "$FORK")"
apex_authority_set "$(apex_repo_key "$SCP")" yes sess /x
eq "…so granting upstream grants nothing in the fork" no \
	"$(apex_authority_get "$(apex_repo_key "$FORK")")"

# Every apex worker runs in a linked worktree of the manager's repo. If a
# worktree keyed differently, the human would be asked once per worker.
WT="$TMPROOT/wt-branch"
( cd "$SCP" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
	&& git worktree add -q -b wt "$WT" ) >/dev/null 2>&1
eq "a linked worktree keys to the same repo" "$(apex_repo_key "$SCP")" "$(apex_repo_key "$WT")"

LOCAL=$(mkrepo localonly)
contains "a remoteless repo falls back to its path" "path:" "$(apex_repo_key "$LOCAL")"
eq "…and that path is the main worktree"  "path:${LOCAL:A}" "$(apex_repo_key "$LOCAL")"

mkdir -p "$TMPROOT/plain"
eq "a non-repo directory yields no key at all" 1 \
	"$(rc apex_repo_key "$TMPROOT/plain")"

# ─── 4. the CLI ──────────────────────────────────────────────────────

print "\nthe authority subcommand"

REPO=$(mkrepo cli git@github.com:Wred/tmux-delta.git)
apex() { ( cd "$REPO" && "$SCRIPTS/tmux-apex.sh" "$@" ) }
rm -f "$AUTH_FILE"

j() { print -r -- "$1" | jq -r "$2" }

out=$(apex authority --json)
eq "a never-answered repo reports merge false" false "$(j "$out" .merge)"
eq "…and answered false"                       false "$(j "$out" .answered)"
eq "…under the normalised key"  github.com/wred/tmux-delta "$(j "$out" .repo_key)"

out=$(apex authority --grant --json)
eq "--grant grants"      true "$(j "$out" .merge)"
out=$(apex authority --json)
eq "…and a separate process sees it"  true "$(j "$out" .merge)"
out=$(apex authority --revoke --json)
eq "--revoke revokes"    false "$(j "$out" .merge)"
eq "…and counts as answered"  true "$(j "$out" .answered)"

out=$(apex authority --grant=no --json)
eq "--grant=WORD takes a spelled-out answer" false "$(j "$out" .merge)"
out=$(apex authority --grant=true --json)
eq "…in any unambiguous spelling"            true  "$(j "$out" .merge)"

out=$(apex authority 2>&1)
contains "the human-readable form names the repo key" "github.com/wred/tmux-delta" "$out"
contains "…and says plainly that it is granted" "GRANTED" "$out"
contains "…and how to take it back"  "authority --revoke" "$out"

apex authority --revoke >/dev/null
out=$(apex authority 2>&1)
contains "an ungranted repo says what apex does instead" "ready-and-ineligible" "$out"
contains "…and how to grant it"  "authority --grant" "$out"

# A half-understood flag must never land on the permissive side.
out=$(apex authority --grant=maybe 2>&1) && rc=0 || rc=$?
eq "an unparseable --grant value fails"  1 "$rc"
contains "…loudly"  "takes yes|no" "$out"
eq "…and changes nothing"  false "$(j "$(apex authority --json)" .merge)"

out=$(apex authority --nonsense 2>&1) && rc=0 || rc=$?
eq "an unknown flag fails"  1 "$rc"
out=$(apex authority --ask --grant 2>&1) && rc=0 || rc=$?
eq "--ask and --grant together are refused"  1 "$rc"

out=$(apex init --merge maybe 2>&1) && rc=0 || rc=$?
eq "init --merge validates its value too"  1 "$rc"
contains "…with the same message"  "takes yes|no" "$out"
# Validated on the flag having been seen, not on its value being non-empty: the
# old guard let `--merge ''` through as though no flag had been passed.
out=$(apex init --merge '' 2>&1) && rc=0 || rc=$?
eq "an empty --merge value is a named error, not silence"  1 "$rc"

# The second axis through the CLI.
apex authority --grant >/dev/null
out=$(apex authority --self-review yes --json)
eq "--self-review yes grants the second axis"  true "$(j "$out" .self_review)"
eq "…leaving merge granted"  true "$(j "$out" .merge)"
out=$(apex authority --self-review no --json)
eq "--self-review no drops it"  false "$(j "$out" .self_review)"
eq "…without revoking merge"    true  "$(j "$out" .merge)"
out=$(apex authority --revoke --json)
eq "--revoke clears both"  false "$(j "$out" .self_review)"

out=$(apex authority --self-review yes 2>&1) && rc=0 || rc=$?
eq "self-review alone cannot bootstrap merge authority"  1 "$rc"
contains "…and says why"  "authorises" "$out"
eq "…and nothing was written"  false "$(j "$(apex authority --json)" .self_review)"

out=$(apex authority --self-review perhaps 2>&1) && rc=0 || rc=$?
eq "an unparseable --self-review value fails"  1 "$rc"

# `--self-review` on an unanswered repo used to backfill the merge axis from
# `apex_authority_get`, which returns `no` both for "declined" and for "nobody
# asked" — so it recorded a decline nobody gave, `init` stopped asking, and
# `doctor` said declined instead of never-answered.
rm -f "$AUTH_FILE"
out=$(apex authority --self-review no 2>&1) && rc=0 || rc=$?
eq "--self-review on an unanswered repo is refused"  1 "$rc"
contains "…saying it must not answer for the human"  "must not answer" "$out"
eq "…and the merge question is still open"  false "$(j "$(apex authority --json)" .answered)"
out=$(apex authority --revoke --self-review no --json)
eq "…while an explicit answer alongside it is fine"  true "$(j "$out" .answered)"

# init: a flag that was seen either takes effect or is named as an error. On its
# own, --self-review was parsed, validated, then silently dropped.
out=$(apex init --self-review no 2>&1) && rc=0 || rc=$?
eq "init --self-review without --merge is a named error"  1 "$rc"
contains "…pointing at the subcommand that does it"  "authority --self-review" "$out"
out=$(apex init --merge no --self-review yes 2>&1) && rc=0 || rc=$?
eq "init refuses self-review without merge too"  1 "$rc"

out=$(apex authority --grant --self-review yes --json)
eq "both axes in one call"  true "$(j "$out" .self_review)"
contains "the human-readable form distinguishes the axes" "own review" \
	"$(apex authority 2>&1)"
apex authority --revoke >/dev/null

# Granting needs a terminal: the skill says the grant is the human's to give, and
# an agent invoking this from a tool call has no terminal. Revoking is
# deliberately not gated — it moves toward the default.
noauth() { ( cd "$REPO" && unset APEX_AUTHORITY_UNATTENDED_GRANT && "$SCRIPTS/tmux-apex.sh" "$@" ) }
out=$(noauth authority --grant 2>&1) && rc=0 || rc=$?
eq "granting from a non-terminal is refused"  1 "$rc"
contains "…naming the opt-out for provisioning"  "APEX_AUTHORITY_UNATTENDED_GRANT" "$out"
eq "…and grants nothing"  false "$(j "$(apex authority --json)" .merge)"
out=$(noauth authority --revoke 2>&1) && rc=0 || rc=$?
eq "revoking from a non-terminal is fine"  0 "$rc"
apex authority --grant >/dev/null
out=$(noauth authority --self-review yes 2>&1) && rc=0 || rc=$?
eq "granting the second axis is gated the same way"  1 "$rc"
apex authority --revoke >/dev/null

# ─── 5. asking without hanging ───────────────────────────────────────

print "\nasking a human"

# init also runs from Claude Code hooks and from relink, where stdin is a pipe
# or closed. A prompt there either hangs the session start or reads EOF as an
# answer nobody gave, so the question is only ever asked at a terminal.
source "$SCRIPTS/tmux-apex.sh" >/dev/null 2>&1
eq "a piped stdin is not interactive"  1 "$(print x | APEX_ASSUME_NONINTERACTIVE= rc _apex_interactive)"
eq "the explicit override is not interactive"  1 \
	"$(APEX_ASSUME_NONINTERACTIVE=1 rc _apex_interactive)"

# The prompt itself: anything that is not an affirmative is a no, including the
# bare newline, unrecognised words, and EOF from a terminal that went away.
ask() {
	rm -f "$AUTH_FILE"
	print -r -- "$1" | _apex_ask_merge_authority "$KEY" sess "$REPO" >/dev/null 2>&1
	apex_authority_get "$KEY"
}
eq "y grants"        yes "$(ask y)"
eq "yes grants"      yes "$(ask yes)"
eq "n declines"      no  "$(ask n)"
eq "an empty answer declines"  no "$(ask '')"
eq "an unrecognised answer declines" no "$(ask 'sure, whatever')"
eq "a shaped answer this version cannot honour declines" no "$(ask reviewed)"

# The second question is only put once the first is yes — ungranted, it would be
# asking a human to rule on a hypothetical — and it is a no unless answered.
ask2() {
	rm -f "$AUTH_FILE"
	printf '%s\n' "$1" "$2" | _apex_ask_merge_authority "$KEY" sess "$REPO" >/dev/null 2>&1
	apex_authority_get "$KEY" self_review
}
eq "yes then yes grants self-review"  yes "$(ask2 y y)"
eq "yes then no does not"             no  "$(ask2 y n)"
eq "yes then silence does not"        no  "$(ask2 y '')"
out=$(printf 'n\ny\n' | _apex_ask_merge_authority "$KEY" sess "$REPO" 2>&1)
eq "declining merge means self-review is never asked" 1 \
	"$(rc grep -qF "own review" <<< "$out")"

rm -f "$AUTH_FILE"
_apex_ask_merge_authority "$KEY" sess "$REPO" >/dev/null 2>&1 < /dev/null || true
eq "EOF declines"  no "$(apex_authority_get "$KEY")"
eq "…and is recorded as a decision, not left unanswered" 0 \
	"$(rc apex_authority_answered "$KEY")"

# Whichever way it went, the answer is logged where the human can see who
# decided what.
ev=$(grep -F '"event":"merge-authority"' "$APEX_ROOT/sess/events.jsonl" 2>/dev/null | tail -1)
contains "the answer is journalled"  '"source":"prompt"' "$ev"
eq "…with the repo it applies to"  "$KEY" "$(print -r -- "$ev" | jq -r .repo_key)"
eq "…as a boolean, matching the store"  false "$(print -r -- "$ev" | jq -r .merge)"

# ─── 6. reporting ────────────────────────────────────────────────────

print "\nreporting it back"

# An authority the agent cannot see is one it will forget it does not have.
rm -f "$AUTH_FILE"
out=$(apex doctor 2>&1) || true
contains "doctor reports the authority"  "Merge authority:" "$out"
contains "…says it was never answered"   "Never answered for that repo" "$out"
contains "…and names which repo the answer is about"  "github.com/wred/tmux-delta" "$out"
contains "…and names the command"        "authority --grant" "$out"

apex authority --grant >/dev/null
out=$(apex doctor 2>&1) || true
contains "doctor reflects a grant"  "GRANTED" "$out"
contains "…and that self-review is not part of it"  "NOT on apex's own review" "$out"
apex authority --self-review yes >/dev/null
contains "…and reflects the second axis when granted"  "including on apex's own review" \
	"$(apex doctor 2>&1 || true)"
apex authority --revoke >/dev/null

# The fallback that used to sit here read the answer off $PWD when the manager
# had no usable repo record, so `status` in an unrelated granted repo reported
# the manager as having authority it did not have — fail-open, in a fail-closed
# feature. An authority we cannot resolve now reports as unknown.
eq "an unresolvable manager reports unknown, not the local repo's answer" unknown \
	"$(_apex_status_authority no-such-manager)"
contains "…and unknown renders as no authority"  "treat as not granted" \
	"$(apex_authority_describe unknown)"

print ""
print "  $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
