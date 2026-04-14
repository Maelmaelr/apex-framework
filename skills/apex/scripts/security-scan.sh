#!/usr/bin/env bash
# security-scan.sh -- Pattern-based security scan fallback (for when Semgrep is unavailable).
# Version: v1.0 -- 2026-03-30
# Usage: bash security-scan.sh file1 [file2 ...]
# Output: One line per match:
#   TIER:{n} FILE:{path} LINE:{n} PATTERN:{name} MATCH:{matched_text}
# Summary line:
#   SECURITY: {tier1} FAIL, {tier2} WARN, {tier3} INFO
# Exit codes:
#   0  No Tier 1 findings
#   1  Tier 1 findings present
#   2  Bad arguments

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash security-scan.sh file1 [file2 ...]

Runs a 3-tier pattern-based security scan on the provided files.
Excludes test files, example configs, and fixture files automatically.

Tiers:
  Tier 1 (FAIL)  -- blocks verification
  Tier 2 (WARN)  -- flagged, does not block
  Tier 3 (INFO)  -- logged only

Output format (one line per match):
  TIER:{n} FILE:{path} LINE:{n} PATTERN:{name} MATCH:{matched_text}

Summary (always printed):
  SECURITY: {tier1} FAIL, {tier2} WARN, {tier3} INFO

Exit codes:
  0  No Tier 1 findings
  1  Tier 1 findings present
  2  Bad arguments

Examples:
  bash security-scan.sh apps/api/app/controllers/posts_controller.ts
  bash security-scan.sh apps/web/lib/auth.ts apps/api/app/services/stripe_service.ts
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  echo "error: at least one file path is required" >&2
  usage >&2
  exit 2
fi

# --- Exclusion filter ---
# Returns 0 (skip) if a file matches exclusion rules, 1 (include) otherwise.
is_excluded() {
  local f="$1"
  local base
  base="$(basename "$f")"
  # Test files
  [[ "$base" == *.spec.ts   ]] && return 0
  [[ "$base" == *.test.ts   ]] && return 0
  [[ "$base" == *.spec.tsx  ]] && return 0
  [[ "$base" == *.test.tsx  ]] && return 0
  # Example configs
  [[ "$base" == *.example   ]] && return 0
  [[ "$base" == env.example ]] && return 0
  # Fixture / test-helper files
  [[ "$f" == */__tests__/*   ]] && return 0
  [[ "$f" == */tests/*       ]] && return 0
  [[ "$f" == */fixtures/*    ]] && return 0
  # helpers.ts inside a test directory
  if [[ "$base" == "helpers.ts" ]]; then
    [[ "$f" == */tests/* || "$f" == */__tests__/* ]] && return 0
  fi
  return 1
}

# Build list of files that pass the exclusion filter and actually exist.
SOURCE_FILES=()
for f in "$@"; do
  if [[ ! -f "$f" ]]; then
    continue
  fi
  if is_excluded "$f"; then
    continue
  fi
  SOURCE_FILES+=("$f")
done

# Nothing to scan after exclusions.
if [[ ${#SOURCE_FILES[@]} -eq 0 ]]; then
  echo "SECURITY: 0 FAIL, 0 WARN, 0 INFO"
  exit 0
fi

# --- Counters ---
tier1_count=0
tier2_count=0
tier3_count=0

# --- Helpers ---

# emit_match TIER PATTERN_NAME FILE LINE MATCH
emit_match() {
  local tier="$1"
  local pattern_name="$2"
  local filepath="$3"
  local lineno="$4"
  local match_text="$5"
  echo "TIER:${tier} FILE:${filepath} LINE:${lineno} PATTERN:${pattern_name} MATCH:${match_text}"
}

# run_pattern TIER PATTERN_NAME PCRE_REGEX file1 [file2 ...]
# Runs grep -nP and emits one output line per match.
run_pattern() {
  local tier="$1"
  local pattern_name="$2"
  local regex="$3"
  shift 3
  # grep -nP: line numbers, PCRE; exit 1 = no match (ok), exit 2 = error
  while IFS=: read -r filepath lineno match_text; do
    emit_match "$tier" "$pattern_name" "$filepath" "$lineno" "$match_text"
    case "$tier" in
      1) (( tier1_count++ )) ;;
      2) (( tier2_count++ )) ;;
      3) (( tier3_count++ )) ;;
    esac
  done < <(grep -nP "$regex" "$@" 2>/dev/null || true)
}

# --- Tier 1: FAIL patterns ---
# SQL injection: template literal with variable inside a file that calls .query(, rawQuery, or .raw(
sql_files=()
for f in "${SOURCE_FILES[@]}"; do
  if grep -qP '\.query\(|rawQuery|\.raw\(' "$f" 2>/dev/null; then
    sql_files+=("$f")
  fi
done
if [[ ${#sql_files[@]} -gt 0 ]]; then
  run_pattern 1 "sql-injection" '`[^`]*\$\{[^}]+\}[^`]*`' "${sql_files[@]}"
fi

# eval / new Function
run_pattern 1 "eval-exec" 'eval\s*\(|new\s+Function\s*\(' "${SOURCE_FILES[@]}"

# Secrets in NEXT_PUBLIC_ vars
run_pattern 1 "secrets-in-public-vars" 'NEXT_PUBLIC_.*(?:SECRET|KEY|TOKEN|PASSWORD)' "${SOURCE_FILES[@]}"

# Mass assignment: ORM create/update with unsanitized request body
run_pattern 1 "mass-assignment" '\.create\(\s*(?:req\.body|request\.body|body)\s*\)' "${SOURCE_FILES[@]}"

# Command injection
run_pattern 1 "command-injection" '(?:exec|spawn|execSync|spawnSync)\s*\(.*(?:req\.|request\.|params\.|query\.)' "${SOURCE_FILES[@]}"

# SSRF
run_pattern 1 "ssrf" '(?:fetch|axios|got|request)\s*\(.*(?:req\.|request\.|params\.|query\.|body\.)' "${SOURCE_FILES[@]}"

# --- Tier 2: WARN patterns ---
# Wildcard CORS
run_pattern 2 "wildcard-cors" '(?:origin|Access-Control-Allow-Origin).*\*' "${SOURCE_FILES[@]}"

# Hardcoded secrets
run_pattern 2 "hardcoded-secrets" '(?:sk-[a-zA-Z0-9]{20,}|(?:api_key|apiKey|secret_key|secretKey)\s*[:=]\s*['"'"'"][^'"'"'"]{8,})' "${SOURCE_FILES[@]}"

# Weak hashing
run_pattern 2 "weak-hashing" '(?:createHash|\.hash)\s*\(\s*['"'"'"](?:md5|sha1)['"'"'"]' "${SOURCE_FILES[@]}"

# Unsafe HTML
run_pattern 2 "unsafe-html" 'dangerouslySetInnerHTML\s*=\s*\{\{.*(?:__html|props|state|data)' "${SOURCE_FILES[@]}"

# --- Tier 3: INFO patterns ---
# Error details in responses -- only files that also call res.json / response.json / Response.json
response_files=()
for f in "${SOURCE_FILES[@]}"; do
  if grep -qP 'res\.json|response\.json|Response\.json' "$f" 2>/dev/null; then
    response_files+=("$f")
  fi
done
if [[ ${#response_files[@]} -gt 0 ]]; then
  run_pattern 3 "error-details-in-response" '(?:error\.message|error\.stack|err\.message|err\.stack)' "${response_files[@]}"
fi

# ts-ignore in security-sensitive files only
security_files=()
for f in "${SOURCE_FILES[@]}"; do
  local_base="$(basename "$f")"
  if [[ "$local_base" =~ auth|crypto|jwt|middleware|webhook ]]; then
    security_files+=("$f")
  fi
done
if [[ ${#security_files[@]} -gt 0 ]]; then
  run_pattern 3 "ts-ignore-in-security-file" '@ts-ignore|@ts-expect-error' "${security_files[@]}"
fi

# --- Summary ---
parts=()
[[ $tier1_count -gt 0 ]] && parts+=("${tier1_count} FAIL")
[[ $tier2_count -gt 0 ]] && parts+=("${tier2_count} WARN")
[[ $tier3_count -gt 0 ]] && parts+=("${tier3_count} INFO")

if [[ ${#parts[@]} -eq 0 ]]; then
  echo "SECURITY: 0 FAIL, 0 WARN, 0 INFO"
else
  # Join with ", "
  summary="SECURITY:"
  first=true
  for part in "${parts[@]}"; do
    if [[ "$first" == true ]]; then
      summary="${summary} ${part}"
      first=false
    else
      summary="${summary}, ${part}"
    fi
  done
  echo "$summary"
fi

# Exit 1 if any Tier 1 findings, 0 otherwise.
if [[ $tier1_count -gt 0 ]]; then
  exit 1
fi
exit 0
