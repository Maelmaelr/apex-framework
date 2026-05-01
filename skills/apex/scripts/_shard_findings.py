#!/usr/bin/env python3
"""Step 6.b: shard preflight sizing + shard plan. Spec: apex-core.md step 6.b.

Reads findings-{session}.json, applies optional --min-confidence filter, groups
files by top-level dir (sub-sharding by file extension when any dir holds > 15
files), emits shard-plan-{session}.json with telemetry + screening prompt.

Args:
  --findings PATH        (required) - findings-{session}.json
  --hypothesis PATH      (required) - {session}-hypothesis.json
  --output PATH          (required) - shard-plan-{session}.json
  --min-confidence LEV   (optional) - low|medium|high (default low = no filter)

Exit codes: 0 = success | 11 = shard count > 8 | 1 = unrecoverable error
"""
from __future__ import annotations
import argparse
import json
import math
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _validate  # noqa: E402

DETERMINISTIC = {"static-imports", "ast-grep", "framework"}
SHARD_CAP = 15


def is_deterministic(entry: dict) -> bool:
    return any(r.get("layer") in DETERMINISTIC for r in entry.get("reasons", []))


def is_ripgrep_only(entry: dict) -> bool:
    layers = {r.get("layer") for r in entry.get("reasons", [])}
    return bool(layers) and layers.issubset({"ripgrep"})


def top_level_dir(path: str, project_root: str) -> str:
    """First path segment relative to project root, or '<root>' for files at root.

    Files outside the project root keep their absolute first segment as a
    fallback bucket so they cluster together rather than collapsing into '<root>'.
    """
    norm = os.path.realpath(path) if os.path.isabs(path) else os.path.normpath(path)
    if norm.startswith(project_root + os.sep):
        rel = os.path.relpath(norm, project_root)
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


def screening_prompt(original_prompt: str, hypothesis: str) -> str:
    return f"""You are a screener for apex step 6.c. Decide keep/drop per file in your shard.

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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--findings", required=True)
    ap.add_argument("--hypothesis", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--min-confidence", default="low", choices=("low", "medium", "high"))
    args = ap.parse_args()

    findings_doc = _validate.consumer_load(args.findings, "findings")
    if findings_doc is None:
        print(f"_shard_findings.py: invalid or missing findings file: {args.findings}", file=sys.stderr)
        return 1

    all_entries = findings_doc.get("findings", [])
    findings_count = len(all_entries)
    deterministic_count = sum(1 for e in all_entries if is_deterministic(e))
    ripgrep_only_count = sum(1 for e in all_entries if is_ripgrep_only(e))
    ripgrep_poisoned = findings_count > 0 and deterministic_count == 0

    order = {"low": 0, "medium": 1, "high": 2}
    min_rank = order[args.min_confidence]
    filtered = [e for e in all_entries if order.get(e.get("confidence", "low"), 0) >= min_rank]
    filter_drop_count = findings_count - len(filtered)

    files = [e["file"] for e in filtered]
    if not files:
        warnings = ["empty findings; no shards produced"]
        if filter_drop_count > 0:
            warnings.append(
                f"--min-confidence={args.min_confidence} dropped all {filter_drop_count} entries"
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
                "min_confidence": args.min_confidence,
            },
        }
        _validate.producer_validate(doc, "shard-plan")
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2)
        return 0

    project_root = os.path.realpath(os.getcwd())

    by_dir: dict[str, list[str]] = defaultdict(list)
    for f in files:
        by_dir[top_level_dir(f, project_root)].append(f)

    shards: list[dict] = []
    shard_idx = 0

    def emit_shard(chunk: list[str], boundary: str) -> None:
        nonlocal shard_idx
        if not chunk:
            return
        shards.append({"shard_id": f"s{shard_idx:02d}", "files": chunk, "boundary_kind": boundary})
        shard_idx += 1

    for d, group in sorted(by_dir.items()):
        if len(group) <= SHARD_CAP:
            emit_shard(sorted(group), "top-level-dir")
            continue
        by_ext: dict[str, list[str]] = defaultdict(list)
        for f in group:
            by_ext[extension(f)].append(f)
        for _ext, ext_group in sorted(by_ext.items()):
            ext_group = sorted(ext_group)
            for i in range(0, len(ext_group), SHARD_CAP):
                emit_shard(ext_group[i: i + SHARD_CAP], "file-type")

    expected_min = math.ceil(len(files) / SHARD_CAP)
    if len(shards) < expected_min:
        print(
            f"_shard_findings.py: shard count {len(shards)} < ceil({len(files)}/{SHARD_CAP})={expected_min}",
            file=sys.stderr,
        )
        return 1

    with open(args.hypothesis, encoding="utf-8") as f:
        hyp = json.load(f)

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
            f"--min-confidence={args.min_confidence} dropped {filter_drop_count} of {findings_count} entries before sharding"
        )

    doc = {
        "shards": shards,
        "screening_prompt": screening_prompt(hyp.get("original_prompt", ""), hyp.get("hypothesis", "")),
        "_meta": {
            "warnings": warnings,
            "findings_count": findings_count,
            "shard_count": len(shards),
            "deterministic_count": deterministic_count,
            "ripgrep_only_count": ripgrep_only_count,
            "ripgrep_poisoned": ripgrep_poisoned,
            "min_confidence": args.min_confidence,
        },
    }

    try:
        _validate.producer_validate(doc, "shard-plan")
    except _validate.ValidationError as e:
        print(f"_shard_findings.py: producer schema validation failed: {e}", file=sys.stderr)
        return 1

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)

    return 11 if len(shards) > 8 else 0


if __name__ == "__main__":
    sys.exit(main())
