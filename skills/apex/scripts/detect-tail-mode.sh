#!/usr/bin/env bash
# p1.3 / p2.4: detect tail mode (economy vs full).
# Spec: apex-core.md p1.3 / p2.4.
#
# Reads head_sha from .claude-tmp/apex-active/{session}-baseline.json (consumer-
# validated against baseline.schema.json; treated as missing on validate fail).
# Computes (across the apex-driven change set, BOTH tracked and untracked):
#   FILE_COUNT = (git diff --name-only {head_sha}; git ls-files --others --exclude-standard) | sort -u | wc -l
#   LINE_DELTA = additions+deletions from git diff --shortstat {head_sha}
#                + sum of `wc -l` across untracked files
#
# Untracked are counted explicitly because git diff excludes them - a new file
# apex created via the Write tool would otherwise contribute zero lines and
# under-trigger `full` mode for changes that legitimately need learn + docs.
#
# Output (stdout, exactly one token):
#   "economy"  if FILE_COUNT <= 3 AND LINE_DELTA <= 50
#   "full"     otherwise
#
# Args:
#   --session <token>  required, 8-char lowercase hex
#
# Exit codes:
#   0  mode emitted on stdout
#   1  baseline missing / invalid (orchestrator surfaces; tail step skipped or aborted)
#   2  invocation error (bad args, malformed session token)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX_ACTIVE=".claude-tmp/apex-active"
SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    *)
      echo "detect-tail-mode.sh: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SESSION" ]]; then
  echo "detect-tail-mode.sh: --session is required" >&2
  exit 2
fi

if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "detect-tail-mode.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2
  exit 2
fi

BASELINE="$APEX_ACTIVE/${SESSION}-baseline.json"

# Consumer-validate baseline against schema; treat invalid / missing as fatal
# for this step. The orchestrator decides surface vs skip.
HEAD_SHA=$(PYTHONPATH="$SCRIPT_DIR" python3 - "$BASELINE" <<'PY'
import sys
try:
    from _validate import consumer_load
except Exception as e:
    print(f"detect-tail-mode.sh: _validate import failed: {e}", file=sys.stderr)
    sys.exit(1)
data = consumer_load(sys.argv[1], "baseline")
if data is None:
    sys.exit(1)
print(data["head_sha"])
PY
)
rc=$?
if (( rc != 0 )) || [[ -z "$HEAD_SHA" ]]; then
  echo "detect-tail-mode.sh: baseline missing or invalid: $BASELINE" >&2
  exit 1
fi

# --- FILE_COUNT: tracked-modified UNION untracked-non-ignored, deduped ---
TRACKED=$(git diff --name-only "$HEAD_SHA" 2>/dev/null || true)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)
FILE_LIST=$(printf '%s\n%s\n' "$TRACKED" "$UNTRACKED" | grep -v '^$' | sort -u)
if [[ -z "$FILE_LIST" ]]; then
  FILE_COUNT=0
else
  FILE_COUNT=$(printf '%s\n' "$FILE_LIST" | wc -l | tr -d '[:space:]')
fi

# --- LINE_DELTA: tracked diff (insertions+deletions) + untracked wc -l sum ---
# `git diff --shortstat <ref>` emits e.g. " 3 files changed, 42 insertions(+), 7 deletions(-)"
# or empty when there is no diff at all. Parse insertions/deletions independently
# (either may be absent on insert-only / delete-only changes).
SHORTSTAT=$(git diff --shortstat "$HEAD_SHA" 2>/dev/null || true)
INSERTIONS=0
DELETIONS=0
if [[ -n "$SHORTSTAT" ]]; then
  if [[ "$SHORTSTAT" =~ ([0-9]+)[[:space:]]+insertion ]]; then
    INSERTIONS="${BASH_REMATCH[1]}"
  fi
  if [[ "$SHORTSTAT" =~ ([0-9]+)[[:space:]]+deletion ]]; then
    DELETIONS="${BASH_REMATCH[1]}"
  fi
fi

UNTRACKED_LINES=0
if [[ -n "$UNTRACKED" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || continue
    n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]' || echo 0)
    UNTRACKED_LINES=$(( UNTRACKED_LINES + ${n:-0} ))
  done <<< "$UNTRACKED"
fi

LINE_DELTA=$(( INSERTIONS + DELETIONS + UNTRACKED_LINES ))

echo "detect-tail-mode.sh: FILE_COUNT=$FILE_COUNT LINE_DELTA=$LINE_DELTA (head=$HEAD_SHA)" >&2

if (( FILE_COUNT <= 3 )) && (( LINE_DELTA <= 50 )); then
  echo "economy"
else
  echo "full"
fi
exit 0
