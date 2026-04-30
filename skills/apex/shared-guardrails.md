---
name: shared-guardrails
description: Cross-cutting rules referenced by every apex skill and agent. Single source of truth for safety paths, scope-check hook resolution, scope-write producers, manifest schema, trace path schema, JSON Schema validation, and mid-/apex abort cleanup.
---

# Shared guardrails

This file consolidates the cross-cutting rules from `apex-core.md` "Conventions" and "Failure handling". Every other skill / agent file in this repo should reference back here rather than duplicating these rules.

## Standard safety paths (always allowed in any scope artifact)

Closed set:
- `.claude-tmp/`
- `~/.claude/tmp/`
- `/tmp/{session}-*`
- project `docs/**`
- any `README*` file at any depth

Never includes `.env*` or `.git/`.

## Session token format

8-char lowercase hex (`openssl rand -hex 4`). Tight enough that cleanup glob `*{session}*` cannot substring-match unrelated files.

## Session manifest schema

`.claude-tmp/apex-active/{session}.json`:
```
{session, pid, cc_session_id, p2_cc_session_id?}
```
- `pid` and `cc_session_id` are NEVER overwritten
- `p2_cc_session_id` appended by `p2.md` after the p2.0c context clear
- Reflectors locate TaskList at `~/.claude/todos/{id}-agent-{id}.json` using `cc_session_id` (entry-flow / Path 1) or `p2_cc_session_id` (p2.5)

## Scope write producers (single source of truth per artifact)

`{session}-main-scope.json` - exactly one fires per session:
- trivial path -> step 5 inline orchestrator `Write` tool
- zero-layer proceed -> step 6.a inline orchestrator `Write` tool
- normal path -> `verify-claims.sh` (default mode or `--apply-resolved`)

`{session}-{teammate-id}-scope.json` - written only by `teammates.md` at p2.1.

## scope-check hook resolution

PreToolUse on `Edit` / `Write` / `MultiEdit` / `NotebookEdit`. Resolves active scope via on-disk pointer `.claude-tmp/apex-active/{session}-scopes/{session_id}.txt` (single line: absolute path to scope JSON). Hook globs `.claude-tmp/apex-active/*-scopes/{session_id}.txt` to find the matching pointer. Pass-through if no pointer matches.

Pointer writers:
- main orchestrator after each scope write -> `{session}-scopes/{cc_session_id}.txt`
- p2 orchestrator at p2.0 -> `{session}-scopes/{p2_cc_session_id}.txt` (also points at main scope)
- each teammate at its own p1.0 (under `--teammate`) -> `{session}-scopes/{teammate_cc_session_id}.txt`

Bash file ops (`sed -i`, redirection, `tee`, `cp`, `mv`) NOT gated - prompt-layer convention only.

## verify-claims.sh modes (exit-code priority 1 > 2 > 3 > 0)

Default mode (no flag): runs the full claim verification pass and dispatches via exit code.

| Exit | Meaning | abort_cause (stderr) |
|------|---------|----------------------|
| 0 | proceed - scope written as last action | - |
| 1 | abort | `preflight_bad` OR `screened_unconverged` |
| 2 | re-run 6c+7 (cap 1 via `{session}-verify-rerun.json`) | - |
| 3 | inline review - orchestrator writes `claim-review-resolved-{session}.json`, re-invokes `--apply-resolved` | - |

`--apply-resolved` mode: skips re-validation (claims already validated), re-reads `screened-{session}.json` + `claim-review-resolved-{session}.json`, re-adds `keep` claims to screened, and unconditionally writes `{session}-main-scope.json` as its last action (exits 0). Used by orchestrator after exit-3 inline review.

## Trace path schema

`.claude-tmp/apex-active/{session}-traces/{phase}/{agent}[-{disambiguator}].md`

Phases: `entryflow` (screener, rescout) | `p1` (executor + main p1.2 fix-attempts) | `p2` (executor incl. teammate executors + central p2.3 fix-attempts).

Disambiguator: shard-id, task-id, teammate-id, teammate-id-task-id, attempt-N (dash-joined).

Screener and rescout always carry `attempt-N` (preserves both passes on exit-2 re-run).

Trace writers: `executor.md`, `screener.md`, `rescout.md`. Non-trace: shard, verify, learn, documentation, git, reflector.

## JSON Schema validation

Schemas at `skills/apex/schemas/*.schema.json` (this dev repo) - canonical install path is `~/.claude/skills/apex/schemas/`. Producer validates before write; consumer validates before read.

Validation failure handling:
- Producer: aborts with explicit error to stderr (catches malformed output at source)
- Consumer: treats invalid artifact as missing -> triggers the relevant gate-handling path (e.g., `verify-claims.sh` reading invalid `screened-{session}.json` -> exit-2 re-run; `p1.md` reading invalid `preflight-{session}.json` -> hard abort with state-corruption signal)

Validated artifacts: see `apex-core.md` "Artifact validation" section for the full list.

## Mid-/apex abort cleanup

Any orchestrator exit bypassing p1.5/p2.6 runs `scripts/session-end-hook.sh {session}` inline. Triggers:
- verify exit-1 abort (`preflight_bad` or `screened_unconverged`)
- AskUserQuestion-abort at step 2 / 6.a zero-layer / 6.b / p1.0 / p2.0
- zero-layer "no validated paths" abort
- teammate-failure abort
- plan-mode rejection at p2.0c

`session-end-hook.sh` wraps `cleanup-session.sh` + removes `{session}-hypothesis.json` (belt-and-suspenders).

## Project-specific hooks (additive to v1.0)

Wired in `settings.json` alongside the spec hooks. Layered on top of `scope-check-hook.sh` (do not replace it). Listed here so future contributors reading the spec can discover them.

| Hook | Matcher | Purpose |
|------|---------|---------|
| `block-destructive-hook.sh` | PreToolUse Bash | Blocks `git checkout --`, `git show`/`cat-file > file`, `rm -rf`, shell credential reads (CLAUDE.md Git Safety enforcement). |
| `protect-env-hook.sh` | PreToolUse Read/Edit/Write | Blocks `.env*`, `credentials.json`, service-account keys, `.npmrc`, `.pypirc`. Allows `.env.example` / `.sample` / `.template`. |
| `file-health-hook.sh` | PreToolUse Edit/Write | Enforces 400-line/10-line threshold and 500-line hard block per CLAUDE.md file-health rule. |
| `scan-budget-hook.sh` | PreToolUse Bash | Per-session budget on `Grep`/`Glob`/`Read` (warn-then-block). |
| `scout-context-truncate-hook.sh` | PreToolUse Agent | Advisory: when active APEX session reads >300-line file, suggests offset/limit. |
| `precompact-state-hook.sh` | PreCompact / PostCompact / StopFailure | Preserves apex-critical fields across context compaction. |

These are non-contradictory with v1.0 - `scope-check-hook.sh` remains the canonical scope guard; the project-specific hooks add orthogonal safety gates (destructive ops, secrets, file size, scan budget, context preservation).
