---
name: apex
description: Main coding orchestrator. Linear 15-step flow with three tiers (trivial / economy / standard). Trivial decided at step 3; economy decided at step 7. Determinism via session manifest, scope-check hook, file-health hook, bounded fix-loop. Inline orchestrator + delegates to skills/agents per step.
---

# /apex

Main session orchestrator. Full behavioral contract: `apex-core.md`. Light-read skeleton + skip matrix: `apex-core-overview.md`.

## Step 0: queue tasks

```
TaskCreate "1.  Analyze + read project-context.md"
TaskCreate "2.  Create session manifest"
TaskCreate "3.  Trivial pre-flight"
TaskCreate "4.  Hypothesis"
TaskCreate "5.  Load lessons"
TaskCreate "6.  Discovery"
TaskCreate "7.  Economy pre-flight"
TaskCreate "8.  Execute"
TaskCreate "9.  Polish"
TaskCreate "10. Verify"
TaskCreate "11. Tail (documentation [+learn])"
TaskCreate "12. VERSION bump + git sync"
TaskCreate "13. Self-reflect"
TaskCreate "14. Cleanup session"
TaskCreate "15. Inline summary"
```

All 15 always queued. Trivial branch at step 3 marks 4-13 completed-skipped.

## Tier matrix

| Tier     | Decided at | Effect                                                                |
|----------|------------|-----------------------------------------------------------------------|
| trivial  | step 3     | Step 3.1 inline `Edit` / `Write` -> jump to 14. Skips 4-13.           |
| economy  | step 7     | Step 8 executors run on Sonnet; step 11 skips `learn`.                |
| standard | step 7     | Step 8 executors run on the main session model; full tail.            |

## Step contracts (terse)

1. **Analyze** - inline. AskUserQuestion if ambiguous; abort = clean exit (no manifest yet, skip session-end-hook). Read `<project-root>/docs/project-context.md` (best-effort; absent = silent skip; cached for downstream; cap read at ~200 lines). When formulating the working interpretation, expect step 4 to emit a `goals[]` decomposition: single-task prompts -> one goal; multi-task / audit prompts ("make sure all X are properly Y") -> N enumerated goals. Internal bias only; no user-visible change at step 1.
2. **Session manifest** - `bash skills/apex/scripts/create-session.sh --cc-session-id "$(bash skills/apex/scripts/get-cc-session-id.sh)"`.
   - exit 0: `{session}` token to stdout; manifest written + producer-validated.
   - exit 10: stale-only -> auto-cleanup-and-proceed (`bash skills/apex/scripts/session-end-hook.sh <stale-token> --foreign` per stale; re-run create-session). Active-detected -> AskUserQuestion (`abort` | `proceed alongside` | `cleanup-stale-and-proceed`); dismiss/cancel = abort. On abort with no manifest: skip session-end-hook and exit cleanly.
3. **Trivial pre-flight** - inline. Trivial = ALL of: single file edit (or single new file) AND file path explicitly named in `original_prompt` AND no new public symbol / endpoint / component AND no cross-file dependency. ANY ambiguity = non-trivial.
   - **3.1** (trivial only): inline `Write` of `{session}-main-scope.json` (`allowed_files = [<the single file>] + safety paths`) + scope-check pointer at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt`. Inline `Write` of minimal hypothesis stub (`original_prompt` verbatim; `hypothesis` = one-line restatement; `complexity_hint = "low"`; `alternatives = [{interpretation: original_prompt, status: "kept", reason: "trivial path"}]`; producer-validate via `bash skills/apex/scripts/validate-json.sh hypothesis.schema.json <path>`). Inline `Edit` / `Write` of the target. Jump to step 14.
   - Trivial trade-off: skips verify (10), commit (12), reflect (13). User owns lint/build + `git add+commit` afterwards.
4. **Hypothesis** - inline emit. `original_prompt` (verbatim; do NOT paraphrase) + `hypothesis` (1-2 sentences) + `complexity_hint: low|medium|high` + `alternatives: [{interpretation, status: kept|rejected, reason}]` (1-3 entries; minItems: 1) + `goals: [string]` (1..N items; each a discrete actionable check or task; free-text 1-3 sentences. Single-task prompts: one goal verbatim. Multi-task / audit prompts: enumerate one goal per discrete check). `goals.length` drives downstream behaviour at step 6 (top-K), step 7 (deterministic tier rule), step 8.2 (per-goal task split), step 13 (non-convergence detection), step 15 (per-goal summary). For `discovered_paths` only: when `original_prompt` has no path tokens AND `complexity_hint != "low"`, spawn a small Explore subagent (`Agent(subagent_type: "Explore")`) to gather candidate paths; the subagent returns ONLY validated repo-relative paths (existing on disk). Otherwise persist `discovered_paths` empty/absent. Write to `.claude-tmp/apex-active/{session}-hypothesis.json`; producer-validate via `bash skills/apex/scripts/validate-json.sh hypothesis.schema.json <path>`. Validation failure = abort with explicit error.
5. **Load lessons + project docs** - `bash skills/apex/scripts/grep-lessons.sh <project-root> <term1> [<term2> ...]` reads `<project-root>/.claude/lessons-index.md` + `lessons.md` for keywords **extracted deterministically from `hypothesis.goals[]`** (same recipe as step 6: lowercase + tokenize + drop stopwords + drop <4-char tokens + dedupe; cap at top 8 by document-order). Same `goals[]` -> same keyword set. On non-empty output, spawn `agents/lesson-screener.md` (Haiku, single call; raw output + hypothesis explicit in spawn prompt) -> `.claude-tmp/apex-active/{session}-lesson-screened.json` (producer-validated against `lesson-screened.schema.json`); orchestrator reads `kept[]` only - the raw blob never enters working memory. Then `bash skills/apex/scripts/update-hit.sh <project-root>/.claude/lessons.md <line>...` bumps hit timestamps for kept line ranges only. Tolerate empty grep output (no `lessons-index.md` -> silent skip; screener also skipped). Project-context cached from step 1. Working memory propagates kept lessons + matched paths + project context to steps 6 / 8 / 9 / 10 / 11.
6. **Discovery** - agent `agents/discoverer.md` (Sonnet). Discovery cache check fires first via `bash skills/apex/scripts/discovery-cache.sh check <original_prompt> <project_root>` - hit -> reuse cached scope, write scope-check pointer, skip cascade (TTL 7 days OR HEAD diverged > 10 commits). Miss -> layered cascade (LSP -> Glob -> Grep -> screener gate); spawn-prompt seeds = regex tokens from `original_prompt` + `hypothesis.discovered_paths` + lessons paths + project-context paths + `project_root` (subagents do NOT inherit working memory; orchestrator propagates explicitly). Grep keywords are extracted **deterministically** from `hypothesis.goals[]` (lowercase + stopword drop + dedupe; no AI keyword emit). Screener top-K scales by `goals.length` (1 -> 15; 2-5 -> 30; >5 -> 50; default 30 when goals absent). Screener is an inner subagent spawned by `discoverer.md`. Output: `{session}-main-scope.json` + scope-check pointer; cache write via `bash skills/apex/scripts/discovery-cache.sh write` after a non-empty cascade result. Cascade-empty -> agent returns `{cascade_empty: true}`; orchestrator runs AskUserQuestion (`abort` | `proceed-with-discovered-or-prompt-paths`); dismiss/cancel = abort. Both empty -> abort runs `session-end-hook.sh` inline.
7. **Economy pre-flight** - inline **deterministic rule** (no AI emit, no subagent). Inputs: `{session}-hypothesis.json` (`goals`), `{session}-main-scope.json` (`allowed_files`).
   ```
   tier = "economy" if (
     len(hypothesis.goals) == 1
     AND len(allowed_files) <= 5
     AND no /\b(rewrite|migrate|redesign|new endpoint|new component)\b/i match in any goals[]
   ) else "standard"
   ```
   Reason string: `"len(goals)=N, allowed_files=M, rewrite_match=<true|false>"` (mechanical; reproducible run-to-run). Write `{session}-tier.json`; producer-validate via `bash skills/apex/scripts/validate-json.sh tier.schema.json <path>`. Drives step 8 executor model + step 11 learn skip. Same prompt + scope -> same tier, every run.
8. **Execute** - skill `skills/apex/execute.md`. 8.0 baseline + conflict check; 8.1 wc-l split queue; 8.2 **goals-driven task split** (`len(goals)==1` -> 1 task; `len(goals)>1` -> N tasks, one goal per executor by default, with coupled pairs sharing scope (shared JSON files, controller+BFF) merged into one task before disjoint validation; per-task `allowed_files` narrowed to the main-scope subset matching the goal's deterministic noun set) + **scope-size hard split (B1)** when per-task `allowed_files` > 8 (`python3 skills/apex/scripts/chunk-scope.py -n 2`) + disjoint-scopes validation (`python3 skills/apex/scripts/validate-disjoint-scopes.py`); 8.3 dispatch `agents/executor.md` per task (Sonnet if economy, main model if standard; spawn-prompt carries the single goal + scope budget hint E2 + explicit working-memory propagation). Each executor returns `{goal, status, notes, tool_calls_made, files_touched}` where status is `implemented` | `already-satisfied` | `failed` | `split-needed` (C1 self-assessment with residual_goal/residual_files/what_i_did). Each return appended to `{session}-traces/execute/dispatch-summary.json` (E1). On `split-needed`, orchestrator re-spawns ONE follow-up with the residual (cap 1 per goal); second `split-needed` -> failed. Orchestrator collects per-goal results for step 15. Orchestrator MUST NOT inline `Edit` / `Write` / `MultiEdit` / `NotebookEdit` of scope files at step 8.
9. **Polish** - agent `agents/polish.md` (Sonnet). Spawn-prompt: `session`, `main_scope_path`, `baseline_head_sha`, `lessons_hits` (advisory; subagents do NOT inherit working memory). Agent computes touched-by-apex set (`(git diff --name-only {baseline.head_sha}; git ls-files --others --exclude-standard) | sort -u`) INTERSECTED with `allowed_files`; performs in-scope-only fixes (unused imports / dead code / leftover comments / naming). Hard cap = intersected set; scope-check hook is outer guard. Returns one-line summary; no-op exit if nothing actionable.
10. **Verify** - `bash skills/apex/scripts/verify-build.sh --session {session} --with-tests` (project-aware: `package.json` / `Cargo.toml` / `pyproject.toml` / `go.mod`; first-fail-stop). `--session` is required (validates 8-hex; mismatch with `apex-baseline.sh`'s positional style is intentional - keep the flag explicit at every callsite). `--with-tests` delegates to `verify-tests.sh` after lint/typecheck/build pass: derives modified files from `{session}-baseline.json` head_sha, maps them to project-specific test files (vitest `--related` / jest `--findRelatedTests` / heuristic glob; `cargo test -p <pkg>` per touched workspace member; `pytest` on related test files; `go test ./<dir>/...` per touched dir), runs only those. Auto-skips silently when no baseline / no test runner / zero derived test files - failure feeds the same fix-loop as build errors.
    - exit 0 = clean, proceed.
    - non-zero = errors at `.claude-tmp/apex-active/{session}-verify-errors.txt`. Dispatch `agents/executor.md` (always Sonnet, regardless of step 8 tier; trace at `{session}-traces/verify/fix-{attempt-N}.md`). Counter at `{session}-fix-attempts.json` (producer-validated). Cap 3. On cap exhaustion: AskUserQuestion (`abort` | `proceed-with-errors`). `abort` -> clean exit via `session-end-hook.sh {session}` inline. `proceed-with-errors` -> append errors to `~/.claude/tmp/git-agent-errors.log`; fall through to step 11.
11. **Tail** (foreground; Sonnet latest):
    - **standard**: parallel(`agents/documentation.md`, `agents/learn.md`).
    - **economy**: `agents/documentation.md` only (`learn` skipped).
    - Both read `git diff {baseline.head_sha}`. `learn` appends to `.claude-tmp/lessons-tmp.md` under `flock` (via `bash skills/apex/scripts/append-with-lock.sh`).
12. **VERSION bump + git sync** - agent `agents/git-sync.md` (Haiku). Spawn-prompt: `session`, `baseline_head_sha`, `version_path` (`<project-root>/VERSION`; missing = silent skip the bump but still commit / push). Agent reads diff, classifies `minor` | `patch` (never `major` - user-set only), runs `bump-version.sh` + `git-stage-files.sh` + commit + push (one chained Bash call). `git-stage-files.sh` owns the change-set + filters (pre-dirty / dotenv allowlist / `git check-ignore` / cross-session). Push fail-silent (errors -> `~/.claude/tmp/git-agent-errors.log`). Returns `{status, commit_sha, bump_kind}`.
13. **Self-reflect** - `bash skills/apex/scripts/reflect-traces.sh --session {session}` writes a heuristic block to `~/.claude/tmp/apex-workflow-improvements.md` under `flock` (via `bash skills/apex/scripts/append-with-lock.sh`). Then spawn `agents/reflector.md` (Haiku, **foreground**, silent). Reflector reads traces in-place from `.claude-tmp/apex-active/{session}-traces/` (NO snapshot - step 14 cleanup is the only follow-up and explicitly blocks on step 13). Reflector also runs **non-convergence detection**: appends `{ts, session, hash=sha1(normalized original_prompt), scope_count, touched_count, files_touched}` to `~/.claude/tmp/apex-prompt-history.log`; on hash collision with a prior session that touched a different file set, surfaces a `non-convergence:` line in `improvements:` for `/apex-improve` to consume.
14. **Cleanup session** - `bash skills/apex/scripts/cleanup-session.sh --session {session} --post-success`. Idempotent. `--post-success` bypasses the live-PID guard for trusted own-session callers. Does NOT clean `{session}-hypothesis.json` (consumed by step 15).
15. **Inline summary** - inline. Read `{session}-hypothesis.json` (preserved by step 14) + the per-goal status map collected at step 8.3. Emit:
    - Original prompt summary (from `original_prompt`)
    - Hypothesis vs reality (gaps spotted)
    - Per-goal status: `N/M goals passed` (count of `implemented` + `already-satisfied` over `len(goals)`); list each goal with its status + one-line note. First and only place the user sees the goal decomposition - as a record of what was done, never as a question.
    - Short executive summary
    On success: remove `.claude-tmp/apex-active/{session}-hypothesis.json` (consumer cleans up its own input; SessionEnd-hook fallback otherwise).

## Mid-flow abort cleanup

Any orchestrator exit bypassing step 14 runs `bash skills/apex/scripts/session-end-hook.sh {session}` inline. Triggers:
- AskUserQuestion-abort at step 1 (no manifest yet -> skip session-end-hook)
- AskUserQuestion-abort at step 2 active-detected (no manifest written -> skip)
- Step 6 cascade-empty + abort
- Step 6 cascade-empty + proceed-with-prompt-paths but zero validated paths
- Step 8 conflict-check abort
- Step 10 verify cap-3 + `abort`
- Any unexpected error path

Claude Code SessionEnd hook catches the case where the entire CC session ends mid-/apex; the inline call covers "user aborts /apex but stays in the same CC session" so the manifest does not orphan and trigger false-positive concurrency from sibling /apex calls.

See `apex-core.md` for the full per-step contract (artifacts, exit codes, schemas, abort paths) and Conventions block (safety paths, cc_session_id resolution, manifest schema, scope-check hook, file-health hook, trace path schema, JSON-Schema validation).
