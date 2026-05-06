#!/usr/bin/env bash
# Purpose: Discovery cache for /apex step 6. Skips the LSP/Glob/Grep/screener
#   cascade when a prior run already discovered scope for an equivalent prompt
#   on the same project. Cache key = sha1(normalized_prompt + project_root).
#   TTL = 7 days OR HEAD diverged by > 10 commits since cache write. Cache miss
#   leaves the cascade to run normally and (caller) writes the resulting
#   main_scope.json back via `write` afterward.
# Spec: apex-core.md step 6 (discovery), agents/discoverer.md (cache check).
#
# Subcommands:
#   check <prompt> <project_root>
#       stdout: absolute path to cached main-scope.json on hit; nothing on miss.
#       exit:   0 = hit (path printed); 1 = miss / expired / corrupt.
#   write <prompt> <project_root> <main_scope_path>
#       Copy <main_scope_path> into the cache keyed by sha1(prompt + root).
#       exit:   0 = written; 1 = bad args / source missing.
#
# Cache layout: .claude-tmp/apex-discovery-cache/<sha1>.json
#   File body = main_scope.json content + a sidecar header line is NOT used;
#   cache metadata (mtime, HEAD) is read from filesystem + git directly.
#   .claude-tmp/apex-discovery-cache/<sha1>.head = git HEAD sha at write time.
#
# TTL constants:
TTL_DAYS=7
HEAD_DIVERGE_LIMIT=10

set -euo pipefail

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CACHE_DIR="$REPO_ROOT/.claude-tmp/apex-discovery-cache"

normalize_prompt() {
  # Lowercase, collapse whitespace, strip leading/trailing whitespace.
  # Same prompt with different casing / spacing -> same key.
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'
}

cache_key() {
  local prompt="$1" root="$2"
  printf '%s\0%s' "$(normalize_prompt "$prompt")" "$root" | shasum -a 1 | awk '{print $1}'
}

cmd_check() {
  local prompt="${1:-}" root="${2:-}"
  if [[ -z "$prompt" || -z "$root" ]]; then
    echo "Usage: discovery-cache.sh check <prompt> <project_root>" >&2
    exit 1
  fi
  local key entry head_file age_days head_now head_then divergence
  key=$(cache_key "$prompt" "$root")
  entry="$CACHE_DIR/$key.json"
  head_file="$CACHE_DIR/$key.head"
  [[ -f "$entry" ]] || exit 1

  # TTL by mtime (portable: BSD vs GNU stat).
  if stat -f %m "$entry" >/dev/null 2>&1; then
    mtime=$(stat -f %m "$entry")
  else
    mtime=$(stat -c %Y "$entry")
  fi
  age_days=$(( ($(date +%s) - mtime) / 86400 ))
  (( age_days < TTL_DAYS )) || { rm -f "$entry" "$head_file"; exit 1; }

  # HEAD divergence (only if we have both a then-HEAD and a git repo now).
  if [[ -f "$head_file" ]] && head_now=$(cd "$root" && git rev-parse HEAD 2>/dev/null); then
    head_then=$(cat "$head_file")
    if [[ -n "$head_then" && "$head_then" != "$head_now" ]]; then
      divergence=$(cd "$root" && git rev-list --count "$head_then..$head_now" 2>/dev/null || echo 0)
      (( divergence <= HEAD_DIVERGE_LIMIT )) || { rm -f "$entry" "$head_file"; exit 1; }
    fi
  fi

  printf '%s\n' "$entry"
  exit 0
}

cmd_write() {
  local prompt="${1:-}" root="${2:-}" src="${3:-}"
  if [[ -z "$prompt" || -z "$root" || -z "$src" ]]; then
    echo "Usage: discovery-cache.sh write <prompt> <project_root> <main_scope_path>" >&2
    exit 1
  fi
  [[ -f "$src" ]] || { echo "source missing: $src" >&2; exit 1; }
  mkdir -p "$CACHE_DIR"
  local key entry head_file
  key=$(cache_key "$prompt" "$root")
  entry="$CACHE_DIR/$key.json"
  head_file="$CACHE_DIR/$key.head"
  cp "$src" "$entry"
  (cd "$root" && git rev-parse HEAD 2>/dev/null) > "$head_file" || rm -f "$head_file"
  exit 0
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  write) shift; cmd_write "$@" ;;
  *)
    echo "Usage: discovery-cache.sh {check|write} ..." >&2
    exit 1
    ;;
esac
