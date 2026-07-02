#!/usr/bin/env bash
# find-claude-pid.sh -- print the OS pid of the closest claude (Claude Code main
# process) ancestor of THIS shell. Walks up the process tree from $$ via
# `ps -o ppid=` until either the basename of `ps -o comm=` is "claude" or the
# walk hits init (pid 1) / a missing parent.
#
# Why this exists:
#   `$PPID` inside `bash some_script.sh` is the parent shell of the bash
#   subprocess (Claude Code's Bash tool spawns a transient zsh subshell which
#   then runs `bash`; $PPID inside the bash script == zsh pid, NOT claude pid).
#   The transient zsh dies as soon as the Bash tool call returns, leaving any
#   manifest `pid` field set to a dead pid. This helper resolves the actual
#   claude pid so manifest.pid stays alive for the lifetime of the apex run.
#
# Output:
#   - On hit: prints the claude pid to stdout, exits 0.
#   - On miss (no claude found within MAX_DEPTH steps): exits 1 with stderr
#     warning. Caller is expected to fall back to $PPID.
#
# Args: none. Reads $$ at start.
#
# Notes:
#   - macOS BSD `ps -o comm=` returns the absolute executable path; basename
#     normalises to the binary name.
#   - PID-rollover guard: `comm` basename must equal "claude". Any other
#     binary in the ancestry chain is skipped.
#   - MAX_DEPTH=8 covers cmux / tmux / screen / shell wrappers without infinite
#     loops on broken process trees.

set -uo pipefail

MAX_DEPTH=8
cur=$$

for _ in $(seq 1 "$MAX_DEPTH"); do
  parent=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
  [[ -z "$parent" || "$parent" == "0" || "$parent" == "1" ]] && break
  comm=$(ps -o comm= -p "$parent" 2>/dev/null)
  base=$(basename "$comm" 2>/dev/null)
  if [[ "$base" == "claude" ]]; then
    echo "$parent"
    exit 0
  fi
  cur="$parent"
done

echo "find-claude-pid.sh: no claude ancestor found within $MAX_DEPTH steps from \$\$=$$" >&2
exit 1
