#!/usr/bin/env bash
# Probes admin-apex Python deps. Exit 1 + install instructions if missing.
# Spec: admin-apex SKILL.md task 1 invokes this after mode-select.
#
# Strict mode: admin-apex owns mutation and MUST validate before write. No
# parse-only fallback (unlike apex hot path, which degrades gracefully so
# end-user environments without jsonschema are not blocked from /apex runs).
#
# Exit codes:
#   0 - all deps present
#   1 - jsonschema missing; stderr carries the install one-liner

set -euo pipefail

if python3 -c "import jsonschema" 2>/dev/null; then
  exit 0
fi

cat >&2 <<'MSG'
check-deps.sh: jsonschema Python module not installed.

  Install:  pip3 install --user --break-system-packages jsonschema

Why: admin-apex requires strict schema validation before write (no parse-only
fallback). Re-run /admin-apex after install. Apex hot path keeps the lenient
fallback so end-user /apex runs are not blocked.
MSG
exit 1
