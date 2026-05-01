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

# Defensive cc_session_id format check: Claude Code session ids are UUIDs
# (hex + hyphens). Rejecting anything else closes the printf injection edge
# below (we trust the bytes when writing JSON).
if ! [[ "$CC_SESSION_ID" =~ ^[0-9a-fA-F-]+$ ]]; then
  echo "create-session.sh: --cc-session-id has unexpected shape: $CC_SESSION_ID" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "create-session.sh: openssl not found (required for session token generation)" >&2
  exit 1
fi

mkdir -p "$APEX_ACTIVE"

active_tokens=()
stale_tokens=()

# Single python pass extracts {session, pid} pairs from all 8-hex.json manifests
# (skips parse-failed and session-less records silently, matching prior behavior).
# Bash classifies each pair as active|stale via PID-alive + comm-match.
while IFS=$'\t' read -r session_tok pid; do
  [[ -z "$session_tok" ]] && continue
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    stale_tokens+=("$session_tok")
    continue
  fi
  # PID-rollover guard: alive PID is necessary but not sufficient; require
  # ps comm to match "claude" so a recycled PID (some other process) is stale.
  if kill -0 "$pid" 2>/dev/null; then
    # On macOS BSD ps, comm can be a full path; basename normalises both forms.
    comm_base="$(basename "$(ps -o comm= -p "$pid" 2>/dev/null || true)" 2>/dev/null || true)"
    if [[ "$comm_base" == "claude" ]]; then
      active_tokens+=("$session_tok")
    else
      stale_tokens+=("$session_tok")
    fi
  else
    stale_tokens+=("$session_tok")
  fi
done < <(python3 - "$APEX_ACTIVE" <<'PY'
import json, os, re, sys
active = sys.argv[1]
pat = re.compile(r"^[0-9a-f]{8}\.json$")
if not os.path.isdir(active):
    sys.exit(0)
for name in sorted(os.listdir(active)):
    if not pat.match(name):
        continue
    try:
        with open(os.path.join(active, name), encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        continue
    sess = d.get("session", "")
    if sess:
        print(f"{sess}\t{d.get('pid', '')}")
PY
)

if [[ ${#active_tokens[@]} -gt 0 || ${#stale_tokens[@]} -gt 0 ]]; then
  {
    echo "overlap_detected"
    [[ ${#active_tokens[@]} -gt 0 ]] && echo "active: ${active_tokens[*]}"
    [[ ${#stale_tokens[@]} -gt 0 ]] && echo "stale: ${stale_tokens[*]}"
  } >&2
  exit 10
fi

# No overlap: issue token, write manifest via printf (3-field record with shape-validated
# inputs), validate via the shared producer-validate helper, echo token to stdout.
SESSION="$(openssl rand -hex 4)"
MANIFEST="$APEX_ACTIVE/$SESSION.json"

printf '{"session":"%s","pid":%d,"cc_session_id":"%s"}\n' "$SESSION" "$PPID" "$CC_SESSION_ID" > "$MANIFEST"

# Producer-validates-before-write: shells the manifest through validate-json.sh
# (jsonschema-fallback is parse-only when the lib is missing, but the call
# point uniformly enforces the rule across script + inline-LLM producers).
# validate-json.sh ships in this script's dir; missing = corrupt install -> hard fail.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -x "$SCRIPT_DIR/validate-json.sh" ]]; then
  rm -f "$MANIFEST"
  echo "create-session.sh: validate-json.sh missing or non-executable at $SCRIPT_DIR (install corruption); aborting" >&2
  exit 1
fi
if ! "$SCRIPT_DIR/validate-json.sh" manifest.schema.json "$MANIFEST"; then
  rm -f "$MANIFEST"
  echo "create-session.sh: manifest failed schema validation; aborting" >&2
  exit 1
fi

echo "$SESSION"
exit 0
