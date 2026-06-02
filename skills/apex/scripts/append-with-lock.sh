#!/usr/bin/env bash
# Append stdin content to <target> under a portable Python fcntl.flock LOCK_EX
# guard. Spec: agents/reflector.md output contract.
#
# Centralizes the lock-and-append idiom that scripts/reflect-traces.sh
# previously implemented inline (pre-extraction) so the reflector agent can use a
# single helper call instead of re-deriving the lock logic per invocation.
#
# Why a helper exists: macOS lacks `flock(1)`. A literal `flock <lockfile> -c
# 'cat >> <target>'` silently fails on macOS (the binary is missing from
# /usr/local/bin); the LLM-composed Bash command swallows the error and the
# structured analysis block is lost. Python's `fcntl.flock` is portable across
# macOS / Linux / BSD and is the canonical primitive used in the reflect-traces
# script already.
#
# Behavior:
#   - Acquires LOCK_EX on "<target>.lock" (creating the lockfile if absent).
#   - Inserts a single leading newline if the target is non-empty so successive
#     blocks don't run together.
#   - Appends stdin verbatim.
#   - Releases lock on close (fcntl.LOCK_UN).
#   - Empty stdin -> exit 0 silently (caller's no-op contract).
#   - Lock acquire failure (extremely unusual on POSIX) -> degrades to unlocked
#     append rather than abort; the same fail-silent posture as reflect-traces.sh.
#
# Args:
#   $1   <target>   absolute or repo-relative path to the append target.
#                   Lockfile path is "$target.lock"; parent dir is created if missing.
#
# Stdin: content to append (verbatim, no trailing-newline manipulation beyond
# the leading-newline-on-non-empty-target rule above).
#
# Exit codes:
#   0   appended (or stdin was empty)
#   1   bad args (missing $1)
#   2   write failure (logged to ~/.claude/tmp/reflector-errors.log; surface to
#       caller for retry decisions)

set -uo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "Usage: append-with-lock.sh <target>" >&2
  exit 1
fi

# Inline python via `-c`. NOTE: do NOT use a heredoc redirect here - that would
# replace the helper's stdin (the actual content to append) with the script
# source itself, leaving content="<python source>" and an empty target file.
# The `-c <source>` form keeps stdin available for sys.stdin.read().
exec python3 -c '
import datetime
import fcntl
import os
import sys

target = sys.argv[1]
lockfile = target + ".lock"
content = sys.stdin.read()
if not content:
    sys.exit(0)

errlog = os.path.expanduser("~/.claude/tmp/reflector-errors.log")
parent = os.path.dirname(lockfile) or "."

def log_err(msg):
    try:
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(errlog, "a", encoding="utf-8") as lg:
            lg.write(f"{ts} append-with-lock.sh: {msg}\n")
    except OSError:
        pass

try:
    os.makedirs(parent, exist_ok=True)
except OSError as e:
    log_err(f"mkdir failed for {parent}: {e}")
    sys.exit(2)

try:
    with open(lockfile, "a") as lf:
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        except OSError:
            pass
        try:
            need_nl = os.path.exists(target) and os.path.getsize(target) > 0
            with open(target, "a", encoding="utf-8") as t:
                if need_nl:
                    t.write("\n")
                t.write(content)
        finally:
            try:
                fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
except OSError as e:
    log_err(f"write failed on {target}: {e}")
    sys.exit(2)
' "$1"
