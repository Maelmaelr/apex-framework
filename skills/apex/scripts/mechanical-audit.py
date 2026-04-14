#!/usr/bin/env python3
# Usage: mechanical-audit.py --matrix <path> --catalog <path>
# Runs deterministic shell checks for mechanical audit cells (file existence, grep, count).
# Skips cells that require LLM judgment. Updates matrix JSON in-place.
# Exit 0 = cells checked, Exit 1 = no mechanical cells found, Exit 2 = error.

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

# Append parent dir so audit_matrix_lib is importable when invoked from any cwd
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from audit_matrix_lib import compute_file_hash, compute_summary, parse_catalog


# Description patterns that indicate a mechanical (non-judgment) criterion.
# Only match explicit structural assertions, not behavioral descriptions
# that happen to contain words like "present" or "exists".
MECHANICAL_DESC_PATTERNS = [
    re.compile(r"^File\s+\S+\s+exists", re.IGNORECASE),
    re.compile(r"^Pattern\s+`.+`\s+appears\s+in", re.IGNORECASE),
    re.compile(r"^At\s+least\s+\d+\s+instances?\s+of", re.IGNORECASE),
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run deterministic shell checks for mechanical audit cells.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Classifies unchecked/recheck cells as mechanical or judgment.
Mechanical cells are verified via shell commands (file existence,
grep pattern, line count). Results update the matrix JSON in-place.

Exit codes:
  0 = mechanical cells checked
  1 = no mechanical cells found
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
        "--catalog",
        required=True,
        metavar="PATH",
        help="Path to the criteria catalog markdown file",
    )
    return parser.parse_args()


def is_mechanical(criterion):
    """Classify a criterion as mechanical (True) or judgment (False).

    Mechanical: file-existence, pattern-grep, or count-based checks.
    Judgment: behavioral analysis, ownership tracing, design review.

    Only description patterns are used for classification. Property field
    text is too ambiguous (e.g., "auth token is present" is behavioral,
    not mechanical).
    """
    raw_desc = criterion.get("description", "")
    for pat in MECHANICAL_DESC_PATTERNS:
        if pat.search(raw_desc):
            return True

    return False


def check_file_exists(file_path):
    """Check if a file exists. Returns (verdict, evidence)."""
    if os.path.isfile(file_path):
        return "pass", f"File exists: {file_path}"
    return "fail", f"File not found: {file_path}"


def check_grep_pattern(file_path, pattern):
    """Grep for a pattern in a file. Returns (verdict, evidence)."""
    if not os.path.isfile(file_path):
        return "fail", f"File not found: {file_path}"
    try:
        result = subprocess.run(
            ["grep", "-cE", "--", pattern, file_path],
            capture_output=True,
            text=True,
        )
        count = int(result.stdout.strip()) if result.returncode == 0 else 0
        if count > 0:
            # Get first matching line for evidence
            match_result = subprocess.run(
                ["grep", "-m1", "-nE", "--", pattern, file_path],
                capture_output=True,
                text=True,
            )
            first_match = match_result.stdout.strip()
            return "pass", f"Pattern matched {count}x, first: {first_match}"
        return "fail", f"Pattern not found: {pattern}"
    except (OSError, ValueError):
        return "fail", f"Grep error for pattern: {pattern}"


def check_count(file_path, min_count, pattern=None):
    """Count lines or pattern occurrences. Returns (verdict, evidence)."""
    if not os.path.isfile(file_path):
        return "fail", f"File not found: {file_path}"
    try:
        if pattern:
            result = subprocess.run(
                ["grep", "-cE", "--", pattern, file_path],
                capture_output=True,
                text=True,
            )
            count = int(result.stdout.strip()) if result.returncode == 0 else 0
        else:
            result = subprocess.run(
                ["wc", "-l", file_path],
                capture_output=True,
                text=True,
            )
            count = int(result.stdout.strip().split()[0])
        if count >= min_count:
            return "pass", f"Count {count} >= {min_count}"
        return "fail", f"Count {count} < {min_count}"
    except (OSError, ValueError):
        return "fail", f"Count check error"


def run_mechanical_check(cell, criterion, project_root):
    """Run the appropriate mechanical check for a cell. Returns (verdict, evidence)."""
    target = cell.get("target", "")
    full_path = os.path.join(project_root, target)
    pre_filter = criterion.get("pre_filter", "")
    desc = criterion.get("description", "")
    prop = criterion.get("property", "")

    # Strategy 1: If pre_filter is a grep pattern, use it
    if pre_filter and not pre_filter.lower().startswith("(none"):
        return check_grep_pattern(full_path, pre_filter)

    # Strategy 2: Description says "File X exists"
    if re.match(r"^File\s+\S+\s+exists", desc, re.IGNORECASE):
        return check_file_exists(full_path)

    # Strategy 3: Description says "At least N instances of <pattern>"
    count_match = re.match(
        r"^At\s+least\s+(\d+)\s+instances?\s+of\s+(.+)", desc, re.IGNORECASE
    )
    if count_match:
        min_count = int(count_match.group(1))
        pattern = count_match.group(2).strip().strip("`\"'")
        return check_count(full_path, min_count, pattern)

    # Strategy 4: Property is a presence assertion -- grep the pre_filter or file exists
    if re.search(r"(present|contains|starts with)", prop, re.IGNORECASE):
        if pre_filter and not pre_filter.lower().startswith("(none"):
            return check_grep_pattern(full_path, pre_filter)
        return check_file_exists(full_path)

    # Fallback: file existence check
    return check_file_exists(full_path)


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

    # Parse catalog
    criteria = parse_catalog(os.path.abspath(args.catalog))
    criteria_map = {c["id"]: c for c in criteria}

    project_root = data.get("project_root", ".")
    matrix = data.get("matrix", [])

    # Classify and check mechanical cells
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    checked = 0
    passed = 0
    failed = 0

    for cell in matrix:
        status = cell.get("status", "unchecked")
        if status not in ("unchecked", "recheck"):
            continue

        criterion_id = cell.get("criterion", "")
        criterion = criteria_map.get(criterion_id)
        if criterion is None:
            continue

        if not is_mechanical(criterion):
            continue

        verdict, evidence = run_mechanical_check(cell, criterion, project_root)
        cell["status"] = verdict
        cell["evidence"] = evidence
        cell["checked_at"] = now_iso
        # Refresh file hash
        full_path = os.path.join(project_root, cell.get("target", ""))
        cell["file_hash"] = compute_file_hash(full_path)
        if status == "recheck":
            cell["remediated_at"] = None

        checked += 1
        if verdict == "pass":
            passed += 1
        else:
            failed += 1

    if checked == 0:
        print("No mechanical cells found.", file=sys.stderr)
        sys.exit(1)

    # Update summary and write back (pass pre_filter_na count for sparse format)
    na_count = data.get("pre_filter_na", {}).get("count", 0)
    data["summary"] = compute_summary(matrix, na_count)
    data["updated"] = now_iso

    try:
        with open(args.matrix, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
    except OSError as e:
        print(f"ERROR: Cannot write matrix: {e}", file=sys.stderr)
        sys.exit(2)

    print(f"MECHANICAL: {checked} cells checked, {passed} pass, {failed} fail")
    sys.exit(0)


if __name__ == "__main__":
    main()
