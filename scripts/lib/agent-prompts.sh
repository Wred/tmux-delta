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
	print -r -- "You are a managed ${role} agent under tmux-delta apex mode. \
A manager agent in tmux session '${manager}' spawned you and tracks your progress. \
Work autonomously to completion. Do not wait on the human: if you hit a blocking decision or \
an ambiguous acceptance criterion, state the blocker plainly in your final message and stop — \
your manager is notified when you go idle and will send follow-up instructions into this pane. \
Never merge a pull request and never close an issue; that is the human's call. \
Push your work and open a draft PR so the manager can see it."
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
delta_task_marker() {
	local issue="$1" pr="$2"
	if [[ -n $issue ]]; then
		print -r -- "GitHub issue #${issue}."
	elif [[ -n $pr ]]; then
		print -r -- "/my-pr-review ${pr}"
	fi
}
