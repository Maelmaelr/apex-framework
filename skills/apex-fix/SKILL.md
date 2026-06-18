---
name: apex-fix
description: Standalone lint/build fix workflow. Mints a synthetic session, runs scripts/verify-build.sh, spawns agents/executor.md fix-attempts capped at 3, then optional learn.
triggers:
  - apex-fix
---

# apex-fix - Standalone Lint/Build Fix

Thin wrapper around the apex framework's `verify-build.sh` + `agents/executor.md`. No discovery, no scope, no plan - just verify -> fix -> verify until clean or capped.

Spec sources (do NOT duplicate here):
- `~/.claude/skills/apex/steps/10-verify.md` - canonical verify+fix loop (this skill mirrors it standalone)
- `~/.claude/skills/apex/scripts/verify-build.sh` - the verifier (project-type detection, errors-file format)
- `~/.claude/agents/executor.md` - the fixer

## Step 0: Mint synthetic session

```
SESSION=$(openssl rand -hex 4)              # 8-char lowercase hex
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude-tmp/apex-active"
mkdir -p "$ROOT"
ERRORS_FILE="$ROOT/${SESSION}-verify-errors.txt"
TRACE_DIR="$ROOT/${SESSION}-traces/verify"
mkdir -p "$TRACE_DIR"

# Capture HEAD BEFORE executor edits - apex-fix has no manifest / base_branch
# concept, so the diff anchor for any downstream learn.md spawn is the pre-fix
# HEAD sha (the executor mutates the working tree in place; HEAD does not move).
DIFF_ANCHOR=$(git rev-parse HEAD)
```

No manifest, no scope.json - standalone runs trust the user's CWD as scope. `ROOT` anchors to the git toplevel (matching `verify-build.sh`'s `APEX_ACTIVE`), NOT the raw CWD - so running `/apex-fix` from a monorepo subdir (e.g. `apps/web`) does not leak a stray `.claude-tmp/` there, and the errors-file path apex-fix reads matches where `verify-build.sh` writes it. Attempt counter is in-memory only (the on-disk recovery counter from /apex step 10 is not needed: a synthetic session is fresh per invocation).

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
    rm -rf "$ERRORS_FILE" "$ROOT/${SESSION}-traces"
    exit 1
  fi

  attempts=$(( attempts + 1 ))
  TRACE="$TRACE_DIR/fix-${attempts}.md"
  # Spawn agents/executor.md (Sonnet) with the prompt template below;
  # inject $TRACE so the executor's trace-on-failure-or-split contract resolves.
  # On return, re-enter the loop - verify-build.sh re-runs from scratch.
done

# Loop exited via `break` - verify clean. Both exit paths remove the errors
# file + trace dir (clean break here, and the cap-reached abort above); on abort
# the `head -50` stderr dump is the diagnostic signal, not a retained trace dir.
rm -rf "$ERRORS_FILE" "$ROOT/${SESSION}-traces"
```

## Executor spawn prompt (per attempt)

```
You are agents/executor.md. Read it at $HOME/.claude/agents/executor.md and follow it.

Context: standalone apex-fix attempt {N} of 3
Session: {SESSION}

Errors to fix (verify-build.sh output):
<contents of {ERRORS_FILE} - read inline; if > ~200 lines, head/tail and note truncation>

Trace path on failure or split:
.claude-tmp/apex-active/{SESSION}-traces/verify/fix-{N}.md

Active scope: standalone (no scope.json - the scope-check hook passes through when no apex pointer matches the calling cc_session_id). Confine edits to files referenced in the errors output. Do NOT add features, refactor unrelated code, or expand scope.

Hooks active:
- protect-env (PreToolUse Edit/Write/MultiEdit/NotebookEdit) - .env* always denied
- block-destructive (PreToolUse Bash) - rm -rf / git reset --hard / etc. denied
- file-health (PreToolUse Edit/Write/MultiEdit) - split file > 400 lines before adding > 10 lines (NotebookEdit shares the matcher but no-ops: .ipynb is JSON-encoded)

Goal: fix the lint/build errors only.
Return one-line summary; write trace ONLY on failure or split decision.
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

If `attempts >= 1`, optionally spawn `agents/learn.md` (Sonnet, foreground) to capture novel patterns. Skip for purely mechanical fixes (single-rule lint passes, import ordering). Spawn-prompt carries `Session: {SESSION}`, `diff_anchor: {DIFF_ANCHOR}` (pre-fix HEAD sha captured at Step 0; learn.md diffs against it), and an explicit `multi-retry: {attempts} fix-attempts ran` tag. apex-fix keeps the attempt counter in-memory (Step 0) and writes no `{SESSION}-fix-attempts.json`, so this prompt tag is the ONLY signal that opens learn.md's difficulty gate (criterion 1, path b: the spawn prompt explicitly tags the run as multi-retry / non-converging); without it learn.md silently no-ops on every apex-fix learn spawn.

## Cap-reached abort path

When `attempts` hits 3 and the next verify still fails:
1. apex-fix exits non-zero.
2. The first 50 lines of `${SESSION}-verify-errors.txt` are echoed to stderr.
3. Errors file + trace dir are removed (the user's diagnostic signal is the stderr dump; persisted artifacts would only leak across runs since standalone has no session-end-hook to sweep them).

No session-end-hook needed - standalone runs do not own a manifest.

## Boundaries

For discovery / planning / feature work use `/apex`. This skill fixes only the files in the errors output, respects the protect-env / block-destructive / file-health hooks, and leaves commit / push / docs to you (commit separately afterward).

See `~/.claude/skills/apex/steps/10-verify.md` for the in-session counterpart and the full counter / trace contract; `~/.claude/agents/executor.md` for behavior.
