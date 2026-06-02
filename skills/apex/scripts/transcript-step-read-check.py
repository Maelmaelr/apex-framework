#!/usr/bin/env python3
"""Transcript-replay read-before-work canary for apex lazy-loaded step contracts.

Spec: apex-context-rot-optimization plan, Workstream B item 5 (per-workstream DoD
+ canary). Workstream B item 3 (the stateful step-read hook) enforces this same
invariant LIVE during a run; THIS script is the deterministic POST-RUN lint that
asserts it held, parsed from a captured session transcript (the JSONL under
~/.claude/projects/<cwd>/<session>.jsonl).

Invariant (the rot this guards): for every step that became active, the step's
contract sub-file must be Read AFTER the step became active and BEFORE the step's
first work tool (Edit/Write/Task/Bash/...). A step that did its work off stale
memory - the documented drift ("orchestrator drifted past polish", "drifted past
this gate") - surfaces here as a step whose first work tool has no preceding
contract Read inside the step's window.

Model (post-B apex shape - the flow item 5 exists to gate):
  - boundary = a TaskUpdate tool_use marking a step active (status == in_progress;
               step id read from taskId, or metadata.step when keyed that way).
  - contract = a Read whose path matches the gate's regex (steps/NN-*.md post-B).
  - work     = the first Edit/Write/MultiEdit/Task/Agent/Bash after the boundary.
Only ORCHESTRATOR (main-session) tool calls count: subagents do not run steps and
are never gated (mirrors scope-check / item-3's orchestrator-only split - sidechain
lines and non-direct callers are skipped).

Honest scope (do not overclaim): the boundary is an orchestrator-asserted signal
(metadata.step / taskId), not harness ground-truth - exactly item-3's R3-b residual.
This lint makes "did you read the contract before working" deterministic; it cannot
prove "you were on the right step". Today's apex-improve / apex-lessons flows do not
yet emit the clean per-step TaskUpdate boundary (B unbuilt), so against a current
transcript most gates read NOT-RUN - that is the expected pre-B state, not a bug.

Gates file (--gates, JSON):
  {
    "boundary_tool": "TaskUpdate",          # optional, default TaskUpdate
    "boundary_status_key": "status",        # optional, default status
    "boundary_status_value": "in_progress", # optional; null disables the filter
    "boundary_id_key": "taskId",            # optional; e.g. "metadata.step" post-B
    "read_tool": "Read",                    # optional, default Read
    "read_path_key": "file_path",           # optional, default file_path
    "work_tools": ["Edit","Write","MultiEdit","Task","Agent","Bash"],  # optional
    "gates": [ {"id": "8", "contract": "steps/08-.*\\.md$"}, ... ]      # required
  }

CLI: transcript-step-read-check.py --transcript <jsonl> --gates <gates.json> [--json]
Exit 0 = no violation; 1 = >=1 gate violated; 2 = usage / parse error.
"""

import argparse
import json
import re
import sys

WORK_TOOLS_DEFAULT = ["Edit", "Write", "MultiEdit", "Task", "Agent", "Bash"]


def dotted_get(obj, path):
    """Resolve a dotted key path (e.g. 'metadata.step') against nested dicts."""
    cur = obj
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def load_events(transcript_path):
    """Ordered orchestrator (main-session) tool_use events from a session JSONL.

    Each event: {"idx": int, "name": str, "input": dict}. Sidechain (subagent)
    lines and non-direct callers are skipped - steps are an orchestrator concern.
    """
    events = []
    with open(transcript_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") != "assistant" or rec.get("isSidechain"):
                continue
            msg = rec.get("message") or {}
            for block in msg.get("content") or []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                caller = block.get("caller")
                if isinstance(caller, dict) and caller.get("type") not in (None, "direct"):
                    continue
                events.append({"idx": len(events), "name": block.get("name", ""),
                               "input": block.get("input") or {}})
    return events


def find_boundaries(events, spec):
    """Indexes of every step-activation boundary, in order."""
    btool = spec.get("boundary_tool", "TaskUpdate")
    skey = spec.get("boundary_status_key", "status")
    sval = spec.get("boundary_status_value", "in_progress")
    out = []
    for e in events:
        if e["name"] != btool:
            continue
        if sval is not None and str(dotted_get(e["input"], skey)) != str(sval):
            continue
        out.append(e["idx"])
    return out


def evaluate_gate(events, boundaries, spec, gate):
    """Classify one gate: PASS | FAIL | NOT-RUN against the read-before-work rule."""
    id_key = spec.get("boundary_id_key", "taskId")
    read_tool = spec.get("read_tool", "Read")
    read_key = spec.get("read_path_key", "file_path")
    work_tools = set(spec.get("work_tools", WORK_TOOLS_DEFAULT))
    contract = re.compile(gate["contract"])
    gid = str(gate["id"])

    start = None
    for b in boundaries:
        if str(dotted_get(events[b]["input"], id_key)) == gid:
            start = b
            break
    if start is None:
        return {"id": gid, "status": "NOT-RUN", "detail": "no in_progress boundary"}

    later = [b for b in boundaries if b > start]
    end = later[0] if later else (events[-1]["idx"] + 1 if events else start + 1)
    window = [e for e in events if start <= e["idx"] < end]

    first_work = next((e["idx"] for e in window if e["name"] in work_tools), None)
    read_ok = any(
        e["name"] == read_tool
        and contract.search(str(dotted_get(e["input"], read_key) or ""))
        and (first_work is None or e["idx"] < first_work)
        for e in window
    )
    if first_work is None:
        return {"id": gid, "status": "PASS", "detail": "read" if read_ok else "no-work"}
    if read_ok:
        return {"id": gid, "status": "PASS", "detail": "read-before-work"}
    return {"id": gid, "status": "FAIL",
            "detail": "work tool at event %d with no preceding contract read" % first_work}


def main(argv=None):
    ap = argparse.ArgumentParser(description="read-before-work transcript canary")
    ap.add_argument("--transcript", required=True)
    ap.add_argument("--gates", required=True)
    ap.add_argument("--json", action="store_true", help="emit a JSON result block")
    args = ap.parse_args(argv)

    try:
        with open(args.gates, encoding="utf-8") as fh:
            spec = json.load(fh)
    except (OSError, ValueError) as exc:
        print("gates load error: %s" % exc, file=sys.stderr)
        return 2
    gates = spec.get("gates") or []
    if not gates:
        print("no gates declared in spec", file=sys.stderr)
        return 2

    try:
        events = load_events(args.transcript)
    except OSError as exc:
        print("transcript load error: %s" % exc, file=sys.stderr)
        return 2

    boundaries = find_boundaries(events, spec)
    results = [evaluate_gate(events, boundaries, spec, g) for g in gates]
    fails = [r for r in results if r["status"] == "FAIL"]

    if args.json:
        print(json.dumps({"results": results, "violations": len(fails),
                          "events": len(events)}, indent=2))
    else:
        for r in results:
            print("%-8s step %s :: %s" % (r["status"], r["id"], r["detail"]))
        print("read-before-work: %d gate(s), %d violation(s), %d orchestrator events"
              % (len(results), len(fails), len(events)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
