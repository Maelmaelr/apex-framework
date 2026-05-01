#!/usr/bin/env python3
"""Step 6.a layer-3 LSP agent merge.

Spec: apex-core.md step 6.a (LSP layer; hybrid integration) + scout1.md routing.

Folds lsp-agent-{session}.json (from agents/lsp-scout.md) into
findings-{session}.json as additional layer=lsp reasons before 6.b sharding.

For each entry in lsp-agent.found[]:
  - If file already in findings, append a layer=lsp reason (dedup by detail).
  - If file not in findings, add a new entry with reasons=[{layer=lsp, ...}].
After merge, recompute confidence per the same rule as _enumerate_merge.py:
  - 3+ deterministic layers (static-imports / ast-grep / lsp / framework) -> high
  - 1-2 deterministic                                                     -> medium
  - ripgrep-only                                                          -> low

Inputs:
  --findings PATH    (required) - findings-{session}.json (read+write)
  --lsp-agent PATH   (required) - lsp-agent-{session}.json (read-only)

Exit codes:
  0 - merged (or no-op when lsp-agent.found[] is empty)
  1 - schema validation failed (input or output)
  2 - missing input file

Idempotent: safe to re-invoke; layer=lsp reasons are deduped by detail per file.
"""
from __future__ import annotations
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _validate  # noqa: E402

DETERMINISTIC = {"static-imports", "ast-grep", "lsp", "framework"}


def confidence_for(reasons: list[dict]) -> str:
    det = sum(1 for r in reasons if r["layer"] in DETERMINISTIC)
    if det >= 3:
        return "high"
    if det >= 1:
        return "medium"
    return "low"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--findings", required=True)
    ap.add_argument("--lsp-agent", required=True)
    args = ap.parse_args()

    if not os.path.isfile(args.findings):
        print(f"merge-lsp-agent.py: findings not found: {args.findings}", file=sys.stderr)
        return 2
    if not os.path.isfile(args.lsp_agent):
        print(f"merge-lsp-agent.py: lsp-agent not found: {args.lsp_agent}", file=sys.stderr)
        return 2

    findings_doc = _validate.consumer_load(args.findings, "findings")
    if findings_doc is None:
        print(f"merge-lsp-agent.py: findings invalid or unreadable: {args.findings}", file=sys.stderr)
        return 1
    lsp_doc = _validate.consumer_load(args.lsp_agent, "lsp-agent")
    if lsp_doc is None:
        print(f"merge-lsp-agent.py: lsp-agent invalid or unreadable: {args.lsp_agent}", file=sys.stderr)
        return 1

    by_file = {entry["file"]: entry for entry in findings_doc.get("findings", [])}

    added = 0
    augmented = 0
    for item in lsp_doc.get("found", []):
        f = item["file"]
        detail = item.get("detail", "")
        line_range = item.get("line_range")
        reason = {"layer": "lsp", "detail": detail, "line_range": line_range}
        if f in by_file:
            entry = by_file[f]
            if any(r["layer"] == "lsp" and r["detail"] == detail for r in entry["reasons"]):
                continue
            entry["reasons"].append(reason)
            augmented += 1
        else:
            by_file[f] = {"file": f, "reasons": [reason], "confidence": "medium"}
            added += 1

    for entry in by_file.values():
        entry["confidence"] = confidence_for(entry["reasons"])

    findings_doc["findings"] = list(by_file.values())

    meta = findings_doc.setdefault("_meta", {})
    warnings = meta.setdefault("warnings", [])
    if added or augmented:
        warnings.append(
            f"lsp-agent merged: +{added} new files, +{augmented} augmented"
        )

    try:
        _validate.producer_validate(findings_doc, "findings")
    except _validate.ValidationError as e:
        print(f"merge-lsp-agent.py: post-merge findings invalid: {e}", file=sys.stderr)
        return 1

    with open(args.findings, "w", encoding="utf-8") as fp:
        json.dump(findings_doc, fp, indent=2)

    return 0


if __name__ == "__main__":
    sys.exit(main())
