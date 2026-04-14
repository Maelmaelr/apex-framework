#!/usr/bin/env python3
# Usage: Library module for audit matrix scripts. Not invoked directly.
# Provides: parse_catalog, parse_catalog_with_metadata, expand_targets,
#           pre_filter_applicable, compute_summary, compute_file_hash
# Shared by: enumerate-audit-matrix.py, findings-to-catalog.py, audit-catalog-health.py
# v2.0 -- 2026-04-05

import glob
import os
import re
import subprocess
import sys


CRITERION_HEADING_RE = re.compile(r"^##\s+(\S+):\s+(.*)")
KV_RE = re.compile(r"^-\s+([\w][\w-]*):\s*(.*)")

# Metadata regexes for catalog header fields
_META_RE = {
    "created": re.compile(r"^-\s+created:\s*(\S+)"),
    "updated": re.compile(r"^-\s+updated:\s*(\S+)"),
    "criteria_count": re.compile(r"^-\s+criteria-count:\s*(\d+)"),
    "sources": re.compile(r"^-\s+sources:\s*(.*)"),
    "excluded": re.compile(r"^-\s+excluded:\s*(.*)"),
    "project_root": re.compile(r"^-\s+project-root:\s*(.*)"),
}

# Map catalog key names to internal dict key names
KEY_MAP = {
    "pre-filter": "pre_filter",
    "pass": "pass_evidence",
    "fail": "fail_evidence",
}


def strip_backticks(value):
    """Strip all backtick characters from a value string."""
    return value.strip().replace("`", "")


def parse_catalog(catalog_path):
    """Parse criteria catalog markdown into a list of criterion dicts."""
    try:
        with open(catalog_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"ERROR: Catalog file not found: {catalog_path}", file=sys.stderr)
        sys.exit(2)
    except OSError as e:
        print(f"ERROR: Cannot read catalog: {e}", file=sys.stderr)
        sys.exit(2)

    criteria = []
    current = None

    for raw_line in lines:
        line = raw_line.rstrip("\n")

        heading_match = CRITERION_HEADING_RE.match(line)
        if heading_match:
            if current is not None:
                criteria.append(current)
            current = {
                "id": heading_match.group(1),
                "title": heading_match.group(2).strip(),
                "description": "",
                "targets": "",
                "pre_filter": "",
                "property": "",
                "pass_evidence": "",
                "fail_evidence": "",
                "severity": "",
                "source": "",
            }
            continue

        if current is None:
            continue

        kv_match = KV_RE.match(line)
        if kv_match:
            raw_key = kv_match.group(1)
            value = strip_backticks(kv_match.group(2).strip())
            key = KEY_MAP.get(raw_key, raw_key)
            if key in current:
                current[key] = value

    if current is not None:
        criteria.append(current)

    if not criteria:
        print("ERROR: No criteria found in catalog", file=sys.stderr)
        sys.exit(2)

    return criteria


def parse_catalog_with_metadata(catalog_path):
    """Parse criteria catalog markdown into (metadata, criteria).

    Returns a tuple of (metadata_dict, criteria_list). The metadata dict
    contains: created, updated, declared_criteria_count, sources, excluded,
    project_root, criteria_count (actual count), line_count.
    """
    try:
        with open(catalog_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"ERROR: Catalog file not found: {catalog_path}", file=sys.stderr)
        sys.exit(2)
    except OSError as e:
        print(f"ERROR: Cannot read catalog: {e}", file=sys.stderr)
        sys.exit(2)

    metadata = {
        "created": None,
        "updated": None,
        "declared_criteria_count": None,
        "sources": "",
        "excluded": "",
        "project_root": None,
        "line_count": len(lines),
    }
    criteria = []
    current = None

    for raw_line in lines:
        line = raw_line.rstrip("\n")

        # Extract metadata (before first criterion heading)
        if current is None:
            for meta_key, meta_re in _META_RE.items():
                m = meta_re.match(line)
                if m:
                    val = m.group(1).strip()
                    if meta_key == "criteria_count":
                        metadata["declared_criteria_count"] = int(val)
                    elif metadata[meta_key] is None or metadata[meta_key] == "":
                        metadata[meta_key] = val
                    break

        heading_match = CRITERION_HEADING_RE.match(line)
        if heading_match:
            if current is not None:
                criteria.append(current)
            current = {
                "id": heading_match.group(1),
                "title": heading_match.group(2).strip(),
                "description": "",
                "targets": "",
                "pre_filter": "",
                "property": "",
                "pass_evidence": "",
                "fail_evidence": "",
                "severity": "",
                "source": "",
            }
            continue

        if current is None:
            continue

        kv_match = KV_RE.match(line)
        if kv_match:
            raw_key = kv_match.group(1)
            value = strip_backticks(kv_match.group(2).strip())
            key = KEY_MAP.get(raw_key, raw_key)
            if key in current:
                current[key] = value

    if current is not None:
        criteria.append(current)

    metadata["criteria_count"] = len(criteria)
    return metadata, criteria


def expand_targets(target_str, project_root, scope_paths):
    """Expand target glob patterns into a sorted list of relative file paths."""
    if scope_paths is not None:
        # Scope override: filter to files that actually exist
        result = []
        for p in scope_paths:
            full = os.path.join(project_root, p)
            if os.path.isfile(full):
                result.append(p)
        return sorted(set(result))

    patterns = [strip_backticks(p.strip()) for p in target_str.split(",") if p.strip()]
    matched = set()
    for pattern in patterns:
        full_pattern = os.path.join(project_root, pattern)
        for path in glob.glob(full_pattern, recursive=True):
            if os.path.isfile(path):
                rel = os.path.relpath(path, project_root)
                matched.add(rel)
    return sorted(matched)


def pre_filter_applicable(target_path, pre_filter, project_root):
    """Return True if target file matches the pre_filter ERE pattern (applicable)."""
    if not pre_filter or pre_filter.lower().startswith("(none"):
        return True

    full_path = os.path.join(project_root, target_path)
    try:
        result = subprocess.run(
            ["grep", "-qE", "--", pre_filter, full_path],
            capture_output=True,
        )
        return result.returncode == 0
    except OSError:
        # grep not available or other OS error -- assume applicable
        return True


def is_scope_all(target_str):
    """Return True if the target string means 'all files in audit scope'.

    Requires an exact sentinel value to avoid false positives from target
    strings that happen to contain 'all' and 'files' as substrings.
    """
    normalized = target_str.strip().lower()
    return normalized in (
        "all", "all files", "all files in scope",
        "all files in audit scope", "scope:all",
    )


def compute_summary(matrix, pre_filter_na_count=0):
    """Compute summary statistics from the matrix.

    Args:
        matrix: list of cell dicts (sparse format excludes pre-filter N/A cells)
        pre_filter_na_count: number of pre-filter N/A cells not stored in the matrix
    """
    total = len(matrix) + pre_filter_na_count
    counts = {
        "unchecked": 0,
        "not_applicable": 0,
        "pass": 0,
        "fail": 0,
        "recheck": 0,
        "remediated": 0,
    }
    for cell in matrix:
        status = cell.get("status", "unchecked")
        if status in counts:
            counts[status] += 1

    counts["not_applicable"] += pre_filter_na_count

    covered = total - counts["unchecked"] - counts["recheck"]
    coverage_pct = round((covered / total * 100), 1) if total > 0 else 0.0

    return {
        "total_cells": total,
        "unchecked": counts["unchecked"],
        "not_applicable": counts["not_applicable"],
        "pass": counts["pass"],
        "fail": counts["fail"],
        "recheck": counts["recheck"],
        "remediated": counts["remediated"],
        "coverage_pct": coverage_pct,
    }


def compute_file_hash(file_path):
    """Compute content hash via git hash-object. Falls back to None on error."""
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
