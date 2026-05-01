---
name: shared-guardrails
description: Cross-cutting rules referenced by every apex skill and agent. Single source of truth for safety paths, scope-check hook resolution, scope-write producers, manifest schema, trace path schema, JSON Schema validation, and mid-/apex abort cleanup.
---

# Shared guardrails

Cross-cutting reference for apex skill / agent files. Authoritative spec is `apex-core.md`; this file holds only the rules that other files cite by topic (safety paths, manifest schema, scope-write producers, scope-check hook resolution, trace path schema, JSON Schema validation, mid-/apex abort cleanup, project-specific hooks). Anything not listed here lives in `apex-core.md` or `apex-core-overview.md`.

## Standard safety paths (always allowed in any scope artifact)

Closed set:
- `.claude-tmp/`
- `~/.claude/tmp/`
- `~/.claude/plans/` (plan-mode artifacts; orchestrator-owned, not part of any apex scope)
- `/tmp/{session}-*`
- project `docs/**`
- any `README*` file at any depth

Never includes `.env*` or `.git/`.

## Project context (architecture entry point)

`<project-root>/docs/project-context.md` is the canonical entry point to the codebase architecture - written by `apex-init` at project setup and curated by the team thereafter. When present, it surfaces module names, conventions, security-sensitive paths, and architectural boundaries that pure file enumeration cannot reveal.

**Read contract (closed list - hybrid depth, NOT blanket):**
- Main orchestrator at `SKILL.md` Step 1: best-effort read; absent file is silently skipped. Pre-biases hypothesis + propagates by inheritance through working memory to trivial / zero-layer branches.
- `planner.md` at p2.0b: re-read before team-sizing - architectural boundaries inform disjoint-scope and `shared_files` routing.
- `agents/executor.md`: re-read ONLY when the slice spans modules or introduces a new abstraction. Skipped for mechanical edits.
- `agents/documentation.md` at p1.3 / p2.4: ALWAYS re-read - it is the doc-layer entry point when updating project docs / architecture notes.

**Read-skip set (these NEVER read project-context.md):**
- `agents/screener.md` (6.c) - hypothesis already biases keep/drop; architecture context would over-constrain.
- `agents/learn.md`, `agents/git.md`, `agents/reflector.md`, `agents/rescout.md` - inputs are diff / TaskList / traces / missed-regions, not architecture.
- All scripts (enumerate, shard, verify, decide-path, etc.) - mechanical, not LLM-driven.

`docs/**` is already in the safety-paths closed set above, so `project-context.md` is always readable from any apex scope without scope-artifact extension.

## Session token format

8-char lowercase hex (`openssl rand -hex 4`). Tight enough that cleanup glob `*{session}*` cannot substring-match unrelated files.

## cc_session_id resolution

Claude Code does NOT export the active session id as a bash env var. To avoid LLM-side guessing, every apex script that needs `cc_session_id` resolves it through the canonical helper:

`scripts/get-cc-session-id.sh` - echoes the resolved id to stdout (exit 0 on success, exit 1 + stderr message on failure). Resolution order:
1. `$CC_SESSION_ID` env var if set + non-empty (callers who already have it can re-export to skip step 2).
2. Most-recently-modified `.jsonl` in `~/.claude/projects/<encoded-cwd>/` where `<encoded-cwd>` = `pwd | tr '/.' '--'`.

Producers and consumers:
- Step 2 `create-session.sh --cc-session-id "$(bash scripts/get-cc-session-id.sh)"` (orchestrator-driven; placeholder `<session_id>` in skill prompts now resolves through the helper).
- 6.a `zero-layer-extract.sh` falls back to the helper when `CC_SESSION_ID` env is unset.
- Any future script that names `cc_session_id` MUST source the helper rather than re-implement the lookup.

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
- trivial path -> `trivial.md` (inline orchestrator `Write`)
- zero-layer proceed -> `scout1.md` 6.a (inline orchestrator `Write`)
- normal path -> `verify-claims.sh` (default mode or `--apply-resolved`)

**Anti-rule.** Writing `{session}-main-scope.json` outside these three producers is a contract violation. Concretely forbidden: freehand inline `Write` at 6.b post-shard (the ripgrep-poisoned gate's only proceed path is `zero-layer-extract.sh`, never freehand), freehand inline `Write` at any non-trivial step, and manual scope synthesis from grep results in lieu of running scout / verify. The `verify-claims.sh` exit-0 is the canonical normal-path producer; trivial / zero-layer are the only legitimate short-circuits. If the orchestrator is tempted to write scope freehand because scout returned noise, the correct response is the 6.b AskUserQuestion gate (refine | proceed-with-prompt-paths | continue) - not bypassing the gate.

`{session}-{teammate-id}-scope.json` - written only by `teammates.md` at p2.1.

`{session}-plan-candidate.json` - written by `planner.md` at p2.0b before the disjoint-scope validator runs; consumed by `scripts/validate-disjoint-scopes.py` (schema: `plan-candidate.schema.json`). Cleaned by an explicit `rm_target` in `cleanup-session.sh` (no glob match because the suffix is `-plan-candidate.json`, not `-scope.json`).

## scope-check hook resolution

PreToolUse on `Edit` / `Write` / `MultiEdit` / `NotebookEdit`. Resolves active scope via on-disk pointer `.claude-tmp/apex-active/{session}-scopes/{session_id}.txt` (single line: absolute path to scope JSON). Hook globs `.claude-tmp/apex-active/*-scopes/{session_id}.txt` to find the matching pointer. Pass-through if no pointer matches.

Pointer writers:
- main orchestrator after each scope write -> `{session}-scopes/{cc_session_id}.txt`
- p2 orchestrator at p2.0 -> `{session}-scopes/{p2_cc_session_id}.txt` (also points at main scope)
- each teammate at its own p1.0 (under `--teammate`) -> `{session}-scopes/{teammate_cc_session_id}.txt`

Bash file ops (`sed -i`, redirection, `tee`, `cp`, `mv`) NOT gated - prompt-layer convention only.

## Trace path schema

`.claude-tmp/apex-active/{session}-traces/{phase}/{agent}[-{disambiguator}].md`

Phases: `entryflow` (screener, rescout) | `p1` (executor + main p1.2 fix-attempts) | `p2` (executor incl. teammate executors + central p2.3 fix-attempts).

Disambiguator: shard-id, task-id, teammate-id, teammate-id-task-id, attempt-N (dash-joined).

Screener and rescout always carry `attempt-N` (preserves both passes on exit-2 re-run).

Trace writers: `executor.md`, `screener.md`, `rescout.md`. Non-trace: shard, verify, learn, documentation, git, reflector.

## JSON Schema validation

Schemas at `skills/apex/schemas/*.schema.json` (this dev repo) - canonical install path is `~/.claude/skills/apex/schemas/`. Producer validates before write; consumer validates before read.

Helpers (uniform call sites for script + inline-LLM producers):
- `scripts/_validate.py` - python module; `producer_validate(data, schema_name)` raises `ValidationError`, `consumer_load(path, schema_name)` returns `None` on missing/invalid. Schema dir resolves via `APEX_SCHEMA_DIR` env var if set + non-empty; otherwise defaults to `skills/apex/schemas/` (relative to the module).
- `scripts/validate-json.sh [--admin] <schema-name> <json-path>` - thin shell wrapper around `producer_validate`. Used by `create-session.sh` after manifest write and by orchestrator inline-LLM producers (Step 3 hypothesis) immediately after `Write` to enforce the rule across all producer types. The `--admin` flag exports `APEX_SCHEMA_DIR=skills/admin-apex/schemas/` before invoking python (no runtime monkey-patch).

Strict-mode enforcement (admin-apex only):
- Apex hot path keeps lenient parse-only fallback when `jsonschema` is missing (one-line stderr warning per process). Rationale: end-user environments without the dep should not be blocked from `/apex` runs.
- Admin-apex runs `skills/admin-apex/scripts/check-deps.sh` at task 1; missing `jsonschema` aborts with the install one-liner. Rationale: admin-apex owns mutation and must validate before write - parse-only is not an acceptable degradation for the maintenance path.

Validation failure handling:
- Producer: aborts with explicit error to stderr (catches malformed output at source)
- Consumer: treats invalid artifact as missing -> triggers the relevant gate-handling path (e.g., `verify-claims.sh` reading invalid `screened-{session}.json` -> exit-2 re-run; `p1.md` reading invalid `preflight-{session}.json` -> hard abort with state-corruption signal)

Validated artifacts: see `apex-core.md` "Artifact validation" section for the full list.

## Mid-/apex abort cleanup

Any orchestrator exit that bypasses the success-path cleanup (p1.5 / p2.6) MUST run `scripts/session-end-hook.sh {session}` inline before returning. Same idempotent cleanup as SessionEnd, plus removal of `{session}-hypothesis.json` (belt-and-suspenders fallback).

Per-trigger abort paths are documented in their owning step (apex-core.md): step 2 manifest, step 6.a zero-layer, step 6.b shard cap, step 8 verify exit-1, p1.0 / p2.0 conflict check, p2.0c plan-mode rejection, p2.1 teammate-failure.

## Project-specific hooks (additive to v1.0)

Wired in `settings.json` alongside the spec hooks. Layered on top of `scope-check-hook.sh` (do not replace it). Listed here so future contributors reading the spec can discover them.

| Hook | Matcher | Purpose |
|------|---------|---------|
| `block-destructive-hook.sh` | PreToolUse Bash | Blocks `git checkout --`, `git show`/`cat-file > file`, `rm -rf`, shell credential reads (CLAUDE.md Git Safety enforcement). |
| `protect-env-hook.sh` | PreToolUse Read/Edit/Write | Blocks `.env*`, `credentials.json`, service-account keys, `.npmrc`, `.pypirc`. Allows `.env.example` / `.sample` / `.template`. |
| `file-health-hook.sh` | PreToolUse Edit/Write | Enforces 400-line/10-line threshold and 500-line hard block per CLAUDE.md file-health rule. |
| `apex-state-context-hook.sh` | SessionStart matcher=compact\|resume | Re-injects apex-critical fields after compaction or on session resume (via `additionalContext`). PreCompact/PostCompact/StopFailure cannot inject context per Claude Code hook API; SessionStart matcher=compact is the canonical post-compaction hook. |

These are non-contradictory with v1.0 - `scope-check-hook.sh` remains the canonical scope guard; the project-specific hooks add orthogonal safety gates (destructive ops, secrets, file size, context preservation).
