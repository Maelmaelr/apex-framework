---
name: review
description: Step 10.5 review sub-step. Gated code-review pass over diff_anchor..HEAD INTERSECT allowed_files; checks CLAUDE.md rules (pattern, over-engineering, security-at-boundaries, i18n, complexity, doc-consistency). Spawns agents/reviewer.md (Sonnet, foreground). Runs ONLY under standard tier when diff is non-trivial and complexity-hinted.
---

# review (step 10.5)

Spec: `apex-core.md` step 10.5. Sub-step of `apex/SKILL.md` task 10.

## Gate (deterministic, inline at orchestrator; NO AI emit)

Fires ONLY when ALL hold:

1. tier == "standard" (read from `{session}-tier.json`). Economy tier always skips (mirrors step 9 polish-skip rule; tiny scope rarely produces CLAUDE.md-rule violations worth the hop).
2. step 10 verify exited 0 (a broken build is not the reviewer's concern; step 10's fix-loop owns that).
3. `len(touched_files) >= 3` where touched = `(git diff --name-only {diff_anchor}; git ls-files --others --exclude-standard) | sort -u` INTERSECTED with `allowed_files`. Small diffs (1-2 files) skip - the cost-vs-coverage trade does not justify the hop. **Docs-only branch**: when every touched file matches `^docs/` OR `\.(md|markdown|txt)$` OR `^README` OR `^CHANGELOG`, the threshold drops to `>= 1` - 2-file documentation diffs still warrant a cross-link / pattern-integrity pass (reflector a2181263).
4. ANY of:
   - `hypothesis.complexity_hint == "high"`, OR
   - ANY `hypothesis.goals[]` matches `/\b(rewrite|migrate|redesign|refactor|new endpoint|new component|new feature)\b/i`, OR
   - `git diff --shortstat {diff_anchor}` deletions across `allowed_files` >= 200 lines (large structural-deletion clause - full component / file removals warrant review even when complexity_hint is medium and the verb regex misses; reflector cef8604f).

**Doc-consistency carve-out** (overrides 3-4; conditions 1-2 still required): even when conditions 3 and 4 do not both hold, the gate fires when the in-scope set (touched INTERSECT `allowed_files`) contains >= 1 doc/spec path (`*.md` / `docs/**` / `CLAUDE.md` / `.claude/rules/**`) AND >= 1 non-doc code path. This catches small (often 2-file) doc+code co-changes the >= 3 size gate would otherwise skip, so a change cannot silently leave an in-scope doc contradicting the new code. Standard tier only for v1 (economy / trivial unaffected - preserves the economy-skip invariant; economy coverage is a noted future extension).

Otherwise: silent skip; proceed to step 11.

The gate is mechanical and reproducible run-to-run (same prompt + same scope -> same gate verdict).

**Doc-consistency dimension routing**: `agents/reviewer.md` flags an in-scope doc whose stated behavior / signature / flag / contract contradicts an in-scope code change, tagging each finding `authority`. `doc-stale` (doc describes superseded behavior; code correct) -> `action: fix-needed` -> executor updates the in-scope doc (already editable - no new scope), or the mechanical-fix inline allowance below. `code-suspect` (change contradicts an authoritative contract; code may be wrong) -> `action: escalate` -> AskUserQuestion. In-scope-only: the reviewer never reads untouched docs (its hard boundary), so pre-existing drift on out-of-scope docs stays out of scope - a future out-of-band project-wide audit, not this hot-path pass.

## Inputs at spawn (caller propagates explicitly to `agents/reviewer.md`)

Subagents do NOT inherit working memory; the orchestrator MUST propagate every input below at the spawn site.

- `session` - 8-char hex token.
- `main_scope_path` - `.claude-tmp/apex-active/{session}-main-scope.json`.
- `diff_anchor` - orchestrator resolves it inline as `git merge-base <manifest.base_branch> HEAD` (the apex/<session> fork point; stable from session mint with no mid-run supersede path).
- `project_root` - absolute path to repo root.
- `attempt` - 1 on initial spawn; 2 on post-fix re-review.
- `prior_findings_path` - present ONLY on attempt 2: `.claude-tmp/apex-active/{session}-traces/review/result-1.json`.

## Procedure

1. **Evaluate gate**. If any condition fails, write `.claude-tmp/apex-active/{session}-review-skipped.json` with `{reason: "<one-line>"}` so `/apex-improve` can audit gate effectiveness, then return to caller without spawning.

2. **Spawn `agents/reviewer.md`** (Sonnet, foreground). Agent returns the JSON shape defined by `skills/apex/schemas/review-result.schema.json`; orchestrator producer-validates via `bash skills/apex/scripts/validate-json.sh review-result.schema.json <agent-output-path>`.

3. **Branch on `action`**:
   - `pass` -> proceed to step 11 (no trace; silent green).
   - `fix-needed` -> dispatch `agents/executor.md` ONCE (Sonnet, cap 1, no retry). Spawn-prompt carries the findings list as the fix scope (no `goal` field; this is a fix-only invocation analogous to step 10's fix-loop). After the executor returns, spawn `agents/reviewer.md` again with `attempt=2` + `prior_findings_path` to confirm fixes landed. **Mechanical-fix inline allowance**: when every finding is a zero-ambiguity surgical edit (dead-code delete, void-pattern early-return, unused-import strip) AND finding count <= 2, the orchestrator MAY inline-Edit the fix instead of dispatching the executor; on inline-edit it MUST append a synthetic entry to `.claude-tmp/apex-active/{session}-fix-attempts.json` `{kind: "review-inline", files: [<paths>], count: N}` BEFORE step 11 so the learn difficulty gate (`attempts >= 1`) observes the rollup and learn runs (mirrors step-8 cross-scope-inline pattern landed in commit 06a9090; reflector 213a7c3c: review attempt-1 fix dead-assertion delete was inline-handled and learn-skipped because no fix-attempts.json existed).
   - `escalate` -> AskUserQuestion (`accept-and-proceed` | `apply-fix-manually` | `abort`). Dismiss / cancel = `accept-and-proceed`. `abort` triggers `bash skills/apex/scripts/session-end-hook.sh {session}` inline.

4. **Attempt counter**: maintain `.claude-tmp/apex-active/{session}-review-attempts.json` (cap 2 reviews + 1 fix = max 3 hops total). On `attempt=2` returning `fix-needed` again (the fix did not resolve), the orchestrator MUST escalate (no third attempt; force AskUserQuestion).

5. **Trace path**: agent writes to `.claude-tmp/apex-active/{session}-traces/review/result-{attempt}.md` ONLY when `action != pass`. Fix-dispatch trace lives at the executor's standard fix-loop path: `.claude-tmp/apex-active/{session}-traces/verify/fix-{attempt-N}.md` with attempt-N offset by step-10's fix-attempts counter (review-fixes share the verify fix-loop trace tree by convention so reflectors see one fix-attempt timeline).

## Fix-dispatch contract (when action == fix-needed)

The executor spawn for review-fix follows `agents/executor.md` step 10 fix-loop convention:

- Always Sonnet (regardless of step 8 tier).
- No `goal` field; the findings list IS the work.
- Cap 1 (single fix attempt; do not retry inside review-fix).
- Spawn-prompt carries: session, main_scope_path, diff_anchor, findings array verbatim, `attempt-N = step10-fix-attempts + 1`.
- Executor returns the legacy one-line summary (no `{goal, status, ...}` shape; this is the step-10 fix-loop shape, not the step-8 dispatch shape).

## Re-review contract (attempt 2)

Same agent spawn as attempt 1 with `attempt=2` + `prior_findings_path`. Agent:

- Confirms each prior finding is now absent from the diff (fixed) OR still present.
- A still-present finding gets prefixed `STILL-PRESENT-AFTER-FIX:` and forces `action: "escalate"`.
- A clean re-review returns `action: "pass"` and proceeds to step 11.

## What this sub-step does NOT do

- Does NOT run lint / build / test (step 10 owns that).
- Does NOT touch project files itself; reviewer.md never edits, executor.md does the fix dispatch.
- Does NOT loop indefinitely; cap is hard at 2 reviews + 1 fix.
- Does NOT escalate to a different agent on persistent failure; AskUserQuestion is the only escalation.

## Reflector visibility

The reflector (step 13) reads `.claude-tmp/apex-active/{session}-traces/review/**` in-place. Surface review patterns in `improvements:` as:

- `review-fired: gate_match=<reason> findings=N action=<verdict>` when the gate passed.
- `review-skipped: gate_block=<reason>` when the gate dropped (read from `{session}-review-skipped.json`).

See `apex-core.md` step 10.5 / `agents/reviewer.md` for the full contract; `skills/apex/schemas/review-result.schema.json` for the return shape.
