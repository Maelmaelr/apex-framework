#!/usr/bin/env python3
"""Pre-scan lessons.md for stale entries by [last-hit: YYYY-MM-DD] tag age.

Output is a starting candidate list for /apex-lessons (analyze phase) Step 3.5 - the
LLM reviews each candidate and decides ARCHIVE (move to lessons-archive.md)
or KEEP (re-verified by recent grep hit).

Tag formats handled:
  [last-hit: YYYY-MM-DD]                                   -> age-tested
  [verified, last-hit: YYYY-MM-DD]                         -> age-tested
  [unverified, last-hit: YYYY-MM-DD]                       -> age-tested
  [anti-pattern, last-hit: YYYY-MM-DD]                     -> age-tested
  [anti-pattern, unverified, last-hit: YYYY-MM-DD]         -> age-tested
  []                                                        -> stale (legacy empty)
  [verified] (no last-hit)                                 -> EXEMPT (still tracking)

Usage:
  python3 stale-lessons.py <path/to/lessons.md> [--days 90]

Exit codes:
  0  scan complete (output may be empty if no stale entries)
  1  bad args / file not found
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

LESSON_RE = re.compile(r'^- (\[[^\]]*\])?\s*(.+)$')
DATE_RE = re.compile(r'last-hit:\s*(\d{4}-\d{2}-\d{2})')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    ap.add_argument('--days', type=int, default=90)
    args = ap.parse_args()

    p = Path(args.path)
    if not p.exists():
        sys.stderr.write(f"stale-lessons.py: not found: {p}\n")
        return 1

    today = datetime.date.today()
    threshold = datetime.timedelta(days=args.days)
    section = ''

    for i, line in enumerate(p.read_text(encoding='utf-8').splitlines(), 1):
        if line.startswith('## '):
            section = line[3:].strip()
            continue
        m = LESSON_RE.match(line)
        if not m:
            continue
        tag = (m.group(1) or '').strip()
        body = m.group(2).strip()

        dm = DATE_RE.search(tag)
        if dm:
            try:
                lh = datetime.date.fromisoformat(dm.group(1))
            except ValueError:
                continue
            age = today - lh
            if age > threshold:  # strictly older than --days (triage.md: "> 90 days ago")
                print(f"L{i} [section: {section}] last-hit: {lh.isoformat()} (age: {age.days}d) {body[:80]}")
        elif tag == '[]':
            print(f"L{i} [section: {section}] last-hit: never (legacy []) {body[:80]}")
        # [verified] without last-hit is EXEMPT - tracking starts on next grep hit.

    return 0


if __name__ == '__main__':
    sys.exit(main())
