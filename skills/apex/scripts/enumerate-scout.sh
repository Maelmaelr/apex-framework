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
      python3 - "$LAYER_DIR/static-imports.jsonl" "$seed" <<PY
import json, os, sys
out_path, seed = sys.argv[1:3]
data = json.loads('''$out''')
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
    python3 - "$LAYER_DIR/ast-grep.jsonl" "$term" <<PY
import json, os, sys
out_path, term = sys.argv[1:3]
seen = set()
lines = '''$out'''.splitlines()
with open(out_path, "a", encoding="utf-8") as f:
    for ln in lines:
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
# Probe for an LSP CLI usable from a one-shot bash invocation. Most LSP servers
# require JSON-RPC over stdio with init/shutdown handshakes -- not feasible from
# bash. We probe for tools that ship references-via-CLI shortcuts. None today
# in common shape, so this layer is reserved; spec's "when an LSP server is up
# and responsive" graceful-degrades it. See TODO.
layer3() {
  # Probe presence of common LSP CLIs to surface the layer when env supports it.
  if command -v gopls >/dev/null 2>&1; then
    # gopls has `gopls references` but requires a position arg; without seed
    # positions we can't query meaningfully. Skip with a stderr breadcrumb
    # rather than emit empty noise.
    echo "enumerate-scout.sh: layer 3 LSP gopls detected but no seed positions; skipping" >&2
  fi
  # No findings emitted; layer remains "not-ran" per spec.
  return 0
}

# --- Layer 4: framework-conv ------------------------------------------------
layer4() {
  # Next.js: app/ + pages/ directories. Find route files matching seed terms.
  if [[ -d "app" || -d "pages" || -d "src/app" || -d "src/pages" ]]; then
    local roots=()
    [[ -d "app" ]]      && roots+=("app")
    [[ -d "pages" ]]    && roots+=("pages")
    [[ -d "src/app" ]]  && roots+=("src/app")
    [[ -d "src/pages" ]] && roots+=("src/pages")
    for root in "${roots[@]}"; do
      while IFS= read -r f; do
        emit "framework" "$f" "next.js route under $root"
      done < <(find "$root" -type f \( -name "page.*" -o -name "layout.*" -o -name "route.*" -o -name "*.tsx" -o -name "*.jsx" \) 2>/dev/null | head -200)
    done
  fi
  # Rails: config/routes.rb + app/controllers, app/models.
  if [[ -f "config/routes.rb" ]]; then
    emit "framework" "config/routes.rb" "rails routes"
    while IFS= read -r f; do
      emit "framework" "$f" "rails $(dirname "$f" | sed 's|app/||')"
    done < <(find app/controllers app/models app/views 2>/dev/null -type f | head -200)
  fi
  # Django: any urls.py + settings.py.
  while IFS= read -r f; do
    emit "framework" "$f" "django urls"
  done < <(find . -name urls.py -not -path '*/.*' 2>/dev/null | head -50)
  if [[ -f "manage.py" ]]; then
    while IFS= read -r f; do
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
