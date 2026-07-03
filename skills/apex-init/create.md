# apex-init: Create File Structure

Called from `SKILL.md` after Step 2 (Gather Info). Returns to SKILL.md for Step 7 (Report). Extracted from `SKILL.md` to keep the orchestrator within the file-health content budget.

## Step 3: Create .claude-tmp/

Create directory and initial files (skip any that exist):

```
.claude-tmp/
  apex-active/       (empty directory)
```

Git does not track empty directories. Place a `.gitkeep` file in each empty leaf directory to preserve the structure on clone.

See **Step 3.5** for the project root `.gitignore` (baseline + apex artifact lines).

## Step 3.5: Seed project root `.gitignore`

Ensure the project root has a `.gitignore` covering secrets, dependencies, build outputs, and editor/OS junk. Create it if absent; if present, append only the lines not already there (grep each line first - never duplicate, never reorder, never overwrite; same idempotent contract as every other file in this skill). A freshly initialized project with no `.gitignore` will stage `.env` on the first `git add` - seeding the secret-file lines is the load-bearing reason this step exists (global rule: never commit secrets).

**Always seed these universal categories** (stack-agnostic):
```
# Environment / secrets (never commit)
.env
.env.local
.env.*.local

# Editor / IDE
.idea
.vscode
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Logs
*.log
```
Match the secret-file names to the stack when a different convention is detected (e.g. `*.pem`, `secrets.*`, a cloud service-account `*.json`).

**Add stack-specific lines** from the Step 1 detection (skip the row if no stack was detected):

| Stack | Append |
|-------|--------|
| Node.js | `node_modules`, `dist`, `build`, `.next`, `out`, `coverage`, `.cache`, `*.tsbuildinfo` |
| Rust | `target`, `*.rs.bk` |
| Go | compiled binaries, `*.test`, `*.out` |
| Python | `__pycache__/`, `*.pyc`, `.venv`, `.pytest_cache`, `build`, `dist`, `*.egg-info` |

**Then append the apex artifact lines.** `.claude-tmp/` itself should be committed (the dir skeleton) - do NOT gitignore it wholesale. But the per-session artifacts under `.claude-tmp/apex-active/` are transient and MUST NOT be committed; they have leaked to `main` and been pulled to prod (2-session). These two lines keep the dir alive via its `.gitkeep` while the session artifacts stay ignored:
```
.claude-tmp/apex-active/*
!.claude-tmp/apex-active/.gitkeep
```

If the project will use `/apex` (per-session linked git worktrees), also append `.apex-worktrees/` - the apex mint-worktree.sh worktree root, untracked-by-design; `/apex-merge` filters it from the dirty-tree precheck. The precheck already excludes the untracked `.apex-worktrees/` root from its unconditional dirty-main auto-commit, so this line mainly keeps the worktree root out of `git add .` and IDE/status noise.

## Step 4: Create .claude/ Structure

Create the project-level directory (skip any that exist):

```
.claude/
  commands/           (empty directory)
```

Place `.gitkeep` in `commands/` so the empty committed dir survives clone.

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

`docs/project-context.md` is the canonical architecture entry point: the /apex orchestrator reads it best-effort during understand (absent = silent skip), and executors re-read relevant sections when their brief points at them. The template is a starting structure; the team should curate it as the project grows so module names, security-sensitive paths, and architectural boundaries stay accurate.

### features/index.md Template

```markdown
# Features

Index of feature documentation.

TODO: Add feature docs as the project grows.
```

## Step 6: Create CLAUDE.md

Generate a project-level `CLAUDE.md` at the project root (skip if exists).

Leanness budget: this file loads on every turn and Claude Code degrades past a ~40k-char hard cliff. Keep the seed well under a 30k-char soft ceiling (typically <= ~200 lines) - reference deeper guidance via `docs/` rather than inlining.

Tailor the template based on detected stack. Include:

1. **Header** - project name + one-line description
2. **Commands** - detected from package.json scripts, Makefile, Cargo.toml, etc. Include dev, build, test, lint commands. If none detected, add TODO placeholders.
3. **Structure** - list detected top-level directories and their purposes. For monorepos, list each workspace.
4. **Conventions** - file naming (detect from existing files: kebab-case, snake_case, PascalCase), import style. Add sensible defaults based on stack.
5. **Cross-Package Changes** (monorepo only) - template for update flow across packages.
6. **Security-Sensitive** - list auth/crypto/webhook files if detected, otherwise TODO placeholder.
7. **Doc Quick Reference** - "I need to..." table pointing to docs/ files. Pre-fill with created docs, add TODOs for common needs.
8. **Project Skills** section - list project-level slash commands from `.claude/commands/`. If commands were found in Step 4, list each with its description (from the skill's `description` frontmatter). Otherwise, include placeholder:

```markdown
## Project Skills

Project-level slash commands in `.claude/commands/`.

TODO: Add project-specific skills as needed.
```

9. **APEX** section - standard block:

```markdown
## APEX

\```bash
/apex "task description"   # main coding orchestrator
/apex-merge                # integrate apex/<session> worktree branches into their base
\```
```
