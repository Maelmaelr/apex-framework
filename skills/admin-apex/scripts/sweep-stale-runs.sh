#!/usr/bin/env bash
# Best-effort stale-manifest sweep for admin-apex / apex-improve runs.
# Spec: skills/admin-apex/SKILL.md task 1 (run pre-manifest-write at entry).
#
# Iterates .claude-tmp/admin-apex-active/*.json manifests. For each manifest
# with a numeric "pid" field, classifies stale = PID dead OR
# `ps -o comm= -p <pid>` basename != "claude" (PID-rollover guard).
# On stale: invokes scripts/cleanup-run.sh on the matching {run}.
#
# Manifests without a "pid" field (legacy shape pre-PID-capture) are SKIPPED -
# graceful degradation; we cannot safely classify them, and an active sibling
# session may still own them.
#
# This is the ONLY admin-apex codepath that mass-cleans manifests across
# sibling Claude Code sessions; cc_session_id alone is insufficient because
# concurrent claude processes can hold valid jsonl files indefinitely.
#
# Mirrors apex/scripts/create-session.sh:74-92 PID classification.
#
# Idempotent. Always exit 0; warnings to stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Anchored at framework root regardless of caller cwd.
# APEX_ADMIN_ACTIVE_DIR override is reserved for test fixtures.
ADMIN_ACTIVE="${APEX_ADMIN_ACTIVE_DIR:-$HOME/.claude/.claude-tmp/admin-apex-active}"

[[ -d "$ADMIN_ACTIVE" ]] || exit 0

shopt -s nullglob
manifests=( "$ADMIN_ACTIVE"/*.json )
shopt -u nullglob
(( ${#manifests[@]} == 0 )) && exit 0

# Single python pass extracts {run, pid} pairs from manifests whose name is
# {run}.json (8-hex). Sibling artifacts ({run}-*.json) are skipped by the
# regex - cleanup-run.sh sweeps those via prefix glob.
#
# Pipe, NOT `done < <(python3 ... <<PY)` process substitution: bash 3.2 (macOS
# /bin/bash 3.2.57) mis-scans a heredoc body nested in `<(...)` at RUNTIME and
# aborts "bad substitution" (content-dependent on the body's paren balance;
# `bash -n` parses it cleanly, so the failure is invisible to syntax checks -
# regression-covered by test-sweep.sh). The while body keeps no post-loop
# state, so the pipe subshell is harmless. Mirrors sweep-orphan-artifacts.sh.
python3 - "$ADMIN_ACTIVE" <<'PY' |
import json, os, re, sys
active = sys.argv[1]
pat = re.compile(r"^([0-9a-f]{8})\.json$")
if not os.path.isdir(active):
    sys.exit(0)
for name in sorted(os.listdir(active)):
    m = pat.match(name)
    if not m:
        continue
    try:
        with open(os.path.join(active, name), encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        continue
    run = d.get("run", m.group(1))
    pid = d.get("pid", "")
    print(f"{run}\t{pid}")
PY
while IFS=$'\t' read -r run pid; do
  [[ -z "$run" ]] && continue
  # No pid recorded -> legacy shape; cannot classify safely. Skip.
  [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue

  stale=0
  if kill -0 "$pid" 2>/dev/null; then
    # PID alive -> require ps comm to match "claude" (PID-rollover guard).
    comm_base="$(basename "$(ps -o comm= -p "$pid" 2>/dev/null || true)" 2>/dev/null || true)"
    [[ "$comm_base" == "claude" ]] || stale=1
  else
    # PID dead -> stale.
    stale=1
  fi

  if (( stale )); then
    if [[ -x "$SCRIPT_DIR/cleanup-run.sh" ]]; then
      "$SCRIPT_DIR/cleanup-run.sh" --run "$run" 2>/dev/null || true
    fi
  fi
done

# Orphan-artifact sweep (manifest-stale handled above; this catches {run}-*
# siblings whose {run}.json is GONE - crash-orphaned inventory / drift-report /
# trace scratch a cleanup-run.sh abort left behind. {run}-deferred-findings.json
# is EXEMPT (session-spanning backlog, kept across idle gaps - see the helper's
# header). Lives in skills/apex/scripts/ because the sweep semantics are identical
# for apex-active and admin-apex-active; both call sites consume the same helper.
# Best-effort; never blocks.
APEX_SWEEP="$HOME/.claude/skills/apex/scripts/sweep-orphan-artifacts.sh"
if [[ -x "$APEX_SWEEP" ]]; then
  bash "$APEX_SWEEP" --dir "$ADMIN_ACTIVE" --age-hours 24 2>/dev/null || true
fi

exit 0
