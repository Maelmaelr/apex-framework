# Persistent Verdict Storage

<!-- Referenced by: apex-audit-matrix/SKILL.md Phase 3 -->

Verdicts persist across sessions so subsequent runs start from prior state without requiring `--resume` with a matrix path.

**Location:** `{project-root}/.claude/audit-verdicts/{theme}-verdicts.json` (project-scoped, theme-keyed).

**Format:**
```json
{
  "theme": "security",
  "catalog_path": "relative/path/to/catalog.md",
  "updated": "ISO-8601 timestamp",
  "cells": [
    {
      "target": "relative/path.ts",
      "criterion": "AUTH-01",
      "status": "pass",
      "evidence": "...",
      "file_hash": "abc123...",
      "checked_at": "ISO-8601 timestamp"
    }
  ]
}
```

**Lifecycle:**
1. **Auto-created:** First audit run writes verdicts for all non-`unchecked` cells. Pre-filter N/A cells (metadata-only in sparse format) are excluded; scout N/A (with evidence) is included to preserve LLM audit work.
2. **Auto-loaded:** Subsequent fresh runs (no `--resume`) auto-load from the verdicts file. The script compares stored `file_hash` (git hash-object) against the current file content hash. Unchanged files carry forward their verdicts; changed files get `recheck` status.
3. **Auto-updated:** After each matrix write, non-`unchecked` cells are saved back to the verdicts file. The Matrix Mutation Protocol (apex-doc-formats.md) also syncs verdicts after remediation updates.
4. **Opt-out:** Pass `--no-persist` to skip both auto-load and auto-save. Pass `--verdicts-dir` to override the storage directory.

**Relationship to --resume:** `--resume` loads from a specific matrix JSON file (explicit path). Persistent verdicts load from the theme-keyed store (implicit). Both can coexist: `--resume` takes precedence when provided. Without `--resume`, the persistent store provides the same incremental behavior automatically.
