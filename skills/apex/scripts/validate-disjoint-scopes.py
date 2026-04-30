#!/usr/bin/env python3
# p2.0b disjoint-scope validator.
# Spec: apex-core.md p2.0b "Disjoint-scope rule" | apex-core-overview.md p2.0b.
#
# Pairwise-intersects per-teammate `allowed_files` lists (excluding standard
# safety paths, which are shared by design). On overlap, prints offending
# {file, teammate-a, teammate-b} triples to stdout and exits 1 - the planner
# then reassigns or routes the file to `shared_files` and re-runs.
#
# Standard safety paths (from shared-guardrails.md):
#   .claude-tmp/        ~/.claude/tmp/        /tmp/{session}-*
#   docs/**             README* (any depth)
#
# Input:
#   --plan <path>   JSON file: {"teammates": [{"teammate_id": "ab12",
#                                              "allowed_files": ["..."]}, ...]}
#   --session <token>  optional, used to bound the /tmp/{session}-* safety glob
#
# Stdout (on overlap, one per line):
#   OVERLAP <file>\t<teammate-a>\t<teammate-b>
#
# Exit codes:
#   0  all teammate scopes pairwise disjoint (excl. safety paths)
#   1  at least one overlap detected; planner must reassign / route to shared
#   2  input malformed (parse error, missing fields)

import argparse
import itertools
import json
import os
import re
import sys


def _is_safety(path: str, session: str | None) -> bool:
    p = path.strip()
    if not p:
        return True  # empty entries are ignored, never count as overlap
    if p.startswith(".claude-tmp/") or p == ".claude-tmp":
        return True
    if p.startswith("~/.claude/tmp/") or p == "~/.claude/tmp":
        return True
    if p.startswith("docs/") or p == "docs":
        return True
    base = os.path.basename(p)
    if base.startswith("README"):
        return True
    if session and re.match(rf"^/tmp/{re.escape(session)}-", p):
        return True
    if not session and p.startswith("/tmp/"):
        # Without an explicit session token we cannot bound the glob safely;
        # treat any /tmp/ path as safety to avoid false-positive overlaps.
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate teammate scopes are pairwise disjoint.")
    parser.add_argument("--plan", required=True, help="path to plan JSON")
    parser.add_argument("--session", default=None, help="apex {session} token (8-hex)")
    args = parser.parse_args()

    try:
        with open(args.plan, encoding="utf-8") as f:
            plan = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"validate-disjoint-scopes: failed to read {args.plan}: {e}", file=sys.stderr)
        return 2

    teammates = plan.get("teammates")
    if not isinstance(teammates, list):
        print("validate-disjoint-scopes: missing or invalid 'teammates' array", file=sys.stderr)
        return 2

    sets: list[tuple[str, set[str]]] = []
    for t in teammates:
        tid = t.get("teammate_id")
        files = t.get("allowed_files")
        if not isinstance(tid, str) or not isinstance(files, list):
            print(
                "validate-disjoint-scopes: each teammate needs 'teammate_id' (str) and 'allowed_files' (list)",
                file=sys.stderr,
            )
            return 2
        non_safety = {p for p in files if isinstance(p, str) and not _is_safety(p, args.session)}
        sets.append((tid, non_safety))

    overlaps: list[tuple[str, str, str]] = []
    for (a_id, a_set), (b_id, b_set) in itertools.combinations(sets, 2):
        for f in sorted(a_set & b_set):
            overlaps.append((f, a_id, b_id))

    if overlaps:
        for f, a, b in overlaps:
            print(f"OVERLAP\t{f}\t{a}\t{b}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
