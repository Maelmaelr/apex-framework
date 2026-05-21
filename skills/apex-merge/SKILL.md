---
name: apex-merge
description: Integrate apex/<session> worktree branches back into their recorded base branches. Enumerates `git branch --list 'apex/*'`, reads each session manifest's base_branch + bump_hint, merges onto the recorded base, batches the VERSION bump across the run, spawns agents/apex-merge-resolver.md per conflicted file. Manual trigger only; runs from the main worktree.
---

# /apex-merge

Integration phase for the worktree-isolation model (apex Phase 2 opt-in). One apex/<session> branch per /apex session with `APEX_WORKTREE=1`; this skill folds them back. Manual trigger - no auto-fire from SessionEnd.

Pre-migration sessions (no `worktree_path` in manifest, no `apex/*` branch) are invisible to this skill - their git-stage-files.sh path remains the integration mechanism.

## Step 0: queue tasks

```
TaskCreate "1. Precheck"
TaskCreate "2. Discover apex/* branches"
TaskCreate "3. Update main"
TaskCreate "4. Merge loop"
TaskCreate "5. Cleanup merged branches"
TaskCreate "6. Final push + summary"
```

## Inputs

- `--branch <name>` (optional): merge only this branch. Default: every `apex/*` local branch.
- Each apex/<session> branch's session manifest at `.apex-worktrees/<session>/.claude-tmp/apex-active/<session>.json` (carries `base_branch`, `branch`, `worktree_path`, optional `bump_hint`).

## Step contracts

1. **Precheck** - inline. Refuse to run outside the main worktree:
   ```bash
   TOP=$(git rev-parse --show-toplevel)
   COMMON=$(git rev-parse --git-common-dir | sed 's,/\.git$,,')
   [[ "$TOP" == "$COMMON" ]] || { echo "/apex-merge must run from the main worktree" >&2; exit 1; }
   ```
   Main worktree must be clean (`git status --porcelain` empty). If dirty: AskUserQuestion (`commit-first` | `stash-first` | `abort`; dismiss = abort). `git stash` is explicit user opt-in and bypasses the block-destructive hook only for this prompt.

2. **Discover** - inline. Enumerate `git branch --list 'apex/*'`. For each branch B:
   - SESSION = strip `apex/` prefix.
   - WORKTREE = `git worktree list --porcelain | grep -A2 "^branch refs/heads/$B" | grep '^worktree ' | cut -d' ' -f2`.
   - MANIFEST = `$WORKTREE/.claude-tmp/apex-active/$SESSION.json`.
   - BASE = `jq -r .base_branch "$MANIFEST"` (default `main` if absent).
   - BUMP_HINT = `jq -r '.bump_hint // empty' "$MANIFEST"`.
   - HAS_COMMITS = `git log "$BASE..$B" --oneline` (non-empty -> queue for merge; empty -> queue for cleanup only).
   Write the discovery summary to `.claude-tmp/apex-merge-active/<run>-discovery.json` (run = `openssl rand -hex 4`). When `--branch <name>` is set, filter to that single branch.

3. **Update main** - inline. `git fetch origin`. Refuse non-FF pull:
   ```bash
   git pull --ff-only origin "$(git symbolic-ref --short HEAD)"
   ```
   Non-FF -> exit 1 with explicit error ("main diverged; resolve before /apex-merge"); user resolves and re-runs.

4. **Merge loop** - `bash skills/apex-merge/scripts/merge-loop.sh <run>`. Per branch with commits past base:
   - `git checkout "$BASE"`
   - `git merge --no-ff "$B" -m "Merge $B: <subject from git log -1 --pretty=%s $B>"`
   - On conflict: print conflicted paths; for each spawn `agents/apex-merge-resolver.md` (Sonnet, foreground) with the full-context bundle (conflicted body, base-side diff, apex-side diff, apex hypothesis, base-side commit messages, apex commit log). Resolver returns proposed body; orchestrator shows diff via AskUserQuestion (`accept` | `reject-edit-manually` | `abort-merge`; dismiss = `reject-edit-manually`). On accept: write file, `git add P`. On reject: surface to user for manual edit, wait, then `git add P`. On abort: `git merge --abort`, skip this branch's cleanup, continue with next.
   - All conflicts resolved -> `git merge --continue`.
   Per-branch result recorded in `<run>-merge-result.json` (status: `merged` | `skipped-conflict-abort` | `nothing-to-merge`).

5. **Cleanup merged branches** - inline. For each branch with status `merged` OR `nothing-to-merge`:
   - `git branch -D "$B"`
   - `git push origin --delete "$B" 2>/dev/null || true` (silent on no remote tracking)
   - `git worktree remove "$WORKTREE"` (refuse if dirty unless `--force-cleanup-dirty` flag was passed by caller).
   Branches with status `skipped-conflict-abort` keep their worktree + branch (try again next /apex-merge).

6. **Final push + summary** - inline.
   - **Batched VERSION bump**: read each merged session's `bump_hint`. Highest tier wins (`minor` > `patch`); if any session hints `minor`, run `bash skills/apex/scripts/bump-version.sh --kind minor`; else if any hints `patch`, `--kind patch`; else skip. Commit the bump as `apex-merge: VERSION <old> -> <new> (<N> sessions)`.
   - `git push origin "$(git symbolic-ref --short HEAD)"`.
   - Print summary: `merged N branches, K conflicts auto-resolved, M conflicts manual, P branches skipped (conflict-abort), cleaned Q worktrees, VERSION <old> -> <new>`.

## Out of scope

- pre-migration sessions (no `worktree_path` manifest) - their commits land via skills/apex/scripts/git-stage-files.sh on every /apex run.
- merging across non-apex/* branches - the user pre-renames anything they want preserved.
- multi-base coordination - each branch lands on its own recorded base independently; cross-base conflicts surface as merge conflicts on the second branch.

See spec: `tmp/worktree-migration-spec.md` (sections "/apex-merge skill", "Decisions", "Edge cases").
