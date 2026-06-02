# apex step 11 - Tail

Lazy-loaded contract for orchestrator step 11. Dispatched from `skills/apex/SKILL.md`
step 11; Read this file before executing the step so the rule is maximally recent
(B/R3 read-before-work). The item-3 step-read gate enforces the read once armed;
until then the dispatch is a soft convention. Full per-step contract (artifacts,
exit codes, abort paths): `apex-core.md` step 11.

## Contract

**Tail** (foreground; Sonnet latest):
- **standard**: `agents/documentation.md` UNLESS `hypothesis.mode == "code-only-no-docs"` (mode-skip clause; doc agent ran despite mode flag, 4 doc files mutated); `agents/learn.md` ONLY when the **difficulty gate** holds (file `{session}-fix-attempts.json` exists AND its `attempts >= 1`). First-try-clean sessions skip `learn` entirely - the lessons file stays lean by construction. When both run, dispatch in parallel. **doc-inline marker**: when documentation.md is skipped because an in-scope doc file (`docs/**`, `*.md`, `README*`, `CLAUDE.md`) was already edited inline by an executor or by the orchestrator, append `doc-inline: <repo-relative-path>` to dispatch-summary `notes` (one per touched doc) so step-13 reflector distinguishes inline-doc-done from a skipped doc-agent step.
- **economy**: `agents/documentation.md` only (`learn` skipped); same `hypothesis.mode == "code-only-no-docs"` skip applies.
- Both read `git diff {diff_anchor}`. `learn` appends to `.claude-tmp/lessons-tmp.md` under `flock` (via `bash skills/apex/scripts/append-with-lock.sh`); the agent's own bar drops within-session trivia even when the gate opens.
