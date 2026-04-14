#!/usr/bin/env python3
# Usage: enumerate-audit-matrix.py --catalog <path> --project-root <path> [--output-dir <dir>] [--resume <json>] [--scope <paths>] [--verdicts-dir <dir>] [--no-persist]
# Parses a criteria catalog markdown and generates a coverage matrix JSON for audit tracking.
# Exit 0 = matrix generated with applicable cells, Exit 1 = no applicable cells, Exit 2 = error.
# v3.0 -- 2026-04-01 (sparse matrix: pre-filter N/A as metadata, not cells)

import argparse
import json
import os
import secrets
import sys
from datetime import datetime, timezone

from audit_matrix_lib import (
    compute_file_hash,
    compute_summary,
    expand_targets,
    is_scope_all,
    parse_catalog,
    pre_filter_applicable,
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate a coverage matrix for a criteria catalog.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Parses a criteria catalog markdown file and expands target globs to
produce a (target x criterion) matrix JSON. Each cell is pre-filtered
via grep to determine applicability.

Verdict persistence (default on):
  Verdicts from previous runs are auto-loaded from {verdicts-dir}/{theme}-verdicts.json.
  Changed files (by git hash) get promoted to 'recheck'. After matrix generation,
  non-unchecked verdicts are auto-saved back.

Exit codes:
  0 = matrix generated with applicable cells
  1 = no applicable cells found (all N/A or no targets matched)
  2 = error (file not found, parse error, etc.)
""",
    )
    parser.add_argument(
        "--catalog",
        required=True,
        metavar="PATH",
        help="Path to the criteria catalog markdown file",
    )
    parser.add_argument(
        "--project-root",
        required=True,
        metavar="PATH",
        help="Path to the project root directory",
    )
    parser.add_argument(
        "--output-dir",
        metavar="DIR",
        help="Output directory for matrix JSON (default: .claude-tmp/audit-matrix/ relative to project-root)",
    )
    parser.add_argument(
        "--resume",
        metavar="JSON",
        help="Path to existing matrix JSON to resume (keeps pass/fail/not_applicable cells)",
    )
    parser.add_argument(
        "--scope",
        metavar="PATHS",
        help="Comma-separated file paths to limit target enumeration (overrides catalog target globs)",
    )
    parser.add_argument(
        "--verdicts-dir",
        metavar="DIR",
        help="Persistent verdict storage directory (default: {project-root}/.claude/audit-verdicts/)",
    )
    parser.add_argument(
        "--no-persist",
        action="store_true",
        help="Skip auto-save/auto-load of persistent verdicts",
    )
    return parser.parse_args()


def build_matrix(criteria, project_root, scope_paths):
    """Build sparse matrix: only applicable cells. Pre-filter N/A tracked as metadata."""
    matrix = []
    pre_filter_na = {}  # criterion_id -> count
    all_targets = set()
    deferred_criteria = []  # criteria with "all files in scope" targets

    for criterion in criteria:
        if is_scope_all(criterion["targets"]):
            deferred_criteria.append(criterion)
            continue
        targets = expand_targets(criterion["targets"], project_root, scope_paths)
        for target in targets:
            all_targets.add(target)
            applicable = pre_filter_applicable(
                target, criterion["pre_filter"], project_root
            )
            if applicable:
                full_path = os.path.join(project_root, target)
                matrix.append({
                    "target": target,
                    "criterion": criterion["id"],
                    "status": "unchecked",
                    "evidence": None,
                    "checked_at": None,
                    "remediated_at": None,
                    "file_hash": compute_file_hash(full_path),
                })
            else:
                cid = criterion["id"]
                pre_filter_na[cid] = pre_filter_na.get(cid, 0) + 1

    # Deferred criteria apply to all previously discovered targets
    for criterion in deferred_criteria:
        for target in sorted(all_targets):
            applicable = pre_filter_applicable(
                target, criterion["pre_filter"], project_root
            )
            if applicable:
                full_path = os.path.join(project_root, target)
                matrix.append({
                    "target": target,
                    "criterion": criterion["id"],
                    "status": "unchecked",
                    "evidence": None,
                    "checked_at": None,
                    "remediated_at": None,
                    "file_hash": compute_file_hash(full_path),
                })
            else:
                cid = criterion["id"]
                pre_filter_na[cid] = pre_filter_na.get(cid, 0) + 1

    na_count = sum(pre_filter_na.values())
    na_metadata = {"count": na_count, "by_criterion": pre_filter_na}
    return matrix, all_targets, na_metadata


def load_resume_matrix(resume_path):
    """Load an existing matrix JSON for resume mode."""
    try:
        with open(resume_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"ERROR: Resume file not found: {resume_path}", file=sys.stderr)
        sys.exit(2)
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: Cannot parse resume file: {e}", file=sys.stderr)
        sys.exit(2)


def apply_resume(new_matrix, old_data):
    """Merge old matrix state into new matrix. Returns merged matrix list."""
    old_cells = {}
    for cell in old_data.get("matrix", []):
        key = (cell["target"], cell["criterion"])
        old_cells[key] = cell

    merged = []
    for cell in new_matrix:
        key = (cell["target"], cell["criterion"])
        old_cell = old_cells.get(key)

        if old_cell is None:
            merged.append(cell)
            continue

        old_status = old_cell.get("status", "unchecked")

        if old_status in ("pass", "fail", "not_applicable"):
            merged.append(old_cell)
        elif old_status == "remediated":
            merged.append({**old_cell, "status": "recheck"})
        else:
            merged.append(cell)

    return merged


def load_verdicts(verdicts_path):
    """Load persistent verdicts file. Returns None if not found."""
    if not os.path.isfile(verdicts_path):
        return None
    try:
        with open(verdicts_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"WARNING: Cannot parse verdicts file, ignoring: {e}", file=sys.stderr)
        return None


def apply_verdicts(new_matrix, verdicts_data):
    """Merge persistent verdicts into new matrix with change detection.

    If file_hash matches stored hash, carry forward the verdict.
    If file_hash differs, promote pass/fail to recheck.
    """
    old_cells = {}
    for cell in verdicts_data.get("cells", []):
        key = (cell["target"], cell["criterion"])
        old_cells[key] = cell

    merged = []
    carried = 0
    rechecked = 0

    for cell in new_matrix:
        key = (cell["target"], cell["criterion"])
        old_cell = old_cells.get(key)

        if old_cell is None:
            merged.append(cell)
            continue

        old_status = old_cell.get("status", "unchecked")
        if old_status == "unchecked":
            merged.append(cell)
            continue

        # Change detection: compare file hashes
        old_hash = old_cell.get("file_hash")
        new_hash = cell.get("file_hash")
        hash_changed = old_hash is not None and new_hash is not None and old_hash != new_hash

        if hash_changed and old_status in ("pass", "fail"):
            # File changed since verdict -- needs recheck
            merged.append({
                **old_cell,
                "status": "recheck",
                "file_hash": new_hash,
            })
            rechecked += 1
        else:
            # Hash matches or status is not_applicable/recheck/remediated -- carry forward
            carried_cell = {**old_cell, "file_hash": new_hash}
            if old_status == "remediated":
                carried_cell["status"] = "recheck"
            merged.append(carried_cell)
            carried += 1

    if carried or rechecked:
        print(
            f"VERDICTS: loaded {carried + rechecked} persistent"
            f" ({carried} carried, {rechecked} rechecked due to file changes)"
        )

    return merged


def save_verdicts(verdicts_path, theme, catalog_path, matrix):
    """Save checked cells to persistent verdicts file.

    In sparse format, the matrix only contains applicable cells (no pre-filter N/A).
    Scout N/A (with evidence) is included to preserve LLM audit work across runs.
    """
    cells = [
        cell for cell in matrix
        if cell.get("status") != "unchecked"
    ]

    if not cells:
        return

    verdicts_dir = os.path.dirname(verdicts_path)
    os.makedirs(verdicts_dir, exist_ok=True)

    verdicts_data = {
        "version": "1.0",
        "theme": theme,
        "catalog_path": catalog_path,
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cells": cells,
    }

    try:
        with open(verdicts_path, "w", encoding="utf-8") as f:
            json.dump(verdicts_data, f, indent=2)
            f.write("\n")
        print(f"VERDICTS: saved {len(cells)} to {verdicts_path}")
    except OSError as e:
        print(f"WARNING: Cannot save verdicts: {e}", file=sys.stderr)


def main():
    args = parse_args()

    project_root = os.path.abspath(args.project_root)
    catalog_path = os.path.abspath(args.catalog)

    if not os.path.isdir(project_root):
        print(f"ERROR: Project root not found: {project_root}", file=sys.stderr)
        sys.exit(2)

    # Parse scope if provided
    scope_paths = None
    if args.scope:
        scope_paths = [p.strip() for p in args.scope.split(",") if p.strip()]

    # Parse catalog
    criteria = parse_catalog(catalog_path)

    # Build matrix (sparse: no pre-filter N/A cells, only applicable)
    matrix, all_targets, pre_filter_na = build_matrix(criteria, project_root, scope_paths)

    # Derive theme from catalog filename
    theme = os.path.splitext(os.path.basename(catalog_path))[0]

    # Verdict persistence paths
    if args.verdicts_dir:
        verdicts_dir = os.path.abspath(args.verdicts_dir)
    else:
        verdicts_dir = os.path.join(project_root, ".claude", "audit-verdicts")
    verdicts_path = os.path.join(verdicts_dir, f"{theme}-verdicts.json")

    # Auto-load persistent verdicts (on fresh run without --resume)
    if not args.resume and not args.no_persist:
        verdicts_data = load_verdicts(verdicts_path)
        if verdicts_data is not None:
            matrix = apply_verdicts(matrix, verdicts_data)

    # Resume mode (explicit --resume takes priority)
    if args.resume:
        old_data = load_resume_matrix(args.resume)
        matrix = apply_resume(matrix, old_data)

    # Check for applicable cells (sparse matrix has no pre-filter N/A)
    if len(matrix) == 0:
        print("No applicable cells found (all N/A or no targets matched).")
        sys.exit(1)

    # Generate uid
    uid = datetime.now().strftime("%Y%m%d") + "-" + secrets.token_hex(3)

    # Output directory
    if args.output_dir:
        output_dir = os.path.abspath(args.output_dir)
    else:
        output_dir = os.path.join(project_root, ".claude-tmp", "audit-matrix")

    os.makedirs(output_dir, exist_ok=True)

    output_filename = f"{theme}-{uid}.json"
    output_path = os.path.join(output_dir, output_filename)

    # Build criteria summary list
    criteria_summary = [
        {"id": c["id"], "title": c["title"], "severity": c["severity"]}
        for c in criteria
    ]

    # Build criteria definitions for inline embedding in scout prompts
    criteria_definitions = {}
    for c in criteria:
        criteria_definitions[c["id"]] = {
            "description": c["description"],
            "property": c["property"],
            "pass": c["pass_evidence"],
            "fail": c["fail_evidence"],
            "severity": c["severity"],
        }

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    summary = compute_summary(matrix, pre_filter_na["count"])

    output_data = {
        "version": "2.0",
        "theme": theme,
        "catalog_path": catalog_path,
        "project_root": project_root,
        "created": now_iso,
        "updated": now_iso,
        "criteria": criteria_summary,
        "criteria_definitions": criteria_definitions,
        "matrix": matrix,
        "pre_filter_na": pre_filter_na,
        "summary": summary,
    }

    # Preserve created timestamp from resumed matrix
    if args.resume and "created" in old_data:
        output_data["created"] = old_data["created"]

    try:
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(output_data, f, indent=2)
            f.write("\n")
    except OSError as e:
        print(f"ERROR: Cannot write output: {e}", file=sys.stderr)
        sys.exit(2)

    # Auto-save persistent verdicts
    if not args.no_persist:
        save_verdicts(verdicts_path, theme, catalog_path, matrix)

    # Unique files and criteria counts
    unique_files = len(set(c["target"] for c in matrix))
    unique_criteria = len(criteria)
    na_total = summary["not_applicable"]

    print(
        f"MATRIX: {summary['total_cells']} cells"
        f" ({len(matrix)} stored, {pre_filter_na['count']} pre-filter N/A as metadata)"
        f" ({summary['unchecked']} unchecked, {na_total} N/A)"
        f" across {unique_files} files and {unique_criteria} criteria"
        f" -- {output_path}"
    )

    sys.exit(0)


if __name__ == "__main__":
    main()
