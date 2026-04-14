#!/usr/bin/env python3
# Usage: audit-baselines.py <subcommand> [args]
# Subcommands: token-proxy, finding-delta, coverage-gap
# Establishes improvement baselines for APEX audit quality metrics.
# Exit 0 = success (JSON to stdout), Exit 1 = error.
# v1.0 -- 2026-03-30

import argparse, json, re, sys
from pathlib import Path


def error(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        error(f"File not found: {path}")
    except (json.JSONDecodeError, OSError) as e:
        error(f"Cannot parse {path}: {e}")


STEP_WEIGHTS = {
    "1": 1.0, "2": 1.5, "2.6": 2.0, "3": 2.5, "4": 3.0,
    "5": 3.5, "5A": 4.0, "6": 4.5, "7": 5.0,
}


def cmd_token_proxy(args):
    """Parse session manifests and estimate per-session complexity."""
    session_dir = Path(args.session_dir)
    if not session_dir.is_dir():
        error(f"Session directory not found: {session_dir}")
    manifests = sorted(
        p for p in session_dir.glob("apex-*.json")
        if not p.stem.endswith(("-scope", "-budget"))
    )
    if not manifests:
        error(f"No session manifests found in {session_dir}")

    sessions = []
    for mpath in manifests:
        data = load_json(mpath)
        files_claimed = len(data.get("files", []))
        step = data.get("current_step", "unknown")
        weight = STEP_WEIGHTS.get(str(step), 2.0)
        sessions.append({
            "session_id": mpath.stem,
            "files_claimed": files_claimed,
            "path": data.get("path"),
            "current_step": step,
            "has_scout_findings": data.get("scout_findings") is not None,
            "has_tail_mode": data.get("tail_mode") is not None,
            "complexity_proxy": round(files_claimed * weight, 1),
        })

    complexities = [s["complexity_proxy"] for s in sessions]
    result = {
        "metric": "token-proxy",
        "session_count": len(sessions),
        "sessions": sessions,
        "aggregate": {
            "total_files_claimed": sum(s["files_claimed"] for s in sessions),
            "avg_complexity": round(sum(complexities) / len(complexities), 1),
            "max_complexity": max(complexities),
        },
    }
    print(json.dumps(result, indent=2))


def _index_matrix(data):
    """Build {(target, criterion): status} from matrix JSON, skipping N/A."""
    return {
        (c.get("target", ""), c.get("criterion", "")): c.get("status", "unchecked")
        for c in data.get("matrix", [])
        if c.get("status") != "not_applicable"
    }


def cmd_finding_delta(args):
    """Compare two matrix runs and output new/disappeared/stable counts."""
    before_cells = _index_matrix(load_json(args.before))
    after_cells = _index_matrix(load_json(args.after))
    all_keys = set(before_cells) | set(after_cells)
    total = len(all_keys)

    new_findings = disappeared = stable_fail = stable_pass = other = 0
    for key in all_keys:
        b, a = before_cells.get(key, "absent"), after_cells.get(key, "absent")
        if a == "fail" and b in ("unchecked", "pass", "absent"):
            new_findings += 1
        elif b == "fail" and a in ("pass", "absent"):
            disappeared += 1
        elif b == "fail" and a == "fail":
            stable_fail += 1
        elif b == "pass" and a == "pass":
            stable_pass += 1
        else:
            other += 1

    print(json.dumps({
        "metric": "finding-delta",
        "total_cells": total,
        "new_findings": new_findings,
        "disappeared_findings": disappeared,
        "stable_fail": stable_fail,
        "stable_pass": stable_pass,
        "other_transitions": other,
        "rerun_finding_rate_pct": round(new_findings / total * 100, 2) if total else 0.0,
    }, indent=2))


def _parse_scout_findings(text):
    """Extract FAIL file paths from scout findings (markdown + JSON verdicts)."""
    fails = set()
    for block in re.split(r"(?=^- TYPE:)", text, flags=re.MULTILINE):
        if "FAIL" in block:
            m = re.search(r"^- FILE:\s*(\S+?)(?::\d+)?$", block, re.MULTILINE)
            if m:
                fails.add(m.group(1))
    jm = re.search(r"```json\s*(\{.*?\})\s*```", text, re.DOTALL)
    if jm:
        try:
            for v in json.loads(jm.group(1)).get("verdicts", []):
                if v.get("verdict") == "FAIL":
                    fails.add(v.get("file", ""))
        except (json.JSONDecodeError, AttributeError):
            pass
    fails.discard("")
    return fails


def cmd_coverage_gap(args):
    """Cross-reference matrix verdicts against scout findings."""
    matrix_data = load_json(args.matrix)
    fp = Path(args.scout_findings)
    if not fp.is_file():
        error(f"Scout findings file not found: {fp}")
    try:
        scout_fails = _parse_scout_findings(fp.read_text(encoding="utf-8"))
    except OSError as e:
        error(f"Cannot read scout findings: {e}")

    matrix_fails = {
        c.get("target", "") for c in matrix_data.get("matrix", [])
        if c.get("status") == "fail"
    }
    overlap = scout_fails & matrix_fails
    scout_only = scout_fails - matrix_fails
    matrix_only = matrix_fails - scout_fails
    total_unique = len(scout_fails | matrix_fails)

    print(json.dumps({
        "metric": "coverage-gap",
        "scout_fail_count": len(scout_fails),
        "matrix_fail_count": len(matrix_fails),
        "overlap": len(overlap),
        "scout_only": sorted(scout_only),
        "matrix_only": sorted(matrix_only),
        "finding_missed_rate_pct": (
            round(len(matrix_only) / total_unique * 100, 2) if total_unique else 0.0
        ),
    }, indent=2))


def main():
    p = argparse.ArgumentParser(description="APEX audit improvement baseline metrics.")
    sub = p.add_subparsers(dest="command")
    tp = sub.add_parser("token-proxy", help="Estimate session complexity from manifests")
    tp.add_argument("--session-dir", required=True, metavar="DIR", help="Session manifest dir")
    fd = sub.add_parser("finding-delta", help="Compare two matrix runs for finding drift")
    fd.add_argument("--before", required=True, metavar="JSON", help="Earlier matrix JSON")
    fd.add_argument("--after", required=True, metavar="JSON", help="Later matrix JSON")
    cg = sub.add_parser("coverage-gap", help="Cross-reference matrix vs scout findings")
    cg.add_argument("--matrix", required=True, metavar="JSON", help="Audit matrix JSON")
    cg.add_argument("--scout-findings", required=True, metavar="MD", help="Scout findings .md")
    args = p.parse_args()
    if not args.command:
        p.print_help()
        sys.exit(1)
    {"token-proxy": cmd_token_proxy, "finding-delta": cmd_finding_delta,
     "coverage-gap": cmd_coverage_gap}[args.command](args)


if __name__ == "__main__":
    main()
