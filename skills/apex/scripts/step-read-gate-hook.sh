#!/usr/bin/env bash
# APEX step-read gate hook (Workstream B item 3 / B/R3 - the linchpin).
# Spec: apex-context-rot-optimization plan, "Item 3 design - B/R3 stateful
#       step-read gate". Post-run companion: skills/apex/scripts/transcript-step-
#       read-check.py (item 5 canary). Fixtures: skills/admin-apex/scripts/test-step-gate.sh.
#
# Enforces (LIVE, across separate tool calls): once the orchestrator marks step NN
# active, the step's contract file (skills/apex/steps/NN-*.md) must be Read before
# that step's first work tool (Edit/Write/MultiEdit/NotebookEdit/Task/Bash) runs.
# Turns the documented read-once drift ("orchestrator drifted past polish",
# "drifted past this gate") from a soft convention into a fail-closed gate - the
# same read-before-work invariant transcript-step-read-check.py asserts post-run.
#
# ONE script, wired at THREE touchpoints (settings.json), branches on tool_name:
#   1. PreToolUse:TaskUpdate - status==in_progress + tool_input.metadata.step set
#                              -> stamp active_step / active_since. Never gates.
#   2. PostToolUse:Read      - path matches skills/apex/steps/NN-*.md
#                              -> stamp read_steps[NN].
#   3. PreToolUse:Edit|Write|MultiEdit|NotebookEdit|Task|Bash - the GATE:
#                              deny iff active_step set and its contract is unread
#                              since the step became active.
#
# Orchestrator-only: acts solely on a direct scope-pointer hit (the apex main
# session). Subagents (pointer miss) are never gated - they do not run steps
# (mirrors scope-check-hook.sh's orchestrator/subagent split).
#
# State (per session, on disk): .claude-tmp/apex-active/{session}-step-progress.json
#   {"active_step": "NN", "active_since": <epoch>, "read_steps": {"NN": <epoch>}}
# Its EXISTENCE is the arming sentinel, created by create-session.sh at session
# mint (step 2). Present from mint -> the hook is ARMED for every apex session
# but NON-ENFORCING: until B extracts skills/apex/steps/NN-*.md and the
# orchestrator stamps active_step (TaskUpdate metadata.step), every branch
# fail-opens. Built ahead of B as its acceptance gate (same build-before-B
# pattern as the item-5 canary).
#
# Failure modes (deliberate): fail-OPEN on unset active_step / missing state / any
# parse error (never brick a session); fail-CLOSED only when active_step is set but
# its contract is unread. Read is never gated (it satisfies the gate).
#
# Hook protocol: always exit 0. PreToolUse deny via stdout JSON
# permissionDecision=deny; allow = no stdout. PostToolUse: no decision, exit 0.

set -uo pipefail

APEX_ACTIVE=".claude-tmp/apex-active"

# Fast-path 1: no apex session here -> nothing to gate (covers all non-/apex calls).
[[ -d "$APEX_ACTIVE" ]] || exit 0

# Fast-path 2: no step-progress sentinel here -> dormant. Keeps the hot path
# (Bash/Task/Edit) at two shell globs, no python, when no apex session has armed
# it (non-apex contexts, or before create-session.sh writes the sentinel).
shopt -s nullglob
_sp=("$APEX_ACTIVE"/*-step-progress.json)
shopt -u nullglob
[[ ${#_sp[@]} -gt 0 ]] || exit 0

INPUT=$(cat)

# Event arrives via env (APEX_STEP_EVENT); the heredoc is python's stdin (the
# program), so the two never collide. Any python crash -> fail-open (|| exit 0).
APEX_STEP_EVENT="$INPUT" APEX_ACTIVE="$APEX_ACTIVE" python3 <<'PY' 2>/dev/null || exit 0
import os, json, sys, re, glob, time

try:
    data = json.loads(os.environ.get("APEX_STEP_EVENT", "") or "{}")
except Exception:
    sys.exit(0)  # unparseable event -> fail-open

apex_active = os.environ.get("APEX_ACTIVE", ".claude-tmp/apex-active")
session_id = data.get("session_id", "") or ""
tool = data.get("tool_name", "") or ""
ti = data.get("tool_input") or {}

# Resolve apex {session} from cc session_id via the scope pointer (orchestrator
# only). Pointer miss -> subagent / non-apex -> never gate.
session = None
if session_id:
    for p in glob.glob(os.path.join(apex_active, "*-scopes", session_id + ".txt")):
        if os.path.isfile(p):
            d = os.path.basename(os.path.dirname(p))
            if d.endswith("-scopes"):
                session = d[: -len("-scopes")]
            break
if session is None:
    sys.exit(0)

state_path = os.path.join(apex_active, session + "-step-progress.json")
try:
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)
except Exception:
    sys.exit(0)  # sentinel gone / unreadable -> dormant
if not isinstance(state, dict):
    sys.exit(0)


def dotted_get(obj, path):
    cur = obj
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def norm_step(v):
    s = str(v)
    return str(int(s)) if s.isdigit() else s


def save(st):
    try:
        with open(state_path, "w", encoding="utf-8") as fh:
            json.dump(st, fh)
    except Exception:
        pass


STEP_RE = re.compile(r"(?:^|/)skills/apex/steps/0*(\d+)-[^/]*\.md$")
WORK = {"Edit", "Write", "MultiEdit", "NotebookEdit", "Task", "Bash"}

# Branch 1: step-start signal. Stamp active_step + active_since. Never gate.
if tool == "TaskUpdate":
    if str(ti.get("status", "")) == "in_progress":
        step = dotted_get(ti, "metadata.step")
        if step is not None:
            state["active_step"] = norm_step(step)
            state["active_since"] = time.time()
            state.setdefault("read_steps", {})
            save(state)
    sys.exit(0)

# Branch 2: contract read. Stamp read_steps[NN].
if tool == "Read":
    m = STEP_RE.search(str(ti.get("file_path", "") or ""))
    if m:
        state.setdefault("read_steps", {})[norm_step(m.group(1))] = time.time()
        save(state)
    sys.exit(0)

# Branch 3: work tools. Gate on read-before-work.
if tool in WORK:
    active = state.get("active_step")
    if active is None:
        sys.exit(0)  # fail-open: no step active yet
    active = norm_step(active)
    since = state.get("active_since")
    read_ts = (state.get("read_steps") or {}).get(active)
    if since is not None and (read_ts is None or read_ts < since):
        reason = ("B/R3: Read skills/apex/steps/%s-*.md before acting on step %s "
                  "(lazy-load contract; read-once drift guard)." % (active.zfill(2), active))
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason}}))
    sys.exit(0)

sys.exit(0)
PY
exit 0
