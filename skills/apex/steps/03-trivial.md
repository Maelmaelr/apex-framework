# apex step 3 - Trivial pre-flight

Lazy-loaded contract for orchestrator step 3. Dispatched from `skills/apex/SKILL.md`
step 3; Read this file before executing the step so the rule is maximally recent
(B/R3 read-before-work). The item-3 step-read gate enforces the read once armed;
until then the dispatch is a soft convention. This file is the full per-step contract. Cross-cutting rules: `apex-core.md` ## Conventions; routing summary: `apex-core-overview.md`.

## Contract

Inline. Trivial = ALL of: single file edit (or single new file) AND file path explicitly named in `original_prompt` AND no new public symbol / endpoint / component AND no cross-file dependency. ANY ambiguity = non-trivial.
   - **Verb-pattern relaxation**: when `original_prompt` matches `/^\s*(rename|format|fix typos?|reword|add (a )?comment|remove (a )?comment|update copy|update string)\b/i`, the path-naming requirement is relaxed: if the prompt does not name a path explicitly, a single inline `Glob` for the most specific noun in the prompt is allowed - exactly one match qualifies (zero or 2+ = non-trivial). All other trivial constraints (no new public symbol / no cross-file dep / ANY ambiguity disqualifies) still apply. Pushes pure edit-only prompts onto the 4-13-skip rail.
   - **3.1** (trivial only): inline `Write` of `{session}-main-scope.json` (`allowed_files = [<the single file>] + safety paths`) + scope-check pointer at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt`. Inline `Write` of minimal hypothesis stub (`original_prompt` verbatim; `hypothesis` = one-line restatement; `complexity_hint = "low"`; `alternatives = [{interpretation: original_prompt, status: "kept", reason: "trivial path"}]`; producer-validate via `bash skills/apex/scripts/validate-json.sh hypothesis.schema.json <path>`). Inline `Edit` / `Write` of the target, then a lightweight inline commit of the single-file change (`git add <file>` + `git commit -m <one-liner drafted from `original_prompt`>`; no push, no `bump_hint` classification) so the worktree lands as a clean committed `apex/{session}` branch awaiting `/apex-merge` rather than a dirty leftover no cleanup path reaps. Jump to step 14.
   - Trivial trade-off: skips verify (10), the full step-12 commit machinery (`bump_hint` + push), and reflect (13); it DOES make a lightweight inline commit at 3.1 so the worktree is a clean mergeable branch, not a lingering dirty worktree. User owns lint/build verification; integration is via `/apex-merge` like any non-trivial session.
