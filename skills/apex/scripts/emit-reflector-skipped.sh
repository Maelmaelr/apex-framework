#!/usr/bin/env bash
# Emit a SKIPPED-no-inputs sentinel line into ~/.claude/tmp/apex-workflow-improvements.md
# via append-with-lock.sh. Centralises timestamp resolution so the reflector agent
# (Haiku) cannot leak a literal `$(date ...)` subshell into the log.
#
# Spec: agents/reflector.md "Empty-input gate (SKIPPED-no-inputs sentinel)".
#
# Why a helper exists: the reflector emits the sentinel via a quoted heredoc
#   cat <<'EOF' | bash append-with-lock.sh ...
#   ## {token} - {phase} - SKIPPED-no-inputs - {timestamp}
#   EOF
# Quoted-EOF disables shell expansion, so any agent-side `$(date ...)` in the
# template is preserved verbatim. Multiple incidents (5616f4dd 2026-05-03, plus
# 2026-05-02 lost-block precedent) show Haiku skipping the timestamp substitution
# step and committing the literal subshell. This script bypasses agent
# composition entirely - bash resolves the timestamp before append-with-lock.sh
# sees the line.
#
# Args:
#   $1   token   8-char lowercase hex (apex {session} or admin-apex/lessons {run})
#   $2   phase   entryflow | entryflow+p1 | p2 | admin-apex | lessons-analyze | lessons-extract
#
# Exit codes:
#   0   sentinel appended (or append-with-lock.sh's no-op silent contract)
#   1   bad args (missing / wrong-shape token, missing / unknown phase)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOKEN="${1:-}"
PHASE="${2:-}"

if [[ -z "$TOKEN" || -z "$PHASE" ]]; then
  echo "emit-reflector-skipped.sh: usage: $0 <token> <phase>" >&2
  exit 1
fi

if [[ ! "$TOKEN" =~ ^[0-9a-f]{8}$ ]]; then
  echo "emit-reflector-skipped.sh: token must be 8-char lowercase hex: $TOKEN" >&2
  exit 1
fi

case "$PHASE" in
  entryflow|entryflow+p1|p2|admin-apex|lessons-analyze|lessons-extract) ;;
  *)
    echo "emit-reflector-skipped.sh: unknown phase: $PHASE" >&2
    exit 1
    ;;
esac

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf '## %s - %s - SKIPPED-no-inputs - %s\n' "$TOKEN" "$PHASE" "$ts" \
  | bash "$SCRIPT_DIR/append-with-lock.sh" \
       "$HOME/.claude/tmp/apex-workflow-improvements.md"
