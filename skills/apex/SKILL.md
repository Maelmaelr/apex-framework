---
name: apex
description: Main coding orchestrator. Entry point for /apex; runs the entry flow (analyze, manifest, hypothesis, lessons, trivial detection, scout, verify, path decision) then dispatches to Path 1 (medium/trivial) or Path 2 (complex).
---

# /apex (main orchestrator)

This skill is the entry point invoked by `/apex <prompt>`. It owns the entry flow (steps 0-10) and routes into either `p1.md` (Path 1) or `plan-mode.md` (Path 2 plan-mode chain).

Spec sources (canonical, do NOT duplicate here):
- `apex-core.md` "Entry flow" (steps 0-10) - full behavioral contract
- `apex-core-overview.md` "Entry flow" - lighter step-by-step routing summary

## Step ownership

| Step | Owner | Notes |
|------|-------|-------|
| 0    | this skill | TaskCreate entry tasks 1-5 |
| 1    | inline prompt | AskUserQuestion if ambiguous |
| 2    | `scripts/create-session.sh` | Manifest + concurrency check |
| 3    | inline prompt | Writes `{session}-hypothesis.json` |
| 4    | `scripts/grep-lessons.sh` + `scripts/update-hit.sh` | |
| 5    | inline prompt | Trivial -> `trivial.md`; non-trivial -> Step 6 |
| 6    | `scout1.md` | 6.a / 6.b / 6.c (incl. orchestrator AskUserQuestion contracts) |
| 7    | `scout2.md` | + 7.x targeted rescout if gated |
| 8    | `scripts/verify-claims.sh` | Exit-code dispatch (priority 1>2>3>0) |
| 9    | `scripts/decide-path.sh` | medium -> `p1.md`; complex -> `plan-mode.md` chain |
| 10   | `reflect.md` (`--phase entryflow`) -> `scripts/reflect-traces.sh` + `agents/reflector.md` | Path 2 only; reflector spawned in background |
| p2.0a/b/c | `plan-mode.md` | Path 2 only; sequential after step 10 |

## Cross-cutting rules

See `shared-guardrails.md` for: scope enforcement, safety paths, manifest schema, trace path schema, scope-write producers, mid-/apex abort cleanup, JSON Schema validation.

## Step 0: TaskCreate the entry chain

Each line below is one `TaskCreate(subject, description)`. Tasks run in TaskCreate order; `TaskCreate` has no `blockedBy` / `blocks` parameter - if a parallel branch needs an explicit merge dependency, set it after the fact via `TaskUpdate addBlockedBy`.

```
TaskCreate "1. Analyze"            (inline; AskUserQuestion if ambiguous)
TaskCreate "2. Session manifest"   (scripts/create-session.sh)
TaskCreate "3. Hypothesis"         (inline; writes {session}-hypothesis.json)
TaskCreate "4. Load lessons"       (scripts/grep-lessons.sh + scripts/update-hit.sh)
TaskCreate "5. Trivial detection"  (inline; trivial -> trivial.md, non-trivial -> tasks 6-9)
```

Append on non-trivial: `6. scout1.md`, `7. scout2.md`, `8. verify-claims.sh`, `9. decide-path.sh`.

Append on `decide-path.sh = complex`: `10. reflect.md --phase entryflow` (background; via `reflect-traces.sh`), then `p2.0a / p2.0b / p2.0c` per `plan-mode.md`. On `decide-path.sh = medium`: NO append; orchestrator dispatches into `p1.md` per "Step 9 path dispatch" below.

## Step 1: Analyze (inline)

Read the user's prompt. Identify the task type, files / modules implied, action verbs. If the prompt is ambiguous, surface via AskUserQuestion. **Assuming is forbidden** - prefer asking over guessing.

Then read `<project-root>/docs/project-context.md` if it exists (best-effort; absent = skip silently). This is the canonical entry point to the codebase architecture - module names, conventions, security-sensitive paths, architectural boundaries. The read pre-biases Step 3 hypothesis (architecture terms surface in `hypothesis` and `alternatives`) and propagates by **inheritance** through working memory to the trivial / zero-layer branches. The read is NOT pushed into scout / screener / git / learn / reflector prompts (token cost, no decision benefit). Architecture-sensitive downstream consumers (`planner.md` at p2.0b, `agents/executor.md` on slice spans, `agents/documentation.md` at p1.3 / p2.4) re-read directly when their work requires it. See `shared-guardrails.md` "Project context" for the closed hybrid contract.

## Step 2: Create session manifest

Resolve the current Claude Code session id via `scripts/get-cc-session-id.sh` (canonical: env-var fast path, latest-jsonl fallback - single source of truth). Then call `scripts/create-session.sh --cc-session-id "$(bash scripts/get-cc-session-id.sh)"`. Exit codes:
- `0` - manifest written + producer-validated against `manifest.schema.json`, `{session}` token printed to stdout. Capture and use throughout.
- `10` - overlap detected. Script writes detected state to stderr (active manifests / stale manifests). Orchestrator surfaces:

```
AskUserQuestion (options filtered to detected state):
  - "abort"              (always present)
  - "proceed alongside"  (only if active session detected; new {session} token issued)
  - "cleanup-stale-and-proceed" (only if stale manifest detected; for each stale,
                          invoke session-end-hook.sh <stale-token>; then re-run create-session.sh)
  Dismiss / cancel = abort
```

On abort: no manifest exists yet, so `session-end-hook.sh` is skipped; exit cleanly.

## Step 3: Hypothesis (inline)

Carefully read the prompt - prompt phrasing may bias / narrow actual scope. Emit:

- `original_prompt: <verbatim user prompt>` (preserves the user's exact wording for downstream reflectors and the p1.6 / p2.7 inline summary; do NOT paraphrase)
- `hypothesis: <string>` - the orchestrator's working interpretation in one or two sentences (not a plan, not a task list)
- `complexity_hint: low|medium|high` - heuristic only, refined nowhere downstream:
  - `low`  - single-file edit, no new abstractions (typo, one-liner, in-place rename of a local symbol)
  - `medium` - multi-file but bounded module / package, no cross-cutting design choices
  - `high` - cross-module, cross-package, new abstraction, ambiguous scope, or any "rewrite / rethink / migrate" verb. The planner uses this to fire high-effort keyword for Path 2 teammates (see `apex-core.md` "Effort levels")
- `alternatives: [{interpretation, status: kept|rejected, reason}]` - 1-3 narrower / broader scope readings, each a structured anti-bias check (not vibes). Keep the readings the orchestrator finds plausible; reject the ones that would over- or under-shoot. Each entry carries a one-line `reason`. Example for prompt "fix the login form validation":
  - kept: "validation rules in all auth-related forms" (broader; reason: "shared validator likely")
  - rejected: "rebuild the auth subsystem" (broadest; reason: "explicit 'fix' verb scopes to existing rules")

Write `.claude-tmp/apex-active/{session}-hypothesis.json` via the `Write` tool, conforming to `schemas/hypothesis.schema.json`. Then enforce producer-validates-before-write per shared-guardrails: `bash scripts/validate-json.sh hypothesis.schema.json .claude-tmp/apex-active/{session}-hypothesis.json` - exit-1 means malformed; abort with explicit error. The artifact is preserved across p1.5 / p2.6 cleanup and consumed by step 4 keyword extraction, 6.b shard, 8 verify error-surfacing, both reflectors, and `summary.md` at p1.6 / p2.7 (which removes it on success; `session-end-hook.sh` is the idempotent fallback).

## Step 4: Load lessons

Best-effort. Project has no `.claude/lessons-index.md` -> skip silently.

- Derive ~8 keywords from `{session}-hypothesis.json` (`hypothesis` field + symbol/module names from `alternatives`); prefer specific tokens (function / table / component names) over generic (`config`, `error`, `auth` bare).
- `scripts/grep-lessons.sh <project-root> <term1> [<term2> ...]` - reads `<project-root>/.claude/lessons-index.md` + `lessons.md`; emits `--- LINES s-e ---` blocks (absolute line numbers in `lessons.md`); 150-line cap with `TRUNCATED` footer (narrow keywords and re-run if hit). Tolerate empty output.
- `scripts/update-hit.sh <project-root>/.claude/lessons.md <line>...` - pass every absolute line number from the emitted blocks (expand each `s-e` to the integer range); idempotent. Skip if every matched block already shows today's date.
- Keep matched lessons in working memory for downstream steps (5 trivial detection, p1.1 implement, scout / planner). Advisory only - never override the user prompt or scope decisions.

See `scripts/grep-lessons.sh` and `scripts/update-hit.sh` headers for full I/O contracts.

## Step 5: Trivial detection (inline)

Trivial = ALL of: single file edit (or single new file), no cross-file dependencies in `{session}-hypothesis.json`, no new abstractions (no new public symbol / component / endpoint). **Default to non-trivial when uncertain** - hidden-blast-radius cost dominates the latency saving.

- trivial -> read and follow `~/.claude/skills/apex/trivial.md` (writes scope inline + scope pointer, marks queued 6-9 completed if any, calls `p1.md`; no preflight artifact written).
- non-trivial -> TaskCreate tasks 6-9 per Step 0 template; proceed to Step 6.

## Step 6 routing

`scout1.md` owns 6.a / 6.b / 6.c. Orchestrator-side AskUserQuestion contracts (zero-layer at 6.a, > 8 shards at 6.b) live in `scout1.md` "AskUserQuestion contracts (orchestrator-side)". `Dismiss / cancel = abort` for both.

## Step 8 verify-claims dispatch

Exit-code priority 1 > 2 > 3 > 0. Read `abort_cause` from stderr on exit 1.

| Exit | Action | User-facing message |
|------|--------|---------------------|
| 0 | scope written, proceed | (none - step 9 dispatches) |
| 1 (`preflight_bad`) | abort + cleanup | "Hypothesis may be wrong - review and re-prompt" + surface hypothesis text from `{session}-hypothesis.json` |
| 1 (`screened_unconverged`) | abort + cleanup | "Scout could not converge after re-screening - review hypothesis and re-prompt" |
| 2 | re-run 6.c + 7 (one cap via `{session}-verify-rerun.json`) | (none) |
| 3 | inline review of `claim-review-{session}.json` (>=3 unresolved); write `claim-review-resolved-{session}.json` (`[{file, action: keep\|drop, reason}]`); re-invoke `verify-claims.sh --apply-resolved` | (none) |

On exit 0 (default mode OR `--apply-resolved`): the script wrote `{session}-main-scope.json`. The orchestrator MUST then write the scope-check pointer at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt` (single line: absolute path to the scope JSON) via the `Write` tool, mirroring the trivial / zero-layer branches (`shared-guardrails.md` / scope-check hook). Without the pointer, the PreToolUse hook is pass-through and downstream `Edit` / `Write` are unguarded.

On exit 1: run `scripts/session-end-hook.sh {session}` inline before exiting (mid-abort cleanup).

## Step 9 path dispatch

`scripts/decide-path.sh` echoes `medium` or `complex`. Branch on the value:

| Mode | Action |
|------|--------|
| `medium` | Read and follow `~/.claude/skills/apex/p1.md` directly (p1.md TaskCreates p1.1 -> p1.6 inline at its Step 3). No entry-flow task append. Mirrors trivial -> `trivial.md` -> p1.md. |
| `complex` | Tasks 10 + p2.0a/b/c queued per Step 0 append; proceed. p2.0c `ExitPlanMode` clears context; the embedded plan routes the post-clear session into `p2.md`. |

Without an explicit medium dispatch the model finishes task 9 with no pending tasks and silently terminates - p1.X never gets created.

## Path 2 plan-mode chain (p2.0a / p2.0b / p2.0c)

Read and follow `~/.claude/skills/apex/plan-mode.md`. Sequential post-step-9 tasks (entry-flow self-reflect runs in the background and does NOT block p2.0a): `EnterPlanMode` -> embed plan via `planner.md` + disjoint-scope validator -> `ExitPlanMode` (rejection -> `session-end-hook.sh {session}` inline).

## Mid-/apex abort cleanup

Any orchestrator exit bypassing p1.5 / p2.6 runs `scripts/session-end-hook.sh {session}` inline. Triggers (per `shared-guardrails.md`):
- verify exit-1 (preflight_bad / screened_unconverged)
- AskUserQuestion-abort at step 2 / 6.a / 6.b / p1.0 / p2.0
- zero-layer "no validated paths" abort
- teammate-failure abort
- plan-mode rejection at p2.0c
