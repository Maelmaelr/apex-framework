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
TaskCreate "4.6 Lint/build cleanup post-conflict"
TaskCreate "5. Cleanup merged branches"
TaskCreate "6. Final push + summary"
TaskCreate "6.5 Cleanup project apex scratch"
TaskCreate "7. Self-reflect"
```

**Deferred-tool guard.** `TaskCreate`/`TaskUpdate`/`TaskList` are deferred - batch-fetch via `ToolSearch select:TaskCreate,TaskUpdate,TaskList` before queuing. If a `TaskCreate` errors (`InputValidationError` / schema-not-loaded), do NOT fire the remaining lines - re-run that ToolSearch load, retry ONCE, then STOP and surface (an empty/flaky ToolSearch return fails every call identically; same contract as apex SKILL.md Step 0).

## Inputs

- `--branch <name>` (optional): merge only this branch. Default: every `apex/*` local branch.
- Each apex/<session> branch's session manifest at `.apex-worktrees/<session>/.claude-tmp/apex-active/<session>.json` (carries `base_branch`, `branch`, `worktree_path`; its `bump_hint` field is vestigial - not read here or by the deploy skill, see Step 6).

## Step contracts

1. **Precheck** - inline. Refuse to run outside the main worktree:
   ```bash
   TOP=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
   COMMON=$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)
   [[ "$TOP" == "$COMMON" ]] || { echo "/apex-merge must run from the main worktree" >&2; exit 1; }
   ```
   Main worktree may be dirty. `.apex-worktrees/` is untracked-by-design (its mode-160000 gitlinks must never be committed). Per explicit user request, project `.claude/` + `.claude-tmp/` ARE swept into the auto-commit and land on main (operator config + apex artifacts integrate with the merge); everything else is auto-committed unconditionally with NO dirty-count prompt and NO source-path warning ("just commit, don't ask" is the intended contract; recover manually via `git restore` / `git stash` / `git revert` if needed). The verbatim `git status --porcelain` set lands in `${RUN}-precheck-auto-committed.txt` for audit. The auto-commit MUST NEVER carry `--no-verify` (CLAUDE.md non-negotiable; pre-commit hook failure -> AskUserQuestion `abort-merge | retry-after-fix`, never bypass). First unstage any `.apex-worktrees/*` gitlinks; then a `git ls-files -u` guard aborts on unmerged (UU) index entries left by an orphaned stash-pop, so conflict markers are never staged onto main (cluster: merge-precheck-unmerged-index). The follow-on `git add -A` MUST carry `':!.apex-worktrees'` so it does not re-stage what `git rm --cached` just unstaged:
   ```bash
   if [[ -n "$(git ls-files .apex-worktrees 2>/dev/null)" ]]; then
     git rm --cached -r .apex-worktrees 2>/dev/null || true
   fi
   DIRTY_LIST=$(git status --porcelain | grep -v '^?? \.apex-worktrees/$' || true)
   DIRTY_COUNT=$(printf '%s\n' "$DIRTY_LIST" | grep -c . || true)
   if [[ "$DIRTY_COUNT" -gt 0 ]]; then
     # Capture porcelain list BEFORE commit so committed paths stay auditable.
     printf '%s\n' "$DIRTY_LIST" > "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-precheck-auto-committed.txt"
     UU=$(git ls-files -u | awk '{print $4}' | sort -u)
     [[ -z "$UU" ]] || { printf 'apex-merge precheck ABORT: unmerged (UU) index entries (orphaned stash-pop); resolve before re-running:\n%s\n' "$UU" >&2; exit 1; }
     git add -A -- ':!.apex-worktrees'
     MAD=$(git diff --cached --name-status | awk \
       '{c[substr($1,1,1)]++} END{printf "M:%d A:%d D:%d", c["M"]+0, c["A"]+0, c["D"]+0}')
     git commit -m "apex-merge: auto-commit dirty main before integration ($DIRTY_COUNT files) [run:$RUN]" \
       -m "Changes: $MAD" \
       -m "Co-Authored-By: Claude <noreply@anthropic.com>"
     # Append short hash + subject for post-hoc audit (no full SHA / --stat - duplicate data; cluster: merge-precheck-observability).
     git show -s --format='%h %s' HEAD >> "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-precheck-auto-committed.txt"
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
   NEVER write `cc_session_id:""` (breaks SessionEnd sweep) and NEVER use bare `$PPID` inside `bash -c` (captures transient zsh pid). Reuse `RUN` across all subsequent steps. Then append a one-line summary trace for Step 7's reflector: `step-1: precheck ok (auto-committed N dirty files on main; list -> $HOME/.claude/.claude-tmp/apex-merge-active/<run>-precheck-auto-committed.txt)` if `DIRTY_COUNT > 0` else `step-1: precheck ok (main worktree clean)`, written to `$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-summary.md`. The embedded absolute path points at the sidecar listing every auto-committed path (cluster: merge-precheck-observability).

2. **Discover** - inline. Enumerate `git for-each-ref --format='%(refname:short)' 'refs/heads/apex/*'`. For each branch B:
   - SESSION = strip `apex/` prefix.
   - WORKTREE = `git worktree list --porcelain | awk -v b="refs/heads/$B" '/^worktree / {wt=$2} $1=="branch" && $2==b {print wt; exit}'` (remember the last-seen worktree, emit on branch match - portable to bash 3.2; avoids the `grep -A2` shifted-map bug).
   - MANIFEST = `$WORKTREE/.claude-tmp/apex-active/$SESSION.json`.
   - BASE = `jq -r .base_branch "$MANIFEST"` (default `main` if absent).
   - HAS_COMMITS = `git log "$BASE..$B" --oneline` (non-empty -> queue for merge; empty -> queue for cleanup only).
   Write to `$HOME/.claude/.claude-tmp/apex-merge-active/<run>-discovery.json` (same canonical location as the manifest; merge-loop.sh reads/writes the same path). Schema: `{branches: [{branch, base, subject, status}]}` where `status` is `"needs-merge"` (HAS_COMMITS non-empty) OR `"cleanup-only"` (empty). `merge-loop.sh` filters on `status == "needs-merge"` (string compare, NOT a boolean). `--branch <name>` filters to that single branch. For ALL-clean-merge runs (no conflicts at Step 4, no resolver spawn) omit per-entry `worktree_path` + manifest paths (pure overhead). Append `step-2: discovered N branches (M needs-merge, K cleanup-only)` to `<run>-summary.md`.

   **Zero-branch path (N=0)**: NOT a full early-exit. Steps 4/4.5/4.6/5 are natural no-ops - each carries a run-only-when guard, so `merge-loop.sh` / `replay-side-effects.sh` / `apex-fix` are never invoked; the orchestrator does NOT improvise inline no-ops - it lets each guard self-skip and records the step-N summary lines. Steps 3 (update main) and 6 STILL run, but step 6 push self-gates on local-ahead: Step 1's dirty-main auto-commit is unconditional, so a real local commit reaches origin while a clean zero-branch run skips the gratuitous push round-trip. Also write the sentinel `<run>-merge-result.json` = `[]` when N=0 so the declared artifact set stays complete for audit regardless of branch count (cluster: merge-zero-branch-artifacts).

3. **Update main** - inline. `git fetch origin`. Short-circuit pull via `git merge-base --is-ancestor` so post-auto-commit local-ahead is handled cleanly (plain `LOCAL==ORIGIN` string compare miscomputes):
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
   Non-FF -> exit 1 with explicit error ("main diverged; resolve before /apex-merge"). The summary line distinguishes `fetch ran, no pull` from `fetch+pull` so the reflector sees whether fetch actually changed anything. Emit exactly once per step.

4. **Merge loop** - `bash skills/apex-merge/scripts/merge-loop.sh <run>`. Per branch with commits past base:
   - `git checkout "$BASE"`
   - `git merge --no-ff "$B" -m "Merge $B: <subject from git log -1 --pretty=%s $B>"`
   - On conflict: merge-loop.sh prints the conflicted paths and, on exit 20, one reload reminder per remaining conflicted file (if trivial-union staged every file but `git commit --no-edit` failed, the reload set falls back to the full content-conflict set - merge-loop.sh:300). **Before resolving EACH conflicted file, Read `skills/apex-merge/resolve-one-conflict.md`** - the per-conflict-file contract (trivial-union skip already applied inline by merge-loop.sh; DU/UD/DD index-state -> `keep-deleted`|`keep-modified`; content-resolver spawn via `agents/apex-merge-resolver.md` + Bash-splice-not-Edit; `accept`|`reject-edit-manually`|`abort-merge` decision). Lazy-loaded per loop iteration - the conflict-file count is unknown at step start, so the contract is read fresh at each conflict (Workstream B item-4).
   - All conflicts resolved -> `git merge --continue`.
   - **Exit 2 (two pre-merge guards)**: merge-loop.sh exits 2 from either the wrong-worktree guard (`merge-loop.sh:75`; fires when not invoked from the main worktree) or the dirty-tree gate (`merge-loop.sh:84`; main worktree dirty), both BEFORE any branch is touched - distinct from exit 20 (conflict) / 21 (merge-refused). The two need different recovery: for the dirty-tree case re-run Step 1's filtered auto-commit (unstage `.apex-worktrees` gitlinks -> `git add -A -- ':!.apex-worktrees'` + commit, NEVER `--no-verify`), then re-invoke `merge-loop.sh <run>`; for the wrong-worktree case `cd` to the main worktree and re-invoke (the auto-commit recovery does not apply).
   Per-branch result recorded in `<run>-merge-result.json`. `merge-loop.sh` writes non-conflict statuses directly: `merged` (clean or trivial-union), `checkout-failed` (base checkout failed; loop continues), or `merge-refused` (git merge non-zero, no conflicts; exit 21); a real conflict writes a transient `conflict` entry then exits 20. The orchestrator owns the conflict path: rewrite that transient entry to its terminal status via `bash skills/apex-merge/scripts/stamp-merge-result.sh <run> --branch <B> --status <merged|skipped-conflict-abort> [--decision <accept|reject-edit-manually|mixed> --paths <csv>]` - `merged` after accept/reject + `git merge --continue` (pass `--decision` + resolver-touched files as `--paths`), or `skipped-conflict-abort` after `git merge --abort` (no decision/paths) - so `conflict` is never final. The merged stamp writes `detail="resolver=<decision>"` + `paths=[...]`; step 4.6 keys its apex-fix gate on exactly those two fields (`resolver=` count + lintable `.paths`), so an un-stamped merged entry silently skips the post-conflict lint pass (F22). Do NOT hand-edit - the stamper is idempotent and drops the stale conflict-path detail. Cleanup-only branches (no commits past base) get no entry; they carry `cleanup-only` in `<run>-discovery.json` (Step 2). `pushed`: `true`|`false`|`not-attempted` (Step 6). Omit `detail` when empty (Step 2's discipline). `merge-loop.sh` itself appends the per-branch `step-4: <branch> <status> (conflicts=N resolver=<accept|reject|abort|none|trivial-union>)` line to `<run>-summary.md` for every NON-CONFLICT outcome, so Step 7 reflector input is self-contained; the orchestrator MUST NOT re-append those (double entries on every clean run). The ONE exception is a conflict branch (exit 20): the resolver decision is unknown until resolved + stamped, so merge-loop.sh skips its `append_summary` there and the orchestrator appends that branch's `step-4: ...` line itself, right after the `stamp-merge-result.sh` call above.

4.5. **Replay worktree side-effects** - inline, runs ONLY when step 4 merged 1+ branches cleanly (status `merged` exists in `<run>-merge-result.json`). Each apex worktree's executor logged its state-mutating commands to `.claude-tmp/apex-active/{session}-side-effects.jsonl` (migrations, seeders, codegen, etc.); main never saw those runs, so they must replay here before step 5 removes the worktrees. Read this step's contract entirely before running it - it executes shell commands on the main worktree.
   ```bash
   bash skills/apex-merge/scripts/replay-side-effects.sh "$RUN"
   ```
   Script reads every merged branch's side-effects log, dedupes by the whitespace-normalized verbatim `cmd` string (leading `KEY=VALUE` env assignments are part of the string, so `DB=stage pnpm migrate` and `DB=prod pnpm migrate` do NOT collapse), and on non-empty `unique_cmds` writes `<run>-side-effects-dedup.json` + prints cmds to stdout. **Empty `unique_cmds` skips the artifact write AND the summary line entirely** (no zero-payload `dedup.json`, no `artifact skipped` note - silence is the signal; cluster: merge-side-effects-empty-skip); the non-empty case writes the dedup artifact but no summary line - the orchestrator appends `step-4.5: replayed K/N (skipped=M)` itself after the AskUserQuestion below. Non-empty list -> AskUserQuestion (`run-all` | `skip-all`; dismiss = `skip-all`; prompt MUST include the full deduped command list verbatim). On `run-all`: invoke each sequentially from main worktree root, first-failure-stop; record `{cmd, exit_code, stderr_tail}` into `<run>-side-effects-replay.json`. Non-zero exit halts the replay (user resolves + re-runs `/apex-merge`). On `skip-all`: write `{skipped: true}`. Append `step-4.5: replayed K/N (skipped=M)` to `<run>-summary.md`. Per the destructive-operation rule, AskUserQuestion is mandatory - never auto-run.

4.6. **Lint/build cleanup post-conflict** - inline, runs ONLY when step 4 resolved 1+ conflicts (clean-merge-only runs skip; union of two clean diffs cannot introduce a lint regression neither side had). Merge resolution stitches code at the file level and can leave unused imports / unreferenced symbols / lint regressions neither side carried alone; run `apex-fix` once on main. Run from the main worktree (precheck Step 1 already enforces cwd):
   ```bash
   RESOLVED_CONFLICTS=$(jq -r '.[] | select(.status=="merged") | (.detail // "")' \
     "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-merge-result.json" 2>/dev/null \
     | grep -c 'resolver=' || true)
   ```
   `RESOLVED_CONFLICTS == 0` -> silent skip + `step-4.6: skipped (no conflicts to fix)`. `RESOLVED_CONFLICTS >= 1` -> first narrow scope to the conflict-touched files so apex-fix's executor cannot drift outside the resolved set. Build a synthetic apex-style scope pointer keyed to the current `cc_session_id`:
   ```bash
   FIX_SESSION=$(openssl rand -hex 4)
   SCOPE_DIR="$HOME/.claude/.claude-tmp/apex-active"
   mkdir -p "$SCOPE_DIR/${FIX_SESSION}-scopes"
   CC_ID=$(bash $HOME/.claude/skills/apex/scripts/get-cc-session-id.sh)
   # Conflict-touched paths from this run's merge-result (status=merged AND detail names a resolver hop), filtered to lintable extensions only (.ts|.tsx|.js|.jsx|.mjs|.cjs|.json); markdown-only resolver hops produce an empty array and skip apex-fix entirely.
   # Single-pass flatten: the prior two-stage form (jq -r .paths | jq -Rs split) re-parsed pretty-printed
   # array lines ('"file.ts",'), so the extension test never matched and allowed_files came out empty.
   jq '[.[] | select(.status=="merged") | select((.detail // "") | test("resolver=")) | .paths // [] | .[]
        | select(test("\\.(ts|tsx|js|jsx|mjs|cjs|json)$"))] | {allowed_files: .}' \
     "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-merge-result.json" \
     > "$SCOPE_DIR/${FIX_SESSION}-main-scope.json"
   echo "${FIX_SESSION}" > "$SCOPE_DIR/${FIX_SESSION}-scopes/${CC_ID}.txt"
   # Then invoke apex-fix only when allowed_files is non-empty; on return (or empty-skip) remove the synthetic scope pointer.
   ```
   When `allowed_files` is empty (every resolver hop was markdown-only), `rm -rf "$SCOPE_DIR/${FIX_SESSION}-scopes" "$SCOPE_DIR/${FIX_SESSION}-main-scope.json"` and record `step-4.6: skipped (no lintable resolver-touched files)`. Otherwise invoke `apex-fix` via Skill (`Skill(skill="apex-fix")`). After return (regardless of outcome), `rm -rf "$SCOPE_DIR/${FIX_SESSION}-scopes" "$SCOPE_DIR/${FIX_SESSION}-main-scope.json"`. Clean exit -> `step-4.6: apex-fix clean (resolved_conflicts=N)`. Non-zero exit -> AskUserQuestion (`proceed-anyway` | `abort-merge-run`; dismiss = `proceed-anyway`). `abort-merge-run` halts before Step 5 (worktrees + branches preserved; SessionEnd hook does NOT sweep `<run>` on this branch). `proceed-anyway` continues with `step-4.6: apex-fix fail (resolved_conflicts=N, cap-reached)` recorded.

5. **Cleanup merged branches** - inline. For each branch that integrated - merge-result status `merged`, plus the `cleanup-only` branches from `<run>-discovery.json` (no commits past base, already current) - run in THIS order (worktree removal must precede branch deletion):
   - `git worktree remove "$WORKTREE"` (refuse if dirty unless `--force-cleanup-dirty`). **Dirty-classification fast-path**: before the AskUserQuestion prompt, classify each `git -C "$WORKTREE" status --porcelain` line. A line is safe when it is a deletion of a path tracked on BASE HEAD (`D ` prefix, `git -C "$WORKTREE" cat-file -e BASE:<path>` confirms it exists on base; stale checkout safe to drop) OR `bash skills/apex-merge/scripts/dirty-classify.sh --is-ignorable <path>` exits 0 (harness state + the auto-generated/regen allowlist - next-env.d.ts, data/model-specs/*.json, .venv, etc.; extend the allowlist IN that script when reflectors flag new patterns). When EVERY line is safe -> auto-force without prompting and record `step-5: auto-force <branch> (deletions-only|auto-generated-only)`. Any real source modification / unrecognized untracked file falls through to the standard AskUserQuestion: `force-remove` (discard) | `keep-worktree` (skip cleanup) | `merge-to-main` (apply the worktree diff onto base + commit, then force-remove - for a cleanup-only branch whose worktree holds uncommitted work worth keeping).
   - `git worktree prune` (mandatory; drains stale admin entries so `git branch -D` succeeds).
   - `git branch -D "$B"`
   - Per-branch incremental append `step-5: <branch> cleaned (worktree+local)` to `<run>-summary.md` (mirrors merge-loop.sh step-4 pattern; partial-abort still leaves a reflector-legible trail). **Append idempotency guard**: before every step-5 line append (auto-force, cleaned, pruned-N-refs), `grep -qF "step-5: <branch>" <run>-summary.md` and skip the append on hit so partial-failure retry of the cleanup loop does not double-write the same per-branch line (step-5 auto-force line duplicated in summary indicating retry without idempotency).
   Remote-delete is batched AFTER the per-branch loop completes. First detect a configured remote (`git remote get-url origin >/dev/null 2>&1`): when ABSENT, skip the deletes and append `step-5: no-remote-configured (Q branches kept local)` once - do NOT emit a `remote-pruned` line (the prior single line conflated "no origin" with "pruned 0 refs"). When PRESENT, per cleaned branch in one tail pass first probe `git ls-remote --exit-code --heads origin "$B"`: a missing ref (never pushed) is counted as skipped - nothing to delete, NOT a failure. Else `git push origin --delete "$B"`, checking each exit code explicitly (never blanket `2>/dev/null || true` - it swallows the failure AND miscounts); count exit-0 deletes into `step-5: pruned-N-refs R/Q`, appended once, plus one `step-5: remote-delete-failed <branches>` line for any real non-zero delete. Hoisting it out of the per-branch body means a guardrail rejection on one remote-delete cannot orphan local cleanup for sibling branches. Branches with a non-integrated status (`skipped-conflict-abort`, `checkout-failed`, `merge-refused`) keep worktree + branch. Final append `step-5: cleaned Q worktrees, kept P (conflict-abort)` to `<run>-summary.md`.

6. **Final push + summary** - inline. VERSION bumping is NOT this step's responsibility; the project-side deploy skill (e.g. `.claude/skills/deploy/` in the project repo) derives the bump tier from the merged commits' types (commit-type buckets) and owns the bump + commit. It works from the integration commits, not session `bump_hint`: manifests are removed with their worktrees at Step 5 cleanup, gone by deploy time.
   - `B=$(git symbolic-ref --short HEAD)`; push ONLY when `git rev-list origin/$B..HEAD` is non-empty - skips the no-op round-trip on a clean zero-branch run. Update `<run>-merge-result.json` per entry: `pushed: true|false|"not-attempted"`.
   - Print + append to `<run>-summary.md`: `step-6: merged N branches, K conflicts auto-resolved, M conflicts manual, P branches skipped, cleaned Q worktrees, pushed-precheck=<yes|no> pushed-merges=<yes|no|skipped>`. The split keeps zero-branch runs unambiguous: a dirty-autocommit push is not an integration push (cluster: merge-zero-branch-artifacts).

6.5. **Cleanup project apex scratch** - inline, unconditional, runs before Step 7 (idempotent; no-op when absent). The main worktree's gitignored `.claude-tmp/apex-active/` + `.claude-tmp/apex-discovery-cache/` accumulate stale per-session manifests, scope pointers, and discovery cache across /apex runs - stale `{session}-scopes/{cc_session_id}.txt` pointers can arm the scope-check hook and block later edits (`resolve-one-conflict.md`). Both are local scratch (gitignored - never tracked or pushed); live /apex sessions run under `.apex-worktrees/<session>/.claude-tmp/`, not here, so wiping main's copies drops only stale state. Run from the main worktree (Step 1 enforces cwd):
   ```bash
   TOP=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
   CLEANED=""
   for d in apex-active apex-discovery-cache; do
     if [[ -n "$TOP" && -d "$TOP/.claude-tmp/$d" ]]; then
       rm -rf "$TOP/.claude-tmp/$d"; CLEANED="${CLEANED:+$CLEANED,}$d"
     fi
   done
   if [[ -n "$CLEANED" ]]; then NOTE="cleaned project apex scratch ($CLEANED)"; else NOTE="nothing to clean"; fi
   echo "step-6.5: $NOTE" >> "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-summary.md"
   ```

7. **Self-reflect** - **No-work gate (cluster: apex-merge-reflector-gate)**: `branches_merged==0` AND `conflicts==0` -> skip the spawn (a bare dirty-main auto-commit is the normal contract, nothing to reflect on); append `## <run> - apex-merge - SKIPPED-no-work - <ts>` via `skills/apex/scripts/append-with-lock.sh`, then sweep. Otherwise: orchestrator routed around a shipped script / skipped a documented step in 1-6.5 -> write `<run>-orchestrator-proposals.md`, one `- gap:`/`- improvement:` pair per deviation, BEFORE the spawn (rolled into reflector gaps/improvements); skip on clean runs. Then spawn `agents/reflector.md` (Sonnet, foreground, `phase=apex-merge`) and sweep this run's artifacts. Spawn-prompt template (substitute `<run>`):

   ```
   You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md and follow the `apex-merge step 7` row of the invocation table. Inputs: `<run>-summary.md` + `<run>-discovery.json` + `<run>-merge-result.json` + (when present) `<run>-orchestrator-proposals.md` + `git log -1 --pretty=%B` for the integration commit.

   Token:    <run>             # 8-hex; used in place of {session}
   Phase:    apex-merge
   Manifest: $HOME/.claude/.claude-tmp/apex-merge-active/<run>.json

   Errors -> ~/.claude/tmp/reflector-errors.log (silent failure otherwise). Shut down silently.
   ```

   After reflector returns, sweep `rm -f "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}"*` (reflector failure does NOT block cleanup; SessionEnd-hook is the orphan fallback - `skills/admin-apex/scripts/session-end-hook.sh`).

## Scope

Merges `apex/*` branches only - pre-rename anything else you want preserved. No multi-base coordination: each branch lands on its own recorded base; cross-base conflicts surface as merge conflicts on the second branch. See spec: `tmp/worktree-migration-spec.md`.
