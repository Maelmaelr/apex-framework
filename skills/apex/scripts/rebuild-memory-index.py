#!/usr/bin/env python3
# rebuild-memory-index.py -- regenerates MEMORY.md from memory/*.md frontmatter
# Usage: python3 rebuild-memory-index.py <memory-dir> [--dry-run]
# Exit 0 = success, Exit 1 = error (bad dir, no files, write failure).
# v1.0 -- 2026-03-28

import argparse
import os
import sys

KNOWN_TYPES = ["user", "feedback", "project", "reference"]
TYPE_LABELS = {
    "user": "User",
    "feedback": "Feedback",
    "project": "Project",
    "reference": "Reference",
}
MAX_ENTRY_LENGTH = 150
DESC_TRUNCATE_AT = 120
INDEX_FILENAME = "MEMORY.md"


def parse_frontmatter(filepath):
    """
    Parse YAML frontmatter from a markdown file.
    Returns a dict with keys: name, description, type.
    Returns None if frontmatter is missing or malformed.
    """
    try:
        with open(filepath, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError as exc:
        print(f"WARNING: cannot read {filepath}: {exc}", file=sys.stderr)
        return None

    if not lines or lines[0].rstrip() != "---":
        return None

    fm_lines = []
    end_idx = None
    for i, line in enumerate(lines[1:], start=1):
        if line.rstrip() == "---":
            end_idx = i
            break
        fm_lines.append(line)

    if end_idx is None:
        return None

    fields = {}
    for line in fm_lines:
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()

    name = fields.get("name", "").strip()
    description = fields.get("description", "").strip()
    entry_type = fields.get("type", "").strip().lower()

    if not name or not description or not entry_type:
        return None

    return {"name": name, "description": description, "type": entry_type}


def truncate(text, max_len):
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def build_index(memory_dir):
    """
    Scan memory_dir for .md files, parse frontmatter, group by type.
    Returns (groups, counts, skipped) where groups is {type: [(filename, meta), ...]}.
    """
    try:
        entries = os.listdir(memory_dir)
    except OSError as exc:
        print(f"ERROR: cannot list directory {memory_dir}: {exc}", file=sys.stderr)
        sys.exit(1)

    md_files = sorted(
        f for f in entries if f.endswith(".md") and f != INDEX_FILENAME
    )

    if not md_files:
        print("ERROR: no memory files found", file=sys.stderr)
        sys.exit(1)

    groups = {t: [] for t in KNOWN_TYPES}
    skipped = 0

    for filename in md_files:
        filepath = os.path.join(memory_dir, filename)
        meta = parse_frontmatter(filepath)
        if meta is None:
            print(
                f"WARNING: skipping {filename} -- missing or invalid frontmatter",
                file=sys.stderr,
            )
            skipped += 1
            continue

        entry_type = meta["type"]
        if entry_type not in groups:
            groups[entry_type] = []
        groups[entry_type].append((filename, meta))

    # Sort each group alphabetically by name
    for t in groups:
        groups[t].sort(key=lambda x: x[1]["name"].lower())

    counts = {t: len(groups[t]) for t in KNOWN_TYPES}
    # Include unknown types in count
    for t in groups:
        if t not in counts:
            counts[t] = len(groups[t])

    return groups, counts, skipped


def render_index(groups):
    """Render the full MEMORY.md content from grouped entries."""
    lines = ["# Auto Memory", ""]

    # Emit known types first, then any extras encountered in files
    all_types = list(KNOWN_TYPES) + [t for t in groups if t not in KNOWN_TYPES]

    first_section = True
    for entry_type in all_types:
        entries = groups.get(entry_type, [])
        if not entries:
            continue

        label = TYPE_LABELS.get(entry_type, entry_type.capitalize())

        if not first_section:
            lines.append("")
        lines.append(f"## {label}")
        first_section = False

        for filename, meta in entries:
            base = os.path.splitext(filename)[0]
            name = meta["name"]
            desc = truncate(meta["description"], DESC_TRUNCATE_AT)
            entry = f"- [{name}]({base}.md) - {desc}"
            # Hard-clamp total entry length
            if len(entry) > MAX_ENTRY_LENGTH:
                entry = entry[: MAX_ENTRY_LENGTH - 3] + "..."
            lines.append(entry)

    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Rebuild MEMORY.md index from memory/*.md frontmatter."
    )
    parser.add_argument(
        "memory_dir",
        help="Path to the memory directory (e.g., ~/.claude/projects/.../memory/)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the generated MEMORY.md without writing it.",
    )
    args = parser.parse_args()

    memory_dir = os.path.expanduser(args.memory_dir)

    if not os.path.isdir(memory_dir):
        print(f"ERROR: {memory_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    groups, counts, skipped = build_index(memory_dir)

    total = sum(
        len(v) for v in groups.values()
    )
    if total == 0:
        print("ERROR: no memory files with valid frontmatter found", file=sys.stderr)
        sys.exit(1)

    content = render_index(groups)

    u = counts.get("user", 0)
    f = counts.get("feedback", 0)
    p = counts.get("project", 0)
    r = counts.get("reference", 0)

    if args.dry_run:
        print(content)
        print(
            f"\nMEMORY INDEX (dry-run): Would rebuild with {total} entries "
            f"({u}U, {f}F, {p}P, {r}R)",
            file=sys.stderr,
        )
        return

    index_path = os.path.join(memory_dir, INDEX_FILENAME)
    try:
        with open(index_path, "w", encoding="utf-8") as fh:
            fh.write(content)
    except OSError as exc:
        print(f"ERROR: cannot write {index_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    print(
        f"MEMORY INDEX: Rebuilt with {total} entries ({u}U, {f}F, {p}P, {r}R)"
    )


if __name__ == "__main__":
    main()
