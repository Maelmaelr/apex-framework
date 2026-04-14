---
name: apex-init
description: Initialize a new project with APEX-compatible structure (.claude-tmp, docs, CLAUDE.md).
triggers:
  - apex-init
---

# apex-init - Project Initialization

**Step 0:** `ToolSearch select:AskUserQuestion` (fetch deferred tool before use).

Sets up a new project with documentation structure, lesson capture, and conventions for APEX workflow compatibility.

**Idempotent:** Safe to re-run. Never overwrites existing files -- only creates missing ones.

## Step 1: Detect Project

Scan the current working directory:

Run all checks below in parallel (single message with multiple Glob/Read/Bash calls):

1. Check for existing APEX artifacts: `CLAUDE.md`, `.claude-tmp/`, `docs/project-context.md`
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

If ALL artifacts exist (CLAUDE.md + .claude-tmp/ + docs/project-context.md + .claude/audit-criteria/ + .claude/audit-verdicts/ + .claude/scout-findings/), print "Project already initialized. Nothing to do." and stop. Otherwise continue -- re-runs backfill missing dirs without overwriting existing files.

## Step 2: Gather Info

Use AskUserQuestion:

**Question 1:** "Short project description (1-2 sentences)?"
- Options: "Enter description" (Recommended), "Skip (use directory name)"

**Question 2:** "What structure do you want to initialize?" (multiSelect)
- Options:
  - "Full (CLAUDE.md + docs/ + .claude-tmp/)" (Recommended)
  - "Minimal (CLAUDE.md + .claude-tmp/ only)"
  - "Docs only (docs/ structure)"

Skip questions for components that already exist.

## Step 3: Create .claude-tmp/

Create directory and initial files (skip any that exist):

```
.claude-tmp/
  lessons-tmp.md
  git-diff/          (empty directory)
  party/
    archives/        (empty directory)
  brainstorm/
    archives/        (empty directory)
  audit/             (empty directory)
  prd/               (empty directory)
  scout/             (empty directory)
  apex-active/       (empty directory)
  apex-context/      (empty directory)
```

**lessons-tmp.md**: Create as an empty file (zero bytes).

Git does not track empty directories. Place a `.gitkeep` file in each empty leaf directory to preserve the structure on clone.

`.claude-tmp/` should be committed to git. Do NOT add it to `.gitignore`.

## Step 4: Create .claude/ Structure

Create the project-level directory (skip any that exist):

```
.claude/
  lessons.md
  lessons-index.md
  lessons-archive.md
  commands/           (empty directory)
  audit-criteria/     (committed; project-level criteria catalogs)
  audit-verdicts/     (gitignored; persistent verdict JSON)
  scout-findings/     (gitignored; persistent scout finding store)
```

**lessons.md** content:
```markdown
# Lessons Learned
```

**lessons-index.md**: Create as an empty file (zero bytes).

**lessons-archive.md** content:
```markdown
# Lessons Archive
```

Place `.gitkeep` in `commands/` and `audit-criteria/` so empty committed dirs survive clone. `audit-verdicts/` and `scout-findings/` are gitignored -- no `.gitkeep` needed.

**Gitignore entries:** Append the following to `.gitignore` (create the file if absent; skip any line already present):

```
.claude/audit-verdicts/
.claude/scout-findings/
```

Dedupe before appending -- grep the target lines and only add missing ones.

If `.claude/commands/` already contains files, scan them and note the existing commands for inclusion in CLAUDE.md (Step 6).

## Step 5: Create docs/

Create directory structure and template files (skip any that exist):

```
docs/
  project-context.md
  features/
    index.md
```

### project-context.md Template

Read template from ~/.claude/skills/apex-init/context-template.md. Use detected project info to fill in `{placeholders}` with actual values.

### features/index.md Template

```markdown
# Features

Index of feature documentation.

TODO: Add feature docs as the project grows.
```

## Step 6: Create CLAUDE.md

Generate a project-level `CLAUDE.md` at the project root (skip if exists).

Tailor the template based on detected stack. Include:

1. **Header** -- project name + one-line description
2. **Commands** -- detected from package.json scripts, Makefile, Cargo.toml, etc. Include dev, build, test, lint commands. If none detected, add TODO placeholders.
3. **Structure** -- list detected top-level directories and their purposes. For monorepos, list each workspace.
4. **Conventions** -- file naming (detect from existing files: kebab-case, snake_case, PascalCase), import style. Add sensible defaults based on stack.
5. **Cross-Package Changes** (monorepo only) -- template for update flow across packages.
6. **Security-Sensitive** -- list auth/crypto/webhook files if detected, otherwise TODO placeholder.
7. **Doc Quick Reference** -- "I need to..." table pointing to docs/ files. Pre-fill with created docs, add TODOs for common needs.
8. **Project Skills** section -- list project-level slash commands from `.claude/commands/`. If commands were found in Step 4, list each with its description (from the skill's `description` frontmatter). Otherwise, include placeholder:

```markdown
## Project Skills

Project-level slash commands in `.claude/commands/`. Improvable via `/admin-apex --improve`.

TODO: Add project-specific skills as needed.
```

9. **APEX** section -- standard block:

```markdown
## APEX

\```bash
/apex "task description"
\```
```

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

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Never overwrite existing files
- Never read or modify .env files
- Never commit or push to git
- Never install dependencies
- Never create docs that duplicate information already in existing project files
