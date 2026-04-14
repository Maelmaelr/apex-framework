#!/usr/bin/env bash
# Usage: run-regression.sh [--help]
# Validates that enumerate-audit-matrix.py generates correct matrix cells
# from test fixtures with known security properties.
#
# Full scout accuracy regression requires launching scouts via Claude Code --
# this script validates matrix generation only. Manual scout testing procedure:
#   1. Run this script to generate the matrix
#   2. In Claude Code, run /apex-audit-matrix with --catalog pointing to
#      tests/catalog/test-criteria.md and --project-root pointing to tests/fixtures/
#   3. Compare scout verdicts in the output matrix against expected-verdicts.json
#   4. Each fixture has a known expected verdict -- mismatches indicate scout regression
#
# Exit codes: 0 = all checks pass, 1 = mismatch detected, 2 = setup error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$SCRIPT_DIR"
FIXTURES_DIR="$TESTS_DIR/fixtures"
CATALOG="$TESTS_DIR/catalog/test-criteria.md"
EXPECTED="$TESTS_DIR/expected/expected-verdicts.json"
SCRIPTS_DIR="$(dirname "$TESTS_DIR")/scripts"
ENUMERATE="$SCRIPTS_DIR/enumerate-audit-matrix.py"
OUTPUT_DIR="$(mktemp -d)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
    exit 0
fi

# Validate prerequisites
for f in "$CATALOG" "$EXPECTED" "$ENUMERATE"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Required file not found: $f" >&2
        exit 2
    fi
done

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo "ERROR: Fixtures directory not found: $FIXTURES_DIR" >&2
    exit 2
fi

echo "=== Regression Test: Matrix Generation ==="
echo "Catalog:  $CATALOG"
echo "Fixtures: $FIXTURES_DIR"
echo "Expected: $EXPECTED"
echo ""

# Step 1: Run enumerate-audit-matrix.py
echo "--- Step 1: Generate matrix ---"
MATRIX_OUTPUT=$(python3 "$ENUMERATE" \
    --catalog "$CATALOG" \
    --project-root "$FIXTURES_DIR" \
    --output-dir "$OUTPUT_DIR" \
    --no-persist 2>&1) || {
    echo "ERROR: enumerate-audit-matrix.py failed:" >&2
    echo "$MATRIX_OUTPUT" >&2
    rm -rf "$OUTPUT_DIR"
    exit 2
}
echo "$MATRIX_OUTPUT"

# Find the generated matrix JSON
MATRIX_JSON=$(find "$OUTPUT_DIR" -name "*.json" -type f | head -1)
if [[ -z "$MATRIX_JSON" || ! -f "$MATRIX_JSON" ]]; then
    echo "ERROR: No matrix JSON generated in $OUTPUT_DIR" >&2
    rm -rf "$OUTPUT_DIR"
    exit 2
fi

# Step 2: Report matrix cell count
echo ""
echo "--- Step 2: Matrix cell summary ---"
TOTAL_CELLS=$(python3 -c "
import json, sys
with open('$MATRIX_JSON') as f:
    data = json.load(f)
matrix = data.get('matrix', [])
statuses = {}
for cell in matrix:
    s = cell.get('status', 'unknown')
    statuses[s] = statuses.get(s, 0) + 1
print(f'Total cells: {len(matrix)}')
for s, c in sorted(statuses.items()):
    print(f'  {s}: {c}')
")
echo "$TOTAL_CELLS"

# Step 3: Validate applicable cells against expected verdicts
echo ""
echo "--- Step 3: Pre-filter validation ---"
RESULT=$(python3 -c "
import json, sys

with open('$MATRIX_JSON') as f:
    matrix_data = json.load(f)

with open('$EXPECTED') as f:
    expected = json.load(f)

matrix = matrix_data.get('matrix', [])

# Build lookup: (target, criterion) -> status
cell_map = {}
for cell in matrix:
    key = (cell['target'], cell['criterion'])
    cell_map[key] = cell.get('status', 'unknown')

passed = 0
failed = 0
errors = []

for exp in expected:
    fixture = exp['fixture']
    criterion = exp['criterion_id']
    expected_verdict = exp['expected_verdict']
    key = (fixture, criterion)

    actual_status = cell_map.get(key)

    if actual_status is None:
        errors.append(f'  MISSING  {fixture} x {criterion}: cell not in matrix')
        failed += 1
        continue

    # For matrix generation layer: we validate pre-filter applicability.
    # Expected pass/fail fixtures should be 'unchecked' (applicable).
    # If a fixture that should match is 'not_applicable', the pre-filter is wrong.
    if actual_status == 'not_applicable':
        errors.append(
            f'  FAIL     {fixture} x {criterion}: '
            f'pre-filter marked not_applicable (expected applicable for {expected_verdict} verdict)'
        )
        failed += 1
    else:
        print(f'  PASS     {fixture} x {criterion}: applicable (status={actual_status})')
        passed += 1

for err in errors:
    print(err)

print(f'')
print(f'Results: {passed} passed, {failed} failed out of {passed + failed} scenarios')
sys.exit(1 if failed > 0 else 0)
")
echo "$RESULT"
EXIT_CODE=$?

# Cleanup
rm -rf "$OUTPUT_DIR"

if [[ $EXIT_CODE -eq 0 ]]; then
    echo ""
    echo "=== ALL CHECKS PASSED ==="
    exit 0
else
    echo ""
    echo "=== FAILURES DETECTED ==="
    exit 1
fi
