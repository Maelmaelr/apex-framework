#!/usr/bin/env python3
"""validate-document.py -- Structural validation for audit/PRD documents.

Usage: python3 validate-document.py <document.md>

Checks:
  1. YAML front matter integrity (required fields, valid structure)
  2. ID uniqueness across the document body (no duplicate BP-xx or REQ-xx)
  3. Tier completeness (body ID count per tier matches YAML progress totals)
  4. Completed-list integrity (no duplicate IDs in fixed_items/implemented_items)

Exit codes: 0 = all checks pass, 1 = validation errors found, 2 = usage error
"""

import re
import sys
from collections import Counter

def parse_yaml_frontmatter(lines):
    """Extract YAML front matter between --- delimiters."""
    if not lines or lines[0].strip() != "---":
        return None, lines
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return None, lines
    return lines[1:end], lines[end + 1:]


def parse_yaml_simple(yaml_lines):
    """Minimal YAML parser for document front matter (nested dicts with lists)."""
    result = {}
    current_key = None
    for line in yaml_lines:
        stripped = line.rstrip()
        if not stripped or stripped.startswith("#"):
            continue
        # Top-level key
        if not stripped.startswith(" ") and ":" in stripped:
            key, _, val = stripped.partition(":")
            val = val.strip()
            if val:
                result[key.strip()] = val
            else:
                result[key.strip()] = {}
                current_key = key.strip()
        # Nested key (2-space indent)
        elif stripped.startswith("  ") and not stripped.startswith("    ") and current_key is not None:
            key, _, val = stripped.strip().partition(":")
            val = val.strip()
            if isinstance(result[current_key], dict):
                # Parse inline list: ["A", "B"]
                list_match = re.match(r'\[([^\]]*)\]', val)
                if list_match:
                    items = list_match.group(1)
                    if items.strip():
                        result[current_key][key.strip()] = [
                            s.strip().strip('"').strip("'")
                            for s in items.split(",")
                        ]
                    else:
                        result[current_key][key.strip()] = []
                # Parse inline dict: { total: N }
                elif val.startswith("{") and val.endswith("}"):
                    inner = val[1:-1].strip()
                    d = {}
                    for pair in inner.split(","):
                        if ":" in pair:
                            k, _, v = pair.partition(":")
                            v = v.strip()
                            try:
                                d[k.strip()] = int(v)
                            except ValueError:
                                d[k.strip()] = v
                    result[current_key][key.strip()] = d
                else:
                    result[current_key][key.strip()] = val
    return result


def detect_doc_type(yaml_data):
    """Detect document type from YAML fields."""
    if "fixed_items" in yaml_data:
        return "audit"
    if "implemented_items" in yaml_data:
        return "prd"
    return None


def extract_body_ids(body_lines, id_pattern):
    """Extract all IDs matching pattern from document body, with positions."""
    ids = []
    for i, line in enumerate(body_lines, 1):
        for match in re.finditer(id_pattern, line):
            ids.append((match.group(0), i))
    return ids


def extract_tier_ids(body_lines, id_pattern, tier_sections):
    """Extract IDs grouped by tier from the priority ranking section."""
    tier_ids = {tier: [] for tier in tier_sections}
    current_tier = None
    in_ranking = False

    # Pre-compile word-boundary regex per tier variant to avoid substring
    # collisions (e.g., "flows" contains "low", "shigh" contains "high").
    tier_patterns = {}
    for tier_name in tier_sections:
        variants = [tier_name.replace("_", " ")]
        if tier_name == "must_have":
            variants.append("must have")
        elif tier_name == "should_have":
            variants.append("should have")
        elif tier_name == "nice_to_have":
            variants.append("nice to have")
        tier_patterns[tier_name] = [
            re.compile(rf'\b{re.escape(v)}\b') for v in variants
        ]
    stop_patterns = [
        re.compile(rf'\b{re.escape(tier.replace("_", " "))}\b')
        for tier in tier_sections
    ]

    for line in body_lines:
        stripped = line.strip()
        lower = stripped.lower()

        # Detect priority ranking section
        if "priority" in lower and ("ranking" in lower or "rank" in lower):
            in_ranking = True
            continue

        if in_ranking:
            # Detect tier headers with word-boundary matching
            for tier_name, patterns in tier_patterns.items():
                if any(p.search(lower) for p in patterns):
                    current_tier = tier_name
                    break

            # Extract IDs on this line
            if current_tier:
                for match in re.finditer(id_pattern, stripped):
                    tier_ids[current_tier].append(match.group(0))

            # Stop at next major section
            if stripped.startswith("## ") and not any(
                p.search(lower) for p in stop_patterns
            ):
                if in_ranking and current_tier is not None:
                    break

    return tier_ids


def validate(filepath):
    errors = []

    try:
        with open(filepath, "r") as f:
            lines = f.readlines()
    except FileNotFoundError:
        errors.append(f"FILE: not found: {filepath}")
        print("\n".join(errors))
        return errors

    # 1. Parse YAML front matter
    yaml_lines, body_lines_raw = parse_yaml_frontmatter(lines)
    if yaml_lines is None:
        errors.append("YAML: missing front matter (no --- delimiters)")
        print("\n".join(errors))
        return errors

    yaml_data = parse_yaml_simple(yaml_lines)
    doc_type = detect_doc_type(yaml_data)

    if doc_type is None:
        errors.append("YAML: cannot detect document type (no fixed_items or implemented_items)")
        print("\n".join(errors))
        return errors

    # Type-specific config
    if doc_type == "audit":
        items_key = "fixed_items"
        id_prefix = "BP"
        tiers = ["critical", "high", "medium", "low"]
        required_fields = ["name", "created", "updated", "fixed_items", "progress"]
    else:
        items_key = "implemented_items"
        id_prefix = "REQ"
        tiers = ["must_have", "should_have", "nice_to_have"]
        required_fields = ["name", "created", "updated", "implemented_items", "progress"]

    id_pattern = rf'\b{id_prefix}-\d+\b'

    # Check required fields
    for field in required_fields:
        if field not in yaml_data:
            errors.append(f"YAML: missing required field '{field}'")

    # 2. Check ID uniqueness on definition lines only
    # Definition lines start with [ID] as the primary tag (e.g., "[REQ-01] Build...")
    # IDs naturally repeat in YAML, priority ranking, and cross-references
    body_text = [l.rstrip() for l in body_lines_raw]
    def_pattern = rf'^\[({id_prefix}-\d+)\]'
    def_ids = []
    for i, line in enumerate(body_text, 1):
        match = re.match(def_pattern, line.strip())
        if match:
            def_ids.append((match.group(1), i))
    def_counts = Counter(id_str for id_str, _ in def_ids)
    for id_str, count in def_counts.items():
        if count > 1:
            dup_lines = [ln for i, ln in def_ids if i == id_str]
            errors.append(
                f"ID-UNIQUENESS: {id_str} defined {count} times "
                f"(lines: {', '.join(str(l) for l in dup_lines)})"
            )

    # 3. Tier completeness: body ID count per tier vs YAML progress totals
    progress = yaml_data.get("progress", {})
    tier_ids = extract_tier_ids(body_text, id_pattern, tiers)

    for tier in tiers:
        tier_progress = progress.get(tier, {})
        expected_total = tier_progress.get("total", 0) if isinstance(tier_progress, dict) else 0
        actual_count = len(tier_ids.get(tier, []))
        if expected_total > 0 and actual_count != expected_total:
            errors.append(
                f"TIER-COMPLETENESS: {tier} has {actual_count} IDs in priority section "
                f"but progress.{tier}.total = {expected_total}"
            )

    # 4. Completed-list integrity: no duplicates in fixed_items/implemented_items
    completed = yaml_data.get(items_key, {})
    if isinstance(completed, dict):
        for tier, id_list in completed.items():
            if isinstance(id_list, list):
                list_counts = Counter(id_list)
                for id_str, count in list_counts.items():
                    if count > 1:
                        errors.append(
                            f"COMPLETED-DEDUP: {id_str} appears {count} times "
                            f"in {items_key}.{tier}"
                        )

    # Output
    if errors:
        print(f"VALIDATE: {len(errors)} error(s) in {filepath}")
        for e in errors:
            print(f"  - {e}")
    else:
        print(f"VALIDATE: {filepath} OK")

    return errors


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 validate-document.py <document.md>")
        sys.exit(2)

    errors = validate(sys.argv[1])
    sys.exit(1 if errors else 0)
