#!/usr/bin/env bash
# Step 2: create session manifest with concurrency check.
# Spec: apex-core.md step 2 + Conventions / Session manifest schema.
#
# Behavior:
#   1. Scan .claude-tmp/apex-active/*.json (manifest filename pattern: 8-hex.json).
#      Active = manifest exists AND PID alive AND ps comm matches "claude".
#      Stale  = manifest exists but PID dead OR comm mismatch (PID-rollover guard).
#   2. On overlap (any active OR stale found): exit 10 with stderr listing detected
#      state. Orchestrator branches per skills/apex/SKILL.md Step 2: stale-only -> auto
#      cleanup-stale-and-proceed (no prompt; PID dead = no concurrent file overlap);
#      active-detected -> AskUserQuestion (abort | proceed-alongside | cleanup-stale-and-proceed),
#      options filtered to detected state.
#   3. On no overlap: generate {session} via openssl rand -hex 4, write manifest:
#        {session, pid: <claude-pid>, cc_session_id}
#      pid is the claude main process pid, resolved via find-claude-pid.sh
#      (walks up the process tree until comm basename == "claude"). $PPID is
#      NOT used: when this script is invoked as `bash create-session.sh ...`,
#      $PPID is the transient zsh subshell that Claude Code's Bash tool
#      spawned, not claude itself; that zsh exits as soon as the Bash tool
#      call returns, leaving manifest.pid pointing at a dead pid and causing
#      sibling /apex's create-session.sh to mis-classify the live session as
#      stale and auto-cleanup-stale-and-proceed wipe its manifest.
#   4. Echo {session} to stdout for orchestrator capture.
#
# Args:
#   --cc-session-id <id>  (required) - Claude Code session id passed by orchestrator.
#   --alongside           (optional) - skip the overlap exit; mint a fresh manifest
#                                       even when active or stale siblings are
#                                       present. Used by SKILL Step 2's
#                                       proceed-alongside branch (reflector a06efb91:
#                                       orchestrator had to manually generate
#                                       token+manifest because no flag existed).
#
# Exit codes:
#   0  - manifest written, {session} on stdout
#   10 - overlap detected (orchestrator decides)
#   1  - unrecoverable error (bad args, openssl missing, etc.)
#
# Stderr on exit 10 (one line per token; orchestrator parses):
#   overlap_detected
#   active: <tok1> [<tok2> ...]   (omitted when no active)
#   stale:  <tok1> [<tok2> ...]   (omitted when no stale)

set -euo pipefail

# CWD=PROJECT_ROOT fail-fast guard (reflector c5ea7797): this script writes the
# manifest to the RELATIVE path .claude-tmp/apex-active, so it MUST run from the
# project root. Invoked from the apex skill dir (or any non-root CWD) it would
# silently create a manifest under the wrong .claude-tmp and strand the session.
# Fail loudly instead of corrupting state.
#   (a) never run from inside the apex install tree ($HOME/.claude/...)
#   (b) when in a git repo, CWD must be the git toplevel (manifest at repo root)
# Non-git projects skip (b) but still get (a). No jq/git dependency for (a).
_CSH_PWD="$(pwd -P)"
_CSH_HOME_CLAUDE="$(cd "$HOME/.claude" 2>/dev/null && pwd -P || echo "$HOME/.claude")"
case "$_CSH_PWD/" in
  "$_CSH_HOME_CLAUDE"/*)
    echo "create-session.sh: refusing to run from inside the apex install tree ($_CSH_PWD); cd to the project root first" >&2
    exit 1
    ;;
esac
if _CSH_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  _CSH_TOPLEVEL="$(cd "$_CSH_TOPLEVEL" 2>/dev/null && pwd -P || echo "$_CSH_TOPLEVEL")"
  if [[ "$_CSH_PWD" != "$_CSH_TOPLEVEL" ]]; then
    echo "create-session.sh: CWD ($_CSH_PWD) is not the git toplevel ($_CSH_TOPLEVEL); run from the project root so the manifest lands in the right .claude-tmp" >&2
    exit 1
  fi
fi

APEX_ACTIVE=".claude-tmp/apex-active"

CC_SESSION_ID=""
ALONGSIDE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cc-session-id)
      CC_SESSION_ID="${2:-}"
      shift 2
      ;;
    --alongside)
      ALONGSIDE=1
      shift
      ;;
    *)
      echo "create-session.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CC_SESSION_ID" ]]; then
  echo "create-session.sh: --cc-session-id is required" >&2
  exit 1
fi

# Defensive cc_session_id format check: Claude Code session ids are UUIDs
# (hex + hyphens). Rejecting anything else closes the printf injection edge
# below (we trust the bytes when writing JSON).
if ! [[ "$CC_SESSION_ID" =~ ^[0-9a-fA-F-]+$ ]]; then
  echo "create-session.sh: --cc-session-id has unexpected shape: $CC_SESSION_ID" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "create-session.sh: openssl not found (required for session token generation)" >&2
  exit 1
fi

mkdir -p "$APEX_ACTIVE"

# Orphan-artifact sweep (defense against {session}-* siblings without a
# {session}.json manifest - e.g., a prior CC crash that aborted before the
# manifest was written, or a partial cleanup that missed siblings). Best-effort;
# never blocks session creation. Only artifacts older than 24h are touched, so
# in-flight producers writing siblings before their manifest are not raced.
SCRIPT_DIR_PRE_SCAN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR_PRE_SCAN/sweep-orphan-artifacts.sh" ]]; then
  bash "$SCRIPT_DIR_PRE_SCAN/sweep-orphan-artifacts.sh" --dir "$APEX_ACTIVE" --age-hours 24 2>/dev/null || true
fi

# Discovery-cache global eviction (TTL_DAYS-based). Without this, entries only
# evict per-key on `check` reads of the same prompt; the cache dir grows
# unbounded when prompts are not re-issued. Best-effort; never blocks.
if [[ -x "$SCRIPT_DIR_PRE_SCAN/discovery-cache.sh" ]]; then
  bash "$SCRIPT_DIR_PRE_SCAN/discovery-cache.sh" prune 2>/dev/null || true
fi

active_tokens=()
stale_tokens=()

# Single python pass extracts {session, pid} pairs from all 8-hex.json manifests
# (skips parse-failed and session-less records silently, matching prior behavior).
# Bash classifies each pair as active|stale via PID-alive + comm-match.
while IFS=$'\t' read -r session_tok pid; do
  [[ -z "$session_tok" ]] && continue
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    stale_tokens+=("$session_tok")
    continue
  fi
  # PID-rollover guard: alive PID is necessary but not sufficient; require
  # ps comm to match "claude" so a recycled PID (some other process) is stale.
  if kill -0 "$pid" 2>/dev/null; then
    # On macOS BSD ps, comm can be a full path; basename normalises both forms.
    comm_base="$(basename "$(ps -o comm= -p "$pid" 2>/dev/null || true)" 2>/dev/null || true)"
    if [[ "$comm_base" == "claude" ]]; then
      active_tokens+=("$session_tok")
    else
      stale_tokens+=("$session_tok")
    fi
  else
    stale_tokens+=("$session_tok")
  fi
done < <(python3 - "$APEX_ACTIVE" <<'PY'
import json, os, re, sys
active = sys.argv[1]
pat = re.compile(r"^[0-9a-f]{8}\.json$")
if not os.path.isdir(active):
    sys.exit(0)
for name in sorted(os.listdir(active)):
    if not pat.match(name):
        continue
    try:
        with open(os.path.join(active, name), encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        continue
    sess = d.get("session", "")
    if sess:
        print(f"{sess}\t{d.get('pid', '')}")
PY
)

# Orphan-CC-session downgrade (reflector fd09e42c): a manifest from a prior CC
# session can register as active because the long-lived claude PID is shared
# across CC sessions and survives a CC restart - PID-alive + comm-match alone
# returns persistent overlap false-positives every apex run after a CC restart
# (the cited cluster: prior-CC manifests 7e0abf6a + b01eecec kept triggering
# overlap detection every subsequent apex run). When an active token's manifest
# carries a cc_session_id that differs from ours AND no sibling artifact under
# its {session}-* prefix has been touched in the last hour (a live apex run
# continuously writes traces / dispatch artifacts; an orphan is silent), demote
# from active to stale so the orchestrator's auto-cleanup-stale-and-proceed
# path applies. Keeps PID liveness as the cheap first filter; the cc_session_id
# + activity check is the second filter that distinguishes co-running sibling
# from prior-CC orphan.
if [[ ${#active_tokens[@]} -gt 0 ]]; then
  active_tokens_filtered=()
  for tok in "${active_tokens[@]}"; do
    manifest_path="$APEX_ACTIVE/$tok.json"
    manifest_cc="$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('cc_session_id', ''))
except Exception:
    pass
" "$manifest_path" 2>/dev/null || true)"
    if [[ -n "$manifest_cc" && "$manifest_cc" != "$CC_SESSION_ID" ]]; then
      newest_sibling="$(find "$APEX_ACTIVE" -name "${tok}-*" -mmin -60 -print -quit 2>/dev/null || true)"
      if [[ -z "$newest_sibling" ]]; then
        stale_tokens+=("$tok")
        continue
      fi
    fi
    active_tokens_filtered+=("$tok")
  done
  active_tokens=("${active_tokens_filtered[@]}")
fi

if [[ ${#active_tokens[@]} -gt 0 || ${#stale_tokens[@]} -gt 0 ]]; then
  if [[ $ALONGSIDE -eq 1 ]]; then
    # Caller explicitly opted in to running alongside detected siblings;
    # skip the exit-10 prompt and fall through to mint a fresh manifest.
    :
  else
    {
      echo "overlap_detected"
      [[ ${#active_tokens[@]} -gt 0 ]] && echo "active: ${active_tokens[*]}"
      [[ ${#stale_tokens[@]} -gt 0 ]] && echo "stale: ${stale_tokens[*]}"
    } >&2
    exit 10
  fi
fi

# No overlap: issue token, write manifest via printf (3-field record with shape-validated
# inputs), validate via the shared producer-validate helper, echo token to stdout.
SESSION="$(openssl rand -hex 4)"
MANIFEST="$APEX_ACTIVE/$SESSION.json"

# Resolve claude pid via tree walk (see header doc). Fall back to $PPID only if
# the walk fails - $PPID is the transient zsh subshell when this script runs
# under `bash` invocation, but it is the best signal we have if claude is not
# in the ancestry (defensive fallback; will mis-classify as stale on next
# sibling check, surfacing the install issue rather than silently corrupting).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PID="$(bash "$SCRIPT_DIR/find-claude-pid.sh" 2>/dev/null)"
if [[ -z "$CLAUDE_PID" || ! "$CLAUDE_PID" =~ ^[0-9]+$ ]]; then
  echo "create-session.sh: find-claude-pid.sh found no claude ancestor; falling back to \$PPID=$PPID (manifest may be classified stale by sibling /apex)" >&2
  CLAUDE_PID="$PPID"
fi

# Phase 2 worktree mode: APEX_WORKTREE=1 opt-in (spec: tmp/worktree-migration-spec.md
# "/apex step 2 changes"). Creates <main-worktree>/.apex-worktrees/<session> on a
# fresh apex/<session> branch off current HEAD, cd's into it, persists
# worktree_path/branch/base_branch in the manifest. The rest of step 2 (manifest
# write below) and all subsequent /apex steps then operate inside the worktree.
# APEX_WORKTREE unset/0 -> pre-migration behavior preserved exactly (manifest in
# main worktree, no branch creation).
WORKTREE_PATH=""
BRANCH=""
BASE_BRANCH=""
if [[ "${APEX_WORKTREE:-0}" == "1" ]]; then
  _WT_TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  _WT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null | sed 's,/\.git$,,' || echo "")"
  _WT_COMMON_RES="$(cd "$_WT_COMMON" 2>/dev/null && pwd -P || echo "$_WT_COMMON")"
  _WT_TOP_RES="$(cd "$_WT_TOP" 2>/dev/null && pwd -P || echo "$_WT_TOP")"
  if [[ -z "$_WT_TOP_RES" || -z "$_WT_COMMON_RES" ]]; then
    echo "create-session.sh: APEX_WORKTREE=1 requires a git repo; refusing to mint worktree" >&2
    exit 1
  fi
  # Nested-worktree guard: refuse if cwd is already a non-main (secondary)
  # worktree (e.g., another apex/<session> worktree). The user must cd to the
  # main worktree first; nesting apex worktrees produces unowned branch graphs.
  if [[ "$_WT_TOP_RES" != "$_WT_COMMON_RES" ]]; then
    echo "create-session.sh: APEX_WORKTREE=1 refuses to start from a secondary worktree (cwd=$_WT_TOP_RES, main=$_WT_COMMON_RES); cd to the main worktree and retry" >&2
    exit 1
  fi
  BASE_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
  if [[ -z "$BASE_BRANCH" ]]; then
    echo "create-session.sh: APEX_WORKTREE=1 requires HEAD on a branch (detached HEAD detected); checkout a branch first" >&2
    exit 1
  fi
  WORKTREE_PATH="$_WT_COMMON_RES/.apex-worktrees/$SESSION"
  BRANCH="apex/$SESSION"
  if [[ -e "$WORKTREE_PATH" ]]; then
    echo "create-session.sh: worktree dir already exists at $WORKTREE_PATH; run 'git worktree remove $WORKTREE_PATH --force' first" >&2
    exit 1
  fi
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "create-session.sh: branch $BRANCH already exists; run 'git branch -D $BRANCH' first" >&2
    exit 1
  fi
  if ! git worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD >/dev/null 2>&1; then
    echo "create-session.sh: git worktree add failed for $WORKTREE_PATH on branch $BRANCH" >&2
    exit 1
  fi
  cd "$WORKTREE_PATH"
  APEX_ACTIVE=".claude-tmp/apex-active"
  mkdir -p "$APEX_ACTIVE"
  MANIFEST="$APEX_ACTIVE/$SESSION.json"
fi

# Manifest write: 3 required fields always; the 3 worktree fields are populated
# only when APEX_WORKTREE=1 above. Python (not printf) so values pass through
# json.dumps and survive any future quoting weirdness in BASE_BRANCH.
python3 - "$MANIFEST" "$SESSION" "$CLAUDE_PID" "$CC_SESSION_ID" "$WORKTREE_PATH" "$BRANCH" "$BASE_BRANCH" <<'PY'
import json, sys
path, sess, pid, cc, wt, br, base = sys.argv[1:8]
m = {"session": sess, "pid": int(pid), "cc_session_id": cc}
if wt:
    m["worktree_path"] = wt
    m["branch"] = br
    m["base_branch"] = base
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(m) + "\n")
PY

# Producer-validates-before-write: shells the manifest through validate-json.sh
# (jsonschema-fallback is parse-only when the lib is missing, but the call
# point uniformly enforces the rule across script + inline-LLM producers).
# validate-json.sh ships in this script's dir; missing = corrupt install -> hard fail.
# (SCRIPT_DIR resolved above for find-claude-pid.sh; reuse.)
if [[ ! -x "$SCRIPT_DIR/validate-json.sh" ]]; then
  rm -f "$MANIFEST"
  echo "create-session.sh: validate-json.sh missing or non-executable at $SCRIPT_DIR (install corruption); aborting" >&2
  exit 1
fi
if ! "$SCRIPT_DIR/validate-json.sh" manifest.schema.json "$MANIFEST"; then
  rm -f "$MANIFEST"
  echo "create-session.sh: manifest failed schema validation; aborting" >&2
  exit 1
fi

echo "$SESSION"
exit 0
