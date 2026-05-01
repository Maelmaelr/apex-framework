#!/usr/bin/env bash
# Thin shell wrapper around _validate.py producer_validate.
# Spec: shared-guardrails.md "JSON Schema validation".
#
# Lets script and inline-LLM producers invoke the same validator after Write,
# closing the producer-validates-before-write enforcement gap.
#
# Args (positional):
#   $1  -- schema name (with or without .schema.json suffix); resolves under
#          skills/apex/schemas/ unless --admin is set.
#   $2  -- absolute path to the JSON file to validate.
#
# Flags:
#   --admin   -- resolve schema under skills/admin-apex/schemas/ instead.
#
# Exit codes:
#   0  -- valid (or jsonschema-fallback parse-only OK)
#   1  -- invalid: validation failed, missing file, or bad args
#
# When jsonschema is not importable, _validate.py falls back to JSON-parse-only
# and prints a one-line warning to stderr; exit code stays 0 if JSON parses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ADMIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin) ADMIN=1; shift ;;
    *) break ;;
  esac
done

if [[ $# -ne 2 ]]; then
  echo "validate-json.sh: usage: $0 [--admin] <schema-name> <json-path>" >&2
  exit 1
fi

SCHEMA="$1"
JSON_PATH="$2"

if [[ ! -f "$JSON_PATH" ]]; then
  echo "validate-json.sh: file not found: $JSON_PATH" >&2
  exit 1
fi

if [[ "$ADMIN" -eq 1 ]]; then
  # Resolve admin-apex schema dir once and export so _validate.py picks it up
  # at module load via APEX_SCHEMA_DIR (no runtime monkey-patch).
  export APEX_SCHEMA_DIR="$(cd "$SCRIPT_DIR/../../admin-apex/schemas" && pwd)"
fi

PYTHONPATH="$SCRIPT_DIR" python3 - "$SCHEMA" "$JSON_PATH" <<'PY'
import json, sys
schema_name, json_path = sys.argv[1], sys.argv[2]

from _validate import producer_validate, ValidationError

try:
    with open(json_path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    print(f"validate-json.sh: parse failed: {e}", file=sys.stderr)
    sys.exit(1)

try:
    producer_validate(data, schema_name)
except ValidationError as e:
    print(f"validate-json.sh: {e}", file=sys.stderr)
    sys.exit(1)
PY
