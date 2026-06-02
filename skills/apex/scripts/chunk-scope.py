#!/usr/bin/env python3
"""Partition allowed_files into N approximately-equal chunks.

Spec: skills/apex/steps/08-execute.md step 8.2 (B1: scope-size hard split when
len(allowed_files) > 8). Goal text duplicates across chunks; first executor
to implement wins, the second sees `already-satisfied`.

Input:  one path per line on stdin OR a JSON array via --json.
Output: JSON `{chunks: [[...], [...], ...]}` with N chunks (default 2).

Partition policy: group paths by parent directory, sort groups largest-first,
deal each group greedily into the smallest current chunk. Keeps directory-
siblings together where possible; chunks remain pairwise disjoint by
construction so step 8.2 disjoint-scopes validation continues to pass.

Exit codes:
  0 - chunked successfully
  1 - bad args / empty input
"""
import argparse
import json
import sys
from collections import defaultdict
from pathlib import PurePosixPath


def chunk(paths, n):
    if n < 1:
        raise ValueError("n must be >= 1")
    groups = defaultdict(list)
    for p in paths:
        groups[str(PurePosixPath(p).parent)].append(p)
    sorted_groups = sorted(groups.values(), key=len, reverse=True)
    chunks = [[] for _ in range(n)]
    for g in sorted_groups:
        smallest_idx = min(range(n), key=lambda i: len(chunks[i]))
        chunks[smallest_idx].extend(sorted(g))
    for c in chunks:
        c.sort()
    return chunks


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true",
                    help="read JSON array from stdin (default: one path per line)")
    ap.add_argument("-n", type=int, default=2,
                    help="number of chunks (default 2)")
    args = ap.parse_args()
    raw = sys.stdin.read()
    if not raw.strip():
        print("chunk-scope: empty input", file=sys.stderr)
        sys.exit(1)
    if args.json:
        paths = json.loads(raw)
        if not isinstance(paths, list):
            print("chunk-scope: --json input must be a JSON array", file=sys.stderr)
            sys.exit(1)
    else:
        paths = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    if not paths:
        print("chunk-scope: no paths", file=sys.stderr)
        sys.exit(1)
    chunks = chunk(paths, args.n)
    json.dump({"chunks": chunks}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
