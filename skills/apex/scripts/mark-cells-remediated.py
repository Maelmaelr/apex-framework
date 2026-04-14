#!/usr/bin/env python3
"""mark-cells-remediated.py -- Mark specific audit matrix cells as remediated.

Usage:
    python3 mark-cells-remediated.py <matrix-path> "target:CRITERION_ID" ...

Arguments:
    matrix-path       Path to the audit matrix JSON file
    target:CRITERION  One or more cell keys in "relative/path.ts:CRITERION_ID" format

Only cells with status "fail" are eligible for marking. Others are skipped silently.

Exit codes:
    0  Success (prints "Marked N cells as remediated")
    1  Usage error or file not found
"""
import json
import sys
from collections import Counter
from datetime import datetime, timezone


def main() -> int:
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <matrix-path> \"target:CRITERION_ID\" ...", file=sys.stderr)
        return 1

    path = sys.argv[1]
    cells_to_mark = set(sys.argv[2:])

    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"ERROR: Matrix file not found: {path}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid JSON in {path}: {e}", file=sys.stderr)
        return 1

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    marked = 0

    for cell in data["matrix"]:
        key = f"{cell['target']}:{cell['criterion']}"
        if key in cells_to_mark and cell["status"] == "fail":
            cell["status"] = "remediated"
            cell["remediated_at"] = now
            marked += 1

    data["updated"] = now

    c = Counter(cell["status"] for cell in data["matrix"])
    na_meta = data.get("pre_filter_na", {}).get("count", 0)
    total = len(data["matrix"]) + na_meta
    covered = total - c.get("unchecked", 0) - c.get("recheck", 0)

    data["summary"] = {
        "total_cells": total,
        "pass": c.get("pass", 0),
        "fail": c.get("fail", 0),
        "not_applicable": c.get("not_applicable", 0) + na_meta,
        "unchecked": c.get("unchecked", 0),
        "recheck": c.get("recheck", 0),
        "remediated": c.get("remediated", 0),
        "coverage_pct": round(covered / total * 100, 1) if total else 0.0,
    }

    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    print(f"Marked {marked} cells as remediated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
