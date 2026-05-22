---
name: apex-merge
description: Integrate apex/<session> worktree branches back into their recorded base branches. Enumerates `git branch --list 'apex/*'`, reads each session manifest's base_branch + bump_hint, merges onto the recorded base, batches the VERSION bump across the run, spawns agents/apex-merge-resolver.md per conflicted file. Manual trigger only; runs from the main worktree.
---

# /apex-merge

Integration phase for the worktree-isolation model. One `apex/<session>` branch per /apex session; this skill folds them back. Manual trigger - no auto-fire from SessionEnd.

## Step 0: queue tasks

```
TaskCreate "1. Precheck"
TaskCreate "2. Discover apex/* branches"
TaskCreate "3. Update main"
TaskCreate "4. Merge loop"
TaskCreate "4.5 Replay worktree side-effects"
TaskCreate "4.6 Lint/build cleanup post-merge"
TaskCreate "5. Cleanup merged branches"
TaskCreate "6. Final push + summary"
TaskCreate "7. Self-reflect"
```

## Inputs

- `--branch <name>` (optional): merge only this branch. Default: every `apex/*` local branch.
- Each apex/<session> branch's session manifest at `.apex-worktrees/<session>/.claude-tmp/apex-active/<session>.json` (carries `base_branch`, `branch`, `worktree_path`, optional `bump_hint`).

## Step contracts

1. **Precheck** - inline. Refuse to run outside the main worktree:
   ```bash
   TOP=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
   COMMON=$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)
   [[ "$TOP" == "$COMMON" ]] || { echo "/apex-merge must run from the main worktree" >&2; exit 1; }
   ```
   Main worktree may be dirty. The `.apex-worktrees/` directory created by `apex create-session` is untracked-by-design; filter that single line before measuring. Anything else is auto-committed inline before proceeding - the user's policy is "just commit, don't ask" (run 03d9a286), so /apex-merge MUST NOT block on AskUserQuestion at precheck. Discard / stash-first are no longer offered; run `git restore` / `git stash` manually before /apex-merge if either is the intent. First, unstage any `.apex-worktrees/*` paths that a prior `git add .` accidentally recorded as mode-160000 gitlinks (reflector ba0afe92 + 32455372 recurrence: gitlink residue forced an extra cleanup commit before the VERSION bump). The follow-on `git add -A` MUST carry the `':!.apex-worktrees'` pathspec exclude - without it, `git add -A` re-walks the working tree and re-stages the same gitlinks the `git rm --cached` just unstaged, reverting the unstage in a single commit:
   ```bash
   if [[ -n "$(git ls-files .apex-worktrees 2>/dev/null)" ]]; then
     git rm --cached -r .apex-worktrees 2>/dev/null || true
   fi
   DIRTY_COUNT=$(git status --porcelain | grep -v '^?? \.apex-worktrees/$' | wc -l | tr -d ' ')
   if [[ "$DIRTY_COUNT" -gt 0 ]]; then
     git add -A -- ':!.apex-worktrees'
     git commit -m "apex-merge: auto-commit dirty main before integration ($DIRTY_COUNT files)"
   fi
   ```

   **Mint run + manifest** (arms SessionEnd sweep + the Step 7 reflector):
   ```bash
   RUN=$(openssl rand -hex 4)
   mkdir -p "$HOME/.claude/.claude-tmp/apex-merge-active"
   CC_ID=$(bash "$HOME/.claude/skills/apex/scripts/get-cc-session-id.sh")
   PID=$(bash "$HOME/.claude/skills/apex/scripts/find-claude-pid.sh" 2>/dev/null || echo "$PPID")
   printf '{"run":"%s","cc_session_id":"%s","pid":%s,"producer":"apex-merge"}\n' \
     "$RUN" "$CC_ID" "$PID" > "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}.json"
   ```
   NEVER write `cc_session_id:""` (breaks `skills/admin-apex/scripts/session-end-hook.sh` sweep) and NEVER use bare `$PPID` inside a `bash -c` subshell (captures transient zsh pid). Reuse this `RUN` across all subsequent steps (replaces the inline `openssl rand -hex 4` previously minted at Step 2). Initialize the per-run summary trace consumed by Step 7's reflector (record whether the precheck auto-committed so the reflector sees the friction):
   ```bash
   if [[ "$DIRTY_COUNT" -gt 0 ]]; then
     printf 'step-1: precheck ok (auto-committed %s dirty files on main)\n' "$DIRTY_COUNT" \
       >> "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-summary.md"
   else
     printf 'step-1: precheck ok (main worktree clean)\n' \
       >> "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-summary.md"
   fi
   ```

2. **Discover** - inline. Enumerate `git branch --list 'apex/*'`. For each branch B:
   - SESSION = strip `apex/` prefix.
   - WORKTREE = `git worktree list --porcelain | grep -A2 "^branch refs/heads/$B" | grep '^worktree ' | cut -d' ' -f2`.
   - MANIFEST = `$WORKTREE/.claude-tmp/apex-active/$SESSION.json`.
   - BASE = `jq -r .base_branch "$MANIFEST"` (default `main` if absent).
   - BUMP_HINT = `jq -r '.bump_hint // empty' "$MANIFEST"`.
   - HAS_COMMITS = `git log "$BASE..$B" --oneline` (non-empty -> queue for merge; empty -> queue for cleanup only).
   Write the discovery summary to `$HOME/.claude/.claude-tmp/apex-merge-active/<run>-discovery.json` (same canonical location as the manifest at Step 1; merge-loop.sh reads/writes the same path, so reflector + scripts probe ONE location, not two - reflector ba0afe92). Schema per entry: `{branch, base, subject, status}` where `status` is the string `"needs-merge"` (HAS_COMMITS non-empty) OR `"cleanup-only"` (HAS_COMMITS empty); top-level shape is `{branches: [<entry>, ...]}`. `merge-loop.sh` filters on `status == "needs-merge"` (string compare, NOT a `needs_merge` boolean - keep the field name + value in sync with the script or it silently returns zero entries, reflector ba0afe92). When `--branch <name>` is set, filter to that single branch. For single-branch clean-merge runs (branches.length==1 AND that branch has no conflicts at Step 4) omit per-entry `worktree_path` + manifest absolute paths from the artifact - the Step 6 summary already names the branch, so those fields are pure overhead. Append a one-line outcome to `<run>-summary.md` (e.g., `step-2: discovered N branches (M needs-merge, K cleanup-only)`).

3. **Update main** - inline. `git fetch origin`. Then short-circuit pull when local already matches origin (reflector bc822776: pull was a no-op network round-trip on already up-to-date branches):
   ```bash
   BRANCH="$(git symbolic-ref --short HEAD)"
   LOCAL=$(git rev-parse HEAD)
   ORIGIN=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "$LOCAL")
   if [[ "$LOCAL" == "$ORIGIN" ]]; then
     echo "step-3: main already up-to-date (skip pull)" >> "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-summary.md"
   else
     git pull --ff-only origin "$BRANCH"  # refuse non-FF
   fi
   ```
   Non-FF -> exit 1 with explicit error ("main diverged; resolve before /apex-merge"); user resolves and re-runs. Append `step-3: main updated <old-sha>..<new-sha>` to `<run>-summary.md` after a real pull (the up-to-date branch already wrote its own line above).

4. **Merge loop** - `bash skills/apex-merge/scripts/merge-loop.sh <run>`. Per branch with commits past base:
   - `git checkout "$BASE"`
   - `git merge --no-ff "$B" -m "Merge $B: <subject from git log -1 --pretty=%s $B>"`
   - On conflict: print conflicted paths; for each spawn `agents/apex-merge-resolver.md` (Sonnet, foreground) with the full-context bundle (conflicted body, base-side diff, apex-side diff, apex hypothesis, base-side commit messages, apex commit log). Resolver returns proposed body; orchestrator shows diff via AskUserQuestion (`accept` | `reject-edit-manually` | `abort-merge`; dismiss = `reject-edit-manually`). On accept: write file, `git add P`. On reject: surface to user for manual edit, wait, then `git add P`. On abort: `git merge --abort`, skip this branch's cleanup, continue with next.
   - All conflicts resolved -> `git merge --continue`.
   Per-branch result recorded in `<run>-merge-result.json` (`status`: `merged` | `skipped-conflict-abort` | `nothing-to-merge`; `pushed`: `true` | `false` | `not-attempted` - populated by Step 6 after `git push`). Mirror the Step 2 omit-empty discipline: when `detail` is an empty string (clean merge with no conflict-path payload), omit the field from the entry rather than emit `"detail": ""` - downstream parse noise without information value, reflector 32455372. Append `step-4: <branch> <status> (conflicts=N resolver=<accept|reject|abort>)` per branch to `<run>-summary.md` so the Step 7 reflector sees per-branch friction without re-reading the result JSON.

4.5. **Replay worktree side-effects** - inline, runs ONLY when step 4 merged 1+ branches cleanly (status `merged` exists in `<run>-merge-result.json`). Each apex worktree's executor logged its state-mutating commands to `.claude-tmp/apex-active/{session}-side-effects.jsonl` (migrations, seeders, codegen producing untracked output, etc.); main's working state was not touched by those runs, so they must replay here before step 5 removes the worktrees. Read this step's contract entirely before running it - it executes shell commands on the main worktree.
   ```bash
   bash skills/apex-merge/scripts/replay-side-effects.sh "$RUN"
   ```
   Script reads every merged branch's worktree side-effects log, dedupes by `{cmd, env_inline}` key (whitespace-normalized; `env_inline` = leading `KEY=VALUE` pairs preserved verbatim so `DB=stage pnpm migrate` and `DB=prod pnpm migrate` do NOT collapse - reflector 742e1387), writes `<run>-side-effects-dedup.json`, and prints the unique cmd list to stdout. Empty list = silent skip (no AskUserQuestion, append `step-4.5: no side-effects to replay` to `<run>-summary.md`). Non-empty list -> AskUserQuestion (header: "Replay N side-effects?"; options: `run-all` | `skip-all`; dismiss = `skip-all`). The prompt MUST include the full deduped command list verbatim so the user sees what will run. On `run-all`: invoke each command sequentially from the main worktree root (`cd "$MAIN_TOP"`), one Bash call per command, with first-failure-stop; record outcome (`{cmd, exit_code, stderr_tail}`) into `<run>-side-effects-replay.json`. A non-zero exit surfaces the failing command to the user inline and halts the replay (do NOT continue; the user resolves manually then re-runs `/apex-merge`). On `skip-all`: write an empty replay file with `{skipped: true}`. Append `step-4.5: replayed K/N (skipped=M)` to `<run>-summary.md` (where N=unique deduped, K=ran successfully, M=skipped). Per the destructive-operation rule in CLAUDE.md, the AskUserQuestion is mandatory - never auto-run.

4.6. **Lint/build cleanup post-merge** - inline, runs ONLY when step 4 resolved 1+ conflicts. Merge resolution stitches code from two branches at the file level, which can leave unused imports / unreferenced symbols / lint regressions that neither base nor apex side carried alone; run `apex-fix` once on the main worktree to surface and auto-fix them. Clean-merge-only runs (zero resolver hops) skip - the union of two clean diffs cannot introduce a lint regression neither side had. Run from the main worktree (precheck Step 1 already enforces cwd; do NOT cd into any session worktree - those are about to be removed in Step 5):
   ```bash
   RESOLVED_CONFLICTS=$(jq -r '.[] | select(.status=="merged") | (.detail // "")' \
     "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-merge-result.json" 2>/dev/null \
     | grep -c 'resolver=' || true)
   ```
   `RESOLVED_CONFLICTS == 0` -> silent skip; append `step-4.6: skipped (no conflicts to fix)` to `<run>-summary.md`. `RESOLVED_CONFLICTS >= 1` -> invoke the `apex-fix` skill via the Skill tool (`Skill(skill="apex-fix")`). apex-fix mints its own synthetic session, runs `verify-build.sh`, dispatches executor fix-attempts capped at 3, and either exits clean or surfaces remaining errors via stderr dump. Clean exit -> append `step-4.6: apex-fix clean (resolved_conflicts=N)`. Non-zero exit (cap-3 reached or unresolvable) -> AskUserQuestion (header: "apex-fix failed post-merge"; options: `proceed-anyway` | `abort-merge-run`; dismiss = `proceed-anyway`). `abort-merge-run` halts before Step 5 (worktrees + branches preserved for user investigation; the SessionEnd hook does NOT sweep `<run>` artifacts on this branch so the discovery / merge-result / summary trail survives). `proceed-anyway` continues to Step 5 with the lint debt visible in `<run>-summary.md` (`step-4.6: apex-fix fail (resolved_conflicts=N, cap-reached)`).

5. **Cleanup merged branches** - inline. For each branch with status `merged` OR `nothing-to-merge`, run in THIS order (git refuses to delete a branch while a worktree still references it, so worktree removal must precede branch deletion - reflector ba0afe92):
   - `git worktree remove "$WORKTREE"` (refuse if dirty unless `--force-cleanup-dirty` flag was passed by caller).
   - `git worktree prune` (idempotent; mandatory, not optional - drains stale worktree admin entries so the next `git branch -D` succeeds even if a prior aborted remove left a stale registration).
   - `git branch -D "$B"`
   - `git push origin --delete "$B" 2>/dev/null || true` (silent on no remote tracking)
   Branches with status `skipped-conflict-abort` keep their worktree + branch (try again next /apex-merge). Append `step-5: cleaned Q worktrees, kept P (conflict-abort)` to `<run>-summary.md`.

6. **Final push + summary** - inline.
   - **Batched VERSION bump**: read each merged session's `bump_hint`. Highest tier wins (`minor` > `patch`); if any session hints `minor`, run `bash skills/apex/scripts/bump-version.sh --kind minor`; else if any hints `patch`, `--kind patch`; else skip. Log the per-hint distribution explicitly (e.g., `bump-resolution: minor=2 patch=1 none=0 -> minor`) so multi-branch runs do not collapse the decision into branch-count. Commit the bump as `apex-merge: VERSION <old> -> <new> (<N> sessions)`.
   - `git push origin "$(git symbolic-ref --short HEAD)"`. Update `<run>-merge-result.json` per entry: set `pushed: true` on push success, `pushed: false` on push failure, `pushed: "not-attempted"` if push was skipped (e.g., no remote).
   - Print summary: `merged N branches, K conflicts auto-resolved, M conflicts manual, P branches skipped (conflict-abort), cleaned Q worktrees, VERSION <old> -> <new>, bump-resolution: <distribution>, pushed: <yes|no|skipped>`.
   - Append the same summary line as `step-6: <summary>` to `<run>-summary.md`.

7. **Self-reflect** - if the orchestrator routed around any shipped script or skipped any documented step during steps 1-6 (precheck bug workaround, manual conflict-resolution divergence, etc.), write a free-form `<run>-orchestrator-proposals.md` capturing each deviation as a `- gap: ...` / `- improvement: ...` pair BEFORE spawning the reflector. The reflector reads this as a second input alongside summary + result JSON and rolls each entry into its gaps/improvements lines, so mid-run tooling failures are no longer lost to the human-prompt path. Skip the artifact entirely on clean runs. Then spawn `agents/reflector.md` (Sonnet, foreground) with `phase=apex-merge`, then sweep this run's artifacts. Spawn-prompt template (substitute `<run>`):

   ```
   You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md and
   follow the `apex-merge step 7` row of the invocation table. No reflect-traces.sh
   heuristic block exists for this phase; inputs are this run's summary trace plus
   `<run>-discovery.json` + `<run>-merge-result.json` + (when present)
   `<run>-orchestrator-proposals.md` plus `git log -1 --pretty=%B` for the
   integration commit (when one landed).

   Token:    <run>             # 8-hex; used in place of {session}
   Phase:    apex-merge
   Manifest: $HOME/.claude/.claude-tmp/apex-merge-active/<run>.json   # absolute on purpose: subagent CWD != ~/.claude breaks relative paths.

   Errors -> ~/.claude/tmp/reflector-errors.log (silent failure otherwise).
   Shut down silently (no main-session output).
   ```

   After reflector returns, sweep the run inline (no shared cleanup script - apex-merge owns one ACTIVE dir):
   ```bash
   rm -f "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}"*
   ```
   Reflector failure does NOT block cleanup. SessionEnd-hook is the orphan fallback when Step 7 never fires (abort / crash); see `skills/admin-apex/scripts/session-end-hook.sh` for the apex-merge-active scan.

## Out of scope

- merging across non-apex/* branches - the user pre-renames anything they want preserved.
- multi-base coordination - each branch lands on its own recorded base independently; cross-base conflicts surface as merge conflicts on the second branch.

See spec: `tmp/worktree-migration-spec.md` (sections "/apex-merge skill", "Decisions", "Edge cases").
