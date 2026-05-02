#!/usr/bin/env python3
"""Pre-scan lessons.md for candidate duplicate pairs by token-overlap (Jaccard).

Output is a starting candidate list for /apex-lessons-analyze Step 2 - the LLM
reviews each pair and decides merge / dedup / keep-both. Heuristic-only; not
authoritative (false positives expected; the LLM is the gate).

Tag formats handled (parsed but NOT used for similarity):
  [last-hit: YYYY-MM-DD], [verified, ...], [unverified, ...], [anti-pattern, ...]

Usage:
  python3 lesson-dedup.py <path/to/lessons.md> [--threshold 0.6]

Exit codes:
  0  scan complete (output may be empty if no pairs above threshold)
  1  bad args / file not found
"""
import argparse
import re
import sys
from pathlib import Path

LESSON_RE = re.compile(r'^- (?:\[[^\]]*\]\s+)?(.+)$')
TOKEN_RE = re.compile(r'[A-Za-z0-9_]{3,}')


def parse_lessons(text):
    """Yield (line_num, section, lesson_body) for each entry under a `## ` header."""
    section = ''
    for i, line in enumerate(text.splitlines(), 1):
        if line.startswith('## '):
            section = line[3:].strip()
            continue
        m = LESSON_RE.match(line)
        if m:
            yield i, section, m.group(1).strip()


def tokens(s):
    return set(t.lower() for t in TOKEN_RE.findall(s))


def jaccard(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    ap.add_argument('--threshold', type=float, default=0.6)
    args = ap.parse_args()

    p = Path(args.path)
    if not p.exists():
        sys.stderr.write(f"lesson-dedup.py: not found: {p}\n")
        return 1

    text = p.read_text(encoding='utf-8')
    lessons = list(parse_lessons(text))
    if len(lessons) < 2:
        return 0

    pairs = []
    for i in range(len(lessons)):
        ti = tokens(lessons[i][2])
        for j in range(i + 1, len(lessons)):
            tj = tokens(lessons[j][2])
            score = jaccard(ti, tj)
            if score >= args.threshold:
                pairs.append((score, lessons[i], lessons[j]))

    pairs.sort(reverse=True, key=lambda x: x[0])
    for score, (la_n, la_s, la_t), (lb_n, lb_s, lb_t) in pairs:
        print(f"score={score:.2f} L{la_n} [{la_s}] {la_t[:80]}")
        print(f"          L{lb_n} [{lb_s}] {lb_t[:80]}")
        print()

    return 0


if __name__ == '__main__':
    sys.exit(main())
