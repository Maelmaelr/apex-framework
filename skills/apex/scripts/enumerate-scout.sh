#!/usr/bin/env bash
# Step 6.a: deterministic enumeration. Single file, layered.
# Spec: apex-core.md step 6.a.
#
# Layers (priority order, each optional; "ran" = executed AND emitted >=1 finding):
#   1. Static imports     -- madge (JS/TS), pydeps (Python). Explicit deps, zero noise.
#   2. ast-grep           -- structural queries via sg/ast-grep (tree-sitter).
#   3. LSP references     -- only when a usable CLI server is detected (rare).
#   4. Framework-conv     -- Next.js (app/, pages/), Rails (config/routes.rb), Django (urls.py).
# Fallback (only when layers 1-4 produced 0):
#   5. ripgrep            -- text patterns. Noise generator, demoted to last resort.
#
# Output: findings-{session}.json (validated against schemas/findings.schema.json).
#   - Dedupe by realpath-canonicalized file
#   - reasons[]: one item per matching layer with detail + line_range (when known)
#   - confidence: 3+ deterministic = high; 1-2 = medium; ripgrep-only = low
#   - rescout layer reserved for 7.x merge (never appears here)
#
# Zero-layer case (all 4 deterministic + ripgrep produce 0):
#   - write empty findings file with _meta.warnings=['no layers produced findings']
#   - exit 10 (orchestrator dispatches zero-layer branch)
#
# Args:
#   --session <token>     (required, 8-hex)
#   --hypothesis <path>   (required) -- .claude-tmp/apex-active/{session}-hypothesis.json
#
# Exit codes: 0 = success | 10 = zero-layer | 1 = unrecoverable error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOUT_DIR=".claude-tmp/scout"

SESSION=""
HYPOTHESIS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)    SESSION="${2:-}";    shift 2 ;;
    --hypothesis) HYPOTHESIS="${2:-}"; shift 2 ;;
    *) echo "enumerate-scout.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SESSION" || ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "enumerate-scout.sh: --session required (8-hex)" >&2; exit 1
fi
if [[ -z "$HYPOTHESIS" || ! -f "$HYPOTHESIS" ]]; then
  echo "enumerate-scout.sh: --hypothesis required and must exist" >&2; exit 1
fi

mkdir -p "$SCOUT_DIR"
LAYER_DIR="/tmp/${SESSION}-enumerate"
mkdir -p "$LAYER_DIR"
trap 'rm -rf "$LAYER_DIR"' EXIT

OUTPUT="$SCOUT_DIR/findings-${SESSION}.json"

# --- Read hypothesis -> seed paths + terms ----------------------------------
SEEDS_FILE="$LAYER_DIR/seeds.json"
python3 - "$HYPOTHESIS" "$SEEDS_FILE" <<'PY'
import json, os, re, sys
hyp_path, seeds_path = sys.argv[1:]
with open(hyp_path, encoding="utf-8") as f:
    hyp = json.load(f)
prompt = hyp.get("original_prompt", "") or ""
hypothesis = hyp.get("hypothesis", "") or ""
text = f"{prompt}\n{hypothesis}"

# Path extraction: any token with a slash and an extension, or quoted/backticked
# relative paths. Validate against on-disk presence.
path_re = re.compile(r"`([^`]+)`|\"([^\"]+)\"|([A-Za-z0-9_./\-]+\.[A-Za-z0-9]+)")
seen = set()
seed_paths = []
for m in path_re.finditer(text):
    cand = next((g for g in m.groups() if g), "")
    cand = cand.strip()
    if not cand or cand in seen:
        continue
    seen.add(cand)
    if os.path.isfile(cand):
        seed_paths.append(cand)

# Term extraction: identifier-like tokens, deduped, length >= 3, dropped if all
# digits. Cap at 16 to keep downstream invocations bounded.
term_re = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
seen_terms = set()
seed_terms = []
for tok in term_re.findall(text):
    if tok.isdigit() or tok.lower() in {"the", "and", "for", "with", "from", "this", "that", "into"}:
        continue
    if tok in seen_terms:
        continue
    seen_terms.add(tok)
    seed_terms.append(tok)
    if len(seed_terms) >= 16:
        break

with open(seeds_path, "w", encoding="utf-8") as f:
    json.dump({"seed_paths": seed_paths, "seed_terms": seed_terms}, f)
PY

# --- Helper: emit one entry to a layer file ---------------------------------
# Layer files are JSONL: one {"file": ..., "detail": ..., "line_range": null|[s,e]} per line.
emit() {
  local layer="$1" file="$2" detail="$3" line_range="${4:-null}"
  python3 - "$LAYER_DIR/$layer.jsonl" "$file" "$detail" "$line_range" <<'PY'
import json, os, sys
out, file, detail, line_range = sys.argv[1:5]
try:
    canon = os.path.realpath(file)
except OSError:
    canon = file
lr = None if line_range == "null" else json.loads(line_range)
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps({"file": canon, "detail": detail, "line_range": lr}) + "\n")
PY
}

# Read seeds back into bash arrays. Portable replacement for `mapfile`
# (macOS ships bash 3.2 which lacks mapfile/readarray).
SEED_PATHS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SEED_PATHS+=("$line")
done < <(python3 -c "import json; print('\n'.join(json.load(open('$SEEDS_FILE'))['seed_paths']))")
SEED_TERMS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SEED_TERMS+=("$line")
done < <(python3 -c "import json; print('\n'.join(json.load(open('$SEEDS_FILE'))['seed_terms']))")

# Filter stdin paths to those whose path contains at least one SEED_TERM
# (case-insensitive fixed-string match). Empty SEED_TERMS = pass-through. Used
# by layer 4 to bound framework enumeration to seed-relevant route/component
# files; without this, a typical Next.js project floods 200 route files into
# findings regardless of the user's prompt.
filter_by_seeds() {
  if [[ ${#SEED_TERMS[@]} -eq 0 ]]; then
    cat
    return 0
  fi
  local args=()
  for term in "${SEED_TERMS[@]}"; do
    args+=(-e "$term")
  done
  grep -iF "${args[@]}" || true
}

# --- Layer 1: static-imports ------------------------------------------------
layer1() {
  local produced=0
  if command -v madge >/dev/null 2>&1; then
    for seed in "${SEED_PATHS[@]+"${SEED_PATHS[@]}"}"; do
      [[ "$seed" =~ \.(js|jsx|mjs|cjs|ts|tsx)$ ]] || continue
      # `madge --json file` prints {file: [imports]}. Capture forward + reverse.
      local out
      out=$(madge --json "$seed" 2>/dev/null || true)
      [[ -z "$out" ]] && continue
      # Quoted heredoc + argv passing: $out can contain ''' or backslash-special
      # sequences that would break a triple-quoted string literal interpolation.
      python3 - "$LAYER_DIR/static-imports.jsonl" "$seed" "$out" <<'PY'
import json, os, sys
out_path, seed, raw = sys.argv[1:4]
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
seen = set()
with open(out_path, "a", encoding="utf-8") as f:
    for k, vs in data.items():
        for path in [k] + list(vs or []):
            cp = os.path.realpath(path) if os.path.exists(path) else path
            if cp in seen:
                continue
            seen.add(cp)
            f.write(json.dumps({"file": cp, "detail": f"madge from {seed}", "line_range": None}) + "\n")
PY
      produced=1
    done
  fi
  if command -v pydeps >/dev/null 2>&1; then
    for seed in "${SEED_PATHS[@]+"${SEED_PATHS[@]}"}"; do
      [[ "$seed" =~ \.py$ ]] || continue
      local out
      out=$(pydeps --no-output --show-deps "$seed" 2>/dev/null || true)
      [[ -z "$out" ]] && continue
      # pydeps --show-deps is JSON-like dict-of-dicts; extract path values.
      python3 - "$LAYER_DIR/static-imports.jsonl" "$seed" "$out" <<'PY'
import ast, json, os, sys
out_path, seed, raw = sys.argv[1:4]
try:
    data = ast.literal_eval(raw)  # pydeps prints a python repr
except Exception:
    data = {}
seen = set()
with open(out_path, "a", encoding="utf-8") as f:
    for mod, info in (data.items() if isinstance(data, dict) else []):
        path = (info or {}).get("path") if isinstance(info, dict) else None
        if not path or not os.path.isfile(path):
            continue
        cp = os.path.realpath(path)
        if cp in seen:
            continue
        seen.add(cp)
        f.write(json.dumps({"file": cp, "detail": f"pydeps from {seed} ({mod})", "line_range": None}) + "\n")
PY
      produced=1
    done
  fi
  return 0
}

# --- Layer 2: ast-grep ------------------------------------------------------
layer2() {
  local sg_bin=""
  if command -v sg >/dev/null 2>&1; then sg_bin="sg"
  elif command -v ast-grep >/dev/null 2>&1; then sg_bin="ast-grep"
  else return 0
  fi
  for term in "${SEED_TERMS[@]+"${SEED_TERMS[@]}"}"; do
    # Pattern: identifier match. ast-grep needs a metavariable wrap to be a valid pattern.
    local out
    out=$("$sg_bin" run --pattern "$term" --json=stream 2>/dev/null || true)
    [[ -z "$out" ]] && continue
    # Quoted heredoc + argv passing: ast-grep's --json=stream output can carry
    # arbitrary source-code fragments which would break triple-quoted interpolation.
    python3 - "$LAYER_DIR/ast-grep.jsonl" "$term" "$out" <<'PY'
import json, os, sys
out_path, term, raw = sys.argv[1:4]
seen = set()
with open(out_path, "a", encoding="utf-8") as f:
    for ln in raw.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            obj = json.loads(ln)
        except json.JSONDecodeError:
            continue
        path = obj.get("file") or obj.get("filename") or obj.get("path")
        if not path or not os.path.isfile(path):
            continue
        cp = os.path.realpath(path)
        rng = obj.get("range") or {}
        start = (rng.get("start") or {}).get("line")
        end = (rng.get("end") or {}).get("line") or start
        line_range = [start + 1, end + 1] if isinstance(start, int) else None
        key = (cp, tuple(line_range) if line_range else None)
        if key in seen:
            continue
        seen.add(key)
        f.write(json.dumps({"file": cp, "detail": f"ast-grep '{term}'", "line_range": line_range}) + "\n")
PY
  done
  return 0
}

# --- Layer 3: LSP references ------------------------------------------------
# Hybrid integration per apex-core.md step 6.a layer 3:
# 1. Deterministic path (this layer): scripts/_lsp_query.py spawns an LSP server
#    over stdio (typescript-language-server --stdio for TS/JS), runs the
#    JSON-RPC handshake with workspace pre-load, queries textDocument/references
#    for each (TS seed_path x seed_term), emits {file, detail, line_range}
#    JSONL into LAYER_DIR/lsp.jsonl. Per-invocation timeout 15s; cap workspace
#    pre-load at 200 files (in _lsp_query.py).
# 2. Agent fallback (orchestrator-side, not this script): agents/lsp-scout.md
#    is spawned by scout1.md when (a) seed_paths include non-TS languages
#    (Python, Go, Rust...) covered by MCP LSP plugins, or (b) deterministic
#    LSP returned 0 references. The agent uses mcp__*lsp__find_references
#    against the long-running plugin-managed servers (no per-invocation spawn
#    cost) and writes lsp-agent-{session}.json which scout1.md merges before
#    6.b shard.
layer3() {
  local ts_seeds=()
  for seed in "${SEED_PATHS[@]+"${SEED_PATHS[@]}"}"; do
    [[ "$seed" =~ \.(ts|tsx|js|jsx|mjs|cjs|mts|cts)$ ]] && ts_seeds+=("$seed")
  done
  if [[ ${#ts_seeds[@]} -eq 0 ]] || ! command -v typescript-language-server >/dev/null 2>&1; then
    return 0
  fi
  for seed in "${ts_seeds[@]}"; do
    for term in "${SEED_TERMS[@]+"${SEED_TERMS[@]}"}"; do
      python3 "$SCRIPT_DIR/_lsp_query.py" \
        --server "typescript-language-server --stdio" \
        --root "$PWD" \
        --file "$seed" \
        --term "$term" \
        2>/dev/null \
        >> "$LAYER_DIR/lsp.jsonl" || true
    done
  done
  return 0
}

# --- Layer 4: framework-conv ------------------------------------------------
# Two principles: (1) match real framework conventions (App-Router has a strict
# set of route filenames; Pages-Router treats any file as a route); (2) bound
# emissions to seed-relevant files via filter_by_seeds, except for canonical
# entry-point files (config/routes.rb, urls.py, settings.py) which are always
# relevant to any change in their domain.
layer4() {
  # Next.js App Router (app/, src/app/): strict route conventions only,
  # seed-filtered. The previous "*.tsx -o *.jsx" wildcard treated every
  # component as a route and flooded findings.
  local app_dirs=()
  [[ -d "app" ]]     && app_dirs+=("app")
  [[ -d "src/app" ]] && app_dirs+=("src/app")
  for root in "${app_dirs[@]+"${app_dirs[@]}"}"; do
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      emit "framework" "$f" "next.js app-router route under $root"
    done < <(
      find "$root" -type f \( \
        -name 'page.*' -o -name 'layout.*' -o -name 'route.*' \
        -o -name 'error.*' -o -name 'loading.*' -o -name 'not-found.*' \
        -o -name 'template.*' -o -name 'default.*' \
      \) 2>/dev/null | filter_by_seeds | head -200
    )
  done
  # Next.js Pages Router (pages/, src/pages/): every .tsx/.jsx/.ts/.js IS a
  # route by convention - the broad pattern is correct here, but we still
  # seed-filter to bound the scope.
  local pages_dirs=()
  [[ -d "pages" ]]     && pages_dirs+=("pages")
  [[ -d "src/pages" ]] && pages_dirs+=("src/pages")
  for root in "${pages_dirs[@]+"${pages_dirs[@]}"}"; do
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      emit "framework" "$f" "next.js pages-router route under $root"
    done < <(
      find "$root" -type f \( \
        -name '*.tsx' -o -name '*.jsx' -o -name '*.ts' -o -name '*.js' \
      \) 2>/dev/null | filter_by_seeds | head -200
    )
  done
  # Rails: config/routes.rb is the canonical route map (always relevant; emit
  # unconditionally). App dirs are seed-filtered to bound scope.
  if [[ -f "config/routes.rb" ]]; then
    emit "framework" "config/routes.rb" "rails routes"
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      emit "framework" "$f" "rails $(dirname "$f" | sed 's|app/||')"
    done < <(
      find app/controllers app/models app/views 2>/dev/null -type f \
      | filter_by_seeds | head -200
    )
  fi
  # Django: urls.py + settings.py are canonical entry points (typically <=5
  # per project; emit unconditionally).
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    emit "framework" "$f" "django urls"
  done < <(find . -name urls.py -not -path '*/.*' 2>/dev/null | head -50)
  if [[ -f "manage.py" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      emit "framework" "$f" "django settings"
    done < <(find . -name settings.py -not -path '*/.*' 2>/dev/null | head -10)
  fi
  return 0
}

# --- Layer 5: ripgrep fallback ----------------------------------------------
# Only fires when layers 1-4 produced 0. Noisiest layer; flagged confidence: low
# downstream when it's the only contributor.
layer5() {
  local ripgrep_bin=""
  if command -v rg >/dev/null 2>&1; then ripgrep_bin="rg"
  elif command -v grep >/dev/null 2>&1; then ripgrep_bin="grep"
  else return 0
  fi
  for term in "${SEED_TERMS[@]+"${SEED_TERMS[@]}"}"; do
    local matches
    if [[ "$ripgrep_bin" == "rg" ]]; then
      matches=$(rg -l --no-messages --hidden --glob '!.git' --glob '!node_modules' "$term" 2>/dev/null | head -100 || true)
    else
      matches=$(grep -rlI --exclude-dir=.git --exclude-dir=node_modules "$term" . 2>/dev/null | head -100 || true)
    fi
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ ! -f "$f" ]] && continue
      emit "ripgrep" "$f" "ripgrep '$term'"
    done <<< "$matches"
  done
  return 0
}

layer1
layer2
layer3
layer4
DETERMINISTIC_NONEMPTY=0
for ll in static-imports ast-grep lsp framework; do
  [[ -s "$LAYER_DIR/$ll.jsonl" ]] && DETERMINISTIC_NONEMPTY=1
done
RIPGREP_FIRED=0
if [[ "$DETERMINISTIC_NONEMPTY" -eq 0 ]]; then
  layer5
  [[ -s "$LAYER_DIR/ripgrep.jsonl" ]] && RIPGREP_FIRED=1
fi

# --- Merge layers, dedupe, derive confidence, write findings.json -----------
# _enumerate_merge.py exits 10 on zero-layer, 1 on schema validation failure, 0 otherwise.
set +e
python3 "$SCRIPT_DIR/_enumerate_merge.py" \
  --layer-dir "$LAYER_DIR" \
  --output "$OUTPUT" \
  --det-nonempty "$DETERMINISTIC_NONEMPTY" \
  --rg-fired "$RIPGREP_FIRED"
exit_code=$?
set -e
exit $exit_code
