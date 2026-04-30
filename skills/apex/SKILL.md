---
name: apex
description: Main coding orchestrator. Entry point for /apex; runs the entry flow (analyze, manifest, hypothesis, lessons, trivial detection, scout, verify, path decision) then dispatches to Path 1 (medium/trivial) or Path 2 (complex).
---

# /apex (main orchestrator)

This skill is the entry point invoked by `/apex <prompt>`. It owns the entry flow (steps 0-10) and routes into either `p1.md` or the Path 2 plan-mode chain.

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
| 5    | inline prompt | Trivial -> writes scope inline + scope pointer -> calls `p1.md` |
| 6    | `scout1.md` | 6.a / 6.b / 6.c |
| 7    | `scout2.md` | + 7.x targeted rescout if gated |
| 8    | `scripts/verify-claims.sh` | Exit-code dispatch (priority 1>2>3>0) |
| 9    | `scripts/decide-path.sh` | medium -> `p1.md`; complex -> p2.0a/b/c TaskCreate |
| 10   | `reflect.md` (`--phase entryflow`) -> `scripts/reflect-traces.sh` + `agents/reflector.md` | Path 2 only; reflector spawned in background |
| p2.0a | this skill (`EnterPlanMode` tool) | Path 2 only |
| p2.0b | `planner.md` (+ `scripts/validate-disjoint-scopes.py`) | Composes plan body inside plan mode |
| p2.0c | this skill (`ExitPlanMode` tool) | On reject -> `session-end-hook.sh {session}` inline |

## Cross-cutting rules

See `shared-guardrails.md` for: scope enforcement, safety paths, manifest schema, trace path schema, scope-write producers, mid-/apex abort cleanup, JSON Schema validation.

## Step 0: TaskCreate entry tasks 1-5

```
TaskCreate "1. Analyze prompt" - inline analysis, AskUserQuestion if ambiguous
TaskCreate "2. Create session manifest" - blockedBy [1] - scripts/create-session.sh
TaskCreate "3. Hypothesis" - blockedBy [2] - emits {session}-hypothesis.json
TaskCreate "4. Load lessons" - blockedBy [3] - grep-lessons.sh + update-hit.sh
TaskCreate "5. Trivial detection" - blockedBy [4] - inline; routes to trivial/non-trivial
```

If step 5 returns non-trivial, append:
```
TaskCreate "6. Scout phase 1" - blockedBy [5] - scout1.md
TaskCreate "7. Scout phase 2 preflight" - blockedBy [6] - scout2.md
TaskCreate "8. Verify claims" - blockedBy [7] - verify-claims.sh
TaskCreate "9. Decide path" - blockedBy [8] - decide-path.sh
```

If step 9 returns complex, append (per `apex-core-overview.md` Path 2):
```
TaskCreate "10. Self-reflect entry-flow" - blockedBy [9] - reflect.md --phase entryflow (-> reflect-traces.sh + reflector.md, background)
TaskCreate "p2.0a Enter plan mode" - blockedBy [9] - EnterPlanMode
TaskCreate "p2.0b Embed delegation plan" - blockedBy [p2.0a] - planner.md
TaskCreate "p2.0c Exit plan mode" - blockedBy [p2.0b] - ExitPlanMode
```

## Step 1: Analyze (inline)

Read the user's prompt. Identify the task type, files / modules implied, action verbs. If the prompt is ambiguous, surface via AskUserQuestion. **Assuming is forbidden** - prefer asking over guessing.

## Step 2: Create session manifest

Call `scripts/create-session.sh --cc-session-id <session_id>`. Exit codes:
- `0` - manifest written, `{session}` token printed to stdout. Capture and use throughout.
- `10` - overlap detected. Script writes detected state to stderr (active manifests / stale manifests). Orchestrator surfaces:

```
AskUserQuestion (matcher: filtered to detected state):
  - "abort"              (always present)
  - "proceed alongside"  (only if active session detected; new {session} token issued)
  - "cleanup-stale-and-proceed" (only if stale manifest detected; for each stale,
                          invoke session-end-hook.sh <stale-token>; then re-run create-session.sh)
  Dismiss / cancel = abort
```

On abort: run `scripts/session-end-hook.sh` is NOT applicable (no manifest yet); just exit cleanly.

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

Write `.claude-tmp/apex-active/{session}-hypothesis.json` via the `Write` tool, conforming to `schemas/hypothesis.schema.json` (producer-validates before write per shared-guardrails). The artifact is preserved across p1.5 / p2.6 cleanup and consumed by step 4 keyword extraction, 6.b shard, 8 verify error-surfacing, both reflectors, and `summary.md` at p1.6 / p2.7 (which removes it on success; `session-end-hook.sh` is the idempotent fallback).

## Step 4: Load lessons

Best-effort consultation of curated project lessons. Skip silently when the project has none.

1. **Derive keywords** from `{session}-hypothesis.json` (the `hypothesis` field plus any specific symbol / module names in `alternatives`). Cap at ~8; prefer specific tokens (function names, table names, component names) over generic ones (`config`, `error`, `auth` bare). The blocklist exists because generic terms over-match in the index.

2. **Run grep:**
   ```
   scripts/grep-lessons.sh <project-root> <term1> [<term2> ...]
   ```
   - `<project-root>` = the orchestrator's working directory (the project being apex'd, NOT the apex skill dir).
   - Reads `<project-root>/.claude/lessons-index.md` and `.claude/lessons.md`. Both absent -> exit 0 with no output (project has no curated lessons; this is the common case for new projects). The orchestrator MUST tolerate empty output.
   - On match, emits one or more blocks of the form:
     ```
     --- LINES <start>-<end> ---
     ## Section Name
     <lesson lines>
     ```
     `<start>`-`<end>` are absolute line numbers in `lessons.md`. Total output capped at 150 lines with a `TRUNCATED` footer; if truncated, narrow the keyword list and re-run.

3. **Track hits** (only when grep emitted blocks):
   ```
   scripts/update-hit.sh <project-root>/.claude/lessons.md <line> [<line> ...]
   ```
   Pass every absolute line number in the emitted block ranges (expand each `--- LINES s-e ---` to the full integer range `s..e`). `update-hit.sh` is idempotent and silently skips lines without `[last-hit:...]` annotations, so over-passing is safe. Optional optimisation: skip step 3 entirely when every matched block already shows today's date.

4. **Keep the matched lesson text in working memory** for downstream steps (5 trivial detection, 5A executor prompts, scout / planner). Lessons are advisory; they do not override the user's prompt or scope decisions.

## Step 5: Trivial detection (inline)

Decide trivial vs non-trivial. Trivial trades fidelity for latency, so the bar is high:

- **trivial** - ALL of:
  - Single file edit (or single new file), AND
  - No cross-file dependencies surfaced in `{session}-hypothesis.json` (no other modules / barrels / callers implicated), AND
  - No new abstractions (no new public symbol, no new component, no new endpoint)
- **non-trivial** - any other shape, OR uncertain. **Default to non-trivial when uncertain** - hidden-blast-radius cost dominates the latency loss of running scout.

### Trivial branch

1. **Write the scope artifact** at `.claude-tmp/apex-active/{session}-main-scope.json` via the `Write` tool, conforming to `schemas/main-scope.schema.json`:
   ```json
   {
     "session": "<8-hex token>",
     "allowed_files": ["<detected file>", ...standard safety paths...],
     "produced_by": "trivial-inline",
     "produced_at": "<ISO-8601 now>"
   }
   ```
   `allowed_files` = the detected single file PLUS standard safety paths (`.claude-tmp/`, `~/.claude/tmp/`, `/tmp/{session}-*`, project `docs/**`, any `README*`; see `shared-guardrails.md`). The schema's `session` field MUST match the manifest's `{session}` token.

2. **Write the scope-check pointer** at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt` via the `Write` tool. The file is a single line containing the absolute path to the scope JSON written in step 1. Required so the PreToolUse scope-check hook can resolve the active scope for any subsequent `Edit` / `Write` (see `shared-guardrails.md` / scope-check hook).

3. **Mark queued tasks 6-9 as completed** (skipped, no-op) on the TaskList - they were never queued in the trivial branch (Step 0 only enqueued 6-9 conditionally), so this is a no-op when only tasks 1-5 exist. If the orchestrator pre-emptively queued them, mark them completed now so the TaskList reflects reality.

4. **Call `p1.md`** - read `~/.claude/skills/apex/p1.md` and follow its instructions. The trivial branch writes NO preflight artifact; p1.0 reads an absent `preflight-{session}.json` and runs the no-findings-consultation branch.

### Non-trivial branch

TaskCreate tasks 6-9 per the template in Step 0. Continue with Step 6 (scout phase 1).

## Step 6 routing: zero-layer (exit code 10 from enumerate)

Surfaced by `scout1.md` / `scout2.md`. Orchestrator handles the user-facing question:

```
AskUserQuestion at 6.a (zero-layer):
  - "abort"
  - "proceed-with-prompt-paths"  (regex-extract paths from original_prompt,
                                  validate each on disk, write scope inline + pointer,
                                  SKIP 6.b/6.c/7/8/9, call p1.md directly)
  Dismiss / cancel = abort
0 validated paths after extraction -> abort like verify exit-1.

AskUserQuestion at 6.b (>8 shards):
  - "continue"  (no max cap; proceed to 6.c with the wide plan)
  - "refine"    (abort cleanly so user can re-prompt with narrower scope)
  Dismiss / cancel = abort
```

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

## Step p2.0a/b/c: Plan-mode chain (Path 2 only)

Queued by step 9 when `decide-path.sh` returns `complex`. Three tasks run sequentially in the entry-flow Claude Code session, immediately after step 10 (entry-flow self-reflect runs in the background and does not block p2.0a). The plan composed in p2.0b is what survives the p2.0c context clear.

### p2.0a Enter plan mode

Call the `EnterPlanMode` tool. No parameters. After this returns, the orchestrator is in plan mode and any subsequent text becomes part of the plan body.

Do NOT call `EnterPlanMode` more than once per Path 2 run - re-entry has no defined semantics and would discard the planner's draft.

### p2.0b Embed delegation plan

Read and follow `~/.claude/skills/apex/planner.md`. Inputs (already on disk from earlier steps):
- `.claude-tmp/scout/screened-{session}.json` - kept-files set (scope source)
- `.claude-tmp/scout/preflight-{session}.json` - `effective_blast`, `mode`
- `.claude-tmp/apex-active/{session}-hypothesis.json` - `complexity_hint`, `original_prompt`, `hypothesis`

Compose the plan body per `planner.md` "Plan embed template" - team size, per-teammate model, per-teammate `{teammate-id}` (`openssl rand -hex 2`), per-teammate task description, per-teammate `allowed_files`, and `shared_files`.

Disjoint-scope validator (mandatory before exit):

```
# Write candidate plan to a tmp file
plan_tmp=".claude-tmp/apex-active/{session}-plan-candidate.json"
# (orchestrator writes JSON: {"teammates":[{"teammate_id":"...","allowed_files":[...]},...]})

python3 ~/.claude/skills/apex/scripts/validate-disjoint-scopes.py \
  --plan "$plan_tmp" --session "{session}"
```

- exit 0 - disjoint, proceed to p2.0c
- exit 1 - overlap; reassign each `OVERLAP <file>\t<a>\t<b>` per the planner heuristic (more findings = stronger owner; cross-cutting -> `shared_files`); re-run the validator
- exit 2 - input malformed (planner bug); abort Path 2 + run `scripts/session-end-hook.sh {session}` inline

After validator exit 0, the **first instruction** in the embedded plan body MUST be:

```
First instruction: read and follow ~/.claude/skills/apex/p2.md
```

Without this, the post-context-clear session has no entry point into the Path 2 chain.

The candidate-plan tmp (`{session}-plan-candidate.json`) is cleaned up by `cleanup-session.sh` along with other `{session}-*` artifacts at p2.6 / SessionEnd; no explicit rm needed.

### p2.0c Exit plan mode

Call the `ExitPlanMode` tool. The user is presented the plan and accepts or rejects:

| Outcome | Action |
|---------|--------|
| User accepts | Claude Code clears context; the embedded "first instruction" runs `p2.md` in the new session, which captures baseline + appends `p2_cc_session_id` to the manifest + writes the post-context-clear scope pointer + TaskCreates p2.1 -> p2.7 |
| User rejects | Orchestrator runs `scripts/session-end-hook.sh {session}` inline (cleans manifest + traces + scope + hypothesis + scope-pointer dir, idempotent), surfaces a brief user-facing summary ("Plan rejected; session cleaned up"), and exits cleanly. Distinct from session-level abort (covered by SessionEnd hook) |

Do NOT re-enter plan mode on rejection - that would loop. Treat rejection as terminal for this `/apex` invocation; the user can re-prompt with a refined request.

## Mid-/apex abort cleanup

Any orchestrator exit bypassing p1.5 / p2.6 runs `scripts/session-end-hook.sh {session}` inline. Triggers (per `shared-guardrails.md`):
- verify exit-1 (preflight_bad / screened_unconverged)
- AskUserQuestion-abort at step 2 / 6.a / 6.b / p1.0 / p2.0
- zero-layer "no validated paths" abort
- teammate-failure abort
- plan-mode rejection at p2.0c
