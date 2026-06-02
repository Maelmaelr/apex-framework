# /apex - Skeleton

What to load, when, under what condition. Full spec: `apex-core.md`.

Legend: `inline` = main-orchestrator inline prompt | `skill` = `~/.claude/skills/apex/*.md` | `agent` = `~/.claude/agents/*.md` | `script` = `~/.claude/skills/apex/scripts/*`.

---

## Tiers

| Tier     | Decided at | Effect                                                                                            |
| -------- | ---------- | ------------------------------------------------------------------------------------------------- |
| trivial  | step 3     | step 3.1 inline edit + commit -> jump to 14. Skips 4-13.                                          |
| economy  | step 7     | step 8 executors = sonnet; step 9 polish skipped; step 10.5 review skipped; step 11 learn skipped. All other steps run. |
| standard | step 7     | step 8 executors = main session model; full tail.                                                 |

Step 13 reflector is **background** in non-trivial paths; reflector owns post-reflect `cleanup-session.sh`. Step 14 only runs on trivial path. Step 15 inline summary is fully deterministic (no LLM hop, no git audit pass).

---

## Entry flow

Step 0 TaskCreates 1-15 (trivial detection at step 3 may collapse 4-13 into "skipped").

```
1. Analyze prompt + read project-context.md: inline
   - if ambiguous: AskUserQuestion (abort | clarification options)
   - bias for step 4: expect goals[] decomposition (single goal for fix-bug-in-file-Y prompts; N enumerated goals for audit / multi-task prompts)

2. Create session: create-session.sh
   - exit 0: {session} token + worktree minted + manifest written.
   - token provenance (hard gate, incident 0abbda5f): thread ONLY the exact stdout {session} token into every `cd <main>/.apex-worktrees/{session}/...` prefix; never fabricate, guess, or reconstruct one (the shell is stateless between Bash calls -> the path is re-typed every command). After exit 0, `test -d` the worktree; if it does not resolve, HARD STOP and re-read stdout - a fabricated token cascades via Claude Code's parallel-batch abort (1 bad `cd` -> N cancelled siblings). Full contract: skills/apex/steps/02-manifest.md (token provenance).
   - exit 1: unrecoverable error (bad args, nested-worktree, detached HEAD, etc.); surface stderr and abort.
   - create-session.sh creates <main>/.apex-worktrees/<session>/ on branch apex/<session> off HEAD, cd's in, persists worktree_path/branch/base_branch in manifest. All subsequent steps run inside the worktree (isolated .claude-tmp/apex-active/, isolated index, isolated working tree). Per-worktree isolation removes the sibling-session conflict surface entirely - no concurrent-apex overlap detection / scope-overlap classification is needed at session mint. Per-project dep bootstrap is framework-owned in 3 layers (see apex-core.md Conventions / Worktree dependency bootstrap): create-session.sh symlinks gitignored caches + .env from main (Layer 1) and runs docs/apex-bootstrap.sh if present (Layer 2); verify-build.sh does a defensive --frozen-lockfile install when node_modules is still absent at step-10 (Layer 3). Nested-worktree / detached-HEAD / non-git-repo guards refuse to mint. Integration: /apex-merge (skills/apex-merge/SKILL.md, manual trigger from main worktree). State-mutating commands the executor ran in the worktree (migrations, seeders, codegen producing untracked output) are logged to {session}-side-effects.jsonl; /apex-merge step 4.5 aggregates + dedupes across all merged worktrees and surfaces the unique set via AskUserQuestion for replay on main. /apex-merge step 4.6 invokes apex-fix when 1+ conflicts were resolved in step 4 (merge resolution stitches code across branches and can leave lint regressions neither side carried alone); clean-merge-only runs skip.

3. Trivial pre-flight: inline
   - trivial = single-file edit, no new public symbol, named target file, ANY ambiguity = non-trivial
   - **verb-pattern relaxation**: prompt matching `/^\s*(rename|format|fix typos?|reword|add (a )?comment|remove (a )?comment|update copy|update string)\b/i` may resolve its target via single inline `Glob` (zero or 2+ matches = non-trivial); other trivial constraints unchanged
   - if trivial:
     - 3.1 inline single Edit/Write + lightweight commit (worktree lands as a clean mergeable apex/<session> branch awaiting /apex-merge, not a dirty leftover); orchestrator writes minimal hypothesis stub (original_prompt + one-line hypothesis) so step 15 contract stays uniform
     - jump to 14 (skip 4-13). Trade-off: no verify, no reflect, no push/bump_hint; user owns lint/build (the 3.1 inline commit already lands a clean mergeable apex/<session> branch).
   - if non-trivial: proceed to 4

4. Hypothesis: inline -> {session}-hypothesis.json
   - original_prompt, hypothesis, complexity_hint, alternatives, discovered_paths, goals (1..N free-text actionable items)
   - goals.length drives steps 6 (top-K), 7 (deterministic tier), 8.2 (per-goal split), 13 (non-convergence), 15 (per-goal summary)
   - validate-json.sh hypothesis.schema.json

5. Load lessons + project docs: grep-lessons.sh -> screener gate (K=25)
   - keywords for grep-lessons.sh extracted deterministically from hypothesis.goals[] (same recipe as step 6: lowercase + tokenize + stopword drop + dedupe). **Keyword cap**: top 8 keys by document-order; halve to top 4 and re-screen once on screener `truncated=true`
   - **gate**: grep output <= 25 lines -> orchestrator picks kept[] inline (no Haiku hop; screener_reason = "inline-pick: ..."); grep output > 25 lines -> spawn agents/lesson-screener.md (Haiku, single call; subagents do NOT inherit working memory; raw grep output + hypothesis explicit in spawn prompt). Either path writes {session}-lesson-screened.json. update-hit.sh runs on kept line ranges.
   - orchestrator reads kept[] only; raw grep blob never enters working memory
   - project-context.md cached from step 1
   - tolerate empty output (no lessons-index.md = silent skip; screener / inline pick also skipped)

6. Discovery: agents/discoverer.md (Sonnet; spawn-prompt carries seeds + hypothesis + session/cc_session_id + project_root; subagents do NOT inherit working memory)
   cache check first: discovery-cache.sh check <prompt> <project_root> -> hit -> reuse cached main-scope, skip cascade. Miss -> run cascade, then discovery-cache.sh write. TTL 7 days OR HEAD diverged > 10 commits.
   seeds: prompt regex + hypothesis.discovered_paths + lessons paths + project-context paths
   cascade (stop at lowest non-empty bounded set):
     a. LSP find-references / definition (when seeds name a symbol; TS-only today)
     b. Glob sibling-pattern expansion (routing/registry/index splits)
     c. Grep keyword search (capped ~150 lines; keywords extracted deterministically from hypothesis.goals[] via lowercase + stopword drop + dedupe)
     d. Screener inner subagent: agents/screener.md (single Sonnet call; spawned by discoverer.md; always fires when cascade reaches this layer; top-K scales by goals.length: 1->15, 2-5->30, >5->50)
   output: {session}-main-scope.json
   write scope-check pointer: .claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt

7. Economy pre-flight: inline deterministic rule (no AI emit, no subagent)
   - inputs: hypothesis.goals (length + text), main-scope.allowed_files (count)
   - rule: economy if (len(goals)==1 AND len(allowed_files)<=5 AND no /\b(rewrite|migrate|redesign|new endpoint|new component)\b/i in any goal text) OR (all goals[] reference one shared plan-file coordinate AND no /\b(rewrite|refactor|migrate|redesign|new endpoint|new component)\b/i -> single-plan-file multi-phase exception) OR (hypothesis.mode==report-only OR every goal a verify/check/audit predicate with no write target -> read-only audit fan-out, Sonnet suffices regardless of goals.length); else standard
   - output: {session}-tier.json (validated against tier.schema.json; same shape) -> reason "len(goals)=N, allowed_files=M, rewrite_match=<true|false>, single_plan_file=<true|false>, report_only=<true|false>"
   - same prompt + scope -> same tier, every run

8. Execute: steps/08-execute.md -> executor.md (per task)
   - 8.0 init: orchestrator resolves diff_anchor via `git merge-base $base_branch HEAD` (base_branch from manifest); modified files derived per-consumer via `git diff --name-only {diff_anchor}`. No producer file.
   - pre-flight wc -l on scope; >400 LOC -> queue split task ahead of edits
   - 8.2 goals-driven split: len(goals)==1 -> 1 task (full scope); len(goals)>1 -> N tasks, one goal per spawn prompt; per-task allowed_files narrowed to main-scope subset matching goal nouns; validate-disjoint-scopes.py enforces disjoint when 2+
   - 8.2 proactive decomposition scout (B0.7; standard tier only): non-coupled task with allowed_files ~3-8 OR complexity_hint==high OR a high-cost large set (>8 files AND audit/verify verb OR 3+ facets OR ~120k projected tokens -> runs BEFORE B1 so a large deep-iteration goal, e.g. A1's 23 files / 134 tool_uses, gets a judgment DAG not B1's coarse -n 2) -> one read-only agents/scout.md (~15 tool-call cap) returns sub-task DAG {subtasks:[{label,files,depends_on}], indivisible, reason} (subtask-plan.schema.json); indivisible -> dispatch whole, else one small executor per independent subtask joins the parallel set (depends_on chains serialized); scout only ADDS splits (files subset of allowed_files), advisory estimate never gates (Open risk 1); economy/trivial skip; closes the deep-iteration blind spot (small OR large file set) B0/B1/B2 counts miss
   - 8.2 scope-size hard split (B1): per-task allowed_files > 8 -> chunk-scope.py -n 2 partition (directory-sibling-preserving, pairwise-disjoint); goal text duplicates; first executor wins, second sees already-satisfied
   - spawn-prompt carries executor stack (hypothesis, single goal, per-task scope, scope budget hint E2 ["Expected: N files, ~K LOC; >2x -> split-needed"], lessons hits, project-context, task description) - subagents do NOT inherit working memory
   - parallel dispatch (mandatory when N >= 2 tasks): all tool_use blocks in ONE assistant message AND run_in_background:true on each; foreground multi-block serialises (user-flagged + reflector e1827632); sequential dispatch is only for coupled / B2 chain tasks
   - executor returns {goal, status, notes, tool_calls_made, files_touched} where status is implemented | already-satisfied | failed | split-needed (C1 self-assessment carries residual_goal + residual_files + what_i_did); orchestrator collects per-goal map for step 15
   - dispatch self-report log (E1): each return appended to {session}-traces/execute/dispatch-summary.json; reflector flags tool_calls_made > 50
   - split-needed redispatch (C1 follow-up): orchestrator re-spawns up to 2 follow-ups with residual_goal + residual_files (cap 2 per goal, under a ~100 tool_use / ~300k token per-goal cumulative-budget guard); third split-needed or budget breach -> failed
   - idempotency: same prompt -> same goals -> same N tasks; if goals were achieved last run, executors return already-satisfied -> empty diff -> step 12 skips commit
   - file-health hook = safety net during edits
   - executor model: sonnet if economy, main session model if standard
   - dispatch-only: orchestrator MUST NOT inline Edit/Write/MultiEdit/NotebookEdit slice files at step 8

9. Polish: agents/polish.md (Sonnet; spawn-prompt carries scope path + diff_anchor + lessons hits; subagents do NOT inherit working memory)
   - **skipped on economy tier** (small scope = small surface; verify catches functional issues)
   - touched INTERSECT scope
   - staleness / inconsistency / unused check
   - lessons context advisory

10. Verify: verify-build.sh --session {session} --with-tests --in-scope-only (apex hot path; apex-fix omits --with-tests / --in-scope-only but still passes --session)
    - lint + typecheck + build (project-aware, first-fail-stop)
    - --with-tests delegates to verify-tests.sh after build: derives modified files from manifest base_branch via merge-base, runs project test runner on related-only set (auto-skip when no manifest / no test runner / zero related)
    - if errors: executor.md (always Sonnet for fix-loop, regardless of step 8's tier; cap 3)
    - on cap exhaustion: AskUserQuestion (abort | proceed-with-errors)

10.5 Review (sub-step; runs ONLY on step 10 exit 0): steps/10-verify.md -> reviewer.md (Sonnet, foreground)
    - deterministic gate: tier==standard AND len(touched INTERSECT allowed_files)>=3 AND (complexity_hint==high OR any goal matches /\b(rewrite|migrate|redesign|refactor|new endpoint|new component|new feature)\b/i OR deletions across allowed_files >= 200 lines)
    - reviewer scans diff INTERSECT allowed_files against CLAUDE.md rules (pattern, over-engineering, security-at-boundaries, i18n, cognitive-complexity); cap 5 findings
    - returns {action: pass|fix-needed|escalate} validated against review-result.schema.json
    - fix-needed: executor.md cap-1 (Sonnet) -> re-spawn reviewer with attempt=2; persistent fix-needed -> escalate
    - escalate: AskUserQuestion (accept-and-proceed | apply-fix-manually | abort)
    - hard cap: 2 reviews + 1 fix; reviewer never edits files

11. Tail (foreground):
    - standard: documentation.md always; learn.md ONLY when difficulty gate holds (fix-attempts.json exists AND attempts>=1) - parallel when both run
    - economy: documentation.md only (learn skipped)

12. Commit + persist bump_hint: **inline** (orchestrator owns; no subagent hop)
    - classify diff -> minor | patch (never major; user-set only)
    - persist classified tier as `bump_hint` into manifest; the project-side deploy skill reads it to drive the batched VERSION bump (/apex-merge no longer owns the bump)
    - **scope-drift pre-commit emit**: before `git add -A`, diff dirty paths against allowed_files and append one `scope-drift foreign-mutation: <path>` line per foreign-modified file to ~/.claude/tmp/git-agent-errors.log (catches tool-side auto-mutations the PreToolUse hook cannot see; commit still proceeds)
    - `git add -A; git commit -m "$MESSAGE"; git push -u origin apex/<session>` (worktree isolation makes shared-working-tree contamination impossible; no allowlist / private-index / CAS-retry needed)
    - empty diff = noop (valid); push failure non-blocking (/apex-merge retries)

13. Self-reflect: reflect-traces.sh + reflector.md (**background** in non-trivial paths)
    - reads traces in-place from .claude-tmp/apex-active/{session}-traces/
    - appends to ~/.claude/tmp/apex-workflow-improvements.md
    - non-convergence detection: appends {ts, session, hash=sha1(prompt), scope_count, touched_count, files_touched} to ~/.claude/tmp/apex-prompt-history.log; on hash collision with different files_touched, surfaces non-convergence: line in improvements:
    - oversized-dispatch flag (E1): read {session}-traces/execute/dispatch-summary.json; trip on orchestrator-recorded actuals - max(tool_calls_made, tool_uses) > 50 OR total_tokens > 150k OR files_touched > 12, never self-report alone - surface oversized-dispatch: line under improvements: (cap 3, top-3 by tool_uses)
    - **owns post-reflect cleanup**: as final action runs `bash scripts/cleanup-session.sh --session {session}` (idempotent)

14. Cleanup session (trivial-only): cleanup-session.sh
    - **runs only on trivial path** (where step 13 was skipped); non-trivial paths get cleanup from the backgrounded reflector at step 13
    - forks on worktree state (clean+no-commits = git worktree remove --force + branch -D; clean+commits or dirty = keep, warn awaiting /apex-merge); hypothesis travels with the worktree subtree on remove, preserved on keep branches

15. Inline summary: inline
    - reads {session}-hypothesis.json + per-goal status map from step 8.3 + step 12 commit outcome
    - **fully deterministic** (no LLM hop, no git audit pass): emits EXACTLY title (`# apex summary - session {session}`) + Original request + Hypothesis vs reality (one line) + Per-goal status (N/M goals passed; one short line per goal) + Mid-run notes (MANUAL residuals only, else omitted) + Result (git actions only: version, commit, push)
    - removes hypothesis on success
```

---

## Mid-flow abort cleanup

Any orchestrator exit bypassing step 14 runs `session-end-hook.sh {session}` inline. Triggers:

- AskUserQuestion-abort at step 1 (no manifest yet -> skip session-end-hook)
- Step 6 cascade-empty (abort, or proceed-with-discovered-or-prompt-paths but zero validated)
- Step 10 verify cap-3 exhaustion (if user opts to abort)
- Any unexpected error path

---

## Skip matrix

| Step | trivial | economy        | standard         |
| ---- | ------- | -------------- | ---------------- |
| 1    | run     | run            | run              |
| 2    | run     | run            | run              |
| 3    | run     | run            | run              |
| 3.1  | run     | -              | -                |
| 4    | skip    | run            | run              |
| 5    | skip    | run            | run              |
| 6    | skip    | run            | run              |
| 7    | skip    | run            | run              |
| 8    | skip    | run (sonnet)   | run (main)       |
| 9    | skip    | skip           | run              |
| 10   | skip    | run            | run              |
| 10.5 | skip    | skip           | run (gated)      |
| 11   | skip    | run (no learn) | run (full)       |
| 12   | skip    | run            | run              |
| 13   | skip    | run (background) | run (background) |
| 14   | run     | skip           | skip             |
| 15   | run     | run            | run              |
