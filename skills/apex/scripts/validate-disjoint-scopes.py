#!/usr/bin/env python3
# p2.0b disjoint-scope validator.
# Spec: apex-core.md p2.0b "Disjoint-scope rule" | apex-core-overview.md p2.0b.
#
# Enforces three invariants on the planner's candidate plan:
#   (1) per-teammate `allowed_files` lists pairwise disjoint (excluding standard
#       safety paths, which are shared by design).
#   (2) [if --main-scope is supplied] union of allowed_files MUST be a subset of
#       main-scope `allowed_files`. The planner extends main scope first if any
#       teammate needs files outside it (single source of truth).
#   (3) [if `shared_files` is present in plan] every entry in `shared_files` is
#       disjoint from every teammate's `allowed_files`. A file is in shared XOR
#       in exactly one teammate's allowed_files, never both.
#
# On overlap of any kind, prints offending pairs to stdout and exits 1 -- the
# planner then reassigns or routes to `shared_files` and re-runs.
#
# Standard safety paths (from shared-guardrails.md):
#   .claude-tmp/        ~/.claude/tmp/        /tmp/{session}-*
#   docs/**             README* (any depth)
#
# Input:
#   --plan <path>          JSON file conforming to plan-candidate.schema.json:
#                          {"teammates": [{"teammate_id": "ab12",
#                                          "allowed_files": ["..."]}, ...],
#                           "shared_files"?: ["..."]}
#   --main-scope <path>    optional; main-scope.schema.json file (enables check 2)
#   --session <token>      optional; bounds the /tmp/{session}-* safety glob
#
# Stdout (on overlap, one per line):
#   OVERLAP             <file>\t<teammate-a>\t<teammate-b>     (check 1)
#   NOT_IN_MAIN_SCOPE   <file>\t<teammate-a>                   (check 2)
#   SHARED_OVERLAP      <file>\t<teammate-a>                   (check 3)
#
# Exit codes:
#   0  all enabled invariants hold
#   1  at least one violation; planner must reassign / extend main / route shared
#   2  input malformed (parse error, schema fail, missing fields)

import argparse
import itertools
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _validate import consumer_load  # noqa: E402


def _is_safety(path: str, session: str | None) -> bool:
    p = path.strip()
    if not p:
        return True
    if p.startswith(".claude-tmp/") or p == ".claude-tmp":
        return True
    if p.startswith("~/.claude/tmp/") or p == "~/.claude/tmp":
        return True
    if p.startswith("docs/") or p == "docs":
        return True
    if os.path.basename(p).startswith("README"):
        return True
    if session and re.match(rf"^/tmp/{re.escape(session)}-", p):
        return True
    if not session and p.startswith("/tmp/"):
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate teammate scopes are pairwise disjoint and bounded by main scope.")
    parser.add_argument("--plan", required=True, help="path to plan-candidate JSON")
    parser.add_argument("--main-scope", default=None, help="path to main-scope JSON; enables subset check")
    parser.add_argument("--session", default=None, help="apex {session} token (8-hex)")
    args = parser.parse_args()

    plan = consumer_load(args.plan, "plan-candidate.schema.json")
    if plan is None:
        print(f"validate-disjoint-scopes: invalid or missing plan {args.plan}", file=sys.stderr)
        return 2

    teammates = plan["teammates"]
    shared = [p for p in plan.get("shared_files", []) if isinstance(p, str)]

    # Build per-teammate non-safety sets.
    sets: list[tuple[str, set[str]]] = []
    for t in teammates:
        tid = t["teammate_id"]
        non_safety = {p for p in t["allowed_files"] if isinstance(p, str) and not _is_safety(p, args.session)}
        sets.append((tid, non_safety))

    violations = 0

    # Check 1: pairwise disjoint.
    for (a_id, a_set), (b_id, b_set) in itertools.combinations(sets, 2):
        for f in sorted(a_set & b_set):
            print(f"OVERLAP\t{f}\t{a_id}\t{b_id}")
            violations += 1

    # Check 2: subset of main scope.
    if args.main_scope:
        main = consumer_load(args.main_scope, "main-scope.schema.json")
        if main is None:
            print(f"validate-disjoint-scopes: invalid or missing main-scope {args.main_scope}", file=sys.stderr)
            return 2
        main_set = {p for p in main["allowed_files"] if isinstance(p, str) and not _is_safety(p, args.session)}
        for tid, t_set in sets:
            for f in sorted(t_set - main_set):
                print(f"NOT_IN_MAIN_SCOPE\t{f}\t{tid}")
                violations += 1

    # Check 3: shared_files disjoint from every teammate.
    if shared:
        shared_non_safety = {p for p in shared if not _is_safety(p, args.session)}
        for tid, t_set in sets:
            for f in sorted(shared_non_safety & t_set):
                print(f"SHARED_OVERLAP\t{f}\t{tid}")
                violations += 1

    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
