#!/usr/bin/env python3
"""Step 7.x: merge rescout-{session}.json into screened-{session}.json.

Spec: apex-core.md step 7.x.

Rescout findings are merged as kept (pre-trusted, no re-screening). Rationale:
preflight already named the missed region as relevant, so the keep/drop signal
has been delivered upstream.

Dedupe rules (file paths canonicalized via realpath):
  - if file already in `kept`: append {layer: rescout, ...} to existing reasons[]
    (confidence stays as deterministic-layer-count-derived value; rescout is
    special-cased out of the formula)
  - if file already in `dropped`: move to `kept` with reasons: [{layer: rescout, ...}]
    and rescout-derived confidence (rescout overrides screener-drop because
    preflight explicitly named the region relevant)
  - if file not in either: add as new `kept` entry

Rescout-derived confidence: medium by default; high with explicit line_range.

Args:
  --screened PATH    (required) - screened-{session}.json (read + rewritten in place)
  --rescout PATH     (required) - rescout-{session}.json

Validates both files against schemas before read; validates merged output before write.

Exit codes: 0 = success | 1 = error (file missing, schema invalid, write failed)
"""
from __future__ import annotations
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _validate  # noqa: E402


def _canonical(path: str) -> str:
    return os.path.realpath(path)


def _rescout_reason(found_entry: dict) -> dict:
    return {
        "layer": "rescout",
        "detail": found_entry["reason"],
        "line_range": found_entry.get("line_range"),
    }


def _rescout_confidence(found_entry: dict) -> str:
    return "high" if found_entry.get("line_range") else "medium"


def _new_kept_entry(found_entry: dict) -> dict:
    return {
        "file": found_entry["file"],
        "screener_reason": f"rescout: {found_entry['reason']}",
        "reasons": [_rescout_reason(found_entry)],
        "confidence": _rescout_confidence(found_entry),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--screened", required=True)
    ap.add_argument("--rescout", required=True)
    args = ap.parse_args()

    screened = _validate.consumer_load(args.screened, "screened")
    if screened is None:
        print(
            f"merge-scout-findings.py: screened file missing or invalid: {args.screened}",
            file=sys.stderr,
        )
        return 1

    rescout = _validate.consumer_load(args.rescout, "rescout")
    if rescout is None:
        print(
            f"merge-scout-findings.py: rescout file missing or invalid: {args.rescout}",
            file=sys.stderr,
        )
        return 1

    kept: list[dict] = list(screened.get("kept", []))
    dropped: list[dict] = list(screened.get("dropped", []))

    kept_idx_by_realpath: dict[str, int] = {
        _canonical(e["file"]): i for i, e in enumerate(kept)
    }
    dropped_idx_by_realpath: dict[str, int] = {
        _canonical(e["file"]): i for i, e in enumerate(dropped)
    }
    moved_from_dropped: set[int] = set()

    for found in rescout.get("found", []):
        rp = _canonical(found["file"])

        if rp in kept_idx_by_realpath:
            existing = kept[kept_idx_by_realpath[rp]]
            existing.setdefault("reasons", []).append(_rescout_reason(found))
            continue

        if rp in dropped_idx_by_realpath:
            moved_from_dropped.add(dropped_idx_by_realpath[rp])
            new_entry = _new_kept_entry(found)
            kept.append(new_entry)
            kept_idx_by_realpath[rp] = len(kept) - 1
            continue

        new_entry = _new_kept_entry(found)
        kept.append(new_entry)
        kept_idx_by_realpath[rp] = len(kept) - 1

    if moved_from_dropped:
        dropped = [e for i, e in enumerate(dropped) if i not in moved_from_dropped]

    merged: dict = {"kept": kept, "dropped": dropped}
    if "_meta" in screened:
        merged["_meta"] = screened["_meta"]

    try:
        _validate.producer_validate(merged, "screened")
    except _validate.ValidationError as e:
        print(f"merge-scout-findings.py: schema validation failed: {e}", file=sys.stderr)
        return 1

    try:
        with open(args.screened, "w", encoding="utf-8") as f:
            json.dump(merged, f, indent=2)
    except OSError as e:
        print(f"merge-scout-findings.py: write failed: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
