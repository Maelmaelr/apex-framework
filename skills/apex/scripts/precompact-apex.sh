#!/usr/bin/env bash
# precompact-apex.sh -- PreCompact/PostCompact/StopFailure hook for APEX context preservation.
# Usage: Invoked as hook (reads JSON from stdin). Not called directly.
# Reads active session manifests and echoes structured state
# so it survives compaction as part of the summarized context.

set -euo pipefail

MANIFEST_DIR=".claude-tmp/apex-active"

# Fail silently if no manifest directory or python3 unavailable
[ -d "$MANIFEST_DIR" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Capture stdin before heredoc takes it over
HOOK_INPUT=$(cat 2>/dev/null || true)

# Single python3 invocation: parse hook name + iterate all manifests
python3 - "$MANIFEST_DIR" "$HOOK_INPUT" <<'PYEOF'
import json, sys, os, glob

hook = "PreCompact"
try:
    hook = json.loads(sys.argv[2]).get("hook_event_name", "") or hook
except Exception:
    pass

manifests = sorted(glob.glob(os.path.join(sys.argv[1], "*.json")))
if not manifests:
    sys.exit(0)

print(f"=== APEX SESSION STATE ({hook}) ===")
for fpath in manifests:
    try:
        with open(fpath, encoding="utf-8") as mf:
            d = json.load(mf)
        sid = os.path.splitext(os.path.basename(fpath))[0]
        print(f"Session: {sid}")
        for k in ("task", "started", "path", "current_step", "tail_mode"):
            print(f"  {k}: {d.get(k, '?')}")
        decisions = d.get("decisions", "")
        if decisions:
            print(f"  decisions: {decisions}")
        files = d.get("files", [])
        if files:
            print(f"  files: {', '.join(str(x) for x in files)}")
        sf = d.get("scout_findings", "")
        if sf:
            print(f"  scout_findings: {sf}")
    except Exception:
        pass
print(f"=== END APEX STATE ({hook}) ===")
PYEOF
