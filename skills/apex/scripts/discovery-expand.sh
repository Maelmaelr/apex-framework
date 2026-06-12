#!/usr/bin/env bash
# Purpose: Deterministic candidate-expansion for /apex step 6 discovery. Replaces
#   the ~14 LLM-driven Glob/Grep/Read sibling/consumer/doc expansion clauses that
#   agents/discoverer.md used to walk one-tool-call-at-a-time (runs that ended up
#   >100 tool calls in a single agent context). One bash call now emits the union
#   of every deterministic expansion as a ranked candidate list + the doc-surface
#   set + pre-split write targets, so the discoverer spends its tool budget on the
#   one genuine judgment call (the screener subagent) instead of mechanical greps.
# Spec: agents/discoverer.md (Glob/Grep cascade + mandatory sibling/consumer/doc
#   clauses), skills/apex/steps/06-discovery.md, apex-core.md step 6.
#
# Determinism: same (seeds, goals, prompt, project HEAD) -> same output, run to
#   run. Keyword extraction uses the canonical recipe (apex-core.md Conventions:
#   lowercase + tokenize on whitespace/punct + drop stopwords + drop <4-char +
#   dedupe). This script is the scripted home of the step-6 variant of that recipe.
#
# Safety: the script is purely ADDITIVE and existence-filtered. It never decides
#   final scope - every emitted candidate still flows through the screener
#   subagent (the model judgment layer) for keep/drop. doc_surface entries are
#   folded straight into allowed_files by the discoverer (docs are not screened),
#   so doc clauses require a basename match and are capped.
#
# Args:
#   <project_root>          required; absolute repo root (git worktree).
#   --seeds <file>          repo-relative seed paths, one per line (validated
#                           existing paths from hypothesis.discovered_paths +
#                           prompt regex tokens + lessons + project-context).
#   --goals <file>          hypothesis.goals[] text, one goal per line (gating +
#                           keyword extraction). Optional; empty => conservative.
#   --prompt <file>         original_prompt verbatim (identifier / value-token
#                           extraction). Optional.
#   --out <file>            write JSON here; default stdout.
#
# Output JSON:
#   {
#     "candidates":   [{"path","sources":[clause,...],"match_count":N}, ...],
#     "doc_surface":  ["docs/...md", ...],
#     "presplit_targets": [{"source","split_target","loc"}, ...],
#     "delete_only_hint": ["repo/rel/path", ...],
#     "caps": {"<clause>": {"cap":N,"truncated":bool}, ...}
#   }
#   candidates excludes anything already in --seeds (seeds are scope already).
#
# Exit codes:
#   0 - emitted JSON (possibly empty candidates - a narrow task with no siblings)
#   1 - bad args (missing/!dir project_root, unreadable seeds file)

set -uo pipefail

# script dir (locates the sibling python assembler regardless of caller cwd).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- caps (per-clause; conservative - screener is the over-inclusion backstop) -
CAP_IMPORTER=30
CAP_DIRECT_IMPORT=15
CAP_CALLEE=15
CAP_MULTIPROVIDER=12
CAP_PEERMOUNT=12
CAP_NAMEDPATTERN=12
CAP_VALUERENAME=12
CAP_CLIENTSERVER=6
CAP_DOCSURFACE=25
PRESPLIT_LOC=380   # file-health hook fires at 400; pre-declare the split target.

# shared-component basename pattern (clause 6 gate).
PEERMOUNT_RE="Dialog|Picker|Modal|Drawer|Sheet|Popover"
PEERMOUNT_RE="$PEERMOUNT_RE|-dialog|-picker|-modal|-drawer|-sheet|-popover"

ROOT=""
SEEDS_FILE=""
GOALS_FILE=""
PROMPT_FILE=""
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seeds)  SEEDS_FILE="${2:-}"; shift 2 ;;
    --goals)  GOALS_FILE="${2:-}"; shift 2 ;;
    --prompt) PROMPT_FILE="${2:-}"; shift 2 ;;
    --out)    OUT_FILE="${2:-}"; shift 2 ;;
    -*) echo "discovery-expand: unknown flag $1" >&2; exit 1 ;;
    *)  if [[ -z "$ROOT" ]]; then ROOT="$1"; shift;
        else echo "discovery-expand: unexpected arg $1" >&2; exit 1; fi ;;
  esac
done

if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  echo "Usage: discovery-expand.sh <project_root> [--seeds f] [--goals f] [--prompt f] [--out f]" >&2
  exit 1
fi
ROOT="$(cd "$ROOT" && pwd -P)"

# git-aware file enumeration. git grep / ls-files are tracked-only + fast and
# respect .gitignore; fall back to find for the rare non-git smoke-test case.
HAS_GIT=0
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then HAS_GIT=1; fi

# grep -l for a literal (fixed string) across the tree, repo-relative paths out.
grep_files_fixed() {  # <literal> [pathspec...]
  local lit="$1"; shift
  if [[ $HAS_GIT -eq 1 ]]; then
    git -C "$ROOT" grep -lIF -- "$lit" "$@" 2>/dev/null || true
  else
    grep -rlIF --exclude-dir=.git -- "$lit" "$ROOT" 2>/dev/null | sed "s|^$ROOT/||" || true
  fi
}
# grep -l for an extended regex.
grep_files_re() {  # <ere> [pathspec...]
  local re="$1"; shift
  if [[ $HAS_GIT -eq 1 ]]; then
    git -C "$ROOT" grep -lIE -- "$re" "$@" 2>/dev/null || true
  else
    grep -rlIE --exclude-dir=.git -- "$re" "$ROOT" 2>/dev/null | sed "s|^$ROOT/||" || true
  fi
}

exists() { [[ -f "$ROOT/$1" ]]; }
loc_of() { [[ -f "$ROOT/$1" ]] && wc -l < "$ROOT/$1" | tr -d ' ' || echo 0; }

# Canonical keyword recipe (apex-core.md Conventions). Reads text on stdin.
extract_keywords() {
  tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '\n' \
    | awk 'length($0) >= 4 &&
           $0 !~ /^(were|that|this|these|those|from|with|verify|ensure|make|sure|check|each|all|any|every)$/ \
           { if (!seen[$0]++) print }'
}

# --- load inputs -------------------------------------------------------------
SEEDS=()
if [[ -n "$SEEDS_FILE" ]]; then
  [[ -r "$SEEDS_FILE" ]] || { echo "discovery-expand: cannot read seeds file $SEEDS_FILE" >&2; exit 1; }
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && SEEDS+=("$line")
  done < "$SEEDS_FILE"
fi

GOALS_TEXT=""
[[ -n "$GOALS_FILE" && -r "$GOALS_FILE" ]] && GOALS_TEXT="$(cat "$GOALS_FILE")"
PROMPT_TEXT=""
[[ -n "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] && PROMPT_TEXT="$(cat "$PROMPT_FILE")"
GP_TEXT="$GOALS_TEXT
$PROMPT_TEXT"
GP_LC="$(printf '%s' "$GP_TEXT" | tr '[:upper:]' '[:lower:]')"

# gate helper: does combined goal+prompt text contain any of the given words?
has_word() {  # <word> [word...]
  local w
  for w in "$@"; do
    printf '%s' "$GP_LC" | grep -qiwE "$w" && return 0
  done
  return 1
}

# seed-membership test (bash 3.2 default on macOS: no associative arrays).
is_seed() { printf '%s\n' "${SEEDS[@]+"${SEEDS[@]}"}" | grep -qxF -- "$1"; }

# accumulators (TSV: path<TAB>source ; existence-filtered, non-seed, at emit)
ACC="$(mktemp)"; PRESPLIT="$(mktemp)"; DOCSURF="$(mktemp)"; DELONLY="$(mktemp)"
trap 'rm -f "$ACC" "$PRESPLIT" "$DOCSURF" "$DELONLY"' EXIT

emit() {  # <path> <source>
  local p="$1" src="$2"
  p="${p#"$ROOT"/}"
  exists "$p" || return 0
  is_seed "$p" && return 0
  printf '%s\t%s\n' "$p" "$src" >> "$ACC"
}
emit_doc() { local p="${1#"$ROOT"/}"; exists "$p" && printf '%s\n' "$p" >> "$DOCSURF"; }

# gate flags derived once.
G_TEST=0
has_word 'test' 'spec' 'regression' 'coverage' 'fixture' 'mock' 'e2e' 'unit' 'integration' && G_TEST=1
G_FIX=0
has_word 'fix' 'bug' && G_FIX=1
G_CHANGE=0
has_word 'change' 'modify' 'rename' 'update' 'replace' 'refactor' 'delete' 'remove' 'add' && G_CHANGE=1
G_EXTRACT=0
has_word 'refactor' 'extract' 'helper' 'helpers' 'dedupe' 'share' 'reuse' 'split' && G_EXTRACT=1
G_PROVIDER=0
has_word 'provider' 'providers' && G_PROVIDER=1
G_RENAME=0
has_word 'rename' 'change' 'replace' && G_RENAME=1

# has the repo a client/web tier? (symmetric client/server clause gate)
CLIENT_DIR=""
for d in web client apps/web src/client; do [[ -d "$ROOT/$d" ]] && { CLIENT_DIR="$d"; break; }; done

# =============================================================================
# Per-seed clauses
# =============================================================================
for seed in "${SEEDS[@]+"${SEEDS[@]}"}"; do
  exists "$seed" || continue
  dir="$(dirname "$seed")"; [[ "$dir" == "." ]] && dir=""
  fn="$(basename "$seed")"
  ext="${fn##*.}"
  base="${fn%.*}"
  pfx="${dir:+$dir/}"
  is_test=0
  if [[ "$seed" =~ \.(spec|test)\. || "$seed" =~ /__tests__/ || "$seed" =~ _test\. || "$seed" =~ /test_ ]]; then
    is_test=1
  fi
  is_doc=0
  [[ "$seed" == *.md || "$seed" == docs/* ]] && is_doc=1
  [[ "$is_doc" -eq 1 ]] && { emit_doc "$seed"; continue; }

  # --- clause 1: sibling spec/test inclusion -------------------------------
  if [[ "$is_test" -eq 0 && ( "$G_TEST" -eq 1 || "$G_FIX" -eq 1 || "$G_CHANGE" -eq 1 ) ]]; then
    for cand in "${pfx}${base}.spec.${ext}" "${pfx}${base}.test.${ext}" \
                "${pfx}__tests__/${base}.spec.${ext}" "${pfx}__tests__/${base}.test.${ext}" \
                "${pfx}${base}_test.${ext}" "${pfx}test_${base}.${ext}"; do
      emit "$cand" spec
    done
    # hook parallel-dir test: .../hooks/<name>.tsx -> .../__tests__/hooks/<name>.spec.tsx
    if [[ "$dir" == hooks || "$dir" == */hooks ]]; then
      hp="${dir%hooks}"; hp="${hp%/}"
      for cand in "${hp:+$hp/}__tests__/hooks/${base}.spec.${ext}" \
                  "${hp:+$hp/}__tests__/hooks/${base}.test.${ext}"; do
        emit "$cand" spec
      done
    fi
  fi

  # --- clause 2: sibling helper/utils inclusion ----------------------------
  if [[ "$base" =~ _(controller|service|route)$ ]]; then
    seed_loc="$(loc_of "$seed")"
    if [[ "$G_EXTRACT" -eq 1 || "$seed_loc" -gt 400 ]]; then
      # try both the full base ({x}_controller_helpers) and the role-stripped
      # stem ({x}_helpers) - single-responsibility refactors commonly drop the
      # _controller/_service/_route role from the extracted sibling's name.
      stem="${base%_controller}"; stem="${stem%_service}"; stem="${stem%_route}"
      for suf in helpers utils lib; do
        emit "${pfx}${base}_${suf}.${ext}" helper
        emit "${pfx}${stem}_${suf}.${ext}" helper
      done
    fi
  fi

  # --- clause 3: pre-split LOC projection ----------------------------------
  if [[ "$is_test" -eq 0 ]]; then
    seed_loc="${seed_loc:-$(loc_of "$seed")}"
    if [[ "$seed_loc" -gt "$PRESPLIT_LOC" ]]; then
      printf '%s\t%s\t%s\n' "$seed" "${pfx}${base}_helpers.${ext}" "$seed_loc" >> "$PRESPLIT"
    fi
  fi
  unset seed_loc

  # --- clause 5: SPA-sourced spec (vendor JSON -> sibling parsers) ----------
  if [[ "$ext" == "json" && "$base" =~ spec$ && "$seed" =~ (xai|x\.ai|kie|anthropic|openai) ]]; then
    for sib in "$ROOT/$pfx"*_parser.* "$ROOT/$pfx"*_scraper.* "$ROOT/$pfx"*_doc_fetcher.*; do
      [[ -f "$sib" ]] && emit "${sib#"$ROOT"/}" spaspec
    done
  fi

  # --- clause 6: shared-component peer-mount grep --------------------------
  if [[ "$base" =~ ($PEERMOUNT_RE) ]]; then
    n=0
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      emit "$f" peermount; n=$((n+1)); [[ "$n" -ge "$CAP_PEERMOUNT" ]] && break
    done < <(grep_files_re "$base" '*.ts' '*.tsx' '*.jsx' '*.js')
  fi

  # --- clause 7: symmetric client/server dispatch pair ---------------------
  if [[ -n "$CLIENT_DIR" && "$base" =~ (_executor|_runner|_dispatch|_run_) ]]; then
    # snake_case_run_* <-> kebab-case-runner-* family (best-effort transform).
    kebab="$(printf '%s' "$base" | tr '_' '-' | sed -E 's/-run-/-runner-/;s/-executor$/-runner/;s/-dispatch$/-runner/')"
    n=0
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      emit "$f" clientserver; n=$((n+1)); [[ "$n" -ge "$CAP_CLIENTSERVER" ]] && break
    done < <(grep_files_re "$kebab" "$CLIENT_DIR" 2>/dev/null)
  fi

  # --- clause 10: importer expansion ---------------------------------------
  n=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    emit "$f" importer; n=$((n+1)); [[ "$n" -ge "$CAP_IMPORTER" ]] && break
  done < <(grep_files_re "(from|import|require).*${base}" '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.go')

  # --- clause 11: direct imports of controller/service/route ---------------
  if [[ "$base" =~ _(controller|service|route)$ ]]; then
    n=0
    while IFS= read -r spec; do
      [[ -z "$spec" ]] && continue
      [[ "$spec" == .* || "$spec" == @/* || "$spec" == ~/* ]] || continue
      local_target=""
      if [[ "$spec" == .* ]]; then
        cand="$(cd "$ROOT/$dir" 2>/dev/null && cd "$(dirname "$spec")" 2>/dev/null && pwd -P)/$(basename "$spec")"
        cand="${cand#"$ROOT"/}"
        for e in "" .ts .tsx .js .py /index.ts; do
          [[ -f "$ROOT/${cand}${e}" ]] && { local_target="${cand}${e}"; break; }
        done
      fi
      [[ -n "$local_target" ]] && { emit "$local_target" directimport; n=$((n+1)); }
      [[ "$n" -ge "$CAP_DIRECT_IMPORT" ]] && break
    done < <(grep -oE "(from|require\()[[:space:]]*['\"][^'\"]+['\"]" "$ROOT/$seed" 2>/dev/null \
               | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"")
  fi
done

# =============================================================================
# Prompt/goal-token clauses (run once, not per-seed)
# =============================================================================

# --- clause 9: value/discriminator-rename consumer grep ----------------------
if [[ "$G_RENAME" -eq 1 ]]; then
  while IFS= read -r tok; do
    tok="${tok//\'/}"; tok="${tok//\"/}"
    [[ -z "$tok" ]] && continue
    # generic-word guard: skip single short common words (len<5, no separator).
    [[ "${#tok}" -lt 5 && "$tok" != *-* && "$tok" != *_* ]] && continue
    n=0
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      emit "$f" valuerename; n=$((n+1)); [[ "$n" -ge "$CAP_VALUERENAME" ]] && break
    done < <(grep_files_fixed "$tok")
  done < <(printf '%s' "$GP_TEXT" | grep -oE "'[a-z0-9_-]{3,}'|\"[a-z0-9_-]{3,}\"" | sort -u)
fi

# --- clause 8: named-pattern sibling-consumer (explicit identifier) ----------
# hook/helper identifiers named verbatim in prompt/goals: use-foo-bar, camelCase.
while IFS= read -r ident; do
  [[ -z "$ident" ]] && continue
  n=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    emit "$f" namedpattern; n=$((n+1)); [[ "$n" -ge "$CAP_NAMEDPATTERN" ]] && break
  done < <(grep_files_fixed "$ident" '*.ts' '*.tsx' '*.js' '*.jsx')
done < <(printf '%s' "$GP_TEXT" | grep -oE 'use-[a-z][a-z0-9-]{3,}|[a-z][a-zA-Z0-9]{6,}' | sort -u | head -8)

# --- clause 4: multi-provider sibling ----------------------------------------
if [[ "$G_PROVIDER" -eq 1 ]]; then
  for seed in "${SEEDS[@]+"${SEEDS[@]}"}"; do
    exists "$seed" || continue
    dir="$(dirname "$seed")"; [[ "$dir" == "." ]] && dir=""
    fn="$(basename "$seed")"; ext="${fn##*.}"; base="${fn%.*}"
    # artifact suffix = everything after the first underscore (provider stripped).
    [[ "$base" == *_* ]] || continue
    artifact="${base#*_}"
    n=0
    for sib in "$ROOT/${dir:+$dir/}"*_"${artifact}.${ext}"; do
      [[ -f "$sib" ]] || continue
      emit "${sib#"$ROOT"/}" multiprovider; n=$((n+1)); [[ "$n" -ge "$CAP_MULTIPROVIDER" ]] && break
    done
  done
fi

# --- clause 12: callee-chain (1 hop from a named entry-point op) --------------
# only when prompt/goals name a camelCase entry-point identifier; shallow + capped.
while IFS= read -r op; do
  [[ -z "$op" ]] && continue
  deffile="$(grep_files_re "(function|const|export).*${op}" '*.ts' '*.tsx' '*.js' '*.py' | head -1)"
  [[ -z "$deffile" ]] && continue
  n=0
  while IFS= read -r callee; do
    [[ -z "$callee" || "$callee" == "$op" ]] && continue
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      emit "$f" callee; n=$((n+1)); [[ "$n" -ge "$CAP_CALLEE" ]] && break 2
    done < <(grep_files_re "(function|const|export|def).*${callee}" '*.ts' '*.tsx' '*.js' '*.py')
  done < <(grep -oE '\b[a-z][a-zA-Z0-9]{4,}\(' "$ROOT/$deffile" 2>/dev/null | tr -d '(' | sort -u | head -12)
done < <(printf '%s' "$GP_TEXT" | grep -oE '\b[a-z][a-zA-Z]+[A-Z][a-zA-Z0-9]{3,}\b' | sort -u | head -3)

# clause 15: i18n locale-surface (cluster: i18n-completeness-upfront) - UI-text goal -> every tracked locale file.
if has_word 'i18n' 'locale' 'translation' 'translations' 'message' 'messages' 'label'; then
  for md in messages apps/web/messages src/messages locales src/locales public/locales lang translations; do
    [[ -d "$ROOT/$md" ]] || continue
    while IFS= read -r f; do emit "$f" i18n; done \
      < <(cd "$ROOT" && git ls-files -- "$md" 2>/dev/null | grep -iE '\.json$' | head -40)
    break
  done
fi
# =============================================================================
# Doc-surface (clauses 13 + 14): basename grep across docs + rules, then
# same-dir *.md auto-join for every docs/features/<area>/ that matched.
# =============================================================================
# goal-named doc paths first.
while IFS= read -r tok; do
  [[ "$tok" == *.md ]] && emit_doc "$tok"
done < <(printf '%s' "$GP_TEXT" | grep -oE '[A-Za-z0-9_./-]+\.md' | sort -u)

# basename grep: every kept code candidate + seeds -> matching docs.
{
  printf '%s\n' "${SEEDS[@]+"${SEEDS[@]}"}"
  cut -f1 "$ACC" 2>/dev/null
} | sort -u | while IFS= read -r code; do
  [[ -z "$code" || "$code" == *.md || "$code" == docs/* ]] && continue
  cb="$(basename "$code")"; cbase="${cb%.*}"
  [[ "${#cbase}" -lt 4 ]] && continue
  grep_files_fixed "$cbase" 'docs' '.claude/rules' 2>/dev/null
done | sort -u | while IFS= read -r d; do
  [[ -z "$d" ]] && continue
  emit_doc "$d"
  # clause 14: same-dir sibling *.md auto-join for docs/features/<area>/.
  if [[ "$d" == docs/features/*/* ]]; then
    ddir="$(dirname "$d")"
    for sib in "$ROOT/$ddir"/*.md; do [[ -f "$sib" ]] && emit_doc "${sib#"$ROOT"/}"; done
  fi
done

# CLAUDE.md deep-reference links: docs the project author bound to a subsystem.
if [[ -f "$ROOT/CLAUDE.md" ]]; then
  grep -oE '(docs/[A-Za-z0-9_./-]+\.md|\.claude/rules/[A-Za-z0-9_./-]+\.md)' "$ROOT/CLAUDE.md" 2>/dev/null \
    | sort -u | while IFS= read -r link; do
      lp="$(basename "$(dirname "$link")")"
      if { printf '%s\n' "${SEEDS[@]+"${SEEDS[@]}"}"; cut -f1 "$ACC" 2>/dev/null; } | grep -q "$lp"; then
        emit_doc "$link"
      fi
    done
fi

# --- delete_only hint: goal schedules a path for removal ---------------------
if has_word 'delete' 'remove' 'retire' 'drop'; then
  { printf '%s\n' "${SEEDS[@]+"${SEEDS[@]}"}"; cut -f1 "$ACC" 2>/dev/null; } | sort -u | while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    pb="$(basename "$p")"; pbase="${pb%.*}"
    pat="(delete|remove|git rm|retire|drop)[^.]{0,40}${pbase}"
    printf '%s' "$GP_LC" | grep -qiE "$pat" && printf '%s\n' "$p" >> "$DELONLY"
  done
fi

# =============================================================================
# Assemble JSON via the sibling python module (robust escaping, source dedup,
# match counting, ranking). Kept separate so this driver stays under the code
# line-count budget and the assembler gets its own py_compile coverage.
# =============================================================================
CAPS_SPEC="importer=$CAP_IMPORTER,directimport=$CAP_DIRECT_IMPORT,callee=$CAP_CALLEE"
CAPS_SPEC="$CAPS_SPEC,multiprovider=$CAP_MULTIPROVIDER,peermount=$CAP_PEERMOUNT"
CAPS_SPEC="$CAPS_SPEC,namedpattern=$CAP_NAMEDPATTERN,valuerename=$CAP_VALUERENAME"
CAPS_SPEC="$CAPS_SPEC,clientserver=$CAP_CLIENTSERVER,docsurface=$CAP_DOCSURFACE"

ASM_OUT="${OUT_FILE:-/dev/stdout}"
ACC="$ACC" PRESPLIT="$PRESPLIT" DOCSURF="$DOCSURF" DELONLY="$DELONLY" CAPS="$CAPS_SPEC" \
  python3 "$HERE/discovery-expand-assemble.py" "$ASM_OUT"
exit 0
