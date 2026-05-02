---
name: admin-apex
description: APEX expert / associate. Maintains the apex framework itself - syncs spec docs to real files, evolves the skill set (create/rename/split/merge/retire), validates apex-scoped scripts and schemas, bumps VERSION, commits ~/.claude (private), mirrors apex-framework files to /Users/mael/dev/apex-framework (public), pushes both. Manually triggerable. Reflector-log consolidation lives in /apex-improve (called by /apex-eod step 3); weekly tech-watch lives in /apex-tech-watch.
---

# /admin-apex

Apex internals administrator. Out-of-band - not part of /apex hot path. No project app code, no project-wide build/lint.

Two-repo model: `~/.claude` is the **private** working tree (personal config + apex framework). `/Users/mael/dev/apex-framework` is the **public** mirror (apex framework only). Every commit produced by this skill is replicated to the public mirror via task 10 (allowlisted paths only) and both repos are pushed alongside. Pushes happen ONLY via task 10.

Per-run artifacts live under `.claude-tmp/admin-apex-active/{run}-*` (mirrors apex-active). `{run}` token = `openssl rand -hex 4`, minted at task 1; swept by `scripts/cleanup-run.sh` at SessionEnd (manifest-matched), task 10 (post mirror+push), or task 9's no-commit branch.

Inputs: `skills/apex/**`, `skills/admin-apex/**`, `agents/**`, `apex-core.md`, `apex-core-overview.md`, `README.md`, `settings.json`, repo-root `CLAUDE.md`, `VERSION`.

Self-coverage: admin-apex's own files (`skills/admin-apex/**`) are subject to the same audit + evolve rules as the apex hot path. The 150-line cap on `.md`, the orphan-refs / missing-refs / schema-mismatch / dead-hook detectors, and the doc_only / structural classification used by task 9's bump rule all apply to admin-apex too. Task 11 closes the loop by feeding reflection signals into `~/.claude/tmp/apex-workflow-improvements.md`, which `/apex-improve` consumes to evolve admin-apex like any other apex file.

Per-task summary trace: every task that runs (1-10) appends one line to `.claude-tmp/admin-apex-active/{run}-summary.md` in the format `task-{N}: <outcome>` (e.g., `task-3: drift 2 clusters (oversized, orphan)`, `task-6: applied 4 ops, drift=none`, `task-8: test pass`). Captures friction the JSON artifacts do not (gate dismissals, mid-flight drift `restart`, test failure auto-fix loops). Read by task 11's reflector.

Private-tracked roots auto-staged by task 9 in addition to evolve dirty paths (private to `~/.claude`, NEVER mirrored to public): `plugins/`, `statusline/`, `tmp/`. The closed allowlist in `scripts/mirror-to-dev.sh` excludes these from public.

## Step 0: TaskCreate the chain

Each line is one `TaskCreate(subject, description)`. Tasks run in TaskCreate order; `TaskCreate` has no `blockedBy` parameter (sequential by construction).

```
TaskCreate "1. Mode select"          (inline AskUserQuestion)
TaskCreate "2. Inventory snapshot"   (scripts/inventory-apex.sh)
TaskCreate "3. Audit drift"          (audit.md)
TaskCreate "4. Audit gate"           (inline AskUserQuestion per cluster)
TaskCreate "5. Evolve plan"          (evolve.md task 5)
TaskCreate "6. Apply evolve"         (evolve.md task 6)
TaskCreate "7. Sync docs"            (sync-docs.md)
TaskCreate "8. Test apex scripts"    (scripts/test-apex-scripts.sh)
TaskCreate "9. VERSION + commit"     (scripts/_bump-version.sh + git)
TaskCreate "10. Mirror + push both"  (scripts/mirror-to-dev.sh)
TaskCreate "11. Self-reflect"        (agents/reflector.md --phase admin-apex)
```

Tasks 5-8 are conditional on task 4's gate (skipped on audit-only outcome). Task 9 still runs to capture private-tracked-root deltas; if nothing ends up staged, task 9 produces no commit and task 10 is skipped. Task 11 fires only on task 10 success (the no-commit and hard-stop branches let `cleanup-run.sh` sweep without reflection - those branches lack the post-commit git context the reflector reads).

## Task 1: Mode select

AskUserQuestion (header: "admin-apex mode"; options: `audit-only`, `audit+apply`; dismiss/cancel = abort). Then run `bash skills/admin-apex/scripts/check-deps.sh` - exit 1 means strict Python deps (currently `jsonschema`) are missing; surface the script's stderr install one-liner to the user and abort cleanly (no manifest written yet, no session-end-hook needed). Exit 0 -> proceed.

Mint `{run}` (`openssl rand -hex 4`), `mkdir -p .claude-tmp/admin-apex-active`, resolve `cc_session_id` via `bash skills/apex/scripts/get-cc-session-id.sh` (env-then-jsonl resolver - aborts on failure; NEVER default to empty, since an empty `cc_session_id` makes `session-end-hook.sh` unable to ever match this manifest), and capture parent Claude Code PID as `$PPID`. **Write** `.claude-tmp/admin-apex-active/{run}.json` with `{"run":"{run}","cc_session_id":"<resolved>","pid":<PPID>,"producer":"admin-apex"}`. The `cc_session_id` arms `scripts/session-end-hook.sh` to sweep this run's artifacts when the CC session ends (covers hard-stops, soft-skips, mid-flight rollback, abort, dismiss); the `pid` arms `scripts/sweep-stale-runs.sh` to drain orphans from prior crashed sessions.

Then run `bash skills/admin-apex/scripts/sweep-stale-runs.sh` (best-effort; idempotent). It cleans only sibling manifests where the recorded PID is dead OR `ps -o comm=` does not match `claude` - active sibling sessions are preserved (mirrors `apex/scripts/create-session.sh` PID classification).

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

Mid-flight drift: see `evolve.md` lines 53-57 for the `restart | commit-partial | rollback` contract (rollback is the only admin-apex codepath that runs `git restore`).

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
- `patch` (0.2.1 -> 0.2.2): every applied op has `doc_only: true` (regardless of kind)
- `minor` (0.2.1 -> 0.3.0): any structural-mutation kind (create/rename/split/merge/retire, schema-add/schema-remove, hook-add/hook-remove) OR any `edit` op with `doc_only: false` (touches skills/agents/scripts/schemas/settings)
- no bump: soft-skip outcome (only private-tracked-root deltas, no evolve ops) OR nothing staged (no commit)

```
bash skills/admin-apex/scripts/admin-apex-finalize.sh \
  --run {run} --bump {kind} --message "<one-liner>" --body "<op-list>"
```

Caller decides `{kind}` per the bump rule above (read `{run}-applied-ops.json` to classify). Branch on exit code:
- `0` -> commit created; proceed to task 10
- `10` -> nothing staged; finalize.sh already invoked `cleanup-run.sh`; skip task 10
- `1` -> bad args / defensive-validation failure; surface to user
- `2` -> commit failure; artifacts left for inspection; surface to user

NO push here (task 10 owns pushes). VERSION is appended to `{run}-dirty-paths.txt` so task 10's mirror sees it without a special-case.

## Task 10: Mirror + push both

```
bash skills/admin-apex/scripts/mirror-to-dev.sh "{run}"
```

See `scripts/mirror-to-dev.sh:13-54` for allowlist, path mapping, and exit codes (3-7). On success: proceed to task 11 (reflector); cleanup is deferred until after task 11 returns. On failure: leave artifacts; surface the script's exit code to the user; skip task 11 (no successful run to reflect on).

To inspect without pushing during development: `APEX_MIRROR_NO_PUSH=1 bash skills/admin-apex/scripts/mirror-to-dev.sh "{run}"`.

## Task 11: Self-reflect

Spawn `agents/reflector.md` (Haiku, foreground) with the admin-apex phase. The agent reads its own contract for input/output shape (table row `admin-apex task 11`); this skill supplies only the run-specific context. The reflector's appended block in `~/.claude/tmp/apex-workflow-improvements.md` is consumed by `/apex-improve`'s next run, which can target `skills/admin-apex/**` in `target_files` - closing the self-improvement loop.

Spawn-prompt template (substitute `{run}`):

```
You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md and
follow the `admin-apex task 11` row of the invocation table. No reflect-traces.sh
heuristic block exists for this phase; inputs are this run's summary trace + JSON
artifacts plus `git diff --stat HEAD~1` and `git log -1 --pretty=%B`.

Token:    {run}             # 8-hex; used in place of {session}
Phase:    admin-apex
Manifest: $HOME/.claude/.claude-tmp/admin-apex-active/{run}.json   # absolute on purpose: subagent CWD != ~/.claude breaks relative paths (see agents/reflector.md "CWD discipline").

Errors -> ~/.claude/tmp/reflector-errors.log (silent failure otherwise).
Shut down silently (no main-session output).
```

After reflector returns, invoke `bash skills/admin-apex/scripts/cleanup-run.sh --run {run} --post-success`. The `--post-success` flag bypasses cleanup-run.sh's 60s in-flight mtime guard, which would otherwise refuse cleanup (the just-written `{run}-summary.md` keeps the guard armed) and defer to SessionEnd. Task 11 has authoritative knowledge that mirror-to-dev.sh succeeded, so the guard's defensive purpose (sibling SessionEnd misfire / eager mid-write cleanup) does not apply on this codepath. Reflector failure does NOT block cleanup - the agent self-silences per its contract.

## Out of scope

Reflector log consolidation (owned by `/apex-improve`, called by `/apex-eod` step 3); weekly tech-watch fetching (owned by `/apex-tech-watch`); project app code/build/lint/tests; major version bumps; full reconciliation between private and public repos (task 10 mirrors only this run's dirty paths, not the whole tree).

See `audit.md`, `evolve.md`, `sync-docs.md` for per-task contracts; `schemas/inventory.schema.json` + `schemas/evolve-plan.schema.json` for artifact shapes; `skills/apex/shared-guardrails.md` for the broader apex conventions admin-apex follows.
