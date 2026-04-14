#!/usr/bin/env python3
"""Extract changelog sections between two semver versions from stdin.

Usage: cat CHANGELOG.md | python3 apex-changelog-extract.py <old_version> <new_version>

Reads CHANGELOG markdown from stdin, filters to versions between old_version
(exclusive) and new_version (inclusive), outputs raw text + footer.
"""
# Exit 0 = success, Exit 1 = usage error or empty input.

import re
import sys


def parse_semver(version_str):
    """Parse semver string to tuple for comparison."""
    # Strip leading 'v' if present
    v = version_str.lstrip("v")
    parts = v.split(".")
    result = []
    for p in parts:
        # Extract leading digits only
        m = re.match(r"(\d+)", p)
        result.append(int(m.group(1)) if m else 0)
    while len(result) < 3:
        result.append(0)
    return tuple(result[:3])


def extract_versions(content, old_version, new_version):
    """Extract changelog sections between old (exclusive) and new (inclusive)."""
    old_sv = parse_semver(old_version)
    new_sv = parse_semver(new_version)

    # Split on ## headers that look like version headers
    sections = re.split(r"(?=^## )", content, flags=re.MULTILINE)

    output_sections = []
    versions_scanned = 0

    for section in sections:
        # Match version header: ## [X.Y.Z] or ## X.Y.Z
        header_match = re.match(
            r"^## \[?(\d+\.\d+\.\d+[^\]]*)\]?", section.strip()
        )
        if not header_match:
            continue

        version_str = header_match.group(1)
        try:
            sv = parse_semver(version_str)
        except (ValueError, IndexError):
            continue

        versions_scanned += 1

        # Include if old < version <= new
        if old_sv < sv <= new_sv:
            output_sections.append(section.strip())

    return output_sections, versions_scanned


def main():
    if len(sys.argv) != 3:
        print(
            "Usage: cat CHANGELOG.md | python3 apex-changelog-extract.py <old_version> <new_version>",
            file=sys.stderr,
        )
        sys.exit(1)

    old_version = sys.argv[1]
    new_version = sys.argv[2]

    content = sys.stdin.read()
    if not content.strip():
        print("No changelog content received on stdin.", file=sys.stderr)
        sys.exit(1)

    sections, versions_scanned = extract_versions(content, old_version, new_version)

    if not sections:
        print(f"0 entries found in range {old_version}..{new_version}", file=sys.stderr)

    for section in sections:
        print(section)
        print()

    print(f"{versions_scanned} versions scanned")


if __name__ == "__main__":
    main()
