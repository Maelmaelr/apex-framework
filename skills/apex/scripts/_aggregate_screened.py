#!/usr/bin/env python3
"""Step 6.c aggregator: merge per-shard JSONs -> screened-{session}.json.

Spec: apex-core.md step 6.c aggregator + scout1.md "6.c aggregator inline body".

Reads `.claude-tmp/scout/shard-*-{session}.json` (one per shard), validates each
against shard.schema.json (consumer-validate), concatenates kept + dropped lists
into a single screened doc, validates against screened.schema.json before write.

`reasons` and `confidence` on kept entries are preserved VERBATIM from per-shard
output (which preserved them from 6.a findings) - this is the contract verify
(8) relies on for confidence-aware screening.

Args:
  --session <token>     (required, 8-hex)
  --output <path>       (required) - .claude-tmp/scout/screened-{session}.json

Exit codes: 0 = success | 1 = error (no shards found, schema invalid, etc.)
"""
from __future__ import annotations
import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _validate  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    if len(args.session) != 8 or not all(c in "0123456789abcdef" for c in args.session):
        print(f"_aggregate_screened.py: invalid session token: {args.session}", file=sys.stderr)
        return 1

    pattern = f".claude-tmp/scout/shard-*-{args.session}.json"
    shard_paths = sorted(glob.glob(pattern))
    if not shard_paths:
        print(f"_aggregate_screened.py: no shard files matched {pattern}", file=sys.stderr)
        return 1

    kept: list[dict] = []
    dropped: list[dict] = []
    invalid_paths: list[str] = []

    for p in shard_paths:
        shard = _validate.consumer_load(p, "shard")
        if shard is None:
            invalid_paths.append(p)
            continue
        kept.extend(shard.get("kept", []))
        dropped.extend(shard.get("dropped", []))

    if invalid_paths and not kept and not dropped:
        # Every shard was invalid - aggregation has nothing to do; surface as error.
        print(
            f"_aggregate_screened.py: all {len(invalid_paths)} shard files invalid",
            file=sys.stderr,
        )
        return 1

    doc: dict = {"kept": kept, "dropped": dropped}
    if invalid_paths:
        doc.setdefault("_meta", {})["warnings"] = [
            f"skipped {len(invalid_paths)} invalid shard file(s)"
        ]

    try:
        _validate.producer_validate(doc, "screened")
    except _validate.ValidationError as e:
        print(f"_aggregate_screened.py: schema validation failed: {e}", file=sys.stderr)
        return 1

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)

    return 0


if __name__ == "__main__":
    sys.exit(main())
