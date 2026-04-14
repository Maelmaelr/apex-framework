#!/usr/bin/env python3
# Usage: stale-lessons.py <path-to-lessons.md> [--days N]
# Parses a lessons.md file and outputs lesson blocks where [last-hit] date exceeds N days.
# Exit 0 = stale lessons found, Exit 1 = no stale lessons found.
# v1.0 -- 2026-03-28

import argparse
import re
import sys
from datetime import date, datetime


def parse_args():
    parser = argparse.ArgumentParser(
        description="Find stale lessons in a lessons.md file.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Staleness criteria:
  [last-hit: YYYY-MM-DD]                            with date > N days ago: STALE
  [verified, last-hit: YYYY-MM-DD]                   with date > N days ago: STALE
  [unverified, last-hit: YYYY-MM-DD]                 with date > N days ago: STALE
  [anti-pattern, last-hit: YYYY-MM-DD]               with date > N days ago: STALE
  [anti-pattern, unverified, last-hit: YYYY-MM-DD]   with date > N days ago: STALE
  []                                                 (empty tag, legacy):    STALE (never hit)
  [verified]                                         (no last-hit):          EXEMPT
  [last-hit: YYYY-MM-DD]                            with date <= N days:    FRESH
  [verified, last-hit: YYYY-MM-DD]                   with date <= N days:    FRESH
  [unverified, last-hit: YYYY-MM-DD]                 with date <= N days:    FRESH
  [anti-pattern, last-hit: YYYY-MM-DD]               with date <= N days:    FRESH
  [anti-pattern, unverified, last-hit: YYYY-MM-DD]   with date <= N days:    FRESH

Exit codes:
  0 = stale lessons found
  1 = no stale lessons found
""",
    )
    parser.add_argument("lessons_file", metavar="lessons.md", help="Path to lessons.md file")
    parser.add_argument(
        "--days",
        type=int,
        default=90,
        metavar="N",
        help="Number of days before a lesson is considered stale (default: 90)",
    )
    return parser.parse_args()


# Regex patterns
LESSON_RE = re.compile(r"^- (\[.*?\])\s*(.*)")
DATE_RE = re.compile(r"last-hit:\s*(\d{4}-\d{2}-\d{2})")
SECTION_RE = re.compile(r"^##\s+(.*)")


def classify_tag(tag_str, today, max_days):
    """
    Returns a tuple (status, date_str) where status is 'STALE', 'FRESH', or 'EXEMPT'.
    date_str is the last-hit date string or 'never' for empty tags.
    """
    # Empty tag: legacy, never hit
    if tag_str == "[]":
        return ("STALE", "never")

    date_match = DATE_RE.search(tag_str)

    # Tags without last-hit and no date: exempt (e.g., [verified], [anti-pattern])
    if not date_match:
        return ("EXEMPT", None)

    date_str = date_match.group(1)
    try:
        hit_date = datetime.strptime(date_str, "%Y-%m-%d").date()
    except ValueError:
        # Malformed date -- treat as never hit
        return ("STALE", "never")

    delta = (today - hit_date).days
    if delta > max_days:
        return ("STALE", date_str)
    return ("FRESH", date_str)


def truncate(text, length=80):
    if len(text) <= length:
        return text
    return text[:length] + "..."


def main():
    args = parse_args()
    today = date.today()

    try:
        with open(args.lessons_file, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"ERROR: File not found: {args.lessons_file}", file=sys.stderr)
        sys.exit(2)
    except OSError as e:
        print(f"ERROR: Cannot read file: {e}", file=sys.stderr)
        sys.exit(2)

    current_section = "(no section)"
    stale_count = 0
    fresh_count = 0
    exempt_count = 0
    total_count = 0
    stale_lines = []

    for lineno, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip("\n")

        section_match = SECTION_RE.match(line)
        if section_match:
            current_section = section_match.group(1).strip()
            continue

        lesson_match = LESSON_RE.match(line)
        if not lesson_match:
            continue

        total_count += 1
        tag_str = lesson_match.group(1)
        lesson_text = lesson_match.group(2).strip()

        status, date_str = classify_tag(tag_str, today, args.days)

        if status == "STALE":
            stale_count += 1
            display_date = date_str if date_str else "never"
            stale_lines.append(
                f'STALE: L{lineno} ({current_section}) last-hit: {display_date} -- "{truncate(lesson_text)}"'
            )
        elif status == "FRESH":
            fresh_count += 1
        else:
            exempt_count += 1

    for entry in stale_lines:
        print(entry)

    print(
        f"\nSTALE SUMMARY: {stale_count} stale, {fresh_count} fresh, {exempt_count} exempt"
        f" out of {total_count} lessons"
    )

    # Exit 0 if stale lessons found, 1 if none
    sys.exit(0 if stale_count > 0 else 1)


if __name__ == "__main__":
    main()
