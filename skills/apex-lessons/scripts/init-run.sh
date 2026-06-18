#!/usr/bin/env bash
# Mint run token + write manifest for /apex-lessons (extract or analyze phase).
# Spec: skills/apex-lessons/extract.md "Step 0: Mint run" /
#       skills/apex-lessons/analyze.md "Task Setup" Step 0a.
#
# Project-scoped temp dirs at .claude-tmp/lessons-extract-active/ and
# .claude-tmp/lessons-analyze-active/ (NOT shared with admin-apex / apex-improve
# which live under ~/.claude/.claude-tmp/). Each phase keeps its own dir so the
# reflector can consume both phases as separate runs (separate signals in
# ~/.claude/tmp/apex-workflow-improvements.md).
#
# Manifest schema mirrors admin-apex run manifest so agents/reflector.md can
# consume all phases uniformly:
#   {"run":"<8-hex>","cc_session_id":"<uuid>","pid":<int>,"producer":"lessons-<phase>"}
#
# Echoes 8-hex run token to stdout. Caller captures and uses throughout.
#
# Args:
#   --phase extract|analyze   (required)
#
# Exit codes:
#   0  manifest written, RUN echoed
#   1  bad args / cc_session_id resolution failed (apex/scripts/get-cc-session-id.sh exit 1)

set -euo pipefail

PHASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="${2:-}"; shift 2 ;;
    *) echo "init-run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "$PHASE" in
  extract|analyze) ;;
  *) echo "init-run.sh: --phase must be 'extract' or 'analyze' (got: ${PHASE:-<empty>})" >&2; exit 1 ;;
esac

ROOT=".claude-tmp/lessons-${PHASE}-active"
mkdir -p "$ROOT"

RUN=$(openssl rand -hex 4)
CC_ID=$(bash "$HOME/.claude/skills/apex/scripts/get-cc-session-id.sh")
PID=$PPID

printf '{"run":"%s","cc_session_id":"%s","pid":%d,"producer":"lessons-%s"}\n' \
  "$RUN" "$CC_ID" "$PID" "$PHASE" > "$ROOT/$RUN.json"

# Touch summary file so per-step / per-task summary appends always succeed
# (summary trace is consumed by reflector at the phase's Reflect + Cleanup).
: > "$ROOT/$RUN-summary.md"

echo "$RUN"
