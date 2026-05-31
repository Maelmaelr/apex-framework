---
name: apex-merge
description: Integrate apex/<session> worktree branches back into their recorded base branches. Enumerates `git for-each-ref --format='%(refname:short)' 'refs/heads/apex/*'`, reads each session manifest's base_branch, merges onto the recorded base, spawns agents/apex-merge-resolver.md per conflicted file. Manual trigger only; runs from the main worktree. VERSION bumping is owned by the project-side deploy skill, not this skill.
---

# /apex-merge

Integration phase for the worktree-isolation model. One `apex/<session>` branch per /apex session; this skill folds them back. Manual trigger only.

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

**Deferred-tool guard.** `TaskCreate`/`TaskUpdate`/`TaskList` are deferred - batch-fetch via `ToolSearch select:TaskCreate,TaskUpdate,TaskList` before queuing. If a `TaskCreate` errors (`InputValidationError` / schema-not-loaded), do NOT fire the remaining lines - re-run that ToolSearch load, retry ONCE, then STOP and surface (an empty/flaky ToolSearch return fails every call identically; same contract as apex SKILL.md Step 0 / session 4f42caf5).

## Inputs

- `--branch <name>` (optional): merge only this branch. Default: every `apex/*` local branch.
- Each apex/<session> branch's session manifest at `.apex-worktrees/<session>/.claude-tmp/apex-active/<session>.json` (carries `base_branch`, `branch`, `worktree_path`; `bump_hint` is optional metadata read by the project-side deploy skill, not by this skill).

## Step contracts

1. **Precheck** - inline. Refuse to run outside the main worktree:
   ```bash
   TOP=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
   COMMON=$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)
   [[ "$TOP" == "$COMMON" ]] || { echo "/apex-merge must run from the main worktree" >&2; exit 1; }
   ```
   Main worktree may be dirty. `.apex-worktrees/` is untracked-by-design (its mode-160000 gitlinks must never be committed); filter it before measuring. Project `.claude/` and `.claude-tmp/` ARE swept into the auto-commit and land on main - intentional, so operator config + apex artifacts integrate with the merge (reverses the prior 13c1725f + 858eb258 `.claude-tmp`-must-never-land rule, per explicit user request). Anything else is auto-committed inline unconditionally - per explicit user request there is NO dirty-count prompt (the prior `DIRTY_COUNT > 10` `auto-commit-all | abort-to-review` AskUserQuestion gate is removed; "just commit, don't ask", run 03d9a286; reverses reflector 53bc6e73's count-cap gate). User runs `git restore` / `git stash` manually if needed. At any count, when the dirty set contains source paths (anything outside `.claude/`, `.claude-tmp/`, `.apex-worktrees/`, lessons files), the code below emits a one-line warning naming them before committing so mid-edit files swept into base stay visible (reflector 55923114); the verbatim `git status --porcelain` set lands in `${RUN}-precheck-auto-committed.txt` for post-hoc audit. The auto-commit MUST NEVER carry `--no-verify` (CLAUDE.md non-negotiable; pre-commit hook failure -> AskUserQuestion `abort-merge | retry-after-fix`, never bypass the hook; reflector 4c827a2b). First unstage any `.apex-worktrees/*` mode-160000 gitlinks (reflector ba0afe92 + 32455372). The follow-on `git add -A` MUST carry `':!.apex-worktrees'` so it does not re-stage what `git rm --cached` just unstaged:
   ```bash
   if [[ -n "$(git ls-files .apex-worktrees 2>/dev/null)" ]]; then
     git rm --cached -r .apex-worktrees 2>/dev/null || true
   fi
   DIRTY_LIST=$(git status --porcelain | grep -v '^?? \.apex-worktrees/$' || true)
   DIRTY_COUNT=$(printf '%s\n' "$DIRTY_LIST" | grep -c . || true)
   if [[ "$DIRTY_COUNT" -gt 0 ]]; then
     # Capture porcelain list BEFORE commit so committed paths stay auditable (reflector cluster 390baaaf / 87eeade0 / d60c2e75).
     printf '%s\n' "$DIRTY_LIST" > "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-precheck-auto-committed.txt"
     SRC_DIRTY=$(printf '%s\n' "$DIRTY_LIST" | cut -c4- | grep -Ev '^(\.claude/|\.claude-tmp/|\.apex-worktrees/)|(^|/)lessons\.md$' || true)
     if [[ -n "$SRC_DIRTY" ]]; then
       printf 'apex-merge precheck WARNING: auto-committing source paths to main:\n%s\n' "$SRC_DIRTY" >&2
     fi
     git add -A -- ':!.apex-worktrees'
     git commit -m "apex-merge: auto-commit dirty main before integration ($DIRTY_COUNT files)"
     # Append resulting commit hash + diff-stat for post-hoc audit (apex-merge-precheck-commit-hash).
     { git rev-parse HEAD; git show --stat --oneline HEAD; } >> "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-precheck-auto-committed.txt"
   fi
   ```

   **Mint run + manifest** (arms SessionEnd sweep + the Step 7 reflector):
   ```bash
   RUN=$(openssl rand -hex 4)
   mkdir -p "$HOME/.claude/.claude-tmp/apex-merge-active"
   CC_ID=$(bash "$HOME/.claude/skills/apex/scripts/get-cc-session-id.sh")
   PID=$(bash "$HOME/.claude/skills/apex/scripts/find-claude-pid.sh" 2>/dev/null || echo "$PPID")
   printf '{"run":"%s","cc_session_id":"%s","pid":%s,"producer":"apex-merge"}\n' "$RUN" "$CC_ID" "$PID" > "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}.json"
   ```
   NEVER write `cc_session_id:""` (breaks SessionEnd sweep) and NEVER use bare `$PPID` inside `bash -c` (captures transient zsh pid). Reuse `RUN` across all subsequent steps. Then append a one-line summary trace for Step 7's reflector: `step-1: precheck ok (auto-committed N dirty files on main; list -> <run>-precheck-auto-committed.txt)` if `DIRTY_COUNT > 0` else `step-1: precheck ok (main worktree clean)`, written to `$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-summary.md`. The sidecar `${RUN}-precheck-auto-committed.txt` carries the verbatim `git status --porcelain` lines plus the resulting commit hash + diff-stat (appended after the commit) so the reflector + downstream `/apex-improve` can audit what landed without re-running `git log` (reflector cluster 390baaaf / 87eeade0 / d60c2e75).

2. **Discover** - inline. Enumerate `git for-each-ref --format='%(refname:short)' 'refs/heads/apex/*'`. For each branch B:
   - SESSION = strip `apex/` prefix.
   - WORKTREE = `git worktree list --porcelain | awk -v b="refs/heads/$B" '/^worktree / {wt=$2} $1=="branch" && $2==b {print wt; exit}'` (porcelain emits `worktree <path>` BEFORE the matching `branch refs/heads/...` line; remembering the last-seen worktree and emitting on branch match is portable to bash 3.2 and avoids the shifted-map bug of `grep -A2`).
   - MANIFEST = `$WORKTREE/.claude-tmp/apex-active/$SESSION.json`.
   - BASE = `jq -r .base_branch "$MANIFEST"` (default `main` if absent).
   - HAS_COMMITS = `git log "$BASE..$B" --oneline` (non-empty -> queue for merge; empty -> queue for cleanup only).
   Write to `$HOME/.claude/.claude-tmp/apex-merge-active/<run>-discovery.json` (same canonical location as the manifest; merge-loop.sh reads/writes the same path - reflector ba0afe92). Schema: `{branches: [{branch, base, subject, status}]}` where `status` is `"needs-merge"` (HAS_COMMITS non-empty) OR `"cleanup-only"` (empty). `merge-loop.sh` filters on `status == "needs-merge"` (string compare, NOT a boolean - reflector ba0afe92). `--branch <name>` filters to that single branch. For ALL-clean-merge runs (no entry yields conflicts at Step 4; covers both single-branch and multi-branch when none required a resolver spawn; reflector e3d3f6ba: 3-branch all-clean run carried full worktree_path + manifest payload) omit per-entry `worktree_path` + manifest paths (pure overhead). Append `step-2: discovered N branches (M needs-merge, K cleanup-only)` to `<run>-summary.md`.

   **Zero-branch path (N=0)**: NOT a full early-exit. Steps 4/4.5/4.6/5 are natural no-ops - each carries a run-only-when guard that self-skips, so `merge-loop.sh` / `replay-side-effects.sh` / `apex-fix` are never invoked and the orchestrator does NOT improvise inline no-ops; it lets each guard self-skip and records the step-N summary lines. Steps 3 (update main) and 6 (push) STILL run: Step 1's dirty-main auto-commit is unconditional (per the user-requested decision recorded in Step 1), so any local commit must still reach origin even when no branch needs merging. A zero-branch run therefore commits (if dirty) + pushes, with the merge body short-circuited.

3. **Update main** - inline. `git fetch origin`. Short-circuit pull via `git merge-base --is-ancestor` so post-auto-commit local-ahead is handled cleanly (plain `LOCAL==ORIGIN` string compare miscomputes; reflectors bc822776 + 907a040c):
   ```bash
   BRANCH="$(git symbolic-ref --short HEAD)"
   ORIGIN_REF="origin/$BRANCH"
   if ! git rev-parse "$ORIGIN_REF" >/dev/null 2>&1; then
     SUMMARY="step-3: main up-to-date (no remote tracking; fetch ran, no pull)"
   elif git merge-base --is-ancestor "$ORIGIN_REF" HEAD; then
     SUMMARY="step-3: main up-to-date (local at or ahead of $ORIGIN_REF; fetch ran, no pull)"
   else
     OLD=$(git rev-parse HEAD); git pull --ff-only origin "$BRANCH"  # refuse non-FF
     SUMMARY="step-3: main updated ${OLD}..$(git rev-parse HEAD) (fetch+pull)"
   fi
   echo "$SUMMARY" >> "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-summary.md"
   ```
   Non-FF -> exit 1 with explicit error ("main diverged; resolve before /apex-merge"). The summary line distinguishes `fetch ran, no pull` from `fetch+pull` so the reflector sees whether fetch actually changed anything (reflector 2d76614d). Emit exactly once per step.

4. **Merge loop** - `bash skills/apex-merge/scripts/merge-loop.sh <run>`. Per branch with commits past base:
   - `git checkout "$BASE"`
   - `git merge --no-ff "$B" -m "Merge $B: <subject from git log -1 --pretty=%s $B>"`
   - On conflict: print conflicted paths. **Trivial-union skip (merge-loop.sh inline)**: a single-hunk conflict whose two sides each independently nest `()` `[]` `{}` and carry an even backtick count, AND whose combined add-span is <=50 lines (the conflicted hunk span, not whole-file size - so big append-only files like lessons.md with a one-line date-bump conflict still qualify; reflector 6ed86029), is resolved by inline union of both sides' adds without spawning the resolver - saves ~5-10k tokens an agent would spend to confirm what concatenation produces (reflectors c946e283 + 907a040c). This bracket + backtick balance check (merge-loop.sh `_balanced`) replaces the prior markdown-only gate, so balanced code files now qualify too (single/double-quote parity is deliberately NOT checked - see merge-loop.sh `_balanced`). merge-loop.sh stages and records `detail: trivial-union=N`. Anything the predicate rejects (multi-hunk, unbalanced, hunk-span >50 lines) falls through to the resolver. **DU/UD (delete/modify) + DD index-state conflicts**: merge-loop.sh tags these separately in stdout + the result `detail` (`du-ud=<paths>`) because one side deleted the path - there are NO `<<<<` markers to splice, so the content resolver cannot handle them. Do NOT spawn the resolver for them; per tagged path AskUserQuestion (`keep-deleted` | `keep-modified`; dismiss = `keep-modified` to preserve work) and resolve via `git rm <path>` (keep-deleted) or `git add <path>` (keep-modified). The content resolver only handles `<<<<`-marked UU/AA hunks. Remaining content conflicts spawn `agents/apex-merge-resolver.md` (Sonnet, foreground) with the full-context bundle (conflicted body, base-side + apex-side diffs, apex hypothesis, base/apex commit logs). Resolver returns per-hunk `resolved_block` entries by default (full `proposed_body` only for multi-hunk synthesis); orchestrator splices into the conflicted file via Bash (`printf`/redirect or `git apply`), NEVER the `Edit` / `Write` tools - stale merged-in `{session}-scopes/{cc_session_id}.txt` pointers under main's `.claude-tmp/apex-active/` can arm the scope-check hook and block an `Edit` on the conflicted path, whereas a Bash write bypasses it. Then AskUserQuestion (`accept` | `reject-edit-manually` | `abort-merge`; dismiss = reject-edit). Per-option `description` carries a one-line diff sketch + recommendation only; full rationale lives in `<run>-merge-result.json` (reflector ed637be7). On accept: write file, `git add P`. On reject: user manual edit, then `git add P`. On abort: `git merge --abort`, skip cleanup, continue.
   - All conflicts resolved -> `git merge --continue`.
   Per-branch result recorded in `<run>-merge-result.json`. `merge-loop.sh` writes the status directly for non-conflict outcomes: `merged` (clean or trivial-union), `checkout-failed` (base checkout failed; loop continues to next branch), or `merge-refused` (git merge non-zero with no conflicts; exit 21); on a real conflict it writes a transient `conflict` entry then exits 20. The orchestrator owns the conflict path and rewrites that branch's entry to its terminal status - `merged` after accept/reject + `git merge --continue`, or `skipped-conflict-abort` after `git merge --abort` - so `conflict` is never a final status. Cleanup-only branches (no commits past base) get no merge-result entry; they carry `cleanup-only` in `<run>-discovery.json` (Step 2). `pushed`: `true` | `false` | `not-attempted` (set by Step 6). Mirror Step 2's omit-empty discipline: drop `detail` when empty (reflector 32455372). `merge-loop.sh` itself appends `step-4: <branch> <status> (conflicts=N resolver=<accept|reject|abort|none>)` per branch to `<run>-summary.md` - emit EVERY branch including clean merges (`conflicts=0 resolver=none`) so Step 7 reflector input is self-contained and `<run>-merge-result.json` re-read is unnecessary (reflector 802557ae). Orchestrator MUST NOT re-append this line - the script owns it; an extra orchestrator append produces double entries on every clean run (reflector 3251e5d3).

4.5. **Replay worktree side-effects** - inline, runs ONLY when step 4 merged 1+ branches cleanly (status `merged` exists in `<run>-merge-result.json`). Each apex worktree's executor logged its state-mutating commands to `.claude-tmp/apex-active/{session}-side-effects.jsonl` (migrations, seeders, codegen producing untracked output, etc.); main's working state was not touched by those runs, so they must replay here before step 5 removes the worktrees. Read this step's contract entirely before running it - it executes shell commands on the main worktree.
   ```bash
   bash skills/apex-merge/scripts/replay-side-effects.sh "$RUN"
   ```
   Script reads every merged branch's side-effects log, dedupes by the whitespace-normalized verbatim `cmd` string (leading `KEY=VALUE` env assignments are part of the string, so `DB=stage pnpm migrate` and `DB=prod pnpm migrate` do NOT collapse - reflector 742e1387), and on non-empty `unique_cmds` writes `<run>-side-effects-dedup.json` + prints cmds to stdout. **Empty `unique_cmds` skips the artifact write entirely** (no zero-payload JSON; reflector cluster a9347908 / f171bdbf / 87eeade0 / d60c2e75 / 5c21ac54: dedup.json read+written for runs with zero side-effects across all merged sessions); the script appends `step-4.5: no side-effects to replay (artifact skipped)` to `<run>-summary.md` (mirrors merge-loop.sh step-4 script-ownership pattern, removes orchestrator knowledge of the dedup-empty case; reflectors 2b63b077 + 2c457ebe). Non-empty list -> AskUserQuestion (`run-all` | `skip-all`; dismiss = `skip-all`; prompt MUST include the full deduped command list verbatim). On `run-all`: invoke each sequentially from main worktree root, first-failure-stop; record `{cmd, exit_code, stderr_tail}` into `<run>-side-effects-replay.json`. Non-zero exit halts the replay (user resolves + re-runs `/apex-merge`). On `skip-all`: write `{skipped: true}`. Append `step-4.5: replayed K/N (skipped=M)` to `<run>-summary.md`. Per the destructive-operation rule, AskUserQuestion is mandatory - never auto-run.

4.6. **Lint/build cleanup post-merge** - inline, runs ONLY when step 4 resolved 1+ conflicts (clean-merge-only runs skip; union of two clean diffs cannot introduce a lint regression neither side had). Merge resolution stitches code at the file level and can leave unused imports / unreferenced symbols / lint regressions neither side carried alone; run `apex-fix` once on main. Run from the main worktree (precheck Step 1 already enforces cwd):
   ```bash
   RESOLVED_CONFLICTS=$(jq -r '.[] | select(.status=="merged") | (.detail // "")' \
     "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-merge-result.json" 2>/dev/null \
     | grep -c 'resolver=' || true)
   ```
   `RESOLVED_CONFLICTS == 0` -> silent skip + `step-4.6: skipped (no conflicts to fix)`. `RESOLVED_CONFLICTS >= 1` -> first narrow scope to the conflict-touched files so apex-fix's executor cannot drift outside the resolved set (reflector 907a040c: standalone apex-fix bypassed scope-check, allowed prettier reformats + `next-env.d.ts` drift). Build a synthetic apex-style scope pointer keyed to the current `cc_session_id`:
   ```bash
   FIX_SESSION=$(openssl rand -hex 4)
   SCOPE_DIR="$HOME/.claude/.claude-tmp/apex-active"
   mkdir -p "$SCOPE_DIR/${FIX_SESSION}-scopes"
   CC_ID=$(bash $HOME/.claude/skills/apex/scripts/get-cc-session-id.sh)
   # Conflict-touched paths from this run's merge-result (status=merged AND detail names a resolver hop), filtered to lintable extensions only (.ts|.tsx|.js|.jsx|.mjs|.cjs|.json); markdown-only resolver hops produce an empty array and skip apex-fix entirely (reflector 4c827a2b: markdown-only conflict swept a 219-line unrelated refactor into the merge commit).
   jq -r '.[] | select(.status=="merged") | select(.detail // "" | test("resolver=")) | .paths // .path // empty' \
     "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-merge-result.json" \
     | jq -Rs 'split("\n") | map(select(length>0) | select(test("\\.(ts|tsx|js|jsx|mjs|cjs|json)$"))) | {allowed_files: .}' \
     > "$SCOPE_DIR/${FIX_SESSION}-main-scope.json"
   echo "${FIX_SESSION}" > "$SCOPE_DIR/${FIX_SESSION}-scopes/${CC_ID}.txt"
   # Then invoke apex-fix only when allowed_files is non-empty; on return (or empty-skip) remove the synthetic scope pointer.
   ```
   When `allowed_files` is empty (every resolver hop was markdown-only), `rm -rf "$SCOPE_DIR/${FIX_SESSION}-scopes" "$SCOPE_DIR/${FIX_SESSION}-main-scope.json"` and record `step-4.6: skipped (no lintable resolver-touched files)`. Otherwise invoke `apex-fix` via Skill (`Skill(skill="apex-fix")`). After return (regardless of outcome), `rm -rf "$SCOPE_DIR/${FIX_SESSION}-scopes" "$SCOPE_DIR/${FIX_SESSION}-main-scope.json"`. Clean exit -> `step-4.6: apex-fix clean (resolved_conflicts=N)`. Non-zero exit -> AskUserQuestion (`proceed-anyway` | `abort-merge-run`; dismiss = `proceed-anyway`). `abort-merge-run` halts before Step 5 (worktrees + branches preserved; SessionEnd hook does NOT sweep `<run>` on this branch). `proceed-anyway` continues with `step-4.6: apex-fix fail (resolved_conflicts=N, cap-reached)` recorded.

5. **Cleanup merged branches** - inline. For each branch that integrated - merge-result status `merged`, plus the `cleanup-only` branches from `<run>-discovery.json` (no commits past base, already current) - run in THIS order (worktree removal must precede branch deletion - reflector ba0afe92):
   - `git worktree remove "$WORKTREE"` (refuse if dirty unless `--force-cleanup-dirty`). **Dirty-classification fast-path** (reflectors 05ac48db + cf2e67b6): before the AskUserQuestion prompt, classify dirty payload via `git -C "$WORKTREE" status --porcelain`; when EVERY dirty line is a deletion of a path tracked on BASE HEAD (`D ` prefix on a path that `git -C "$WORKTREE" cat-file -e BASE:<path>` confirms exists on base; stale checkout safe to drop) OR matches a known auto-generated / local-regenerated path - matched on the path alone (status prefix ignored, so untracked `??` regen files classify too): `next-env.d.ts` at any depth incl. `apps/web/next-env.d.ts` (build-tool auto-gen), `.claude/settings.json` + `.claude/settings.local.json` (local harness config, never real work), `data/model-specs/**/*.json` (re-stamped timestamp / fetch_skipped fallback regen), and `.claude-tmp/*-traces/**` (apex executor trace scratch apex-merge created itself, never real work - reflector df21f711); extend by appending to the allowlist when reflectors flag new auto-gen/regen patterns - auto-force without prompting and record `step-5: auto-force <branch> (deletions-only|auto-generated-only)`. Anything not matching either category (real source modifications, unrecognized untracked files) falls through to the standard AskUserQuestion.
   - `git worktree prune` (mandatory; drains stale admin entries so `git branch -D` succeeds).
   - `git branch -D "$B"`
   - Per-branch incremental append `step-5: <branch> cleaned (worktree+local)` to `<run>-summary.md` (mirrors merge-loop.sh step-4 pattern; partial-abort still leaves a reflector-legible trail; reflector e3d3f6ba: orchestrator had to re-prune/re-classify/re-delete inline because end-of-loop append was bypassed by mid-loop abort). **Append idempotency guard**: before every step-5 line append (auto-force, cleaned, remote-pruned), `grep -qF "step-5: <branch>" <run>-summary.md` and skip the append on hit so partial-failure retry of the cleanup loop does not double-write the same per-branch line (reflector 6e33cdd2: step-5 d653cb98 auto-force line duplicated in summary indicating retry without idempotency).
   Remote-delete is batched AFTER the per-branch loop completes - run `git push origin --delete "$B" 2>/dev/null || true` per cleaned branch in one tail pass, then append `step-5: remote-pruned R/Q` once. Hoisting it out of the per-branch body means a guardrail rejection on one remote-delete cannot orphan local cleanup for sibling branches (reflector e3d3f6ba: false-positive on `git push origin --delete` aborted the loop mid-iteration, requiring inline orchestrator recovery). Branches with a non-integrated status (`skipped-conflict-abort`, `checkout-failed`, `merge-refused`) keep worktree + branch. Final append `step-5: cleaned Q worktrees, kept P (conflict-abort)` to `<run>-summary.md`.

6. **Final push + summary** - inline. VERSION bumping is NOT this step's responsibility; the project-side deploy skill (e.g. `.claude/skills/deploy/` in the project repo) reads each merged session's `bump_hint` from the manifest and owns the bump + commit.
   - `git push origin "$(git symbolic-ref --short HEAD)"`. Update `<run>-merge-result.json` per entry: `pushed: true|false|"not-attempted"`.
   - Print + append to `<run>-summary.md`: `step-6: merged N branches, K conflicts auto-resolved, M conflicts manual, P branches skipped, cleaned Q worktrees, pushed: <yes|no|skipped>`.

7. **Self-reflect** - if the orchestrator routed around any shipped script or skipped any documented step during steps 1-6, write a free-form `<run>-orchestrator-proposals.md` capturing each deviation as a `- gap: ...` / `- improvement: ...` pair BEFORE spawning the reflector (rolled into the reflector's gaps/improvements lines so mid-run tooling failures are not lost). Skip the artifact on clean runs. Then spawn `agents/reflector.md` (Sonnet, foreground) with `phase=apex-merge`, then sweep this run's artifacts. Spawn-prompt template (substitute `<run>`):

   ```
   You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md and follow the `apex-merge step 7` row of the invocation table. Inputs: `<run>-summary.md` + `<run>-discovery.json` + `<run>-merge-result.json` + (when present) `<run>-orchestrator-proposals.md` + `git log -1 --pretty=%B` for the integration commit.

   Token:    <run>             # 8-hex; used in place of {session}
   Phase:    apex-merge
   Manifest: $HOME/.claude/.claude-tmp/apex-merge-active/<run>.json

   Errors -> ~/.claude/tmp/reflector-errors.log (silent failure otherwise). Shut down silently.
   ```

   After reflector returns, sweep: `rm -f "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}"*`. Reflector failure does NOT block cleanup. SessionEnd-hook is the orphan fallback (see `skills/admin-apex/scripts/session-end-hook.sh`).

## Out of scope

- merging across non-apex/* branches - user pre-renames anything they want preserved.
- multi-base coordination - each branch lands on its own recorded base; cross-base conflicts surface as merge conflicts on the second branch. See spec: `tmp/worktree-migration-spec.md`.
