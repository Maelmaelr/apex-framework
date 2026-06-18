---
name: apex-init
description: Initialize a new project with APEX-compatible structure (.claude-tmp, docs, CLAUDE.md).
triggers:
  - apex-init
---

# apex-init - Project Initialization

**Step 0:** `ToolSearch select:AskUserQuestion` (fetch deferred tool before use).

Sets up a new project with documentation structure, lesson capture, and conventions for APEX workflow compatibility.

**Idempotent:** Safe to re-run. Never overwrites existing files - only creates missing ones.

## Step 1: Detect Project

Scan the current working directory:

Run all checks below in parallel (single message with multiple Glob/Read/Bash calls):

1. Check for existing APEX artifacts: `CLAUDE.md`, `.claude-tmp/`, `.claude/lessons.md`, `docs/project-context.md`
2. Check `git rev-parse --is-inside-work-tree 2>/dev/null`. If not a git repo, note in summary: `Git: no (consider running git init)`.
3. Detect tech stack:
   - `package.json` -> Node.js (check for next, react, adonis, express, etc.)
   - `Cargo.toml` -> Rust
   - `go.mod` -> Go
   - `pyproject.toml` or `requirements.txt` -> Python
   - `pom.xml` or `build.gradle` -> Java/Kotlin
   - None -> Generic
4. Detect monorepo: `pnpm-workspace.yaml`, `lerna.json`, Cargo workspace, or `workspaces` in package.json
5. Read `package.json` (or equivalent) for project name if available
6. Check for existing `docs/` directory

Print detection summary:
```
Project: {name or directory name}
Stack: {detected stack}
Monorepo: {yes/no, with workspace list if yes}
Existing: {list any APEX artifacts already present}
```

If ALL artifacts exist (CLAUDE.md + .claude-tmp/ + .claude/lessons.md + docs/project-context.md), print "Project already initialized. Nothing to do." and stop. Otherwise continue - re-runs backfill missing dirs (including a missing .claude/) without overwriting existing files.

## Step 2: Gather Info

Use AskUserQuestion:

**Question:** "Short project description (1-2 sentences)?"
- Options: "Enter description" (Recommended), "Skip (use directory name)"

apex-init always creates the full APEX-compatible structure (`.claude-tmp/` + `.claude/` + `docs/` + `CLAUDE.md`); the apex chain reads all of it (manifest dir, lessons files, `docs/project-context.md` at SKILL.md Step 1), so a partial init would leave a non-functional project - there is no structure sub-choice. Creation is idempotent: create.md skips any file/dir that already exists, so re-runs only backfill what is missing.

## Steps 3-6: Create File Structure

Read and follow `~/.claude/skills/apex-init/create.md` to create `.claude-tmp/`, `.claude/`, `docs/`, the project root `.gitignore` (Step 3.5), and the project-level `CLAUDE.md` (skip any files that already exist). Returns when all create operations finish; resume at Step 7 below.

## Step 7: Report

Print summary of what was created:

```
Initialized {project name}:

Created:
  - {list of files/dirs created, one per line}

Skipped (already existed):
  - {list of files/dirs skipped, or "none"}

Next steps:
  1. Review and fill in TODOs in CLAUDE.md and docs/project-context.md
  2. Add architecture docs as the project grows (docs/architecture.md, etc.)
  3. Run /apex "your first task" to start working
```

## Forbidden Actions

Standard apex safety guardrails apply (hook + global-`CLAUDE.md` enforced - no stash, no env-file edits, destructive-op gating, tool-output integrity). Additionally:

- Never overwrite existing files
- Never read or modify .env files
- Never commit or push to git
- Never install dependencies
- Never create docs that duplicate information already in existing project files
