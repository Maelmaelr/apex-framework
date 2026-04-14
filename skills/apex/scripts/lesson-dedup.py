#!/usr/bin/env python3
# lesson-dedup.py -- Fuzzy-match duplicate lessons in a lessons.md file
# Usage: python3 lesson-dedup.py <lessons.md> [--threshold FLOAT]
# Exit 0 = duplicates found, Exit 1 = no lessons or no duplicates, Exit 2 = file error.
# v1.0 -- 2026-03-28

import argparse
import re
import sys
from difflib import SequenceMatcher


def parse_args():
    parser = argparse.ArgumentParser(
        description="Fuzzy-match duplicate lesson blocks in a lessons.md file using difflib.SequenceMatcher."
    )
    parser.add_argument(
        "lessons_file",
        metavar="lessons.md",
        help="Path to the lessons.md file to analyze",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.6,
        metavar="FLOAT",
        help="Similarity threshold (0.0-1.0, default: 0.6). Pairs at or above this score are reported.",
    )
    args = parser.parse_args()
    if not (0.0 <= args.threshold <= 1.0):
        parser.error("--threshold must be between 0.0 and 1.0")
    return args


# Regex to match a lesson line: "- [tag content] lesson text..."
# The tag block is everything between the first '[' and its matching ']'
_LESSON_RE = re.compile(r"^- \[([^\]]*)\]\s+(.*)")


def strip_tag(line):
    """Extract the lesson text portion, stripping the leading '- [tag] ' prefix."""
    m = _LESSON_RE.match(line)
    if m:
        return m.group(2).strip()
    return None


def parse_lessons(path):
    """
    Parse lessons.md and return a list of dicts:
      { "lineno": int, "section": str, "text": str, "raw": str }
    """
    lessons = []
    current_section = "(no section)"
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, start=1):
                line = line.rstrip("\n")
                if line.startswith("## "):
                    current_section = line[3:].strip()
                    continue
                text = strip_tag(line)
                if text is not None:
                    lessons.append(
                        {
                            "lineno": lineno,
                            "section": current_section,
                            "text": text,
                            "raw": line,
                        }
                    )
    except FileNotFoundError:
        print(f"Error: file not found: {path}", file=sys.stderr)
        sys.exit(2)
    except OSError as exc:
        print(f"Error reading file: {exc}", file=sys.stderr)
        sys.exit(2)
    return lessons


def find_candidates(lessons, threshold):
    """
    Compare every pair of lessons using SequenceMatcher.ratio().
    Return list of (score, lesson_a, lesson_b) for pairs >= threshold,
    sorted by score descending.
    """
    candidates = []
    n = len(lessons)
    for i in range(n):
        for j in range(i + 1, n):
            ratio = SequenceMatcher(
                None, lessons[i]["text"], lessons[j]["text"]
            ).ratio()
            if ratio >= threshold:
                candidates.append((ratio, lessons[i], lessons[j]))
    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates


def truncate(text, width=80):
    if len(text) <= width:
        return f'"{text}"'
    return f'"{text[:width]}..."'


def main():
    args = parse_args()
    lessons = parse_lessons(args.lessons_file)

    if not lessons:
        print("No lessons found in file.")
        print(
            f"DEDUP SUMMARY: 0 candidate pairs found above {args.threshold} threshold (0 lessons compared)"
        )
        sys.exit(1)

    candidates = find_candidates(lessons, args.threshold)

    for score, a, b in candidates:
        print(f"DEDUP CANDIDATE (similarity: {score:.2f}):")
        print(f"  L{a['lineno']} ({a['section']}): {truncate(a['text'])}")
        print(f"  L{b['lineno']} ({b['section']}): {truncate(b['text'])}")

    print()
    print(
        f"DEDUP SUMMARY: {len(candidates)} candidate pairs found above {args.threshold} threshold "
        f"({len(lessons)} lessons compared)"
    )

    sys.exit(0 if candidates else 1)


if __name__ == "__main__":
    main()
