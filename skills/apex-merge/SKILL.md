---
name: apex-merge
description: Autonomously commit, merge, resolve, validate, clean up, and push APEX worktree branches. Manual only.
---

# /apex-merge

Integration phase for the worktree-isolation model. One `apex/<session>` branch per /apex session; this skill folds them back without user decision points.

## Step 0: queue tasks

```
TaskCreate "1. Precheck"
TaskCreate "2. Discover apex/* branches"
TaskCreate "3. Update base branches"
TaskCreate "4. Merge loop"
TaskCreate "4.5 Replay worktree side-effects"
TaskCreate "4.6 Lint/build cleanup post-conflict"
TaskCreate "5. Cleanup merged branches"
TaskCreate "6. Final push + summary"
TaskCreate "6.5 Cleanup project apex scratch"
TaskCreate "7. Sweep run artifacts"
```

**Deferred-tool guard.** `TaskCreate`/`TaskUpdate`/`TaskList` are deferred - batch-fetch via `ToolSearch select:TaskCreate,TaskUpdate,TaskList` before queuing. If a `TaskCreate` errors (`InputValidationError` / schema-not-loaded), do NOT fire the remaining lines - re-run that ToolSearch load, retry ONCE, then STOP and surface (an empty/flaky ToolSearch return fails every call identically).

## Inputs

- `--branch <name>` (optional): merge only this branch. Default: every `apex/*` local branch.
- Each apex/<session> branch's session manifest at `.apex-worktrees/<session>/.claude-tmp/apex-active/<session>.json` (carries `base_branch`, `branch`, `worktree_path`; its `bump_hint` field is vestigial - not read here or by the deploy skill, see Step 6).

## Completion contract

`/apex-merge` is autonomous end-to-end. Do not call AskUserQuestion. Auto-commit dirty main and apex worktrees, merge every discovered branch, choose and apply the best evidence-backed conflict resolution, run required side effects and checks, clean integrated worktrees/refs, and push. Invocation is explicit confirmation for that documented local/remote apex cleanup and scratch removal; it does not authorize unrelated destructive operations.

`conflict`, `checkout-failed`, `merge-refused`, validation failure, and push rejection are transient states to diagnose and retry, never successful terminal outcomes. Cap any identical recovery loop at three attempts. Stop with the branch/worktree and run artifacts preserved only on a hard boundary: unreadable tool output, corrupt Git state, a destructive or credential-requiring command that violated the side-effect log contract, missing remote authorization, or the same hook/check failure after three targeted fixes. Never skip a branch or claim completion after a hard stop.

## Step contracts

1. **Precheck** - inline. Refuse to run outside the main worktree:
   ```bash
   TOP=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
   COMMON=$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)
   [[ "$TOP" == "$COMMON" ]] || { echo "/apex-merge must run from the main worktree" >&2; exit 1; }
   ```
   Mint the run token before any audit artifact or commit uses it:
   ```bash
   RUN=$(openssl rand -hex 4)
   mkdir -p "$HOME/.claude/.claude-tmp/apex-merge-active"
   ```
   Then disarm the session-record fence for this repo BEFORE any main-tree write (`mint-worktree.sh` arms `$APEX_FENCE_DIR/<cc_session_id>` records so unanchored apex writes cannot leak into MAIN; integration is the sanctioned main-tree writer, and a same-session /apex -> /apex-merge run would otherwise be denied at the auto-commit below):
   ```bash
   FENCE_DIR="${APEX_FENCE_DIR:-$HOME/.claude/tmp/apex-fence}"
   if [[ -d "$FENCE_DIR" ]]; then
     for f in "$FENCE_DIR"/*; do
       [[ -f "$f" ]] || continue
       case "$(head -n 1 "$f" 2>/dev/null)" in
         "$TOP"/.apex-worktrees/*) rm -f "$f" ;;
       esac
     done
   fi
   ```
   Main worktree may be dirty. `.apex-worktrees/` is untracked-by-design (its mode-160000 gitlinks must never be committed). Project `.claude/` + `.claude-tmp/` and every other dirty path are auto-committed without a prompt. Intersect dirty paths with every apex branch's changed-file set and record any fence-leak overlap in the sidecar; overlap is audit evidence, not a reason to skip the commit. The verbatim `git status --porcelain` set lands in `${RUN}-precheck-auto-committed.txt`. The commit MUST NEVER carry `--no-verify`: diagnose a hook failure, apply the smallest fix, and retry up to three times. A pre-existing unmerged index is corrupt input from outside this run and is a hard stop, so conflict markers are never laundered into the precheck commit. First unstage any `.apex-worktrees/*` gitlinks; the follow-on `git add -A` MUST carry `':!.apex-worktrees'`:
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
     # Append short hash + subject for post-hoc audit (no full SHA / --stat - duplicate data).
     git show -s --format='%h %s' HEAD >> "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-precheck-auto-committed.txt"
   fi
   ```

   Reuse `RUN` across all subsequent steps. Then append a one-line audit trace: `step-1: precheck ok (auto-committed N dirty files on main; list -> $HOME/.claude/.claude-tmp/apex-merge-active/<run>-precheck-auto-committed.txt)` if `DIRTY_COUNT > 0` else `step-1: precheck ok (main worktree clean)`, written to `$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-summary.md`. The embedded absolute path points at the sidecar listing every auto-committed path.

2. **Discover** - inline. Enumerate `git for-each-ref --format='%(refname:short)' 'refs/heads/apex/*'`. For each branch B:
   - SESSION = strip `apex/` prefix.
   - WORKTREE = `git worktree list --porcelain | awk -v b="refs/heads/$B" '/^worktree / {wt=$2} $1=="branch" && $2==b {print wt; exit}'` (remember the last-seen worktree, emit on branch match - portable to bash 3.2; avoids the `grep -A2` shifted-map bug).
   - MANIFEST = `$WORKTREE/.claude-tmp/apex-active/$SESSION.json`.
   - BASE = `jq -r .base_branch "$MANIFEST"` (default `main` if absent).
   - Before computing HAS_COMMITS, auto-commit every non-ignored dirty path in WORKTREE onto B with `apex-merge: auto-commit session worktree before integration [run:<run>]`. Exclude `.apex-worktrees` gitlinks, never use `--no-verify`, and retry a targeted hook fix up to three times. Re-read `git status --porcelain` after the commit; repeat up to three stabilization passes so changes produced by the hook also land. A pre-existing unmerged index is a hard stop. This is the last-write sweep that guarantees session work cannot be lost during cleanup.
   - HAS_COMMITS = `git log "$BASE..$B" --oneline` (non-empty -> queue for merge; empty -> queue for cleanup only).
   Write to `$HOME/.claude/.claude-tmp/apex-merge-active/<run>-discovery.json` (same canonical location as the manifest; merge-loop.sh reads/writes the same path). Schema: `{branches: [{branch, base, subject, status}]}` where `status` is `"needs-merge"` (HAS_COMMITS non-empty) OR `"cleanup-only"` (empty). `merge-loop.sh` filters on `status == "needs-merge"` (string compare, NOT a boolean). `--branch <name>` filters to that single branch. For ALL-clean-merge runs (no conflicts at Step 4, no resolver spawn) omit per-entry `worktree_path` + manifest paths (pure overhead). Append `step-2: discovered N branches (M needs-merge, K cleanup-only)` to `<run>-summary.md`.

   **Zero-branch path (N=0)**: NOT a full early-exit. Steps 4/4.5/4.6/5 are natural no-ops - each carries a run-only-when guard, so `merge-loop.sh` / `replay-side-effects.sh` / the step-4.6 lint pass are never invoked; the orchestrator does NOT improvise inline no-ops - it lets each guard self-skip and records the step-N summary lines. Steps 3 (update main) and 6 STILL run, but step 6 push self-gates on local-ahead: Step 1's dirty-main auto-commit is unconditional, so a real local commit reaches origin while a clean zero-branch run skips the gratuitous push round-trip. Also write the sentinel `<run>-merge-result.json` = `[]` when N=0 so the declared artifact set stays complete for audit regardless of branch count.

3. **Update base branches** - inline. `GIT_TERMINAL_PROMPT=0 git fetch origin`, then apply this reconciliation to the current branch and every distinct BASE in discovery. Fast-forward when remote is ahead; when both sides have commits, merge the remote tip instead of refusing or rewriting local commits:
   ```bash
   START_BRANCH="$(git symbolic-ref --short HEAD)"
   while IFS= read -r BRANCH; do
     git checkout "$BRANCH"
     ORIGIN_REF="origin/$BRANCH"
     if ! git rev-parse "$ORIGIN_REF" >/dev/null 2>&1; then
       SUMMARY="step-3: $BRANCH up-to-date (no remote tracking; fetch ran)"
     elif git merge-base --is-ancestor "$ORIGIN_REF" HEAD; then
       SUMMARY="step-3: $BRANCH up-to-date (local at or ahead of $ORIGIN_REF)"
     elif git merge-base --is-ancestor HEAD "$ORIGIN_REF"; then
       OLD=$(git rev-parse HEAD); git merge --ff-only "$ORIGIN_REF"
       SUMMARY="step-3: $BRANCH updated ${OLD}..$(git rev-parse HEAD) (fetch+ff)"
     else
       OLD=$(git rev-parse HEAD)
       git merge --no-ff "$ORIGIN_REF" -m "Merge $ORIGIN_REF before APEX integration"
       SUMMARY="step-3: $BRANCH reconciled ${OLD}..$(git rev-parse HEAD) (fetch+merge)"
     fi
     echo "$SUMMARY" >> "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-summary.md"
   done < <({ printf '%s\n' "$START_BRANCH"; jq -r '.branches[].base' \
     "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-discovery.json"; } | sort -u)
   git checkout "$START_BRANCH"
   ```
   Resolve a Step 3 merge conflict with the same per-file contract as Step 4, then run the narrowest relevant validation before continuing. A non-conflict merge refusal gets three diagnose/fix/retry attempts and then hard-stops. Emit one step-3 summary line per reconciled branch.

4. **Merge loop** - `bash skills/apex-merge/scripts/merge-loop.sh <run>`. Per branch with commits past base:
   - `git checkout "$BASE"`
   - `git merge --no-ff "$B" -m "Merge $B: <subject from git log -1 --pretty=%s $B>"`
   - On conflict: merge-loop.sh prints the conflicted paths and exits 20. **Before resolving EACH conflicted file, Read `skills/apex-merge/resolve-one-conflict.md`**. Apply its autonomous DU/UD/DD or content-resolver path, verify the result, and stage it. The file count is unknown at step start, so reload the contract per iteration.
   - All conflicts resolved -> `GIT_EDITOR=true git merge --continue`.
   - **Exit 2 (two pre-merge guards)**: merge-loop.sh exits 2 from either the wrong-worktree guard (`merge-loop.sh:75`; fires when not invoked from the main worktree) or the dirty-tree gate (`merge-loop.sh:84`; main worktree dirty), both BEFORE any branch is touched - distinct from exit 20 (conflict) / 21 (merge-refused). The two need different recovery: for the dirty-tree case re-run Step 1's filtered auto-commit (unstage `.apex-worktrees` gitlinks -> `git add -A -- ':!.apex-worktrees'` + commit, NEVER `--no-verify`), then re-invoke `merge-loop.sh <run>`; for the wrong-worktree case `cd` to the main worktree and re-invoke (the auto-commit recovery does not apply).
   Per-branch result is recorded in `<run>-merge-result.json`. `merged` is the only successful terminal status. `checkout-failed`, `merge-refused`, and `conflict` trigger diagnosis and up to three retries; they never survive a completed run. After conflict resolution, `git merge --continue`, then run `bash skills/apex-merge/scripts/stamp-merge-result.sh <run> --branch <B> --status merged --decision autonomous --paths <csv>`. The stamp writes `detail="resolver=autonomous"` and the resolver-touched paths that gate Step 4.6. Reinvoke merge-loop to continue remaining branches. It skips a recorded branch only when the current branch tip is already an ancestor of BASE, so a later stabilization commit is merged on the next pass. The orchestrator appends the conflict branch's single `step-4: <branch> merged (conflicts=N resolver=autonomous)` line after stamping; merge-loop owns all non-conflict summary lines.

4.5. **Replay worktree side-effects** - inline, runs ONLY when step 4 merged 1+ branches cleanly (status `merged` exists in `<run>-merge-result.json`). Each apex worktree's executor logged its state-mutating commands to `.claude-tmp/apex-active/{session}-side-effects.jsonl` (migrations, seeders, codegen, etc.); main never saw those runs, so they must replay here before step 5 removes the worktrees. Read this step's contract entirely before running it - it executes shell commands on the main worktree.
   ```bash
   bash skills/apex-merge/scripts/replay-side-effects.sh "$RUN"
   ```
   Script reads every merged branch's side-effects log, dedupes by the whitespace-normalized verbatim `cmd` string, writes `<run>-side-effects-dedup.json` for a non-empty set, and prints each command. Logs may contain only non-destructive, credential-free commands by `agents/executor.md` contract, so run all commands sequentially from the main root without prompting and record `{cmd, exit_code, stderr_tail}` in `<run>-side-effects-replay.json`. Diagnose and retry a failure up to three times. A destructive or credential-requiring entry violates the producer contract and hard-stops without running it or cleaning worktrees. Empty command sets stay silent. Append `step-4.5: replayed K/N (skipped=0)` after a non-empty successful replay.

4.6. **Lint/build cleanup post-conflict** - inline, runs ONLY when step 4 resolved 1+ conflicts (clean-merge-only runs skip; union of two clean diffs cannot introduce a lint regression neither side had). Merge resolution stitches code at the file level and can leave unused imports / unreferenced symbols / lint regressions neither side carried alone; run one lint/fix pass on main. Run from the main worktree (precheck Step 1 already enforces cwd):
   ```bash
   RESOLVED_CONFLICTS=$(jq -r '.[] | select(.status=="merged") | (.detail // "")' \
     "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-merge-result.json" 2>/dev/null \
     | grep -c 'resolver=' || true)
   ```
   `RESOLVED_CONFLICTS == 0` -> silent skip + `step-4.6: skipped (no conflicts to fix)`. `RESOLVED_CONFLICTS >= 1` -> count the lintable resolver-touched files (markdown-only resolutions skip the lint pass entirely):
   ```bash
   # Conflict-touched paths from this run's merge-result (status=merged AND detail names a resolver
   # hop), filtered to lintable extensions only (.ts|.tsx|.js|.jsx|.mjs|.cjs|.json).
   # Single-pass flatten: the prior two-stage form (jq -r .paths | jq -Rs split) re-parsed
   # pretty-printed array lines ('"file.ts",'), so the extension test never matched.
   LINTABLE=$(jq '[.[] | select(.status=="merged") | select((.detail // "") | test("resolver=")) | .paths // [] | .[]
        | select(test("\\.(ts|tsx|js|jsx|mjs|cjs|json)$"))] | length' \
     "$HOME/.claude/.claude-tmp/apex-merge-active/${RUN}-merge-result.json")
   ```
   `LINTABLE == 0` (every resolver hop was markdown-only) -> record `step-4.6: skipped (no lintable resolver-touched files)`. Otherwise run the project's own lint + typecheck scoped to the resolver-touched files. On failure dispatch ONE `agents/executor.md` (Sonnet, standalone mode, main root as `project_root`) with verbatim errors and edits confined to resolver-touched files; cap at three fix attempts. A persistent failure hard-stops before cleanup and preserves run artifacts. Never proceed with a known red conflict resolution.

5. **Cleanup merged branches** - inline. For each branch that integrated - merge-result status `merged`, plus the `cleanup-only` branches from `<run>-discovery.json` (no commits past base, already current) - run in THIS order (worktree removal must precede branch deletion):
   - Recheck worktree status. When every line is a stale tracked deletion or `dirty-classify.sh --is-ignorable` path, auto-force removal and record the classification. Never discard real source or an unrecognized untracked path: commit it onto B, rerun Steps 4 through 4.6 for B, then recheck. Cap this stabilization loop at three; persistent new writes hard-stop with the worktree intact.
   - `git worktree remove "$WORKTREE"` (use force only for the classified safe set above).
   - `git worktree prune` (mandatory; drains stale admin entries so branch deletion succeeds).
   - Verify `git merge-base --is-ancestor "$B" "$BASE"`, then `git branch -d "$B"`. Never force-delete a branch whose tip is not integrated; return it to Step 4.
   - Per-branch incremental append `step-5: <branch> cleaned (worktree+local)` to `<run>-summary.md` so a hard stop leaves a legible audit trail. Before every step-5 line append, use `grep -qF "step-5: <branch>" <run>-summary.md` to keep retries idempotent.
   Batch remote deletion after the loop. Probe each ref first; delete only a branch verified integrated into its recorded base, and check every exit code. A missing ref is already clean. A remote failure is retried up to three times, then hard-stops and reports the retained ref. Final append: `step-5: cleaned Q worktrees and local branches, pruned R remote refs`.

6. **Final push + summary** - inline. VERSION bumping is NOT this step's responsibility; the project-side deploy skill (e.g. `.claude/skills/deploy/` in the project repo) derives the bump tier from the merged commits' types (commit-type buckets) and owns the bump + commit. It works from the integration commits, not session `bump_hint`: manifests are removed with their worktrees at Step 5 cleanup, gone by deploy time.
   - For the starting branch and every distinct BASE in discovery, push with `GIT_TERMINAL_PROMPT=0` only when that local branch is ahead of its remote. On a non-fast-forward rejection, fetch, merge the remote tip through the same autonomous conflict contract, validate, and retry up to three times. Missing authorization is a hard stop. Update each result entry with `pushed: true|"not-attempted"`; `false` is never a completed state.
   - Print + append: `step-6: merged N branches, resolved K conflicts autonomously, cleaned Q worktrees, pushed-precheck=<yes|no> pushed-merges=<yes|no|skipped>`. A completed run has no skipped branches or manual conflicts.

6.5. **Cleanup project apex scratch** - inline, unconditional, runs before Step 7 (idempotent; no-op when absent). The main worktree's gitignored `.claude-tmp/apex-active/` + `.claude-tmp/apex-discovery-cache/` accumulate stale per-session artifacts (including leftovers from earlier apex generations). Both are local scratch (gitignored - never tracked or pushed); live /apex sessions run under `.apex-worktrees/<session>/.claude-tmp/`, not here, so wiping main's copies drops only stale state. Run from the main worktree (Step 1 enforces cwd):
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

7. **Sweep run artifacts** - inline. The run's `<run>-*` files (summary, discovery, merge-result, dedup/replay, precheck sidecar) are scratch with no post-run consumer:
   ```bash
   rm -rf "$HOME/.claude/.claude-tmp/apex-merge-active"
   ```
   Removing the whole dir also drains leftovers from an earlier hard-stopped run; a hard stop before this step intentionally preserves its artifacts for post-mortem. Step 1 recreates the dir.

## Scope

Merges `apex/*` branches only - pre-rename anything else you want preserved. No multi-base coordination: each branch lands on its own recorded base; cross-base conflicts surface as merge conflicts on the second branch.
