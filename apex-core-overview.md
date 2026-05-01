# /apex v1.0 - Executive Overview

Steps, skill/agent/script used, and routing conditions only. See `apex-core.md` for full spec.

Legend:

- `inline` = main-orchestrator inline prompt
- `skill` = `~/.claude/skills/apex/*.md`
- `agent` = `~/.claude/agents/*.md`
- `script` = bash/python under apex skill dir

---

## Entry flow

- **0. Initialisation**
  - Tool: `apex` (skill)
  - TaskCreates entry tasks 1-5

- **1. Analyze prompt**
  - Tool: inline
  - Routing: AskUserQuestion if ambiguous (assuming forbidden)
  - Reads `<project-root>/docs/project-context.md` if present (best-effort; absent = silent skip). Pre-biases hypothesis + propagates by inheritance to trivial / zero-layer; hybrid depth - downstream re-reads on demand at planner / executor / documentation. See "Cross-cutting infrastructure / Project context" below.

- **2. Create session manifest (concurrency check)**
  - Tool: `create-session.sh` (cc_session_id resolved via canonical `get-cc-session-id.sh` - env-var fast path or latest-jsonl fallback)
  - Routing on overlap: AskUserQuestion with options filtered to detected state
    - `abort` always present
    - `proceed alongside` only if active session detected
    - `cleanup-stale-and-proceed` only if stale manifest detected
    - dismiss/cancel = abort
  - On no overlap: writes `{session}` token + manifest, then producer-validates against `manifest.schema.json` via `validate-json.sh`

- **3. Hypothesis**
  - Tool: inline; producer-validated via `validate-json.sh hypothesis.schema.json` after Write
  - Persists: `original_prompt` (verbatim user prompt - consumed by apex-state-context-hook, reflectors, and p1.6/p2.7 summary)
  - Emits: `complexity_hint: low|medium|high`, `alternatives[]` (1-3 kept/rejected with reason - structured anti-bias check, schema-required `minItems: 1`)
  - Writes: `{session}-hypothesis.json`

- **4. Load lessons**
  - Tool: `grep-lessons.sh` + `update-hit.sh` (scripts)
  - Greps `.claude/lessons-index.md` from hypothesis keywords; tracks hits

- **5. Trivial detection**
  - Tool: inline; trivial branch owned by `trivial.md`
  - Routing:
    - trivial -> `trivial.md` (writes scope inline + scope pointer, calls `p1.md`, no preflight artifact)
    - non-trivial -> TaskCreate tasks 6-9
  - Default to non-trivial when uncertain

- **6. Scout phase 1 (enumerate -> shard -> screen)**
  - Tool: `scout1.md` (skill) - owns 6.a/6.b/6.c

  - **6.a Enumerate (deterministic)**
    - Tool: enumerate script
    - Deterministic layers (priority order):
      1. Static imports (madge / pydeps / etc.)
      2. ast-grep structural queries
      3. LSP references - hybrid: deterministic Python LSP client (`scripts/_lsp_query.py`, TS via typescript-language-server when on PATH) + agent fallback (`agents/lsp-scout.md`, MCP LSP plugins for non-TS / 0-result cases; agent output merged into findings by `scripts/merge-lsp-agent.py` before 6.b shard)
      4. Framework-convention scans (App Router strict route conventions; Pages Router all .ts/.tsx/.js/.jsx; seed-term-filtered)
    - Ripgrep fallback (only when all 4 deterministic layers produce 0)
    - Each finding carries `reasons[]` with layer attribution + `confidence: high|medium|low` (3+ deterministic = high; 1-2 = medium; ripgrep-only = low)
    - **Zero-layer case** (all 4 deterministic layers AND ripgrep fallback produce 0): exit code 10
      - Routing: AskUserQuestion (abort / proceed-with-prompt-paths)
      - On proceed: regex-extract paths from `original_prompt`, write scope inline, SKIP 6.b/6.c/7/8/9, call `p1.md` directly
      - 0 validated paths -> abort like verify exit-1

  - **6.b Shard (preflight sizing)**
    - Tool: shard script
    - Mechanical: shard count = `ceil(files/15)`
    - Routing: if >8 shards -> AskUserQuestion (continue / refine); dismiss = abort
    - Writes `shard-plan-{session}.json`

  - **6.c Parallel screen**
    - Tool: `screener.md` (Sonnet, high effort by default)
    - Per shard: keep/drop + relevance annotation
    - Writes `shard-{shard-id}-{session}.json` + claim-provenance trace `screener-{shard-id}-attempt-N.md`
    - Aggregator merges into `screened-{session}.json`

- **7. Scout phase 2 preflight**
  - Tool: `scout2.md` (skill)
  - Computes `effective_blast`: `small` if kept<=15 AND shards==1; `large` otherwise
  - Writes `preflight-{session}.json` (mode: medium|complex)
  - Gate:
    - `missed_regions=[]` AND `small` -> medium, go 8
    - `missed_regions=[]` AND `large` -> complex, go 8 (no rescout)
    - `missed_regions != []` -> complex, TaskCreate 7.x

  - **7.x Targeted rescout** (only if gate triggered)
    - Tool: `rescout.md` (Sonnet)
    - Re-enumerates missed regions; writes `rescout-{session}.json` + trace `rescout-attempt-N.md`
    - `merge-scout-findings.py` merges as kept (no re-screen) - rescout entries are `confidence: medium` by default; `high` with explicit line_range
    - Does NOT re-trigger preflight (complex mode is sticky)

- **8. Verify claims**
  - Tool: `verify-claims.sh` (script)
  - Reads `screened-{session}.json` + `preflight-{session}.json`
  - Drops mechanically-failed claims (file missing, line_range out-of-bounds/empty)
  - Confidence-aware screening: low-confidence + no line_range -> route to unresolved review
  - **Exit codes (priority 1 > 2 > 3 > 0, most-severe wins)**:
    - `1` abort - `preflight_bad >= 2` (`abort_cause=preflight_bad`) OR re-run cap reached (`abort_cause=screened_unconverged`)
    - `2` re-run 6c+7 - `screened_bad >= 3` OR `screened_bad_rate >= 30%`; capped at 1 rerun via `{session}-verify-rerun.json`
    - `3` inline review - `unresolved >= 3`; orchestrator writes `claim-review-resolved-{session}.json`, re-invokes `--apply-resolved`
    - `0` proceed - scope written, small-batch unresolveds stay dropped

- **9. Decide path**
  - Tool: script (reads `preflight.mode`)
  - Routing:
    - `medium` -> call `p1.md`
    - `complex` -> TaskCreate tasks 10, p2.0a, p2.0b, p2.0c

- **10. Self-reflect entry-flow** (Path 2 only)
  - Tool: `reflect-traces.sh` (script) + `reflector.md` (Haiku, background)
  - reflect-traces.sh: heuristic regex (`error|failed|skip`), count `fix-attempt-N.md`, list verbose traces; appends block to `~/.claude/tmp/apex-workflow-improvements.md` under `flock`
  - reflector always fires (v1.4.0+); parameter = `entryflow`. `novel_flagged` is informational; `novel_traces` drives focus selection
  - Snapshots entryflow traces (50KB cap) before reading; errors -> silent log

---

## Path 1 (medium / trivial / zero-layer)

Same chain serves main mode and teammate mode (under Path 2). `--teammate` flag trims chain.

- **p1.0 Initialisation**
  - Tool: `p1.md` (skill)
  - Reads `preflight-{session}.json`:
    - absent -> trivial/zero-layer branch (no findings consultation)
    - valid -> medium branch (consults findings)
    - invalid -> hard abort (state corruption)
  - **Main-mode only**:
    - Captures `{session}-baseline.json` (`{head_sha}`)
    - Concurrent-apex conflict check: pre-dirty files vs other active apex `*-main-scope.json`
    - On overlap -> AskUserQuestion (abort / proceed-anyway)
  - **Teammate-mode**:
    - Skips baseline + conflict check (p2.0 owns)
    - Writes scope-pointer `{session}-scopes/{teammate_cc_session_id}.txt`
  - TaskCreates p1.1 -> p1.6 (main) or p1.1, p1.1b, p1.3, p1.6 (teammate)

- **p1.1 Implement**
  - Tool: `implement.md` (skill) -> `executor.md` (Sonnet, agent)
  - TaskCreate per task; parallel where possible
  - Executor writes trace `p1/executor-{task-id}.md` on failure or split

- **p1.1b In-scope polish**
  - Tool: `polish.md` (skill)
  - Runs inline on host model (Opus in main/trivial/Opus-teammate, Sonnet in Sonnet-teammate)
  - Set: touched-by-apex INTERSECTED with active scope's `allowed_files`
  - Fixes: orphaned imports, dead code, leftover commented blocks, naming inconsistencies in newly-touched lines
  - Self-enforces hard cap; scope-check hook is outer guard
  - Breakage caught by p1.2 in main mode (counts toward 3-attempt fix cap), by central p2.3 in teammate mode

- **p1.2 Verify (lint/build) + fix** - **main mode only** (skipped in teammate mode)
  - Tool: `verify-fix.md` (skill, `--phase p1`) -> `verify-build.sh` (script) -> `executor.md` (agent)
  - Exit 0 = clean
  - Non-zero -> spawn fix attempt with errors file; trace `p1/fix-{attempt-N}.md`
  - Counter: `{session}-fix-attempts-main.json` (validated against `fix-attempts.schema.json`)
  - Cap: 3 attempts; abort + surface to user on failure (caller runs `session-end-hook.sh`)

- **p1.3 Tail (learn / docs / git)**
  - Tool: `detect-tail-mode.sh` (script) -> agents
  - Mode (single signal):
    - `economy` (FILE_COUNT<=3 AND LINE_DELTA<=50) -> `git.md` only
    - `full` -> `learn.md` + `documentation.md` + `git.md` parallel
  - **Teammate mode**: docs only - spawns `documentation.md` only (no learn, no git; central p2.4 owns)
  - Subagents (all Sonnet, foreground):
    - `learn.md` - reads `git diff {baseline.head_sha}`; appends to `.claude-tmp/lessons-tmp.md`
    - `documentation.md` - reads baseline-pinned diff; updates project docs/architecture
    - `git.md` - per-file `git add` after dotenv pre-filter (block basename matching `.env*` except templates `{.env.example, .env.sample, .env.template}` - aligns with `protect-env-hook.sh`) + `git check-ignore` filter; commits, no push; fail-silent (errors -> `~/.claude/tmp/git-agent-errors.log`)

- **p1.4 Self-reflect** - **main mode only** (teammate skips, p2.5 owns)
  - Tool: `reflect-traces.sh` (script) + `reflector.md` (Haiku, foreground)
  - reflector always fires (v1.4.0+); parameter = `entryflow+p1` (matches heuristics block name and the cross-phase trace inputs)
  - Reads entryflow + p1 traces (snapshot 50KB cap)

- **p1.5 Cleanup session** - **main mode only** (teammate skips, p2.6 owns)
  - Tool: `cleanup-session.sh` (script, idempotent; exit 0 on partial with stderr warnings)
  - Cleans: scout artifacts, all scopes, scope-pointer dir, `task.md` files (no-op in path-1, included for parity), traces, manifest, fix-attempts, baseline, verify-errors, verify-rerun, `/tmp/{session}-*`
  - Preserves `{session}-hypothesis.json` for p1.6

- **p1.6 Inline summary**
  - Tool: inline
  - Reads `{session}-hypothesis.json` (or `{session}-{teammate-id}-task.md` in teammate mode)
  - Emits: original prompt summary, hypothesis vs reality, executive summary
  - Removes hypothesis on success

### Teammate mode trim (under Path 2)

`p1.0 -> p1.1 -> p1.1b -> p1.3 (docs only) -> p1.6`. Skipped: p1.2, p1.4, p1.5 (central p2 owns each).

---

## Path 2 (complex)

Delegation to N teammates via plan mode (size N decided by planner from `complexity_hint` + scope size). The p2.0a/b/c chain is owned by `plan-mode.md` (skill).

- **p2.0a Enter plan mode**
  - Tool: `EnterPlanMode` (via `plan-mode.md`)

- **p2.0b Embed delegation plan**
  - Tool: `planner.md` (skill, called from `plan-mode.md`)
  - Inputs: `screened-{session}.json`, `preflight-{session}.json`, `{session}-hypothesis.json`
  - Outputs:
    - team size + per-teammate model (Opus or Sonnet from `complexity_hint` + scope size; high-effort fires when `complexity_hint == high`)
    - per-teammate `{teammate-id}` (4-char lowercase hex shortened guid via `openssl rand -hex 2`; guid avoids cross-session collisions on any potentially-shared path and makes replacement-teammate ids automatically distinct from failed ones with no bookkeeping)
    - per-teammate task description + `allowed_files`
    - `shared_files[]` (cross-teammate files routed to p2.4)
  - **Disjoint-scope rule**: per-teammate `allowed_files` pairwise disjoint (excl. safety paths)
  - Validator: planner self-checks pairwise intersection; on overlap reassigns or moves to `shared_files`
  - First instruction: call `p2.md`

- **p2.0c Exit plan mode**
  - Tool: `ExitPlanMode` (via `plan-mode.md`)
  - User accepts -> context clears, plan survives
  - **On rejection**: orchestrator runs `session-end-hook.sh {session}` inline, exits cleanly

- **p2.0 Initialisation (post-context-clear)**
  - Tool: `p2.md` (skill)
  - Captures `{session}-baseline.json`
  - Runs concurrent-apex conflict check (same as p1.0 main)
  - Appends `p2_cc_session_id` to manifest (preserves existing `cc_session_id` and `pid` - never overwrites)
  - Writes scope-pointer `{session}-scopes/{p2_cc_session_id}.txt` -> `{session}-main-scope.json`
  - TaskCreates p2.1 -> p2.7

- **p2.1 Setup teammates**
  - Tool: `teammates.md` (skill, runs inline on Opus)
  - Per teammate:
    - First task: call `p1.md --teammate` (flag MUST be passed)
    - Writes `{session}-{teammate-id}-scope.json` (subset of main scope)
    - Writes `{session}-{teammate-id}-task.md`
    - Receives 1-line peer summaries
    - Executor trace path: `p2/executor-{teammate-id}-{task-id}.md`
  - Monitors and coordinates teammates until done
  - **Teammate-failure handling** (`teammates-failure.md` decision tree):
    - (a) orchestrator self-fixes the slice
    - (b) spawns replacement teammate with revised scope (new id = fresh shortened guid; random 4-char hex space makes collision with failed-teammate id negligible, so artifacts stay collision-free without "next unused index" bookkeeping)
    - (c) AskUserQuestion if non-obvious (continue with surviving / retry slice / abort Path 2; dismiss = abort)
  - p2.2 shutdown waits for surviving teammates + any replacement

- **p2.2 Shut down teammates**
  - Tool: `p2-shutdown.md` (skill, inline orchestrator action; no subagent)
  - Per teammate: ack `SendMessage` + `shutdown_request`; wait for `shutdown_response`; then `TeamDelete`
  - Skips dropped teammates from `teammates-failure.md` branch (c)

- **p2.3 Verify (lint/build) + fix**
  - Tool: `verify-fix.md` (skill, `--phase p2`) -> `verify-build.sh` (script) -> `executor.md` (agent)
  - Same logic as p1.2 but central (single counter for the whole Path 2 verify; teammate p1.2 is skipped)
  - Counter: `{session}-fix-attempts-p2.json` (validated against `fix-attempts.schema.json`)
  - Trace: `p2/fix-{attempt-N}.md`
  - Cap: 3 attempts; abort + surface on failure (caller runs `session-end-hook.sh`)

- **p2.4 Tail (learn / docs / git)**
  - Tool: `detect-tail-mode.sh` (script) -> agents (same as p1.3 logic)
  - **Integration pass**: `documentation.md` owns first-write on planner's `shared_files` list (cross-teammate docs/READMEs excluded from teammate scopes); orchestrator passes the list via spawn prompt's `Shared files:` line
  - `git.md` stages teammate-modified tracked + teammate-newly-created untracked files

- **p2.5 Self-reflect**
  - Tool: `reflect-traces.sh` (script) + `reflector.md` (Haiku, foreground)
  - reflector always fires (v1.4.0+); parameter = `p2`
  - Reads `p2_cc_session_id` from manifest to locate p2 TaskList
  - Reads p2 traces only (entryflow already covered by step 10)

- **p2.6 Cleanup session**
  - Tool: `cleanup-session.sh` (idempotent)
  - Cleans all session artifacts: all scopes (main + teammate), scope-pointer dir, all `task.md` files, all fix-attempt counters (main + p2), traces, manifest, baseline, verify-errors, verify-rerun, `/tmp/{session}-*`
  - Preserves `{session}-hypothesis.json` for p2.7

- **p2.7 Inline summary**
  - Tool: inline
  - Same as p1.6: reads hypothesis, emits original prompt summary + hypothesis vs reality + executive summary; removes hypothesis on success

---

## Cross-cutting infrastructure

### Scope enforcement

- **scope-check hook**: PreToolUse on `Edit` / `Write` / `MultiEdit` / `NotebookEdit`
  - Resolves active scope via on-disk pointer `{session}-scopes/{session_id}.txt`
  - Pass-through if no pointer matches calling session_id
  - Bash file ops (`sed -i`, redirection, `tee`, `cp`, `mv`) NOT gated - prompt-layer convention only
- **Main scope write producers** (`{session}-main-scope.json`, exactly one fires per session):
  - trivial path -> step 5 inline orchestrator `Write` tool
  - zero-layer proceed -> step 6.a inline orchestrator `Write` tool
  - normal path -> `verify-claims.sh` (default mode or `--apply-resolved`)
- **Teammate scope writer** (`{session}-{teammate-id}-scope.json`, one per teammate): `teammates.md` at p2.1
- **Standard safety paths** (always allowed in any scope):
  - `.claude-tmp/`, `~/.claude/tmp/`, `/tmp/{session}-*`, project `docs/**`, any `README*` at any depth
  - Closed set; never includes `.env*` or `.git/`

### Project context (architecture entry point)

- `<project-root>/docs/project-context.md` is the codebase architecture entry point, written by `apex-init` and curated by the team
- **Read contract (hybrid depth, NOT blanket)**:
  - Main orchestrator at SKILL.md Step 1 (best-effort; absent = silent skip)
  - `planner.md` at p2.0b (architectural boundaries inform disjoint-scope + `shared_files`)
  - `agents/executor.md` (only when slice spans modules / introduces new abstraction)
  - `agents/documentation.md` at p1.3 / p2.4 (always; doc-layer entry point)
- **Read-skip set**: screener, learn, git, reflector, rescout, all scripts
- Spec contract lives in `skills/apex/shared-guardrails.md` "Project context"

### Failure handling

- **`cleanup-session.sh`**: idempotent, exit 0 with stderr warnings on partial; does NOT touch `{session}-hypothesis.json`
- **`session-end-hook.sh`** (SessionEnd hook + manual entry):
  - Wraps `cleanup-session.sh` + removes `{session}-hypothesis.json`
  - SessionEnd invocation: reads `session_id` from hook stdin, matches against active manifests' `cc_session_id` / `p2_cc_session_id` to derive apex token
  - Manual invocation: positional arg = apex session token
  - Runs on success, abort, crash; idempotent
- **Mid-/apex abort cleanup**: any orchestrator exit bypassing p1.5/p2.6 runs `session-end-hook.sh {session}` inline. Triggers:
  - verify exit-1 abort (`preflight_bad` or `screened_unconverged`)
  - AskUserQuestion-abort at any step (2 / 6.a zero-layer / 6.b / p1.0 / p2.0)
  - zero-layer "no validated paths" abort
  - teammate-failure abort
  - plan-mode rejection at p2.0c

### Trace files

- **Phases**:
  - `entryflow` - screener, rescout
  - `p1` - executor + main p1.2 fix-attempts
  - `p2` - executor (incl. teammate executors) + central p2.3 fix-attempts
- **Trace producers**: `executor.md`, `screener.md`, `rescout.md`
- **Non-trace** (script or output-is-artifact): shard, verify, learn, documentation, git, reflector
- **Path schema**: `.claude-tmp/apex-active/{session}-traces/{phase}/{agent}[-{disambiguator}].md`
  - Screener/rescout always carry `attempt-N` (preserves both passes on exit-2 re-run)

### Reflector

- **`reflect-traces.sh`**: heuristic-first script
  - Regex `error|failed|skip` (gap signals)
  - Count `fix-attempt-N.md` (fixes-observed)
  - List traces > N lines (verbose-reasoning)
  - Appends structured block to `~/.claude/tmp/apex-workflow-improvements.md` under `flock`
  - Flags novel patterns in `novel_traces:` line
- **`reflector.md`** (Haiku):
  - Always fires since v1.4.0 (`novel_flagged` is informational; `novel_traces` drives focus selection)
  - Background at step 10 (entryflow); foreground at p1.4 / p2.5 (no critical user-facing follow-up)
  - Snapshots traces (50KB cap) before reading - defends against cleanup race
  - Errors -> `~/.claude/tmp/reflector-errors.log` (silent failure)
- **Consumer chain (out-of-band)**: `~/.claude/tmp/apex-workflow-improvements.md` is consumed by `/apex-improve` (semantic-first edit pass; auto-fired at `/apex-eod` step 3). `~/.claude/tmp/tech-updates.md` is produced by `/apex-tech-watch` (weekly cron / launchd) and consumed by the same `/apex-improve` run. The pair closes the self-improvement loop: per-session reflector signals + weekly tech currency -> framework edits at EOD.

### Artifact validation

- JSON Schemas at `~/.claude/skills/apex/schemas/*.schema.json`
- Producer validates before write (catches malformed output at source)
- Consumer validates before read (treats invalid as missing -> triggers gate-handling path)
- Validated artifacts:
  - `findings-{session}.json`
  - `shard-{shard-id}-{session}.json`
  - `shard-plan-{session}.json`
  - `screened-{session}.json`
  - `preflight-{session}.json`
  - `rescout-{session}.json`
  - `claim-review-{session}.json`
  - `claim-review-resolved-{session}.json`
  - `{session}.json` (session manifest)
  - `{session}-hypothesis.json`
  - `{session}-fix-attempts-{context}.json` (contexts: `main`, `p2`)
  - `{session}-verify-rerun.json`
  - `{session}-baseline.json`
  - `{session}-main-scope.json`
  - `{session}-{teammate-id}-scope.json`
