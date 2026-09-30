#!/usr/bin/env zsh

# The coding agent used when nothing names one: no CODING_AGENT in the
# environment or the worktree's .envrc, and no --agent/profile on an apex spawn.
# Every fallback reads this rather than spelling an agent itself, so the plugin
# stays harness-agnostic: any agent with an adapter in agents/ can be picked via
# CODING_AGENT, and changing the default is this one line.
typeset -g DELTA_DEFAULT_AGENT=pi
