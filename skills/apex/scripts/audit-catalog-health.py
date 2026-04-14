#!/usr/bin/env python3
# Usage: audit-catalog-health.py --catalog-dir <dir> --project-root <path>
# Validates audit catalogs against current codebase state.
# Reports: stale targets, size limit violations, criteria-count mismatches, source drift.
# Exit 0 = healthy, Exit 1 = issues found, Exit 2 = error.
# v3.0 -- 2026-04-05

import argparse
import glob as globmod
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from audit_matrix_lib import (
    is_scope_all,
    parse_catalog_with_metadata,
    strip_backticks,
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Validate audit catalogs against current codebase state.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Checks for:
  - STALE_TARGET: criterion target globs matching 0 files
  - SIZE_EXCEEDED: catalog exceeds 60 criteria or 600 lines
  - COUNT_MISMATCH: declared criteria-count != actual criterion count
  - MISSING_COUNT: no criteria-count in metadata
  - SOURCE_DRIFT: key source docs modified since catalog creation/update

Exit codes:
  0 = all catalogs healthy (no issues)
  1 = issues found (non-blocking, informational)
  2 = error (file not found, parse error)
""",
    )
    parser.add_argument(
        "--catalog-dir",
        required=True,
        metavar="DIR",
        help="Directory containing catalog .md files",
    )
    parser.add_argument(
        "--project-root",
        required=True,
        metavar="PATH",
        help="Path to the project root directory",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output as JSON instead of text",
    )
    return parser.parse_args()


def resolve_catalog_root(metadata, cli_project_root):
    """Determine the effective project root for a catalog."""
    declared = metadata.get("project_root")
    if declared:
        expanded = os.path.expanduser(declared)
        if os.path.isdir(expanded):
            return os.path.abspath(expanded)
    return cli_project_root


def expand_targets(target_str, project_root):
    """Expand target glob patterns into a set of relative file paths."""
    if is_scope_all(target_str):
        return None

    patterns = [strip_backticks(p.strip()) for p in target_str.split(",") if p.strip()]
    matched = set()
    for pattern in patterns:
        full_pattern = os.path.join(project_root, pattern)
        for path in globmod.glob(full_pattern, recursive=True):
            if os.path.isfile(path):
                rel = os.path.relpath(path, project_root)
                matched.add(rel)
    return matched


def check_source_drift(project_root, baseline_date):
    """Check if key source docs have been modified since catalog creation/update."""
    if not baseline_date:
        return []

    drift_files = []
    for doc in ("CLAUDE.md", "docs/project-context.md"):
        full_path = os.path.join(project_root, doc)
        if not os.path.isfile(full_path):
            continue
        try:
            result = subprocess.run(
                ["git", "log", "--oneline", f"--since={baseline_date}", "--", doc],
                capture_output=True,
                text=True,
                cwd=project_root,
            )
            if result.returncode == 0 and result.stdout.strip():
                commit_count = len(result.stdout.strip().split("\n"))
                drift_files.append({
                    "file": doc,
                    "commits_since": commit_count,
                    "since": baseline_date,
                })
        except OSError:
            pass

    return drift_files


def main():
    args = parse_args()

    project_root = os.path.abspath(args.project_root)
    catalog_dir = os.path.abspath(args.catalog_dir)

    if not os.path.isdir(project_root):
        print(f"ERROR: Project root not found: {project_root}", file=sys.stderr)
        sys.exit(2)

    if not os.path.isdir(catalog_dir):
        print(f"ERROR: Catalog directory not found: {catalog_dir}", file=sys.stderr)
        sys.exit(2)

    catalog_files = sorted(globmod.glob(os.path.join(catalog_dir, "*.md")))
    if not catalog_files:
        print("ERROR: No catalog files found in directory", file=sys.stderr)
        sys.exit(2)

    issues = []
    total_criteria = 0
    seen_drift = set()

    for catalog_path in catalog_files:
        catalog_name = os.path.splitext(os.path.basename(catalog_path))[0]

        # Skip candidate files (generated output, not real catalogs)
        if catalog_name.startswith("candidates-"):
            continue

        try:
            metadata, criteria = parse_catalog_with_metadata(catalog_path)
        except SystemExit:
            issues.append({
                "type": "ERROR",
                "catalog": catalog_name,
                "message": f"Cannot parse catalog: {catalog_path}",
            })
            continue

        total_criteria += len(criteria)
        catalog_root = resolve_catalog_root(metadata, project_root)

        # --- Check 1: criteria-count metadata accuracy ---
        declared = metadata.get("declared_criteria_count")
        actual = len(criteria)
        if declared is None:
            issues.append({
                "type": "MISSING_COUNT",
                "catalog": catalog_name,
                "actual_count": actual,
                "message": f"No criteria-count declared in metadata (actual: {actual})",
                "suggestion": f"Add '- criteria-count: {actual}' to metadata",
            })
        elif declared != actual:
            issues.append({
                "type": "COUNT_MISMATCH",
                "catalog": catalog_name,
                "declared": declared,
                "actual": actual,
                "message": f"Declared criteria-count {declared} != actual {actual}",
                "suggestion": f"Update criteria-count to {actual}",
            })

        # --- Check 2: catalog size limits ---
        if actual > 60:
            issues.append({
                "type": "SIZE_EXCEEDED",
                "catalog": catalog_name,
                "criteria_count": actual,
                "message": f"Catalog has {actual} criteria (max 60) -- split into thematic sub-catalogs",
            })
        line_count = metadata.get("line_count", 0)
        if line_count > 600:
            issues.append({
                "type": "SIZE_EXCEEDED",
                "catalog": catalog_name,
                "line_count": line_count,
                "message": f"Catalog has {line_count} lines (max 600) -- split into thematic sub-catalogs",
            })

        # --- Check 3: stale targets ---
        for criterion in criteria:
            targets = expand_targets(criterion["targets"], catalog_root)
            if targets is None:
                continue
            if len(targets) == 0:
                issues.append({
                    "type": "STALE_TARGET",
                    "catalog": catalog_name,
                    "criterion": criterion["id"],
                    "targets_glob": criterion["targets"],
                    "message": f"Target glob matches 0 files: {criterion['targets']}",
                    "suggestion": "Update target glob to match current file locations",
                })

        # --- Check 4: source drift ---
        created = metadata.get("created")
        updated = metadata.get("updated")
        if created and updated:
            baseline_date = max(created, updated)
        else:
            baseline_date = created
        for d in check_source_drift(catalog_root, baseline_date):
            drift_key = (d["file"], d["since"])
            if drift_key in seen_drift:
                continue
            seen_drift.add(drift_key)
            issues.append({
                "type": "SOURCE_DRIFT",
                "catalog": catalog_name,
                "source_file": d["file"],
                "commits_since": d["commits_since"],
                "since": d["since"],
                "message": f"{d['file']} has {d['commits_since']} commit(s) since catalog update ({d['since']})",
                "suggestion": "Review criteria sourced from this file for accuracy",
            })

    # Output
    if args.json:
        output = {
            "catalogs": len(catalog_files),
            "total_criteria": total_criteria,
            "issue_count": len(issues),
            "issues": issues,
        }
        json.dump(output, sys.stdout, indent=2)
        print()
    else:
        print(f"CATALOGS: {len(catalog_files)} catalogs, {total_criteria} criteria")

        if not issues:
            print("HEALTH: All catalogs healthy -- no issues found")
        else:
            print(f"ISSUES: {len(issues)} found")
            print()

            by_type = {}
            for issue in issues:
                by_type.setdefault(issue["type"], []).append(issue)

            for issue_type, items in by_type.items():
                print(f"--- {issue_type} ({len(items)}) ---")
                for item in items:
                    print(f"  {item['message']}")
                    if "criterion" in item:
                        print(f"    criterion: {item['criterion']}")
                    if "suggestion" in item:
                        print(f"    fix: {item['suggestion']}")
                print()

    sys.exit(1 if issues else 0)


if __name__ == "__main__":
    main()
