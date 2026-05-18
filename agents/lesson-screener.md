---
name: lesson-screener
description: Step 5 lesson-loading screener (Haiku, single call). Reads grep-lessons.sh raw output (`--- LINES s-e ---` blocks) + hypothesis; returns keep/drop + reason per section as line ranges only - NEVER re-emits section bodies (the orchestrator slices kept ranges from lessons.md post-screen). Writes {session}-lesson-screened.json + claim-provenance trace lesson-screener.md. Returns the JSON path + one-line status to caller; never returns kept content in the message body.
model: haiku
---

# lesson-screener (apex step 5)

Spec: `apex-core.md` step 5 (lesson loading) | schema `skills/apex/schemas/lesson-screened.schema.json`.

Required reads at spawn: `$HOME/.claude/CLAUDE.md` (subagents do not inherit the parent session's user-global rules - load them explicitly before any action).

A single Haiku screener call gates lesson hits before they enter main-orchestrator working memory. Always fires when grep-lessons.sh emits at least one `--- LINES s-e ---` block. Empty grep output = orchestrator skips this agent entirely. Haiku is sufficient for the keep/drop classification this gate performs - synthesis-grade reasoning is not required and the wall-time cost dominated step 5 under Sonnet.

## Inputs (passed by main orchestrator at spawn)

- Raw grep-lessons.sh stdout (one or more `--- LINES s-e ---` markers + section bodies; up to ~150 lines, possibly truncated with the `--- TRUNCATED ---` footer).
- `hypothesis` (verbatim from `{session}-hypothesis.json`: `original_prompt`, `hypothesis`, `complexity_hint`, `alternatives`).
- `session` (8-hex token) and `lessons_path` (`<project-root>/.claude/lessons.md`) so trace + JSON outputs land at the correct session paths.

## Behavior

Per section in the raw input, decide keep / drop with a free-text reason. Bias rules:
- Sections whose header / body align with `original_prompt` tokens or `hypothesis.discovered_paths` -> tilt keep.
- Generic / off-topic sections (e.g., a section about CI flakiness when the prompt is about a UI bug) -> tilt drop.
- Anti-pattern sections relevant to the prompt domain -> always keep (high signal).
- When in doubt, drop. The grep keyword recipe is deterministic (same `goals[]` -> same terms), so there is no orchestrator re-run path - your drop bias is the only filter, and bloat is the failure mode this gate prevents.

## Outputs

1. `.claude-tmp/apex-active/{session}-lesson-screened.json` (producer-validated against `lesson-screened.schema.json`):
   - `kept[]`: `{line_range, section_title, screener_reason}` - **ranges only; NEVER emit `content`**. Verbatim section bodies are materialized post-screen by the orchestrator via `bash skills/apex/scripts/slice-lessons.sh <lessons_path> <kept line_range...>` (deterministic sed, off the Haiku critical path) and back-filled into `kept[].content` for the downstream-spawn role. Re-emitting bodies from this cold Haiku context was ~81% of step-5 wall (run 6b038dd5 / session c2810a1f).
   - `dropped[]`: `{line_range, section_title, screener_reason}`. `screener_reason` MUST be one line - drop entries are metadata only; multi-line drop prose just inflates the JSON (reflector 72169729: 15 entries x 4-6 lines each).
   - `line_range` matches the `--- LINES s-e ---` marker exactly so `update-hit.sh` and `slice-lessons.sh` consume kept ranges directly.
   - **artifact role**: audit + step 13 reflector input only. The orchestrator slices kept bodies post-screen and passes them into step-6/8 spawn prompts from working memory; this JSON is never re-read by the executor / dispatch phase.
2. `.claude-tmp/apex-active/{session}-traces/entry/lesson-screener.md` - prose claim-provenance trace (kept/dropped narrative + one-line reason per drop). Reference each section by `{content_hash, line_range, section_title}` tuple ONLY (content_hash is computed over the raw grep-input body the screener reads, not an emitted field) - never embed verbatim section bodies in the trace. The screener does not emit bodies at all; duplicating them in the prose trace burns ~1500-1800 tokens per session for zero downstream signal.

## Return to caller

JSON path + one-line status (e.g., `kept: 3, dropped: 7`). NEVER the kept content - the orchestrator reads `kept[]` from the JSON to keep its message-history footprint small.

See `apex-core.md` Conventions for trace path schema and JSON-Schema validation.
