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
- **Session manifests + hooks** -- PreCompact/PostCompact/StopFailure hooks preserve state across compaction and API failures. Per-tool hooks add guardrails: scope-check (blocks Edit/Write outside teammate scope), scan-budget (caps Grep/Glob/Read during scouting), scout-context-truncate (advisory truncation on large Reads), protect-env (blocks `.env*` and credential reads), and block-destructive (blocks destructive git commands, force push to main, and dangerous `rm`).

## Installation

```bash
npx create-apex
```

The installer pulls the latest apex-framework tarball, copies skills + agents + starter audit-criteria into `~/.claude/`, merges APEX hooks into `~/.claude/settings.json` (preserving your existing hooks), and writes the APEX rules into `~/.claude/CLAUDE.md` (append / overwrite / separate-file modes). Re-run `npx create-apex upgrade` to refresh skills without touching your CLAUDE.md.

To initialize APEX in a specific project, the installer offers to scaffold `.claude/lessons.md`, `.claude/lessons-index.md`, `.claude/audit-criteria/`, `.claude/audit-verdicts/`, `.claude/scout-findings/`, `.claude-tmp/`, and `docs/` stubs. You can also run `/apex-init` from within Claude Code to do the same later.

### Manual install (fallback)

```bash
git clone https://github.com/Maelmaelr/apex-framework ~/apex-framework
for s in apex apex-audit-matrix apex-brainstorm apex-eod apex-file-health \
         apex-fix apex-git apex-init apex-lessons-analyze apex-lessons-extract \
         apex-party admin-apex; do
  ln -s ~/apex-framework/skills/$s ~/.claude/skills/$s
done
for a in scout verifier evaluator; do
  ln -s ~/apex-framework/agents/$a.md ~/.claude/agents/$a.md
done
```

You will still need to merge the hooks in `templates/hooks.json` into `~/.claude/settings.json` manually, and add the content of `templates/apex-rules.md` to your `~/.claude/CLAUDE.md`.

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
- `audit-criteria/` -- starter criteria catalogs (`apex.md`, `skill-quality.md`) seeded into `~/.claude/audit-criteria/` by the installer
- `templates/apex-rules.md` -- sanitized APEX block extracted from the maintainer's `~/.claude/CLAUDE.md` between `<!-- APEX:BEGIN -->` and `<!-- APEX:END -->` markers
- `templates/hooks.json` -- canonical hook entries the installer merges into `~/.claude/settings.json`
- `CLAUDE.md` -- full maintainer CLAUDE.md (reference only; installer uses `templates/apex-rules.md`)

## Status

Actively used daily. Breaking changes happen. Pin to a commit if you need stability.

## License

MIT
