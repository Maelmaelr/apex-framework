#!/usr/bin/env python3
# Usage: evaluator-sample.py --matrix <path> [--sample-pct 25] [--min-sample 3]
# Exit codes: 0 = sampled cells written, 1 = no PASS cells, 2 = error
"""Sample PASS cells from an audit matrix for evaluator re-verification.

Filters PASS cells, weights by criterion severity, random samples a subset,
and verifies file hashes are current. Outputs sampled cells as JSON to stdout.

Usage:
    evaluator-sample.py --matrix <path> [--sample-pct 25] [--min-sample 3]

Exit codes:
    0 = sampled cells written to stdout
    1 = no eligible PASS cells
    2 = error
"""

import argparse
import json
import os
import random
import subprocess
import sys


SEVERITY_WEIGHTS = {
    "critical": 3.0,
    "high": 2.0,
    "medium": 1.0,
    "low": 0.5,
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Sample PASS cells from audit matrix for evaluator re-verification.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Filters PASS cells from the matrix, weights by criterion severity
(CRITICAL 3x, HIGH 2x, MEDIUM 1x, LOW 0.5x), random-samples a
percentage, and verifies file hashes are current (skips stale).

Output: JSON array of sampled cells to stdout.

Exit codes:
  0 = success (sampled cells output)
  1 = no eligible PASS cells
  2 = error
""",
    )
    parser.add_argument(
        "--matrix",
        required=True,
        metavar="PATH",
        help="Path to the audit matrix JSON file",
    )
    parser.add_argument(
        "--sample-pct",
        type=int,
        default=25,
        metavar="N",
        help="Percentage of PASS cells to sample (default: 25)",
    )
    parser.add_argument(
        "--min-sample",
        type=int,
        default=3,
        metavar="N",
        help="Minimum number of cells to sample (default: 3)",
    )
    return parser.parse_args()


def compute_file_hash(file_path):
    """Compute content hash via git hash-object."""
    try:
        result = subprocess.run(
            ["git", "hash-object", "--", file_path],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except OSError:
        pass
    return None


def build_severity_map(criteria_list):
    """Build criterion ID -> severity mapping from matrix criteria section."""
    smap = {}
    for c in criteria_list:
        cid = c.get("id", "")
        severity = c.get("severity", "medium").lower()
        smap[cid] = severity
    return smap


def main():
    args = parse_args()

    # Load matrix
    try:
        with open(args.matrix, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"ERROR: Matrix file not found: {args.matrix}", file=sys.stderr)
        sys.exit(2)
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: Cannot parse matrix: {e}", file=sys.stderr)
        sys.exit(2)

    project_root = data.get("project_root", ".")
    matrix = data.get("matrix", [])
    criteria_list = data.get("criteria", [])
    severity_map = build_severity_map(criteria_list)

    # Filter PASS cells
    pass_cells = [c for c in matrix if c.get("status") == "pass"]

    if not pass_cells:
        print("No PASS cells found in matrix.", file=sys.stderr)
        sys.exit(1)

    # Verify file hashes are current (skip stale)
    eligible = []
    stale_count = 0
    for cell in pass_cells:
        target = cell.get("target", "")
        stored_hash = cell.get("file_hash")
        full_path = os.path.join(project_root, target)

        if not os.path.isfile(full_path):
            stale_count += 1
            continue

        if stored_hash is not None:
            current_hash = compute_file_hash(full_path)
            if current_hash is not None and current_hash != stored_hash:
                stale_count += 1
                continue

        eligible.append(cell)

    if stale_count > 0:
        print(
            f"Skipped {stale_count} stale cells (file changed since verdict).",
            file=sys.stderr,
        )

    if not eligible:
        print("No eligible PASS cells after hash verification.", file=sys.stderr)
        sys.exit(1)

    # Compute sample size
    sample_size = max(args.min_sample, len(eligible) * args.sample_pct // 100)
    sample_size = min(sample_size, len(eligible))

    # Build weights for weighted sampling
    weights = []
    for cell in eligible:
        criterion_id = cell.get("criterion", "")
        severity = severity_map.get(criterion_id, "medium")
        weights.append(SEVERITY_WEIGHTS.get(severity, 1.0))

    # Weighted random sample (without replacement)
    sampled = []
    remaining = list(range(len(eligible)))
    remaining_weights = list(weights)

    for _ in range(sample_size):
        if not remaining:
            break
        chosen = random.choices(remaining, weights=remaining_weights, k=1)[0]
        idx = remaining.index(chosen)
        sampled.append(eligible[chosen])
        remaining.pop(idx)
        remaining_weights.pop(idx)

    # Output sampled cells as JSON
    output = {
        "total_pass": len(pass_cells),
        "eligible": len(eligible),
        "stale_skipped": stale_count,
        "sampled": len(sampled),
        "cells": sampled,
    }
    json.dump(output, sys.stdout, indent=2)
    print()  # trailing newline

    sys.exit(0)


if __name__ == "__main__":
    main()
