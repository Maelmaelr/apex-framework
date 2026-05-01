#!/usr/bin/env bash
# Step 6.b: shard preflight sizing + shard plan.
# Spec: apex-core.md step 6.b.
#
# Behavior:
#   - Read findings-{session}.json -> kept files list
#   - Optional --min-confidence drops entries below threshold BEFORE sharding
#     (used by scout1.md 6.b "screen-deterministic-only" branch)
#   - Mechanical: shard count = ceil(files / 15) (15 keeps Sonnet context comfortable)
#   - Boundary: top-level dir; when any dir holds > 15 files, sub-shard that dir
#     by file extension (file-type fallback per "top-level dir, file-type, or
#     import-edge cluster" enum). Resulting shards capped at 15 files each;
#     remainder folds into a final shard if oversize.
#   - Always emits poisoning telemetry to _meta: findings_count, shard_count,
#     deterministic_count, ripgrep_only_count, ripgrep_poisoned (true when zero
#     deterministic-layer files; surfaces from generic-keyword ripgrep fallout).
#   - If shard count > 8: append warning to _meta.warnings, exit 11 (orchestrator
#     reads _meta.ripgrep_poisoned to branch the AskUserQuestion contract per
#     scout1.md "AskUserQuestion contracts (orchestrator-side)")
#   - Read hypothesis from {session}-hypothesis.json (path passed as arg);
#     inject `original_prompt` + `hypothesis` verbatim into shared screening prompt
#   - Generate shard-plan-{session}.json (validated against shard-plan.schema.json)
#
# Args:
#   --session <token>          (required, 8-hex)
#   --findings <path>          (required) - .claude-tmp/scout/findings-{session}.json
#   --hypothesis <path>        (required) - .claude-tmp/apex-active/{session}-hypothesis.json
#   --min-confidence <level>   (optional) - drop findings entries with confidence
#                              below this level before sharding. One of
#                              low|medium|high (default: low = no filter).
#                              medium drops "low"; high drops "low"+"medium".
#
# Exit codes: 0 = success | 11 = shard count > 8 | 1 = unrecoverable error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOUT_DIR=".claude-tmp/scout"

SESSION=""
FINDINGS=""
HYPOTHESIS=""
MIN_CONFIDENCE="low"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)        SESSION="${2:-}";        shift 2 ;;
    --findings)       FINDINGS="${2:-}";       shift 2 ;;
    --hypothesis)     HYPOTHESIS="${2:-}";     shift 2 ;;
    --min-confidence) MIN_CONFIDENCE="${2:-}"; shift 2 ;;
    *) echo "shard-findings.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "$MIN_CONFIDENCE" in
  low|medium|high) ;;
  *) echo "shard-findings.sh: --min-confidence must be one of low|medium|high" >&2; exit 1 ;;
esac

if [[ -z "$SESSION" || ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "shard-findings.sh: --session required (8-hex)" >&2; exit 1
fi
if [[ -z "$FINDINGS" || ! -f "$FINDINGS" ]]; then
  echo "shard-findings.sh: --findings required and must exist" >&2; exit 1
fi
if [[ -z "$HYPOTHESIS" || ! -f "$HYPOTHESIS" ]]; then
  echo "shard-findings.sh: --hypothesis required and must exist" >&2; exit 1
fi

mkdir -p "$SCOUT_DIR"
OUTPUT="$SCOUT_DIR/shard-plan-${SESSION}.json"

python3 - "$FINDINGS" "$HYPOTHESIS" "$OUTPUT" "$SCRIPT_DIR" "$MIN_CONFIDENCE" <<'PY'
import json
import math
import os
import sys
from collections import defaultdict

sys.path.insert(0, sys.argv[4])
import _validate

findings_path, hypothesis_path, output_path, _script_dir, min_confidence = sys.argv[1:6]

# Consumer-validate findings (treats invalid as missing -> abort 1).
findings_doc = _validate.consumer_load(findings_path, "findings")
if findings_doc is None:
    print(
        f"shard-findings.sh: invalid or missing findings file: {findings_path}",
        file=sys.stderr,
    )
    sys.exit(1)

# Poisoning telemetry (computed against the FULL findings list before any
# --min-confidence filter, so the gate sees the unfiltered ground truth).
all_entries = findings_doc.get("findings", [])
deterministic_layers = {"static-imports", "ast-grep", "lsp", "framework"}


def is_deterministic(entry: dict) -> bool:
    return any(r.get("layer") in deterministic_layers for r in entry.get("reasons", []))


def is_ripgrep_only(entry: dict) -> bool:
    layers = {r.get("layer") for r in entry.get("reasons", [])}
    return bool(layers) and layers.issubset({"ripgrep"})


findings_count = len(all_entries)
deterministic_count = sum(1 for e in all_entries if is_deterministic(e))
ripgrep_only_count = sum(1 for e in all_entries if is_ripgrep_only(e))
ripgrep_poisoned = findings_count > 0 and deterministic_count == 0

# Optional --min-confidence filter (used by scout1.md "screen-deterministic-only"
# branch). Order: low < medium < high. Setting min=medium drops "low"; min=high
# drops "low"+"medium". Default min=low keeps everything.
order = {"low": 0, "medium": 1, "high": 2}
min_rank = order[min_confidence]
filtered_entries = [e for e in all_entries if order.get(e.get("confidence", "low"), 0) >= min_rank]
filter_drop_count = findings_count - len(filtered_entries)

files = [entry["file"] for entry in filtered_entries]
if not files:
    # Zero-layer / empty findings should have been caught at 6.a (exit 10).
    # Also reachable when --min-confidence dropped every entry. Treat as a
    # non-event: write an empty shard plan with a warning + telemetry and
    # exit 0 (downstream 6.c will produce empty screened.json).
    warnings = ["empty findings; no shards produced"]
    if filter_drop_count > 0:
        warnings.append(
            f"--min-confidence={min_confidence} dropped all {filter_drop_count} entries"
        )
    doc = {
        "shards": [],
        "screening_prompt": "",
        "_meta": {
            "warnings": warnings,
            "findings_count": findings_count,
            "shard_count": 0,
            "deterministic_count": deterministic_count,
            "ripgrep_only_count": ripgrep_only_count,
            "ripgrep_poisoned": ripgrep_poisoned,
            "min_confidence": min_confidence,
        },
    }
    _validate.producer_validate(doc, "shard-plan")
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
    sys.exit(0)


# --- Boundary clustering ---------------------------------------------------
# Findings carry realpath-canonicalized absolute paths from 6.a. For the
# purpose of "top-level dir" grouping we want the first path segment relative
# to the project root (CWD), so that `apps/`, `packages/`, `src/` etc. become
# the cluster keys. Files outside the project root keep their absolute first
# segment as a fallback bucket.
PROJECT_ROOT = os.path.realpath(os.getcwd())


def top_level_dir(path: str) -> str:
    """First path segment relative to project root, or '<root>' for files at root.

    Files outside the project root fall back to their absolute first segment so
    they cluster together rather than collapsing into '<root>'.
    """
    norm = os.path.realpath(path) if os.path.isabs(path) else os.path.normpath(path)
    if norm.startswith(PROJECT_ROOT + os.sep):
        rel = os.path.relpath(norm, PROJECT_ROOT)
        parts = [p for p in rel.split(os.sep) if p and p != "."]
    else:
        parts = [p for p in norm.split(os.sep) if p and p != "."]
    if not parts:
        return "<root>"
    return parts[0] if len(parts) > 1 else "<root>"


def extension(path: str) -> str:
    base = os.path.basename(path)
    if "." not in base:
        return "<noext>"
    return base.rsplit(".", 1)[1]


SHARD_CAP = 15

# Group by top-level dir.
by_dir: dict[str, list[str]] = defaultdict(list)
for f in files:
    by_dir[top_level_dir(f)].append(f)

shards: list[dict] = []
shard_idx = 0


def emit_shard(files_chunk: list[str], boundary_kind: str) -> None:
    global shard_idx
    if not files_chunk:
        return
    shards.append(
        {
            "shard_id": f"s{shard_idx:02d}",
            "files": files_chunk,
            "boundary_kind": boundary_kind,
        }
    )
    shard_idx += 1


for d, group in sorted(by_dir.items()):
    if len(group) <= SHARD_CAP:
        emit_shard(sorted(group), "top-level-dir")
        continue
    # File-type fallback: sub-shard by extension within this oversized dir.
    by_ext: dict[str, list[str]] = defaultdict(list)
    for f in group:
        by_ext[extension(f)].append(f)
    for ext, ext_group in sorted(by_ext.items()):
        # Cap each ext-group; carry remainder to a follow-on file-type shard.
        ext_group = sorted(ext_group)
        for i in range(0, len(ext_group), SHARD_CAP):
            emit_shard(ext_group[i : i + SHARD_CAP], "file-type")

# Mechanical sanity: ceil(files/15) is the minimum count given the cap.
expected_min = math.ceil(len(files) / SHARD_CAP)
if len(shards) < expected_min:
    # Should not happen, but defends against a logic regression.
    print(
        f"shard-findings.sh: shard count {len(shards)} < ceil({len(files)}/{SHARD_CAP})={expected_min}",
        file=sys.stderr,
    )
    sys.exit(1)


# --- Screening prompt template --------------------------------------------
with open(hypothesis_path, encoding="utf-8") as f:
    hyp = json.load(f)
original_prompt = hyp.get("original_prompt", "")
hypothesis = hyp.get("hypothesis", "")

screening_prompt = f"""You are a screener for apex step 6.c. Decide keep/drop per file in your shard.

## Hypothesis (verbatim from {{session}}-hypothesis.json)

original_prompt:
{original_prompt}

hypothesis:
{hypothesis}

## Decision rules

For each file in your shard, decide keep or drop with a free-text reason. Bias from confidence (forwarded from 6.a):
- confidence: low  -> drop UNLESS a positive relevance signal to the hypothesis
- confidence: high -> keep UNLESS a clear negative signal
- confidence: medium -> use judgment

## Output

Write `.claude-tmp/scout/shard-{{shard-id}}-{{session}}.json`:
  - kept[]:    {{file, screener_reason, reasons, confidence}}  (reasons + confidence forwarded VERBATIM from input)
  - dropped[]: {{file, screener_reason}}

Write trace `.claude-tmp/apex-active/{{session}}-traces/entryflow/screener-{{shard-id}}-attempt-N.md`
  (kept/dropped narrative, one-line reason per drop).

Return: JSON path + one-line status (e.g., "kept: 7, dropped: 3"). Never the findings body.
"""


# --- Output assembly + gate -----------------------------------------------
warnings: list[str] = []
if len(shards) > 8:
    warnings.append(f"scope likely overshot - {len(shards)} shards needed")
if ripgrep_poisoned:
    warnings.append(
        f"ripgrep-poisoned: {findings_count} findings, 0 deterministic-layer entries "
        f"(all from ripgrep keyword fallback - hypothesis text likely contained generic words)"
    )
if filter_drop_count > 0:
    warnings.append(
        f"--min-confidence={min_confidence} dropped {filter_drop_count} of {findings_count} entries before sharding"
    )

meta: dict = {
    "warnings": warnings,
    "findings_count": findings_count,
    "shard_count": len(shards),
    "deterministic_count": deterministic_count,
    "ripgrep_only_count": ripgrep_only_count,
    "ripgrep_poisoned": ripgrep_poisoned,
    "min_confidence": min_confidence,
}
doc: dict = {"shards": shards, "screening_prompt": screening_prompt, "_meta": meta}

try:
    _validate.producer_validate(doc, "shard-plan")
except _validate.ValidationError as e:
    print(f"shard-findings.sh: producer schema validation failed: {e}", file=sys.stderr)
    sys.exit(1)

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)

# Exit 11 on >8 shards so the orchestrator can surface the AskUserQuestion.
sys.exit(11 if len(shards) > 8 else 0)
PY

exit_code=$?
exit $exit_code
