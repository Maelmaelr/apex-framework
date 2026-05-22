#!/usr/bin/env bash
# /apex-merge step 4.5: collect + dedupe + replay worktree side-effect commands.
# Spec: skills/apex-merge/SKILL.md step 4.5.
#
# Reads each merged session's {session}-side-effects.jsonl from its worktree
# BEFORE step 5 removes the worktree, aggregates the unique cmd set across all
# merged sessions, and prints the deduped commands to stdout (one per line) for
# the orchestrator to surface via AskUserQuestion + run on the main worktree.
#
# Side-effects file shape (one JSON object per line, written by executor):
#   {"cmd": "<verbatim shell command>", "ts": "<iso8601>"}
#
# Dedupe key = the cmd string verbatim (whitespace-normalized: collapse runs of
# whitespace to one space, strip leading/trailing). Same command across two
# sessions runs once.
#
# Args:
#   <run>                    required, 8-hex apex-merge run token
#   --out <path>             optional override (default:
#                            .claude-tmp/apex-merge-active/<run>-side-effects-dedup.json)
#
# Output:
#   <out> path receives JSON:
#     {"run":"<run>","unique_cmds":["<cmd>", ...],
#      "by_session":{"<session>":["<cmd>", ...], ...}}
#   stdout lists each unique cmd, one per line (for AskUserQuestion preview).
#
# Exit codes:
#   0  - aggregation ran (zero-or-more cmds)
#   1  - bad args
#   2  - merge-result missing / unreadable

set -uo pipefail

RUN=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    -*)
      echo "replay-side-effects.sh: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$RUN" ]]; then RUN="$1"
      else
        echo "replay-side-effects.sh: unexpected positional arg: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$RUN" || ! "$RUN" =~ ^[0-9a-f]{8}$ ]]; then
  echo "replay-side-effects.sh: <run> is required (8-hex token)" >&2
  exit 1
fi

ACTIVE_DIR="$HOME/.claude/.claude-tmp/apex-merge-active"
RESULT="$ACTIVE_DIR/$RUN-merge-result.json"
[[ -z "$OUT" ]] && OUT="$ACTIVE_DIR/$RUN-side-effects-dedup.json"

if [[ ! -f "$RESULT" ]]; then
  echo "replay-side-effects.sh: merge-result not found: $RESULT" >&2
  exit 2
fi

MAIN_TOP="$(cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && pwd -P || true)"
if [[ -z "$MAIN_TOP" ]]; then
  echo "replay-side-effects.sh: not inside a git repo" >&2
  exit 2
fi

python3 - "$RESULT" "$MAIN_TOP" "$OUT" <<'PY'
import json, os, re, sys
from pathlib import Path

result_path, main_top, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
result = json.loads(Path(result_path).read_text())

ws = re.compile(r"\s+")
seen = set()
unique = []
by_session = {}

for entry in result:
    if entry.get("status") != "merged":
        continue
    branch = entry.get("branch", "")
    if not branch.startswith("apex/"):
        continue
    session = branch[len("apex/"):]
    log = Path(main_top) / ".apex-worktrees" / session / ".claude-tmp" / "apex-active" / f"{session}-side-effects.jsonl"
    if not log.is_file():
        continue
    cmds = []
    for line in log.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        cmd = rec.get("cmd", "")
        if not cmd:
            continue
        key = ws.sub(" ", cmd).strip()
        if not key:
            continue
        cmds.append(key)
        if key in seen:
            continue
        seen.add(key)
        unique.append(key)
    if cmds:
        by_session[session] = cmds

Path(out_path).write_text(json.dumps({
    "run": os.path.basename(out_path).split("-")[0],
    "unique_cmds": unique,
    "by_session": by_session,
}, indent=2))

for cmd in unique:
    print(cmd)
PY

exit 0
