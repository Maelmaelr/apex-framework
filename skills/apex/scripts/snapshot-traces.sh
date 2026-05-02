#!/usr/bin/env bash
# Snapshot trace files (or admin-apex run artifacts) to /tmp/{token}-{suffix}-snapshot.txt
# capped at 50KB. Defends against the cleanup race (p2.6 / cleanup-run.sh) by
# letting the reflector process a frozen snapshot, not live files.
#
# Spec: agents/reflector.md "First action: snapshot defends against cleanup race".
#
# Args:
#   --token <8hex>      (required) session token (apex) or run token (admin-apex)
#   --phase <name>      (required) entryflow | entryflow+p1 | p2 | admin-apex
#
# Output: /tmp/{token}-{suffix}-snapshot.txt (suffix: entryflow | p1 | p2 | admin-apex)
#
# Phase -> sources mapping:
#   entryflow      -> {token}-traces/entryflow/*.md
#   entryflow+p1   -> {token}-traces/entryflow/*.md + {token}-traces/p1/*.md
#   p2             -> {token}-traces/p2/*.md
#   admin-apex     -> {token}-summary.md + {token}-*.json + {token}-*.txt under
#                     .claude-tmp/admin-apex-active/
#
# Exit: 0 on success (snapshot file always written; "[no source files ...]"
# placeholder when nothing matched). 1 on bad args.

set -uo pipefail

# CWD anchor: derive repo root from script location (skills/apex/scripts/ -> ../../..).
# Without this, agents/reflector.md spawned subagents inherit a CWD other than
# ~/.claude and the relative ADMIN_DIR / APEX_TRACES paths below resolve to
# nonexistent directories - falling through to the empty-EXISTING placeholder
# and producing a false-negative "[no source files for {phase} / {token}]"
# (root cause of the 0109cadd "admin-apex run artifacts not yet available"
# incident).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

TOKEN=""
PHASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2 ;;
    --phase) PHASE="${2:-}"; shift 2 ;;
    *) echo "snapshot-traces.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ "$TOKEN" =~ ^[0-9a-f]{8}$ ]] || { echo "snapshot-traces.sh: --token must be 8-char lowercase hex" >&2; exit 1; }

APEX_TRACES=".claude-tmp/apex-active/$TOKEN-traces"
ADMIN_DIR=".claude-tmp/admin-apex-active"

case "$PHASE" in
  entryflow)
    SUFFIX=entryflow
    SOURCES=("$APEX_TRACES/entryflow"/*.md)
    ;;
  entryflow+p1)
    SUFFIX=p1
    SOURCES=("$APEX_TRACES/entryflow"/*.md "$APEX_TRACES/p1"/*.md)
    ;;
  p2)
    SUFFIX=p2
    SOURCES=("$APEX_TRACES/p2"/*.md)
    ;;
  admin-apex)
    SUFFIX=admin-apex
    SOURCES=("$ADMIN_DIR/$TOKEN-summary.md" "$ADMIN_DIR/$TOKEN-"*.json "$ADMIN_DIR/$TOKEN-"*.txt)
    ;;
  *) echo "snapshot-traces.sh: bad --phase: $PHASE (entryflow|entryflow+p1|p2|admin-apex)" >&2; exit 1 ;;
esac

OUT="/tmp/$TOKEN-$SUFFIX-snapshot.txt"
CAP=51200

# Globs that miss return the literal pattern; filter to actual files.
EXISTING=()
for f in "${SOURCES[@]}"; do
  [[ -f "$f" ]] && EXISTING+=("$f")
done

if [[ ${#EXISTING[@]} -eq 0 ]]; then
  printf '[no source files for %s / %s]\n' "$PHASE" "$TOKEN" > "$OUT"
  exit 0
fi

TOTAL=$(cat "${EXISTING[@]}" | wc -c)
N=${#EXISTING[@]}
cat "${EXISTING[@]}" | head -c "$CAP" > "$OUT"
[[ "$TOTAL" -gt "$CAP" ]] && printf '[snapshot truncated, %s source files total]\n' "$N" >> "$OUT"

exit 0
