#!/usr/bin/env bash
# Step 13: heuristic-first script that runs BEFORE the reflector agent.
# Spec: apex-core.md step 13.
#
# Categorises trace files under .claude-tmp/apex-active/{session}-traces/**/*.md:
#   gap_signals    : trace content matches /error|failed|skip/i
#   fix_attempts   : filename matches fix-N.md or fix-attempt-N.md (attempt- optional)
#   verbose_traces : >= VERBOSE_THRESHOLD lines (REFLECT_VERBOSE_THRESHOLD env, default 100)
# A trace is "novel" when it falls into none of the above. Reflector always fires;
# novel_flagged is informational. The novel_traces line drives focus selection.
#
# Composes the block in python (stdout) and pipes to append-with-lock.sh, which
# owns the portable fcntl.flock idiom (macOS lacks flock(1); literal `flock(1)`
# call silently drops the analysis - see append-with-lock.sh).
#
# Args:
#   --session <token>   (required, 8-char lowercase hex)
#
# Block format (single source of truth shared with reflector.md):
#   ## {session} - heuristics - {timestamp}
#   - gap_signals: <count>
#   - fix_attempts: <count>
#   - verbose_traces: <count>
#   - novel_flagged: <count>
#   - novel_traces: <comma-separated trace paths, max 5>
#
# Exit code: 0 always (fail-silent per spec). Arg-parse errors emit stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CWD anchor: the Python heredoc below reads .claude-tmp/apex-active/{session}-traces
# as a relative path; without this anchor an unexpected caller CWD silently produces
# all-zero heuristics.
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

SESSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION="${2:-}"; shift 2 ;;
    *) echo "reflect-traces.sh: unknown arg: $1" >&2; exit 0 ;;
  esac
done

if [[ -z "$SESSION" ]]; then
  echo "reflect-traces.sh: --session is required" >&2
  exit 0
fi

[[ "$SESSION" =~ ^[0-9a-f]{8}$ ]] || { echo "reflect-traces.sh: bad --session: $SESSION" >&2; exit 0; }

VERBOSE_THRESHOLD="${REFLECT_VERBOSE_THRESHOLD:-100}"

# Compose block on stdout; pipe to the lock-and-append helper. Empty stdin
# (python crash) -> helper exits 0 silently per its contract. `|| true` pins
# the script's exit to 0 across all pipe-stage failures.
SESSION="$SESSION" VERBOSE_THRESHOLD="$VERBOSE_THRESHOLD" \
python3 - <<'PY' | bash "$SCRIPT_DIR/append-with-lock.sh" "$HOME/.claude/tmp/apex-workflow-improvements.md" || true
import datetime, glob, os, re, sys

session = os.environ["SESSION"]
threshold = int(os.environ.get("VERBOSE_THRESHOLD", "100"))

trace_base = f".claude-tmp/apex-active/{session}-traces"
trace_paths: list[str] = []
if os.path.isdir(trace_base):
    for root, _, files in os.walk(trace_base):
        for f in sorted(files):
            if f.endswith(".md"):
                trace_paths.append(os.path.join(root, f))
trace_paths.sort()

gap_re = re.compile(r"error|failed|skip", re.IGNORECASE)
fix_re = re.compile(r"^fix-(?:attempt-)?\d+\.md$")
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
    f"## {session} - heuristics - {ts}\n"
    f"- gap_signals: {len(gap)}\n"
    f"- fix_attempts: {len(fix)}\n"
    f"- verbose_traces: {len(verbose)}\n"
    f"- novel_flagged: {len(novel)}\n"
    f"- novel_traces: {', '.join(novel[:5])}\n"
)
PY
