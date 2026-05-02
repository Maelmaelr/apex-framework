#!/usr/bin/env bash
# Steps 10 / p1.4 / p2.5: heuristic-first script that runs BEFORE the reflector agent.
# Spec: apex-core.md step 10 / p1.4 / p2.5 | apex-core-overview.md step 10 / p1.4 / p2.5.
#
# Categorises trace files:
#   gap_signals    : trace content matches /error|failed|skip/i
#   fix_attempts   : filename matches fix-attempt-<N>.md
#   verbose_traces : >= VERBOSE_THRESHOLD lines (REFLECT_VERBOSE_THRESHOLD env, default 100)
# A trace is "novel" when it falls into none of the above. Reflector always fires;
# novel_flagged is informational. The novel_traces line drives focus selection.
#
# Composes the block in python (stdout) and pipes to append-with-lock.sh, which
# owns the portable fcntl.flock idiom (macOS lacks flock(1); literal `flock(1)`
# call silently drops the analysis - see append-with-lock.sh).
#
# Args:
#   --session <token>                  (required, 8-char lowercase hex)
#   --phase entryflow|entryflow+p1|p2  (required) - matches block name + trace dirs
#
# Block format (single source of truth shared with reflector.md):
#   ## {session} - {phase}-heuristics - {timestamp}
#   - gap_signals: <count>
#   - fix_attempts: <count>
#   - verbose_traces: <count>
#   - novel_flagged: <count>
#   - novel_traces: <comma-separated trace paths, max 5>
#
# Exit code: 0 always (fail-silent per spec). Arg-parse errors emit stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION=""
PHASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION="${2:-}"; shift 2 ;;
    --phase)   PHASE="${2:-}";   shift 2 ;;
    *) echo "reflect-traces.sh: unknown arg: $1" >&2; exit 0 ;;
  esac
done

if [[ -z "$SESSION" || -z "$PHASE" ]]; then
  echo "reflect-traces.sh: --session and --phase are required" >&2
  exit 0
fi

[[ "$SESSION" =~ ^[0-9a-f]{8}$ ]] || { echo "reflect-traces.sh: bad --session: $SESSION" >&2; exit 0; }

case "$PHASE" in
  entryflow|entryflow+p1|p2) ;;
  *) echo "reflect-traces.sh: bad --phase: $PHASE" >&2; exit 0 ;;
esac

VERBOSE_THRESHOLD="${REFLECT_VERBOSE_THRESHOLD:-100}"

# Compose block on stdout; pipe to the lock-and-append helper. Empty stdin
# (python crash) -> helper exits 0 silently per its contract. `|| true` pins
# the script's exit to 0 across all pipe-stage failures.
SESSION="$SESSION" PHASE="$PHASE" VERBOSE_THRESHOLD="$VERBOSE_THRESHOLD" \
python3 - <<'PY' | bash "$SCRIPT_DIR/append-with-lock.sh" "$HOME/.claude/tmp/apex-workflow-improvements.md" || true
import datetime, glob, os, re, sys

session = os.environ["SESSION"]
phase = os.environ["PHASE"]
threshold = int(os.environ.get("VERBOSE_THRESHOLD", "100"))

phase_dirs = {"entryflow": ["entryflow"], "entryflow+p1": ["entryflow", "p1"], "p2": ["p2"]}
trace_base = f".claude-tmp/apex-active/{session}-traces"
trace_paths: list[str] = []
for d in phase_dirs[phase]:
    full = os.path.join(trace_base, d)
    if os.path.isdir(full):
        trace_paths.extend(sorted(glob.glob(os.path.join(full, "*.md"))))

gap_re = re.compile(r"error|failed|skip", re.IGNORECASE)
fix_re = re.compile(r"^fix-attempt-\d+\.md$")
gap, fix, verbose = set(), set(), set()
for p in trace_paths:
    if fix_re.match(os.path.basename(p)):
        fix.add(p)
    try:
        c = open(p, encoding="utf-8").read()
    except OSError:
        continue
    if gap_re.search(c):
        gap.add(p)
    if c.count("\n") >= threshold:
        verbose.add(p)
novel = [p for p in trace_paths if p not in (gap | fix | verbose)]

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
sys.stdout.write(
    f"## {session} - {phase}-heuristics - {ts}\n"
    f"- gap_signals: {len(gap)}\n"
    f"- fix_attempts: {len(fix)}\n"
    f"- verbose_traces: {len(verbose)}\n"
    f"- novel_flagged: {len(novel)}\n"
    f"- novel_traces: {', '.join(novel[:5])}\n"
)
PY
