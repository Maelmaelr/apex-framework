# APEX Framework

A lean, coverage-tracked coding workflow for [Claude Code](https://claude.com/claude-code). APEX routes every task through a deliberate pipeline -- scan, plan, implement, verify, learn -- with built-in audit, lessons capture, and multi-agent orchestration.

This repository is the public mirror of the APEX skills and agent definitions. It is generated from my personal `~/.claude` configuration and is intended as a reference you can fork, adapt, or install.

## What is APEX?

APEX is a set of Claude Code skills (slash commands) that structure how the AI tackles non-trivial engineering tasks. Two execution paths:

- **Path 1 (Direct):** quick scan -> lessons lookup -> implement -> verify -> capture lessons. For small, single-concern changes.
- **Path 2 (Delegated):** scout -> plan -> team execution (multiple agents with independent contexts) -> verify -> tail workflows (lessons + docs + audits). For cross-cutting, multi-file, or security-sensitive work.

Both paths include:

- **Lessons system** -- project-local `.claude/lessons.md` + keyword index. Captured implementation lessons are grep'd on every run, bumped on hit, archived when stale.
- **Audit matrix** -- deterministic `(target x criterion)` enumeration with persistent verdicts, file-hash change detection, and evaluator re-verification of PASS cells to catch false negatives.
- **Session manifests + hooks** -- PreCompact/PostCompact/StopFailure hooks preserve state across compaction and API failures; scope-check and scan-budget hooks enforce discipline during delegated execution.

## Installation

```bash
# Clone into your Claude Code config
git clone https://github.com/Maelmaelr/apex-framework ~/apex-framework

# Symlink (or copy) skills and agents into ~/.claude
for s in apex apex-audit-matrix apex-brainstorm apex-eod apex-file-health \
         apex-fix apex-git apex-init apex-lessons-analyze apex-lessons-extract \
         apex-party admin-apex; do
  ln -s ~/apex-framework/skills/$s ~/.claude/skills/$s
done

for a in scout verifier evaluator; do
  ln -s ~/apex-framework/agents/$a.md ~/.claude/agents/$a.md
done

# Initialize a project
cd your-project
# In Claude Code:
/apex-init
```

`/apex-init` creates the per-project structure: `.claude/lessons.md`, `.claude/lessons-index.md`, `.claude-tmp/`, and stubs in `docs/`.

## Skills

### Core workflow
- **`/apex`** -- entry point. Scans the task, picks Path 1 or Path 2, routes accordingly.
- **`/apex-fix`** -- fix all lint/build errors, then capture lessons.
- **`/apex-git`** -- bump VERSION, generate commit message from accumulated diff summaries, stage, commit, push, clean session artifacts.
- **`/apex-eod`** -- end-of-day chain: file-health -> lessons-extract -> admin-apex --improve -> lessons-analyze -> apex-git.
- **`/apex-init`** -- scaffold a new project with APEX structure.

### Auditing
- **`/apex-audit-matrix`** -- coverage-tracked audit. Deterministic enumeration of `(target x criterion)` cells from a criteria catalog, independent evaluator loop on PASS verdicts, persistent verdict storage in `.claude/audit-verdicts/`.
- Criteria catalogs live in `.claude/audit-criteria/*.md` (project) and `~/.claude/audit-criteria/*.md` (global). Max 60 criteria / 600 lines per catalog.

### Knowledge
- **`/apex-lessons-extract`** -- consolidate pending lessons from `.claude-tmp/` into `.claude/lessons.md`, regenerate index.
- **`/apex-lessons-analyze`** -- deduplicate, freshness-check, merge, and route lessons to their best permanent home.

### Utilities
- **`/apex-file-health`** -- remediate oversized files flagged by verification (split at 400/500 line gates).
- **`/apex-party`** -- multi-persona expert panel discussion.
- **`/apex-brainstorm`** -- structured brainstorming (61 techniques across 10 categories).
- **`/admin-apex`** -- reference + self-improvement (`/admin-apex --improve`).

## Agents

Reusable Agent tool definitions in `agents/`:

- **`scout.md`** -- read-only exploration and audit verdict authoring.
- **`verifier.md`** -- build, lint, and test validation.
- **`evaluator.md`** -- independent re-verification of scout PASS verdicts to catch false negatives.

## Design principles

1. **Coverage over probability.** Audits enumerate the full matrix and persist verdicts -- never "I already checked that" without a file hash to prove it.
2. **Lessons as first-class memory.** Every implementation pass writes to `.claude/lessons.md`. Every future pass greps it first.
3. **Scoped execution.** Delegated teammates get a scope manifest; a pre-tool hook blocks writes outside their allowed files.
4. **Independent verification.** A separate evaluator agent re-checks a weighted sample of PASS verdicts to catch false negatives.
5. **Model tiering.** Opus for reasoning (planning, splits, teammate spawns). Sonnet for read-only exploration, classification, and mechanical edits. Haiku for trivialities.

## Files

- `skills/` -- APEX slash commands
- `agents/` -- reusable agent definitions
- `CLAUDE.md` -- global workflow rules that live at `~/.claude/CLAUDE.md` and are loaded into every Claude Code session

## Status

Actively used daily. Breaking changes happen. Pin to a commit if you need stability.

## License

MIT
