#!/usr/bin/env bash
# Step 2: create session manifest with concurrency check.
# Spec: apex-core.md step 2 + Conventions / Session manifest schema.
#
# Behavior:
#   1. Scan .claude-tmp/apex-active/*.json (manifest filename pattern: 8-hex.json).
#      Active = manifest exists AND PID alive AND ps comm matches "claude".
#      Stale  = manifest exists but PID dead OR comm mismatch (PID-rollover guard).
#   2. On overlap (any active OR stale found): exit 10 with stderr listing detected
#      state. Orchestrator runs AskUserQuestion (abort | proceed-alongside |
#      cleanup-stale-and-proceed) per spec, options filtered to detected state.
#   3. On no overlap: generate {session} via openssl rand -hex 4, write manifest:
#        {session, pid: $PPID, cc_session_id}
#      pid is $PPID (Claude Code main process), NOT $$ (this script's pid).
#   4. Echo {session} to stdout for orchestrator capture.
#
# Args:
#   --cc-session-id <id>  (required) - Claude Code session id passed by orchestrator.
#
# Exit codes:
#   0  - manifest written, {session} on stdout
#   10 - overlap detected (orchestrator decides)
#   1  - unrecoverable error (bad args, openssl missing, etc.)
#
# Stderr on exit 10 (one line per token; orchestrator parses):
#   overlap_detected
#   active: <tok1> [<tok2> ...]   (omitted when no active)
#   stale:  <tok1> [<tok2> ...]   (omitted when no stale)

set -euo pipefail

APEX_ACTIVE=".claude-tmp/apex-active"

CC_SESSION_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cc-session-id)
      CC_SESSION_ID="${2:-}"
      shift 2
      ;;
    *)
      echo "create-session.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CC_SESSION_ID" ]]; then
  echo "create-session.sh: --cc-session-id is required" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "create-session.sh: openssl not found (required for session token generation)" >&2
  exit 1
fi

mkdir -p "$APEX_ACTIVE"

active_tokens=()
stale_tokens=()

shopt -s nullglob
for manifest in "$APEX_ACTIVE"/*.json; do
  base="$(basename "$manifest")"
  # Only treat 8-hex.json as a session manifest; excludes -hypothesis.json,
  # -baseline.json, -*-scope.json, -fix-attempts-*.json, -verify-rerun.json, etc.
  [[ "$base" =~ ^[0-9a-f]{8}\.json$ ]] || continue

  parsed=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    print(f\"{d.get('session','')}\t{d.get('pid','')}\")
except Exception:
    pass
" "$manifest" 2>/dev/null || true)

  session_tok="${parsed%%$'\t'*}"
  pid="${parsed#*$'\t'}"

  # Malformed manifest (missing session or pid, or non-numeric pid) -> stale.
  if [[ -z "$session_tok" || -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    [[ -n "$session_tok" ]] && stale_tokens+=("$session_tok")
    continue
  fi

  # PID-rollover guard: alive PID is necessary but not sufficient; require
  # ps comm to match "claude" so a recycled PID (some other process) is stale.
  if kill -0 "$pid" 2>/dev/null; then
    comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    # On macOS BSD ps, comm can be a full path; basename normalises both forms.
    comm_base="$(basename "${comm:-}" 2>/dev/null || true)"
    if [[ "$comm_base" == "claude" ]]; then
      active_tokens+=("$session_tok")
    else
      stale_tokens+=("$session_tok")
    fi
  else
    stale_tokens+=("$session_tok")
  fi
done
shopt -u nullglob

if [[ ${#active_tokens[@]} -gt 0 || ${#stale_tokens[@]} -gt 0 ]]; then
  {
    echo "overlap_detected"
    [[ ${#active_tokens[@]} -gt 0 ]] && echo "active: ${active_tokens[*]}"
    [[ ${#stale_tokens[@]} -gt 0 ]] && echo "stale: ${stale_tokens[*]}"
  } >&2
  exit 10
fi

# No overlap: issue token, write manifest, echo token to stdout.
SESSION="$(openssl rand -hex 4)"
MANIFEST="$APEX_ACTIVE/$SESSION.json"

python3 - "$MANIFEST" "$SESSION" "$PPID" "$CC_SESSION_ID" <<'PY'
import json, sys
manifest, session, pid, cc_id = sys.argv[1:5]
data = {"session": session, "pid": int(pid), "cc_session_id": cc_id}
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(data, f)
PY

echo "$SESSION"
exit 0
