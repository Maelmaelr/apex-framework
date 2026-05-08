#!/usr/bin/env python3
# Step 8.2 disjoint-scope validator.
# Spec: apex-core.md step 8.2 (task split + disjoint scopes).
#
# Enforces two invariants when the orchestrator spawns 2+ parallel executor tasks:
#   (1) per-task `allowed_files` lists pairwise disjoint (excluding standard
#       safety paths, which are shared by design).
#   (2) [if --main-scope is supplied] union of allowed_files MUST be a subset of
#       main-scope `allowed_files`. Cross-task touch points are routed to a
#       serialised follow-up task, never to a parallel write.
#
# On overlap of any kind, prints offending pairs to stdout and exits 1 -- the
# orchestrator then reassigns and re-runs.
#
# Standard safety paths (from apex-core.md Conventions):
#   .claude-tmp/        ~/.claude/tmp/        /tmp/{session}-*
#   docs/**             README* (any depth)
#
# Input:
#   --plan <path>        JSON file shape:
#                        {"tasks": [{"task_id": "1",
#                                    "allowed_files": ["..."]}, ...]}
#   --main-scope <path>  optional; main-scope.schema.json file (enables check 2)
#   --session <token>    optional; bounds the /tmp/{session}-* safety glob
#
# Stdout (on overlap, one per line):
#   OVERLAP             <file>\t<task-a>\t<task-b>     (check 1)
#   NOT_IN_MAIN_SCOPE   <file>\t<task-a>               (check 2)
#
# Exit codes:
#   0  all enabled invariants hold
#   1  at least one violation; orchestrator must reassign or extend main scope
#   2  input malformed (parse error, missing fields)

import argparse
import itertools
import json
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


def _load_plan(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("tasks"), list):
        return None
    for t in data["tasks"]:
        if not isinstance(t, dict):
            return None
        if not isinstance(t.get("task_id"), str):
            return None
        if not isinstance(t.get("allowed_files"), list):
            return None
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate per-task scopes are pairwise disjoint and bounded by main scope.")
    parser.add_argument("--plan", required=True, help="path to task-plan JSON")
    parser.add_argument("--main-scope", default=None, help="path to main-scope JSON; enables subset check")
    parser.add_argument("--session", default=None, help="apex {session} token (8-hex)")
    args = parser.parse_args()

    plan = _load_plan(args.plan)
    if plan is None:
        print(f"validate-disjoint-scopes: invalid or missing plan {args.plan}", file=sys.stderr)
        return 2

    tasks = plan["tasks"]

    # Single-task short-circuit. The disjoint-check is structurally inapplicable
    # to one-task plans (no pairs to compare) and the subset-of-main-scope check
    # adds noise in single-file review flows where the orchestrator already
    # narrowed scope upstream. Surface the skip explicitly so callers do not
    # mistake it for a silent pass. Reflector b69d28ba: "disjoint-scope
    # validator assumes per-goal distributed writes, inapplicable to single-file
    # review tasks".
    if len(tasks) <= 1:
        print("validate-disjoint-scopes: SKIPPED (single-task plan; disjoint-check inapplicable)", file=sys.stderr)
        return 0

    # Build per-task non-safety sets.
    sets: list[tuple[str, set[str]]] = []
    for t in tasks:
        tid = t["task_id"]
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

    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
