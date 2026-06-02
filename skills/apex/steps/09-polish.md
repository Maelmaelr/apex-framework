# apex step 9 - Polish

Lazy-loaded contract for orchestrator step 9. Dispatched from `skills/apex/SKILL.md`
step 9; Read this file before executing the step so the rule is maximally recent
(B/R3 read-before-work - the documented "orchestrator drifted past polish on
standard" drift is what this lazy-load cures). The item-3 step-read gate enforces
the read once armed; until then the dispatch is a soft convention. This file is the full per-step contract. Cross-cutting rules: `apex-core.md` ## Conventions; routing summary: `apex-core-overview.md`.

## Contract

Agent `agents/polish.md` (Sonnet). **Skipped on economy tier ONLY** (mirrors
learn-skip rule; economy implies a small or report-only surface - its primary
branch is `len(goals)==1 AND allowed_files<=5 AND no rewrite verbs`, and the
single-plan-file + report-only branches also select economy - so the orphan-import
/ dead-code surface is small and step 10 verify catches functional regressions). **Standard tier
ALWAYS runs polish - no skip path** (orchestrator drifted past polish on standard
against this gate; explicit phrasing closes the misread loophole). Spawn-prompt:
`session`, `main_scope_path`, `diff_anchor`, `lessons_hits` (advisory; subagents do
NOT inherit working memory). Agent computes touched-by-apex set (`(git diff
--name-only {diff_anchor}; git ls-files --others --exclude-standard) | sort -u`)
INTERSECTED with `allowed_files` (pre-existing user-dirty files outside scope are
NOT polished - still committed as-is at step 12); performs in-scope-only fixes (unused imports /
dead code / leftover comments / naming). Hard cap = intersected set; scope-check
hook is outer guard. Returns one-line summary; no-op exit if nothing actionable.
