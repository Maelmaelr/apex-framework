# /apex

Apex is the main orchestrator in the main session.

For a summary of steps, skill / agent / script used, and routing conditions, see `apex-core-overview.md`.

## Tiers (cross-cutting)

- **trivial** decided at step 3 (conservative pre-flight; ANY ambiguity = non-trivial). Step 3.1 inline single Edit/Write -> jump to step 14. Skips 4-13.
- **economy** decided at step 7 by inline AI judgement. Step 8 executors run on Sonnet; step 11 skips `learn`.
- **standard** default at step 7 when AI judgement does not classify economy. Step 8 executors run on the main session model; full tail.

## Conventions

- **Standard safety paths** (always allowed in any scope artifact): `.claude-tmp/`, `~/.claude/tmp/`, `/tmp/{session}-*`, project `docs/**`, and any `README*` file at any depth. The set is closed. `.env*` and `.git/` are NEVER safety paths regardless of scope contents.
- **Project context** (architecture entry point): `<project-root>/docs/project-context.md`. Read at step 1 (best-effort; absent = silent skip). Cached for downstream steps via working memory; consumers re-read directly when their work requires it.
- **Project lessons paths**: `<project-root>/.claude/lessons-index.md` (curated index; consumed by step 5 `grep-lessons.sh`), `<project-root>/.claude/lessons.md` (curated body), `<project-root>/.claude/lessons-archive.md` (older / superseded). `learn.md` (step 11) appends novel patterns to `.claude-tmp/lessons-tmp.md`; curation is out of scope for /apex.
- **Session token format**: 8-char lowercase hex (short guid generated at step 2 via `openssl rand -hex 4`).
- **cc_session_id resolution**: Claude Code does NOT export the active session id as a bash env var. Every apex script that needs `cc_session_id` resolves through `scripts/get-cc-session-id.sh` (env-var fast path then most-recent-jsonl fallback at `~/.claude/projects/<encoded-cwd>/`, where `<encoded-cwd> = pwd | tr '/.' '--'`). Step 2 invokes `create-session.sh --cc-session-id "$(bash scripts/get-cc-session-id.sh)"`.
- **JSON Schema validation helpers**: `scripts/_validate.py` (python module - `producer_validate(data, schema_name)` raises `ValidationError`; `consumer_load(path, schema_name)` returns `None` on missing/invalid; schema dir resolved via `APEX_SCHEMA_DIR` env var if set, otherwise defaults to `skills/apex/schemas/` relative to the module) and `scripts/validate-json.sh <schema-name> <json-path>`. Producer scripts validate before write; orchestrator inline-LLM producers (steps 4, 7) validate immediately after `Write`. Apex hot path falls back to JSON-parse-only when `jsonschema` is not importable (one-line stderr warning).
- **Session manifest schema** (`.claude-tmp/apex-active/{session}.json`): `{session, pid, cc_session_id}`. `pid` is the OS process id of the live claude main process - resolved by `scripts/find-claude-pid.sh` (walks up the process tree from the script's `$$` until a process with `comm` basename `claude` is found). `cc_session_id` is the Claude Code session id captured at step 2.
- **Scope write producers** (single source of truth for `{session}-main-scope.json`, exactly one fires per session): trivial path -> orchestrator inline `Write` at step 3.1; non-trivial path -> `discover.md` at step 6.
- **Scope-check pointer**: written immediately after each scope write at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt` (single-line absolute path to the scope JSON). The PreToolUse hook reads this pointer to gate `Edit` / `Write` / `MultiEdit` / `NotebookEdit`.
- **Trace path schema**: `.claude-tmp/apex-active/{session}-traces/{phase}/{agent}[-{disambiguator}].md` where `{phase}` is `entry` (steps 1-7), `execute` (step 8), `verify` (step 10), or `tail` (step 11). `{disambiguator}` is optional (task-id, attempt-N).
- **scope-check hook** (`skills/apex/scripts/scope-check-hook.sh`): PreToolUse on `Edit` / `Write` / `MultiEdit` / `NotebookEdit`. Bash file operations (`sed -i`, redirection, `cp`, `mv`, etc.) are NOT gated by the hook; subagent and skill prompts must restrict file modifications to the hook-gated tools (convention-enforced at the prompt layer). Resolves the active scope file via on-disk pointer (env-var indirection rejected: Claude Code's Bash tool runs each invocation in a fresh subshell). The hook extracts `session_id` from its stdin event JSON and globs `.claude-tmp/apex-active/*-scopes/{session_id}.txt` (any apex `{session}` matches; in practice exactly one matches the calling session_id). When no pointer file matches, the hook is pass-through.
- **file-health hook** (`skills/apex/scripts/file-health-hook.sh`): PreToolUse safety net during step 8 execute. Blocks `Edit` / `Write` on files > 500 LOC; nudges to split first. Pre-flight wc-l queue at step 8 init handles the > 400 LOC cases ahead of edits to avoid hot-path stalls.

## Apex flow

0. Initialisation
   - /apex (main orchestrator) | `~/.claude/skills/apex/SKILL.md`
     - TaskCreate tasks 1 - 15 (15 always queued; trivial branch at step 3 marks 4 - 13 completed-skipped)

1. Analyze + read project-context.md
   - inline task prompt
     - analyzes prompt
     - AskUserQuestion if ambiguous; abort = clean exit (no manifest yet)
     - reads `<project-root>/docs/project-context.md` if present (best-effort; absent = silent skip)

2. Create session manifest | Blocked by #1
   - script `scripts/create-session.sh --cc-session-id "$(bash scripts/get-cc-session-id.sh)"`
     - exit 0: `{session}` token to stdout; manifest written + producer-validated against `manifest.schema.json`
     - exit 10: overlap detected. Script writes detected state to stderr (active / stale manifests). Orchestrator branches on parsed state:
       - **stale-only** (active absent, stale present): auto-cleanup-and-proceed without prompting. For each stale token: `bash scripts/session-end-hook.sh <stale-token> --foreign`; then re-run `create-session.sh`. The `--foreign` flag arms `cleanup-session.sh`'s live-PID guard against sibling classifier bugs.
       - **active-detected**: AskUserQuestion (`abort` always present; `proceed alongside` always present; `cleanup-stale-and-proceed` only if stale also present; dismiss/cancel = abort). On abort: no manifest exists yet, so `session-end-hook.sh` is skipped; exit cleanly.

3. Trivial pre-flight | Blocked by #2
   - inline task prompt
     - **Trivial = ALL of**: single file edit (or single new file), file path explicitly named in `original_prompt`, no new public symbol / endpoint / component, no cross-file dependency. **ANY ambiguity = non-trivial.**
   - if trivial:
     - **3.1** orchestrator performs the inline `Edit` / `Write` directly. Before the edit, orchestrator writes `{session}-main-scope.json` inline (`allowed_files = [<the single file>] + safety paths`) and writes the scope-check pointer. Orchestrator also writes a **minimal hypothesis stub** at `.claude-tmp/apex-active/{session}-hypothesis.json` (`original_prompt` verbatim; `hypothesis` = one-line restatement; `complexity_hint = "low"`; `alternatives = [{interpretation: original_prompt, status: "kept", reason: "trivial path"}]`; producer-validates against `hypothesis.schema.json`) so step 15's summary contract stays uniform across trivial / non-trivial. After the edit, jumps to task 14.
     - **trivial trade-off**: skips verify (10), commit (12), reflect (13). The conservative gate (single named file, no new public symbol, no cross-file dep, ANY ambiguity disqualifies) keeps the edit reversible and small; the user owns lint/build verification and the `git add+commit` afterwards. Misclassification is on the gate, not the trivial path.
     - tasks 4 - 13 marked completed-skipped so TaskList reflects reality.

4. Hypothesis | Blocked by #3
   - inline task prompt
     - emits `original_prompt` (verbatim user prompt - preserves wording for downstream reflector and step 15 summary; do NOT paraphrase)
     - emits `hypothesis` (1 - 2 sentence working interpretation; not a plan, not a task list)
     - emits `complexity_hint: low|medium|high` (advisory; consumed by step 7 economy classifier as one signal)
     - emits `alternatives: [{interpretation, status: kept|rejected, reason}]` - 1 - 3 narrower / broader scope readings, each a structured anti-bias check. minItems: 1 schema-required.
     - emits `discovered_paths: [<paths>]` (optional) - validated repo-relative paths captured via bounded inline `Glob` / `Grep` / `Read` (cap ~5 calls) when the prompt is conceptual. Persist only paths that exist on disk. Empty / absent when the prompt itself names paths or is too abstract.
     - writes `.claude-tmp/apex-active/{session}-hypothesis.json`; producer-validates via `bash scripts/validate-json.sh hypothesis.schema.json <path>`. On validation failure: abort with explicit error.

5. Load lessons + project docs | Blocked by #4
   - script `scripts/grep-lessons.sh <project-root> <term1> [<term2> ...]` reads `<project-root>/.claude/lessons-index.md` + `lessons.md` for ~8 keywords derived from `{session}-hypothesis.json`. Emits `--- LINES s-e ---` blocks (absolute line numbers in `lessons.md`); 150-line cap with `TRUNCATED` footer.
   - script `scripts/update-hit.sh <project-root>/.claude/lessons.md <line>...` bumps hit timestamps for matched line ranges (idempotent; skips if today's date already present).
   - tolerate empty output (no `lessons-index.md` -> silent skip).
   - project-context.md read cached from step 1.
   - working memory: lessons hits + matched paths + project context propagate to step 6 (discovery seeds) and steps 8 / 9 / 10 / 11 (advisory context for executor / polish / verify-fix / documentation / learn).

6. Discovery | Blocked by #5
   - skill `~/.claude/skills/apex/discover.md`
   - **seeds** (cheap, pre-paid in working memory):
     a. regex path-tokens from `original_prompt` (project-tree-shaped + quoted/backticked tokens)
     b. `hypothesis.discovered_paths`
     c. paths / symbols mentioned in step 5 lessons hits
     d. paths mentioned in `<project-root>/docs/project-context.md`
   - **layered cascade** (stop at lowest non-empty bounded set; each layer optional):
     a. **LSP** find-references / definition (when seeds name an identifier-shape symbol; TS-only via typescript-language-server; silent no-op on non-TS repos)
     b. **Glob** sibling-pattern expansion (routing / registry / index splits: when a seed is `routes.ts`, Glob `routes_*.ts` etc.)
     c. **Grep** keyword search (capped ~150 lines; narrower keywords if cap hit)
     d. **Screener LLM gate**: agent `~/.claude/agents/screener.md` (Sonnet, single call). **Always fires** when the cascade reaches this layer (any non-empty layer output flows through screening; cheap Sonnet pass over a ranked top-K cap is the right default - prevents an unscreened LSP / Glob overshoot from becoming scope unilaterally). Reads ranked list + hypothesis; returns keep / drop + relevance per file. Writes `.claude-tmp/apex-active/{session}-screened.json` (`{kept: [{file, screener_reason}], dropped: [{file, screener_reason}]}`; producer-validated against `screened.schema.json`); trace at `.claude-tmp/apex-active/{session}-traces/entry/screener.md`. Consumed by step 13 reflector for accuracy / efficiency evaluation.
   - **output**: `.claude-tmp/apex-active/{session}-main-scope.json` (`{allowed_files: [string]}`); producer-validated against `main-scope.schema.json`.
   - writes scope-check pointer at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt`.
   - **cascade-empty abort**: if all layers exhaust with zero validated paths, AskUserQuestion (`abort` | `proceed-with-discovered-or-prompt-paths` -> first re-use `hypothesis.discovered_paths` (validated at step 4); fall back to regex-extract from `original_prompt` only if `discovered_paths` is empty/absent; validate on disk, write scope with those + safety paths). Both empty -> abort runs `session-end-hook.sh {session}` inline.

7. Economy pre-flight | Blocked by #6
   - inline task prompt (AI judgement; single inline emit, no subagent)
   - inputs: `{session}-hypothesis.json`, `{session}-main-scope.json` (file count + paths), step 5 lessons hits.
   - prompt template:
     ```
     Classify tier: "economy" | "standard".
     Economy when: bounded scope, no new public abstractions, reversible risk, no cross-cutting concerns.
     Standard when: unclear scope, new public surface, irreversible risk, or "rewrite/migrate/redesign" intent.
     Output JSON: {"tier": "economy"|"standard", "reason": "<one line>"}
     ```
   - writes `.claude-tmp/apex-active/{session}-tier.json`; producer-validates against `tier.schema.json`.
   - downstream effect: step 8 executor model (Sonnet vs main); step 11 learn skip flag.

8. Execute | Blocked by #7
   - skill `~/.claude/skills/apex/execute.md`
   - **8.0 init**:
     - capture working-tree baseline: `scripts/apex-baseline.sh` writes `.claude-tmp/apex-active/{session}-baseline.json`: `{head_sha: "<git rev-parse HEAD>", pre_dirty: [<repo-relative paths>]}`. `pre_dirty` = `(git diff --name-only HEAD; git ls-files --others --exclude-standard) | sort -u` captured BEFORE any apex edits. Consumed by steps 9 / 11 / 12 / 13. Step 12 excludes `pre_dirty` from staging so user-pre-existing WIP is never bundled into the apex commit.
     - concurrent-apex conflict check via `scripts/apex-conflict-check.sh`: reads `pre_dirty` from baseline; for each, scan `.claude-tmp/apex-active/*-main-scope.json` excluding our own `{session}` token. On overlap (a pre-dirty file appears in another active apex session's `allowed_files`): AskUserQuestion (`abort` | `proceed-anyway`; dismiss/cancel = abort). On proceed, the apex edit lands on top of the user WIP; the merged file stays dirty post-apex (excluded from step 12) for the user to review and commit.
   - **8.1 pre-flight wc-l split queue**:
     - `wc -l` on `{session}-main-scope.json` `allowed_files`. For each file > 400 LOC: queue an executor task with `--mode split` AHEAD of normal edit tasks. Files > 500 LOC always split. Continuous-prose docs exempt (`*.md` heuristic + skill author judgement).
     - `file-health-hook.sh` (PreToolUse) is the safety net for files that grow during execution.
   - **8.2 task split + disjoint scopes (orchestrator-decided)**:
     - the **main orchestrator** decides task count and per-task allowed-files subsets. Default = 1 executor task spanning the full scope. The orchestrator splits into 2+ parallel tasks only when it identifies clearly independent areas (e.g., disjoint subsystems, unrelated file clusters).
     - when 2+ tasks are spawned, the orchestrator validates per-task allowed-files via `scripts/validate-disjoint-scopes.py`: (i) per-task `allowed_files` pairwise disjoint (excluding safety paths), (ii) union is a subset of `{session}-main-scope.json` `allowed_files`. Cross-task touch points are routed to a serialised follow-up task (no parallel write conflict).
   - **8.3 dispatch**:
     - per-task: agent `~/.claude/agents/executor.md` (Sonnet if `tier=economy`, main session model if `tier=standard`)
     - **spawn-prompt context (executor stack)**: each spawn carries the executor's input stack from main-orchestrator working memory - hypothesis (verbatim), per-task scope (allowed_files subset), step 5 lessons hits relevant to the task, project-context paths, and the task description. Subagents do NOT inherit working memory, so this propagation is explicit-by-spawn.
     - executor respects file-health PreToolUse hook (safety net)
     - on failure or split decision: executor writes trace to `.claude-tmp/apex-active/{session}-traces/execute/executor-{task-id}.md` before returning summary
   - **dispatch-only step**: orchestrator MUST NOT inline `Edit` / `Write` / `MultiEdit` / `NotebookEdit` slice files at step 8.

9. Polish | Blocked by #8
   - inline task prompt (runs on host model)
   - touched-by-apex set: `(git diff --name-only {baseline.head_sha}; git ls-files --others --exclude-standard) | sort -u` from `{session}-baseline.json`
   - INTERSECTED with `allowed_files` from `{session}-main-scope.json` (pre-existing user-dirty files outside scope are NOT polished; still committed as-is at step 12).
   - in-scope-only fixes:
     - unused imports orphaned by step 8 changes
     - dead code orphaned by step 8 (functions / branches no longer called)
     - leftover commented-out blocks in touched lines
     - obvious naming inconsistencies in newly-touched lines
   - lessons hits from step 5 inform staleness signals (advisory).
   - HARD CAP: enforced by intersected set; scope-check hook is outer guard.
   - no-op exit if nothing actionable.

10. Verify | Blocked by #9
    - script `scripts/verify-build.sh` runs lint + build (project-aware: detects `package.json` / `Cargo.toml` / `pyproject.toml` / `go.mod`; runs only the available lint / typecheck / build commands; first-fail-stop)
      - exit 0 = clean, proceed to 11
      - exit non-zero = errors written to `.claude-tmp/apex-active/{session}-verify-errors.txt`
    - if non-zero exit:
      - dispatch agent `~/.claude/agents/executor.md` (**always Sonnet** - fix-loop is bounded and Sonnet is sufficient; orthogonal to step 8's tier-conditional model selection so a standard-tier session doesn't pay Opus rates per fix attempt) with errors file as input; trace path: `.claude-tmp/apex-active/{session}-traces/verify/fix-{attempt-N}.md`
      - attempt counter in `.claude-tmp/apex-active/{session}-fix-attempts.json`; producer-validated against `fix-attempts.schema.json` before each write
      - cap at 3 attempts
      - on cap exhaustion: AskUserQuestion (`abort` | `proceed-with-errors`; dismiss/cancel = abort). On `abort`: clean exit via `session-end-hook.sh {session}` inline. On `proceed-with-errors`: append the verify-errors body to `~/.claude/tmp/git-agent-errors.log` and fall through to step 11 with the build still broken (the user explicitly chose to commit a known-broken state).

11. Tail (foreground; Sonnet latest) | Blocked by #10
    - **standard**: parallel(`documentation.md`, `learn.md`).
    - **economy**: `documentation.md` only (`learn.md` skipped - small scope rarely produces novel project-specific patterns worth distilling).
    - agent `~/.claude/agents/documentation.md` reads `git diff {baseline.head_sha}`; updates project docs / architecture notes when structural changes warrant.
    - agent `~/.claude/agents/learn.md` reads `git diff {baseline.head_sha}`; appends novel patterns / lessons to `.claude-tmp/lessons-tmp.md` under `flock`.
    - distinction: `learn.md` is project-specific (codebase patterns); `reflector.md` (step 13) is apex-specific (workflow / pipeline improvements).

12. VERSION bump + git sync | Blocked by #11
    - script `scripts/bump-version.sh`:
      - reads `<project-root>/VERSION`. Expects `vX.Y.Z`; tolerates missing-`v` and trailing newlines. Missing file = silent skip (proceed to git without bump).
      - inline classify diff (model judgement) -> `minor` | `patch`. **Never `major`** (major is user-set only; if a project needs a major bump the user edits VERSION manually outside /apex).
        - **minor**: new feature, new public symbol / route / component, additive, OR breaking API change (removed/renamed public symbol, contract change, schema migration)
        - **patch**: bug fix, refactor, tweak, internal-only change
      - increments matching segment; resets patch=0 on minor bump; writes back to VERSION.
    - single chained git command (one Bash call): `bash scripts/git-stage-files.sh --head-sha {baseline.head_sha} --session {session} && git commit -m "<freeform>" && git push`
      - `git-stage-files.sh` is the single source of truth for the change-set + filter pipeline:
        - **change set**: `(git diff --name-only {baseline.head_sha}; git ls-files --others --exclude-standard) | sort -u` (covers apex-modified tracked files AND apex-newly-created untracked files; the latter required because `git diff` excludes untracked).
        - **pre-dirty filter**: drop paths in `{baseline.pre_dirty}` (captured at step 8.0). User-pre-existing WIP is never bundled into the apex commit, even when apex deliberately edited a pre-dirty file (the merged change stays dirty for the user).
        - **dotenv pre-filter**: skip basenames matching `.env*` UNLESS in allowlist `{.env.example, .env.sample, .env.template}`. Aligns with `protect-env-hook.sh`; only protection for `git add` when project's `.gitignore` is incomplete.
        - **`git check-ignore` filter**: covers `.claude-tmp/` and the project's `.gitignore`.
        - **cross-session filter**: drop paths claimed by another active session's `*-main-scope.json` `allowed_files`.
        - per-file `git add` for the surviving set.
      - commit message: freeform from diff context (`git diff --staged --stat` + `git diff --staged`); VERSION bump may be referenced in title.
      - fail-silent on push errors (no upstream / non-fast-forward; never `--force`, never auto-set-upstream); errors logged to `~/.claude/tmp/git-agent-errors.log`. Returns success to main so step doesn't fail.

13. Self-reflect | Blocked by #12
    - **Reflection principle**: compare (a) what the session DID (pipeline executed + tasks completed per end-of-session summary) against (b) what it SHOULD have done (pipeline-as-spec + `original_prompt` + hypothesis from `{session}-hypothesis.json`). Spot gaps and what could have been done better.
    - script `scripts/reflect-traces.sh` does heuristic pattern matching on traces:
      - regex for `error|failed|skip` (gap signals)
      - count `fix-{attempt-N}.md` files
      - list traces > N lines (verbose-reasoning improvements)
      - appends structured block to `~/.claude/tmp/apex-workflow-improvements.md` under `flock ~/.claude/tmp/apex-workflow-improvements.md.lock` (portable Python `fcntl.flock` via `scripts/append-with-lock.sh`):

        ## {session} - heuristics - {timestamp}
        - gap_signals: <count>
        - fix_attempts: <count>
        - verbose_traces: <count>
        - novel_flagged: <count>
        - novel_traces: <comma-separated trace paths, max 5>

      - flags traces as "novel" when patterns don't match heuristic categories.

    - agent `~/.claude/agents/reflector.md` (Haiku, **foreground**, silent) - always fires; focus driven by the `novel_traces` line. Foreground because step 14 cleanup is the only follow-up and explicitly blocks on step 13 - no need for background spawn or trace snapshot.
      - inputs: `git diff --stat {baseline.head_sha}` plus `git ls-files --others --exclude-standard`, `.claude-tmp/apex-active/{session}.json` (manifest -> reads `cc_session_id` -> loads main-orchestrator TaskList from `~/.claude/todos/{cc_session_id}-agent-{cc_session_id}.json`), the latest heuristics block in `~/.claude/tmp/apex-workflow-improvements.md`, `.claude-tmp/apex-active/{session}-screened.json` (when present; for screener accuracy / efficiency evaluation against actual touched-by-apex set), all trace files under `.claude-tmp/apex-active/{session}-traces/**/*.md` (read in-place; no snapshot).
      - emits structured append (minimal prose) under shared `flock`:

        ## {session} - reflect - {timestamp}
        - gaps: <one-line per gap, max 3>
        - fixes-observed: <one-line per fix-attempt observed in traces, max 3>
        - improvements: <one-line per suggestion, max 3>
        - workflow-respected: <yes | step-X: <deviation>, max 3>
        - token-reductions: <step-X: <reduction>, max 3>
        - screener-eval: <skipped (no screened.json) | dropped-but-touched: N | kept-but-untouched: N>, max 1>

      - empty-input gate: when traces dir is empty AND manifest read fails, emits SKIPPED-no-inputs sentinel (`## {session} - reflect - SKIPPED-no-inputs - {ts}`) instead of the structured block; consumed by `/apex-improve` analyze phase pre-cluster drop.
      - errors logged to `~/.claude/tmp/reflector-errors.log` (silent failure otherwise).
      - shuts down silently (no main-session output).

14. Cleanup session | Blocked by #13
    - script `scripts/cleanup-session.sh` (idempotent; exit 0 on partial cleanup with warnings to stderr).
    - cleans (only this session's files; concurrent sessions untouched):
      - `.claude-tmp/apex-active/{session}-main-scope.json`
      - `.claude-tmp/apex-active/{session}-scopes/`
      - `.claude-tmp/apex-active/{session}-screened.json`
      - `.claude-tmp/apex-active/{session}-tier.json`
      - `.claude-tmp/apex-active/{session}-traces/`
      - `.claude-tmp/apex-active/{session}.json`
      - `.claude-tmp/apex-active/{session}-fix-attempts.json`
      - `.claude-tmp/apex-active/{session}-baseline.json`
      - `.claude-tmp/apex-active/{session}-verify-errors.txt`
    - **Intentionally NOT cleaned** (consumed by step 15): `.claude-tmp/apex-active/{session}-hypothesis.json`. Step 15 removes it after use; `session-end-hook.sh` is the idempotent fallback.
    - **Live-session guard + --post-success bypass**: by default, `cleanup-session.sh` reads the manifest's `pid` and refuses cleanup if the PID is alive AND `ps -o comm=` matches `claude` (defends against sibling classifier bugs). `--post-success` bypasses the guard for trusted own-session callers (step 14 success path, mid-flow abort, SessionEnd of own session). Without that flag the guard would block legit own-cleanup since manifest.pid is the still-alive caller's claude pid.

15. Inline summary | Blocked by #14
    - inline task prompt reads `{session}-hypothesis.json` (preserved by step 14)
    - emits:
      - Original prompt summary (from `original_prompt` field)
      - Short hypothesis vs reality (gaps spotted) summary
      - Short executive summary
    - on success: removes `.claude-tmp/apex-active/{session}-hypothesis.json` (consumer cleans up its own input; SessionEnd-hook fallback otherwise).

## Failure handling

- `cleanup-session.sh` is idempotent: exit 0 on partial cleanup with warnings to stderr. Live-session guard refuses cleanup if manifest.pid is alive AND `ps -o comm=` matches `claude`. `--post-success` bypasses the guard for trusted own-session callers.
- `session-end-hook.sh` wraps `cleanup-session.sh` and additionally removes `{session}-hypothesis.json`. Manual mode without `--foreign` passes `--post-success` to `cleanup-session.sh` (mid-flow abort = trusted own-session caller); with `--foreign` (step 2 cleanup-stale-and-proceed per-stale invocation), the flag is omitted so the live-PID guard fires defensively.
- **Mid-/apex abort cleanup**: any orchestrator exit bypassing step 14 runs `session-end-hook.sh {session}` inline. Triggers:
  - AskUserQuestion-abort at step 1 (no manifest yet -> skip session-end-hook)
  - AskUserQuestion-abort at step 2 active-detected (no manifest written for this session -> skip)
  - step 6 cascade-empty + abort
  - step 6 cascade-empty + proceed-with-prompt-paths but zero validated paths
  - step 8 conflict-check-abort
  - step 10 verify cap-3 exhaustion (if user opts to abort)
  - any unexpected error path
- The Claude Code SessionEnd hook is the catch-all when the entire Claude Code session ends; the inline call handles the "user aborts /apex but stays in the same Claude Code session" case so the manifest does not orphan and trigger false-positive concurrency detection from sibling /apex calls.
