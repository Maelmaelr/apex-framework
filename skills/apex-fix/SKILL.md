---
name: apex-fix
description: Standalone lint/build fix workflow. Mints a synthetic session, runs scripts/verify-build.sh, spawns agents/executor.md fix-attempts capped at 3, then optional learn.
triggers:
  - apex-fix
---

# apex-fix - Standalone Lint/Build Fix

Thin wrapper around the apex framework's `verify-build.sh` + `agents/executor.md`. No discovery, no scope, no plan - just verify -> fix -> verify until clean or capped.

Spec sources (do NOT duplicate here):
- `~/.claude/skills/apex/scripts/verify-build.sh` - the verifier (project-type detection, errors-file format)
- `~/.claude/agents/executor.md` - the fixer

## Step 0: Mint synthetic session

```
SESSION=$(openssl rand -hex 4)              # 8-char lowercase hex
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROOT="$PROJECT_ROOT/.claude-tmp/apex-active"
mkdir -p "$ROOT"
ERRORS_FILE="$ROOT/${SESSION}-verify-errors.txt"

# Capture HEAD BEFORE executor edits - apex-fix has no manifest / base_branch
# concept, so the diff anchor for any downstream learn.md spawn is the pre-fix
# HEAD sha (the executor mutates the working tree in place; HEAD does not move).
DIFF_ANCHOR=$(git rev-parse HEAD)
```

No manifest, no worktree - standalone runs trust the user's CWD as scope. `ROOT` anchors to the git toplevel (matching `verify-build.sh`'s `APEX_ACTIVE`), NOT the raw CWD - so running `/apex-fix` from a monorepo subdir (e.g. `apps/web`) does not leak a stray `.claude-tmp/` there, and the errors-file path apex-fix reads matches where `verify-build.sh` writes it. Attempt counter is in-memory only (a synthetic session is fresh per invocation).

## Step 1: Verify -> fix loop (cap = 3)

```
MAX=3
attempts=0
while :; do
  if bash $HOME/.claude/skills/apex/scripts/verify-build.sh --session "$SESSION"; then
    break
  fi

  if (( attempts >= MAX )); then
    echo "apex-fix: cap reached ($attempts/$MAX); aborting" >&2
    head -50 "$ERRORS_FILE" >&2
    rm -f "$ERRORS_FILE"
    exit 1
  fi

  attempts=$(( attempts + 1 ))
  # Spawn agents/executor.md (Sonnet) with the prompt template below.
  # On return, re-enter the loop - verify-build.sh re-runs from scratch.
done

# Loop exited via `break` - verify clean. Both exit paths remove the errors
# file (clean break here, and the cap-reached abort above); on abort the
# `head -50` stderr dump is the diagnostic signal.
rm -f "$ERRORS_FILE"
```

## Executor spawn prompt (per attempt)

```
You are agents/executor.md. Read it at $HOME/.claude/agents/executor.md and follow it.

Standalone run (no worktree): anchor per the contract's standalone-caller rule.
task: fix the lint/build errors below (standalone apex-fix attempt {N} of 3)
mode: edit
session: {SESSION}
project_root: {PROJECT_ROOT}   # absolute; cd here first and confirm pwd
files: the files referenced in the errors output (edit-targets); siblings are read-only context

Errors to fix (verify-build.sh output):
<contents of {ERRORS_FILE} - read inline; if > ~200 lines, head/tail and note truncation>

Confine edits to files referenced in the errors output. Do NOT add features, refactor unrelated code, or expand scope.

Hooks active:
- protect-env (PreToolUse Read/Edit/Write/MultiEdit/NotebookEdit) - .env* always denied
- block-destructive (PreToolUse Bash) - rm -rf / git reset --hard / stash / etc. denied
- file-health (PreToolUse Edit/Write/MultiEdit) - split file > 400 lines before adding > 10 lines
- worktree fence - fail-opens outside .apex-worktrees/ (this is a main-tree standalone run)

Goal: fix the lint/build errors only.
Return {status, notes, files_touched}.
```

The errors file is the ONLY input the fixer needs.

## Step 2: Report + optional learn

```
if (( attempts == 0 )); then
  echo "apex-fix: clean on first verify - nothing to do."
  exit 0
fi

echo "apex-fix: passed after $attempts fix-attempt(s)."
```

If `attempts >= 1`, optionally spawn `agents/learn.md` (Sonnet, foreground) to capture novel patterns. Skip for purely mechanical fixes (single-rule lint passes, import ordering). Spawn-prompt carries `Session: {SESSION}`, `diff_anchor: {DIFF_ANCHOR}` (pre-fix HEAD sha captured at Step 0; learn.md diffs against it), and an explicit `multi-retry: {attempts} fix-attempts ran` tag. apex-fix keeps the attempt counter in-memory (Step 0) and writes no `{SESSION}-fix-attempts.json`, so this prompt tag carries the multi-retry difficulty evidence into learn.md's gate (criterion 1, path b: the spawn prompt explicitly tags the run as multi-retry / non-converging) - learn.md's path-a `{SESSION}-fix-attempts.json` read finds nothing in a standalone run. Absent the tag, learn.md does NOT silently no-op: its trust-the-spawn rule (being spawned means the orchestrator's gate already held) proceeds anyway; the tag makes the difficulty explicit rather than relying on that fallback.

## Cap-reached abort path

When `attempts` hits 3 and the next verify still fails:
1. apex-fix exits non-zero.
2. The first 50 lines of `${SESSION}-verify-errors.txt` are echoed to stderr.
3. The errors file is removed (the user's diagnostic signal is the stderr dump; persisted artifacts would only leak across runs since standalone has no session-end-hook to sweep them).

No session-end-hook needed - standalone runs do not own a manifest.

## Boundaries

For discovery / planning / feature work use `/apex`. This skill fixes only the files in the errors output, respects the protect-env / block-destructive / file-health hooks, and leaves commit / push / docs to you (commit separately afterward).

See `~/.claude/agents/executor.md` for the executor contract (standalone-caller anchor rule included).
