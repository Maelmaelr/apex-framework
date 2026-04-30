#!/usr/bin/env bash
# Steps 10 / p1.4 / p2.5: heuristic-first script that runs BEFORE the reflector agent.
# Spec: apex-core.md step 10 / p1.4 / p2.5 | apex-core-overview.md Reflector.
#
# Heuristic categorisation of trace files:
#   - gap_signals    : trace content matches /error|failed|skip/i
#   - fix_attempts   : filename matches fix-attempt-<N>.md
#   - verbose_traces : >= VERBOSE_THRESHOLD lines (default 100)
# A trace is "novel" when it falls into none of the above buckets - useful
# reasoning that the heuristic cannot categorise. The reflector agent fires only
# when novel_flagged >= 1; the orchestrator gates on that count.
#
# Appends a structured block to ~/.claude/tmp/apex-workflow-improvements.md under
# fcntl LOCK_EX on ~/.claude/tmp/apex-workflow-improvements.md.lock (portable
# across macOS without a stock `flock` binary; serialises this script + the
# reflector agent + concurrent-session reflectors).
#
# Args:
#   --session <token>                       (required, 8-char lowercase hex)
#   --phase entryflow|entryflow+p1|p2       (required) - matches block name + trace input scope
#
# Phase -> trace input mapping:
#   entryflow      -> {session}-traces/entryflow/*.md
#   entryflow+p1   -> {session}-traces/entryflow/*.md + {session}-traces/p1/*.md
#   p2             -> {session}-traces/p2/*.md
#
# Output block format (single source of truth shared with reflector.md):
#   ## {session} - {phase}-heuristics - {timestamp}
#   - gap_signals: <count>
#   - fix_attempts: <count>
#   - verbose_traces: <count>
#   - novel_flagged: <count>
#   - novel_traces: <comma-separated trace paths, max 5>
#
# Exit code: 0 always. Failure modes are silent per spec ("errors logged").

# `set -e` would abort on the first heuristic that finds nothing; this script is
# best-effort and must always emit a block (even if all counts are zero) so the
# orchestrator can read the novel_flagged line for its gate decision.
set -uo pipefail

SESSION=""
PHASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    --phase)
      PHASE="${2:-}"
      shift 2
      ;;
    *)
      echo "reflect-traces.sh: unknown arg: $1" >&2
      exit 0
      ;;
  esac
done

if [[ -z "$SESSION" || -z "$PHASE" ]]; then
  echo "reflect-traces.sh: --session and --phase are required" >&2
  exit 0
fi

if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "reflect-traces.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2
  exit 0
fi

case "$PHASE" in
  entryflow|entryflow+p1|p2) ;;
  *)
    echo "reflect-traces.sh: invalid --phase: $PHASE (expected entryflow | entryflow+p1 | p2)" >&2
    exit 0
    ;;
esac

VERBOSE_THRESHOLD="${REFLECT_VERBOSE_THRESHOLD:-100}"

SESSION="$SESSION" PHASE="$PHASE" VERBOSE_THRESHOLD="$VERBOSE_THRESHOLD" \
python3 - <<'PY' || true
import datetime
import fcntl
import glob
import os
import re
import sys

session = os.environ["SESSION"]
phase = os.environ["PHASE"]
verbose_threshold = int(os.environ.get("VERBOSE_THRESHOLD", "100"))

phase_to_dirs = {
    "entryflow": ["entryflow"],
    "entryflow+p1": ["entryflow", "p1"],
    "p2": ["p2"],
}
trace_base = f".claude-tmp/apex-active/{session}-traces"
trace_dirs = [os.path.join(trace_base, d) for d in phase_to_dirs[phase]]

gap_re = re.compile(r"error|failed|skip", re.IGNORECASE)
fix_re = re.compile(r"^fix-attempt-\d+\.md$")

trace_paths: list[str] = []
for d in trace_dirs:
    if os.path.isdir(d):
        trace_paths.extend(sorted(glob.glob(os.path.join(d, "*.md"))))

gap_paths: set[str] = set()
fix_paths: set[str] = set()
verbose_paths: set[str] = set()

for path in trace_paths:
    base = os.path.basename(path)
    if fix_re.match(base):
        fix_paths.add(path)
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        continue
    if gap_re.search(content):
        gap_paths.add(path)
    if content.count("\n") >= verbose_threshold:
        verbose_paths.add(path)

categorised = gap_paths | fix_paths | verbose_paths
novel_paths = [p for p in trace_paths if p not in categorised]

timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
block = (
    f"## {session} - {phase}-heuristics - {timestamp}\n"
    f"- gap_signals: {len(gap_paths)}\n"
    f"- fix_attempts: {len(fix_paths)}\n"
    f"- verbose_traces: {len(verbose_paths)}\n"
    f"- novel_flagged: {len(novel_paths)}\n"
    f"- novel_traces: {', '.join(novel_paths[:5])}\n"
)

target = os.path.expanduser("~/.claude/tmp/apex-workflow-improvements.md")
lockfile = os.path.expanduser("~/.claude/tmp/apex-workflow-improvements.md.lock")
log = os.path.expanduser("~/.claude/tmp/reflector-errors.log")

# Ensure directory exists for both lockfile + target. Silent on permission failures
# - the script's contract is "errors logged, otherwise silent" per spec.
try:
    os.makedirs(os.path.dirname(lockfile), exist_ok=True)
except OSError as e:
    try:
        with open(log, "a", encoding="utf-8") as lg:
            lg.write(f"{timestamp} reflect-traces.sh: mkdir failed: {e}\n")
    except OSError:
        pass
    sys.exit(0)

try:
    with open(lockfile, "a") as lf:
        # fcntl.flock on a file descriptor; LOCK_UN is implicit on close. Wrap the
        # acquire in try/except so a missing fcntl primitive (extremely unlikely on
        # POSIX) degrades to unlocked append rather than aborting.
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        except OSError:
            pass
        try:
            need_nl = os.path.exists(target) and os.path.getsize(target) > 0
            with open(target, "a", encoding="utf-8") as t:
                if need_nl:
                    t.write("\n")
                t.write(block)
        finally:
            try:
                fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
except OSError as e:
    try:
        with open(log, "a", encoding="utf-8") as lg:
            lg.write(f"{timestamp} reflect-traces.sh: write failed: {e}\n")
    except OSError:
        pass
PY

exit 0
