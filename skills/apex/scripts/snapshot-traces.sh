#!/usr/bin/env bash
# Snapshot trace files (or admin-apex run artifacts) to /tmp/{token}-{suffix}-snapshot.txt
# capped at 50KB. Defends against the cleanup race (p2.6 / cleanup-run.sh) by
# letting the reflector process a frozen snapshot, not live files.
#
# Spec: agents/reflector.md "First action: snapshot defends against cleanup race".
#
# Args:
#   --token <8hex>      (required) session token (apex) or run token (admin-apex / lessons-analyze / lessons-extract)
#   --phase <name>      (required) entryflow | entryflow+p1 | p2 | admin-apex | lessons-analyze | lessons-extract
#
# Output: /tmp/{token}-{suffix}-snapshot.txt (suffix: entryflow | p1 | p2 | admin-apex | lessons-analyze | lessons-extract)
#
# Phase -> sources mapping:
#   entryflow         -> {token}-traces/entryflow/*.md
#   entryflow+p1      -> {token}-traces/entryflow/*.md + {token}-traces/p1/*.md
#   p2                -> {token}-traces/p2/*.md
#   admin-apex        -> {token}-summary.md + {token}-*.json + {token}-*.txt under
#                        .claude-tmp/admin-apex-active/
#   lessons-analyze   -> {token}-summary.md + {token}-*.json + {token}-*.txt under
#                        .claude-tmp/lessons-analyze-active/
#   lessons-extract   -> {token}-summary.md under .claude-tmp/lessons-extract-active/
#                        (linear pipeline; no JSON artifacts beyond the manifest)
#
# Exit: 0 on success (snapshot file always written; "[no source files ...]"
# placeholder when nothing matched). 1 on bad args.

set -uo pipefail

# CWD anchor: $CLAUDE_PROJECT_DIR (set by Claude Code) is the orchestrator's
# project root - apex hot path -> <project>/.claude-tmp/, admin-apex -> ~/.claude/.
# Subagent CWD inheritance is unreliable; the env var is the canonical anchor.
# Mirrors inventory-apex.sh / _bump-version.sh / grep-apex-refs.sh / test-apex-scripts.sh.
# Past incident (0109cadd, 2026-05-02): hardcoded REPO_ROOT=~/.claude silently
# broke apex hot path when /apex ran outside ~/.claude.
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

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
LESSONS_ANALYZE_DIR=".claude-tmp/lessons-analyze-active"
LESSONS_EXTRACT_DIR=".claude-tmp/lessons-extract-active"

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
  lessons-analyze)
    SUFFIX=lessons-analyze
    SOURCES=("$LESSONS_ANALYZE_DIR/$TOKEN-summary.md" "$LESSONS_ANALYZE_DIR/$TOKEN-"*.json "$LESSONS_ANALYZE_DIR/$TOKEN-"*.txt)
    ;;
  lessons-extract)
    SUFFIX=lessons-extract
    SOURCES=("$LESSONS_EXTRACT_DIR/$TOKEN-summary.md")
    ;;
  *) echo "snapshot-traces.sh: bad --phase: $PHASE (entryflow|entryflow+p1|p2|admin-apex|lessons-analyze|lessons-extract)" >&2; exit 1 ;;
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
