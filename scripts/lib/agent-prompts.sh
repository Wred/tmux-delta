#!/usr/bin/env zsh

# The two prompts a spawned agent is launched with.
#
# Extracted from tmux-dev-layout.sh so `tmux-apex.sh recover` can rebuild the
# *identical* launch for a member whose pane a tmux crash took out. That matters
# twice over: the task prompt is the fresh-session fallback if the recorded
# conversation can no longer be resumed, and it is also the string
# `_claude_session_for` matches transcripts against to tell a worker's
# conversation from its reviewer's — the two share a worktree, so the opening
# prompt is the only thing that distinguishes them (see issue #18). A drifting
# second copy of this text would silently break both.

# delta_managed_prompt <role> <manager-session> — the appended system prompt
# that tells an agent it is running under an apex manager. Empty when either
# argument is empty (i.e. a plain human-opened session, not an apex spawn).
delta_managed_prompt() {
	local role="$1" manager="$2"
	[[ -n $role && -n $manager ]] || return 0
	# The manager files issues from outside the code, often from a symptom
	# rather than its cause, and cannot cheaply verify the mechanism it blames.
	# You can: the repo is checked out and the CLI is right here. So check the
	# premise before building on it (issues #35/#45, #60, #43).
	local verify=" \
Do not trust a task's stated diagnosis. Whatever an issue, PR comment or manager message \
claims about the cause, or about which command or flag or endpoint has the behaviour it \
blames, verify that claim yourself against the code or by running it before you build on it. \
A stated cause that is wrong makes the fix wrong too, and the check is usually one command. \
If the premise does not hold, say so and fix the real cause."
	# `--role monitor` is the reviewing role apex actually spawns; `reviewer` is
	# the word the pair vocabulary uses for the same job, matched so a rename
	# cannot quietly hand a reviewer the implementer's wording.
	[[ $role == reviewer* || $role == monitor* ]] && verify=" \
Do not trust a task's stated diagnosis. Whatever an issue, PR description or manager message \
claims about the cause, or about which command or flag or endpoint has the behaviour it \
blames, verify that claim yourself against the code or by running it before you accept it. \
A change built on a wrong premise is wrong however clean it reads, and the check is usually \
one command. If the premise does not hold, say so in your review."
	print -r -- "You are a managed ${role} agent under tmux-delta apex mode. \
A manager agent in tmux session '${manager}' spawned you and tracks your progress. \
Work autonomously to completion. Do not wait on the human: if you hit a blocking decision or \
an ambiguous acceptance criterion, state the blocker plainly in your final message and stop — \
your manager is notified when you go idle and will send follow-up instructions into this pane. \
Never merge a pull request and never close an issue; that is the human's call. \
Push your work and open a draft PR so the manager can see it.${verify}"
}

# delta_task_prompt <issue> <pr> <mode> — the initial user prompt. Empty output
# means "no task", which the adapters read as "resume the last session in this
# directory".
delta_task_prompt() {
	local issue="$1" pr="$2" mode="$3"
	if [[ -n $issue ]]; then
		if [[ $mode == autonomous ]]; then
			print -r -- "GitHub issue #${issue}. Read it with: gh issue view ${issue} --json title,body,labels,url,comments. Assign the issue to yourself with gh issue edit ${issue} --add-assignee @me and comment that you have started working on it. Then work it end-to-end: implement, test, commit on the current branch, push, and open a draft PR with gh pr create --draft. If acceptance criteria are ambiguous or you hit a blocking decision, stop and ask rather than guessing."
		else
			print -r -- "GitHub issue #${issue}. Read it with: gh issue view ${issue} --json title,body,labels,url,comments. Summarize it back to me, then ask if I want to assign the issue to myself and start working on it."
		fi
	elif [[ -n $pr ]]; then
		print -r -- "/my-pr-review ${pr}"
	fi
}

# delta_task_marker <issue> <pr> — the leading, task-identifying substring of
# the prompt above, stable across autonomous/interactive mode. This is what
# transcript matching keys on; keep it a prefix of every variant emitted by
# delta_task_prompt for the same task.
#
# The match is a prefix match, so a marker MUST end where the task id ends and
# nothing may extend it: "/my-pr-review 4" prefixes "/my-pr-review 43", which
# had `recover` on PR #4 resume PR #43's conversation in the same worktree. The
# issue marker is terminated by its own "." — the PR marker has no such
# character, so _claude_session_for requires the marker to be followed by end of
# string or a space rather than trusting the marker to terminate itself.
delta_task_marker() {
	local issue="$1" pr="$2"
	if [[ -n $issue ]]; then
		print -r -- "GitHub issue #${issue}."
	elif [[ -n $pr ]]; then
		print -r -- "/my-pr-review ${pr}"
	fi
}

# delta_resume_continuation — what to say to an agent that has just been
# relaunched with --resume (issue #42).
#
# A resumed agent restores its context and then waits at an empty prompt. It
# does not resume *working*, it resumes *waiting*: nothing re-states the task
# and it has no reason to believe it should carry on. So `recover` says so.
#
# Deliberately NOT the task prompt. Handing a resumed agent
# delta_task_prompt again is the thing the resume path exists to avoid — it
# would re-run "assign the issue, comment that you have started, work it
# end-to-end" on a conversation that already did all three, which is how you
# get duplicate comments and duplicate commits. A continuation instruction
# carries no task: it points the agent at its own history and at git, and
# tells it that finishing is a valid answer.
delta_resume_continuation() {
	print -r -- "You were just recovered after a tmux server crash and relaunched on your original conversation, so your full history above is intact and your task has not changed. Nothing was lost on disk either: your worktree, branch and any uncommitted changes survived. Pick up where you left off — re-read your own last few messages, then check what is actually done (\`git status\`, \`git log --oneline @{u}..\` or \`git log --oneline -5\`, and \`gh pr view\` if you had opened one) before you write anything, and do not redo work that is already committed or pushed. If you had already finished, say so in one line and stop rather than starting again."
}
