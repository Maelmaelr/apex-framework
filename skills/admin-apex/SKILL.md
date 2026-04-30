---
name: admin-apex
description: APEX expert / associate. Maintains the apex framework itself - syncs spec docs to real files, evolves the skill set (create/rename/split/merge/retire), validates apex-scoped scripts and schemas, bumps VERSION, commits ~/.claude (private), mirrors apex-framework files to /Users/mael/dev/apex-framework (public), pushes both. Manually triggerable. Reflector-log consolidation is out of scope (future /apex-improve).
---

# /admin-apex

Apex internals administrator. Out-of-band - not part of /apex hot path. No project app code, no project-wide build/lint.

Two-repo model: `~/.claude` is the **private** working tree (personal config + apex framework). `/Users/mael/dev/apex-framework` is the **public** mirror (apex framework only). Every commit produced by this skill is replicated to the public mirror via task 10 (allowlisted paths only) and both repos are pushed alongside. Pushes happen ONLY via task 10.

Per-run artifacts live under `.claude-tmp/admin-apex-active/{run}-*` (mirrors apex-active). `{run}` token = `openssl rand -hex 4`, minted at task 1; cleaned by task 10 after successful push (or by task 9 if task 10 is skipped); left in place on abort.

Inputs: `skills/apex/**`, `agents/**`, `apex-core.md`, `apex-core-overview.md`, `README.md`, `settings.json`, repo-root `CLAUDE.md`, `VERSION`.

Private-tracked roots (auto-staged by task 9 in addition to evolve dirty paths; private to `~/.claude`, NEVER mirrored to public): `plugins/`, `statusline/`, `tmp/`. The closed allowlist in `scripts/mirror-to-dev.sh` already excludes these from public; task 9 uses `git add` (which respects `.gitignore`) so transient files - flock targets, runtime caches - stay out.

## Step 0: TaskCreate the chain

```
TaskCreate "1. Mode select"          - inline AskUserQuestion
TaskCreate "2. Inventory snapshot"   - blockedBy [1] - scripts/inventory-apex.sh
TaskCreate "3. Audit drift"          - blockedBy [2] - audit.md
TaskCreate "4. Audit gate"           - blockedBy [3] - inline AskUserQuestion per cluster
TaskCreate "5. Evolve plan"          - blockedBy [4] - evolve.md (task 5)
TaskCreate "6. Apply evolve"         - blockedBy [5] - evolve.md (task 6)
TaskCreate "7. Sync docs"            - blockedBy [6] - sync-docs.md
TaskCreate "8. Test apex scripts"    - blockedBy [7] - scripts/test-apex-scripts.sh
TaskCreate "9. VERSION + commit"     - blockedBy [8] - scripts/_bump-version.sh + git
TaskCreate "10. Mirror + push both"  - blockedBy [9] - scripts/mirror-to-dev.sh
```

Tasks 5-8 are conditional on task 4's gate (skipped on audit-only outcome). Task 9 still runs to capture private-tracked-root deltas; if nothing ends up staged, task 9 produces no commit and task 10 is skipped.

## Task 1: Mode select

AskUserQuestion (header: "admin-apex mode"; options: `audit-only`, `audit+apply`; dismiss/cancel = abort). Then mint `{run}` and `mkdir -p .claude-tmp/admin-apex-active`.

## Task 2: Inventory snapshot

`bash skills/admin-apex/scripts/inventory-apex.sh --out .claude-tmp/admin-apex-active/{run}-inventory.json`. Non-zero exit -> abort with explicit error (state corruption; no fallback).

## Task 3: Audit drift

Read and follow `skills/admin-apex/audit.md`. Produces `{run}-drift-report.json`.

## Task 4: Audit gate

Read drift report. Hard-stops (skip 5-10, exit 0, no commit, even if private deltas exist):
- mode == `audit-only` (user explicitly asked for inspection only)
- any cluster has `kind == stale-spec` (state is racing; do not commit anything from this run)

Soft-skips (skip 5-8 only; task 9 still runs to capture private-tracked-root deltas):
- `clusters: []` (clean)
- every cluster decision is `keep`/`defer`

Otherwise, AskUserQuestion per cluster (header: cluster.kind; options: `keep | apply | defer`; dismiss = `keep`). At least one `apply` -> proceed to task 5. All `keep`/`defer` -> soft-skip to task 9.

## Task 5 / 6: Evolve

Read and follow `skills/admin-apex/evolve.md`. Task 5 composes `{run}-evolve-plan.json`; task 6 applies ops, producing `{run}-applied-ops.json` + `{run}-dirty-paths.txt`.

Mid-flight drift surfaces AskUserQuestion (`restart | commit-partial | rollback`) per evolve.md:
- `restart` -> abort current run (user re-invokes `/admin-apex`)
- `commit-partial` -> proceed to task 7 with ops-so-far
- `rollback` -> `git restore` on `{run}-dirty-paths.txt`, exit cleanly (only admin-apex codepath that runs `git restore`; explicit user gate)

## Task 7: Sync docs

Read and follow `skills/admin-apex/sync-docs.md`. Produces `{run}-docs-changed.txt`.

## Task 8: Test apex scripts

`bash skills/admin-apex/scripts/test-apex-scripts.sh`. Non-zero -> AskUserQuestion (header: "Test failure"):
- `auto-fix` -> re-enter evolve.md task 6 scoped to failing files
- `rollback-evolve` -> `git restore` on `{run}-dirty-paths.txt`, exit cleanly
- `abort` -> exit cleanly without rollback (preserve dirty state for inspection)
- Dismiss / cancel = `abort`

## Task 9: VERSION + commit

Bump rule (only applies when evolve ran in tasks 5-8 and produced applied ops):
- `patch` (0.2.1 -> 0.2.2): every applied op has `doc_only: true`
- `minor` (0.2.1 -> 0.3.0): any structural mutation (file create/rename/split/merge/retire, schema add/remove, hook add/remove)
- no bump: soft-skip outcome (only private-tracked-root deltas, no evolve ops) OR nothing staged (no commit)

```
# Bump VERSION only if evolve ran and applied ops exist
if [[ -s .claude-tmp/admin-apex-active/{run}-applied-ops.json ]]; then
  new=$(bash skills/admin-apex/scripts/_bump-version.sh patch)   # or minor
  echo VERSION >> .claude-tmp/admin-apex-active/{run}-dirty-paths.txt
fi

# Stage evolve dirty paths (if any)
[[ -s .claude-tmp/admin-apex-active/{run}-dirty-paths.txt ]] && \
  xargs git add -- < .claude-tmp/admin-apex-active/{run}-dirty-paths.txt
[[ -s .claude-tmp/admin-apex-active/{run}-docs-changed.txt ]] && \
  xargs git add -- < .claude-tmp/admin-apex-active/{run}-docs-changed.txt

# Stage private-tracked roots (always; respects .gitignore so transient files stay out)
git add -- plugins/ statusline/ tmp/

# Commit only if anything is staged
if ! git diff --cached --quiet; then
  git commit -m "admin-apex: <one-line summary>" -m "- <op>: <target> [-> <rename_to>]"
fi
```

VERSION is appended to `{run}-dirty-paths.txt` (not staged separately) so task 10's mirror sees it without a special-case. `xargs ... < file` (input redirection) used instead of `xargs -a file` for macOS BSD-xargs portability. The `git add -- plugins/ statusline/ tmp/` line covers both modified-tracked and untracked files; `.gitignore` keeps lock targets / runtime caches out.

NO push here (task 10 owns pushes). On commit failure: leave artifacts; surface to user. Cleanup of `.claude-tmp/admin-apex-active/{run}-*` defers to task 10 (after successful mirror+push) so the mirror script can read the run's dirty-paths/docs-changed files.

If task 9 produced no commit (nothing staged after both evolve + private-roots staging), skip task 10 and clean up artifacts here instead.

## Task 10: Mirror + push both

Replicates this run's allowlisted changes from `~/.claude` into the public mirror at `/Users/mael/dev/apex-framework`, commits there with the same message as the task 9 commit, then pushes the public repo first and `~/.claude` second.

```
bash skills/admin-apex/scripts/mirror-to-dev.sh "{run}"
```

The script applies an allowlist (see header docstring): `skills/apex/**`, `skills/admin-apex/**`, `agents/**`, `VERSION`, `apex-core.md`, `apex-core-overview.md`. Anything else (including `settings.json`, `CLAUDE.md`, `skills/README.md`, and the private orchestration skills `skills/apex-eod/**`, `skills/apex-fix/**`, `skills/apex-init/**`, `skills/apex-file-health/**`, `skills/apex-lessons-analyze/**`, `skills/apex-lessons-extract/**`) is private to `~/.claude` and silently skipped.

Path mapping is identity (`~/.claude/<path>` -> `/Users/mael/dev/apex-framework/<path>`). Deletions in `~/.claude` propagate as deletions in the public mirror. Untouched files in the public mirror are left alone (per-run mirror, NOT a full reconciliation - one-time reconciliations happen out-of-band).

On script success: `rm -rf .claude-tmp/admin-apex-active/{run}-*`. On script failure: leave artifacts; surface to user with the script's exit code (3 = mirror dir missing, 4 = git add failed in public, 5 = git commit failed in public, 6 = push failed in public, 7 = push failed in private).

To inspect without pushing during development: `APEX_MIRROR_NO_PUSH=1 bash skills/admin-apex/scripts/mirror-to-dev.sh "{run}"`.

## Out of scope

Reflector log consolidation (future `/apex-improve`); project app code/build/lint/tests; major version bumps; scheduled runs; full reconciliation between private and public repos (task 10 mirrors only this run's dirty paths, not the whole tree).

See `audit.md`, `evolve.md`, `sync-docs.md` for per-task contracts; `schemas/inventory.schema.json` + `schemas/evolve-plan.schema.json` for artifact shapes; `skills/apex/shared-guardrails.md` for the broader apex conventions admin-apex follows.
