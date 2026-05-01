---
name: sync-git
description: apex-improve Steps 7-8 - VERSION + commit + mirror + push at session end. Standalone-mode only (skipped under apex-eod). Reuses admin-apex's admin-apex-finalize.sh + mirror-to-dev.sh as the single source of truth so apex-improve and admin-apex stay byte-for-byte identical on commit + mirror behavior.
---

# sync-git (apex-improve Steps 7-8)

Spec: `skills/apex-improve/SKILL.md` Steps 7-8.

## When to run

Run only when ALL of:

- Standalone mode (subagent prompt did NOT contain "do NOT commit or push" - apex-eod always emits this line at Step 3 of apex-eod/SKILL.md).
- Step 4 produced `>=1` op in `{run}-applied-ops.json` (zero ops -> nothing to commit).
- Step 5 cleanup completed (the CC version-stamp + workflow-improvements archive happen there; sync-git assumes those files have already settled).

If any condition fails, skip both Steps 7 and 8 and exit cleanly.

## Step 7: VERSION + commit

Mirrors admin-apex SKILL.md task 9. Read `{run}-applied-ops.json` to classify the bump:

| Bump | Condition |
|------|-----------|
| `patch` | every applied op has `doc_only: true` |
| `minor` | any structural-mutation kind (`split`/`rename`/`retire`/`create`/`merge`/`schema-add`/`schema-remove`/`hook-add`/`hook-remove`) OR any `edit` op with `doc_only: false` |
| `none`  | (unreachable here - the `>=1 op` precondition above already gates this case) |

Compose a one-line commit message + multi-line body listing the applied ops, then call:

```
bash skills/admin-apex/scripts/admin-apex-finalize.sh \
  --run {run} --bump {kind} --message "<one-liner>" --body "<op-list>"
```

Branch on exit code:

- `0`  -> commit created; proceed to Step 8.
- `10` -> nothing staged; finalize.sh already invoked `cleanup-run.sh`; skip Step 8 (no commit context to mirror against).
- `1`  -> bad args / defensive-validation failure; surface stderr to user; skip Step 8.
- `2`  -> commit failure; artifacts left for inspection; surface stderr to user; skip Step 8.

`admin-apex-finalize.sh` appends `VERSION` to `{run}-dirty-paths.txt` after a successful bump, so Step 8's mirror picks it up without any special-case wiring (this is the same wiring admin-apex task 10 relies on - single mirror-to-dev.sh contract, two callers).

NO push here - Step 8 owns pushes. Pre-existing private-tracked roots (`plugins/`, `statusline/`, `tmp/`) are auto-staged by `admin-apex-finalize.sh` per its private-allowlist; that is intentionally shared with admin-apex (private-only paths, never mirrored).

## Step 8: Mirror + push both

Mirrors admin-apex SKILL.md task 10. Skip if Step 7 was skipped or returned non-zero.

```
bash skills/admin-apex/scripts/mirror-to-dev.sh "{run}"
```

The script reads `{run}-dirty-paths.txt` + `{run}-docs-changed.txt`, applies the closed allowlist (`skills/apex/**`, `skills/admin-apex/**`, `skills/apex-improve/**`, `skills/apex-tech-watch/**`, `agents/**`, `VERSION`, `apex-core.md`, `apex-core-overview.md`), copies survivors to the public mirror (default `/Users/mael/dev/apex-framework`), commits with the same message as the just-made `~/.claude` commit, then pushes the public repo first and `~/.claude` second.

Exit codes (caller surfaces these to the user; do not retry):

- `0` -> mirrored + pushed (or nothing-to-do).
- `2` -> bad args.
- `3` -> public mirror dir not found.
- `4` -> git add failed in public.
- `5` -> git commit failed in public.
- `6` -> git push failed in public.
- `7` -> git push failed in private.

Inspect-without-pushing during development: `APEX_MIRROR_NO_PUSH=1 bash skills/admin-apex/scripts/mirror-to-dev.sh "{run}"` (commits in both repos but skips both pushes).

## Cleanup

`cleanup-run.sh` is NOT called from Step 8 - the manifest's `cc_session_id` arms `skills/admin-apex/scripts/session-end-hook.sh` to sweep this run's artifacts when the CC session ends. Calling cleanup eagerly here would race with deferred-findings preservation (`{run}-deferred-findings.json` survives across runs).

The no-commit branch (Step 7 exit 10) DOES call `cleanup-run.sh` internally via `admin-apex-finalize.sh` line 124 - that branch leaves no commit context to defer, so eager cleanup is correct there.

## What this step does NOT do

- Does NOT decide whether to skip standalone mode on its own - that gate lives in `SKILL.md` (the subagent-prompt directive check).
- Does NOT overwrite the bump rule with a "compare upstream tags" or "ask the user" step - the rule is byte-for-byte identical to admin-apex SKILL.md task 9 so the two flows produce identical version semantics.
- Does NOT push only one repo (public OR private) - both push together; on per-repo push failure the script exits 6 or 7 and leaves the other repo untouched (mirror-to-dev.sh's behavior).
- Does NOT mirror outside the closed allowlist - `skills/apex-eod/**`, `skills/apex-fix/**`, etc. stay private to `~/.claude` regardless of how Step 4 modified them.

See `skills/admin-apex/SKILL.md` tasks 9-10 for the canonical contract; `skills/admin-apex/scripts/admin-apex-finalize.sh` and `skills/admin-apex/scripts/mirror-to-dev.sh` for the implementation; `skills/apex-improve/SKILL.md` Steps 7-8 stub for the apex-improve entry point.
