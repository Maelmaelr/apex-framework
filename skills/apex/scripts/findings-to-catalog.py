#!/usr/bin/env python3
# Usage: findings-to-catalog.py --matrix <path> [--catalog-dir <dir>] [--output <path>]
# Extracts OPEN-01 FAIL findings from a matrix JSON and generates candidate criteria catalog entries.
# Exit 0 = candidates written, Exit 1 = no OPEN-01 FAIL cells found, Exit 2 = error.
# v1.0 -- 2026-03-30

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone


def parse_args():
    parser = argparse.ArgumentParser(
        description="Convert OPEN-01 FAIL findings into candidate criteria catalog entries.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Reads a matrix JSON file produced by enumerate-audit-matrix.py, extracts
cells where criterion is OPEN-01 and status is 'fail', and generates
catalog-format markdown entries for human review.

Output entries use CANDIDATE-NN IDs and include source metadata linking
back to the original finding.

Exit codes:
  0 = candidate criteria written
  1 = no OPEN-01 FAIL cells found
  2 = error (file not found, parse error, etc.)
""",
    )
    parser.add_argument(
        "--matrix",
        required=True,
        metavar="PATH",
        help="Path to matrix JSON with FAIL verdicts",
    )
    parser.add_argument(
        "--catalog-dir",
        metavar="DIR",
        help="Directory for output (default: derived from matrix JSON catalog_path)",
    )
    parser.add_argument(
        "--output",
        metavar="PATH",
        help="Output path for candidate criteria (default: {catalog-dir}/candidates-{YYYY-MM-DD}.md)",
    )
    return parser.parse_args()


def load_matrix(matrix_path):
    """Load and validate a matrix JSON file."""
    try:
        with open(matrix_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"ERROR: Matrix file not found: {matrix_path}", file=sys.stderr)
        sys.exit(2)
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: Cannot parse matrix file: {e}", file=sys.stderr)
        sys.exit(2)

    if "matrix" not in data:
        print("ERROR: Matrix JSON missing 'matrix' field", file=sys.stderr)
        sys.exit(2)

    return data


def extract_open_failures(matrix_data):
    """Extract cells where criterion is OPEN-01 and status is fail."""
    failures = []
    for cell in matrix_data.get("matrix", []):
        if cell.get("criterion") == "OPEN-01" and cell.get("status") == "fail":
            failures.append(cell)
    return failures


def extract_keywords(evidence):
    """Extract likely pre-filter keywords from evidence text."""
    if not evidence:
        return "(none -- always applies)"

    # Look for quoted terms, code identifiers, and significant words
    quoted = re.findall(r'[`"\']([^`"\']+)[`"\']', evidence)
    if quoted:
        # Use first few quoted terms as ERE alternation
        terms = [re.escape(t) for t in quoted[:3]]
        return "|".join(terms)

    # Fall back to longest significant words from evidence
    words = re.findall(r'\b[a-zA-Z_]\w{4,}\b', evidence)
    if words:
        # Pick up to 3 most distinctive words (longest first)
        unique = sorted(set(words), key=len, reverse=True)[:3]
        return "|".join(unique)

    return "(none -- always applies)"


def derive_targets(target_path):
    """Derive a glob pattern from a specific file path."""
    directory = os.path.dirname(target_path)
    ext = os.path.splitext(target_path)[1]
    if directory and ext:
        return f"{directory}/*{ext}"
    if ext:
        return f"*{ext}"
    return target_path


def estimate_severity(evidence):
    """Estimate severity from evidence content."""
    if not evidence:
        return "medium"
    lower = evidence.lower()
    if any(w in lower for w in ("security", "auth", "inject", "vulnerability", "critical", "exploit")):
        return "high"
    if any(w in lower for w in ("error", "fail", "break", "crash", "missing")):
        return "medium"
    return "low"


def generate_candidate_entry(index, cell, theme):
    """Generate a catalog-format markdown entry for a single finding."""
    candidate_id = f"CANDIDATE-{index:02d}"
    target = cell.get("target", "unknown")
    evidence = cell.get("evidence", "")
    targets_glob = derive_targets(target)
    pre_filter = extract_keywords(evidence)
    severity = estimate_severity(evidence)

    # Build description from evidence
    description = evidence.strip() if evidence else f"Novel finding in {target} (no evidence recorded)"

    # Truncate long descriptions
    if len(description) > 200:
        description = description[:197] + "..."

    lines = [
        f"## {candidate_id}: Finding from {target}",
        f"- description: {description}",
        f"- targets: `{targets_glob}`",
        f"- pre-filter: `{pre_filter}`",
        f"- property: Issue identified in OPEN-01 review of {target}",
        f"- pass: Issue is not present or has been remediated",
        f"- fail: {description}",
        f"- severity: {severity}",
        f"- source: auto-generated from OPEN-01 finding ({theme} audit, {target})",
    ]
    return "\n".join(lines)


def main():
    args = parse_args()

    matrix_path = os.path.abspath(args.matrix)
    matrix_data = load_matrix(matrix_path)

    # Extract OPEN-01 FAIL cells
    failures = extract_open_failures(matrix_data)

    if not failures:
        print("No OPEN-01 FAIL cells found in matrix.")
        sys.exit(1)

    theme = matrix_data.get("theme", "unknown")

    # Determine output directory
    if args.catalog_dir:
        catalog_dir = os.path.abspath(args.catalog_dir)
    else:
        catalog_path = matrix_data.get("catalog_path", "")
        if catalog_path:
            catalog_dir = os.path.dirname(os.path.abspath(catalog_path))
        else:
            catalog_dir = os.path.dirname(matrix_path)

    # Determine output path
    if args.output:
        output_path = os.path.abspath(args.output)
    else:
        date_str = datetime.now().strftime("%Y-%m-%d")
        output_path = os.path.join(catalog_dir, f"candidates-{date_str}.md")

    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    # Generate candidate entries
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    header_lines = [
        f"# Candidate Criteria from OPEN-01 Findings ({theme})",
        "",
        "## Metadata",
        "",
        f"- generated: {now_iso}",
        f"- source-matrix: {matrix_path}",
        f"- theme: {theme}",
        f"- finding-count: {len(failures)}",
        "- status: REVIEW REQUIRED -- edit and append to main catalog",
        "- format: deterministic pre-filters for target-x-criterion matrix generation",
        f"- pre-filter-syntax: grep -E (ERE)",
        f"- target-syntax: shell glob (compatible with glob.glob() and find)",
        "",
        "",
    ]

    entries = []
    for i, cell in enumerate(failures, start=1):
        entries.append(generate_candidate_entry(i, cell, theme))

    content = "\n".join(header_lines) + "\n\n".join(entries) + "\n"

    try:
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError as e:
        print(f"ERROR: Cannot write output: {e}", file=sys.stderr)
        sys.exit(2)

    print(f"CANDIDATES: {len(failures)} entries written to {output_path}")
    sys.exit(0)


if __name__ == "__main__":
    main()
