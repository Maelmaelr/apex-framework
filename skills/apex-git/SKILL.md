---
name: apex-git
description: Commit and push changes using accumulated diff summaries.
triggers:
  - apex-git
---

# apex-git - Commit and Push

Reads diff summaries from `.claude-tmp/git-diff/` if available, otherwise falls back to git diff stat for uncommitted changes. Bumps the version, generates a commit message, stages all changes, commits, pushes, then cleans up.

## Step 0: Read Diffs + Standalone Verification Gate

Glob for `.claude-tmp/git-diff/git-diff-*.md` (CWD-relative) AND `~/.claude/.claude-tmp/git-diff/git-diff-*.md` (absolute). Merge matches from both locations and de-duplicate by path. admin-apex-improve always writes to `~/.claude/.claude-tmp/git-diff/`; project-rooted callers also have the CWD-relative path -- both are read so the summary is found regardless of CWD. Also check for a VERSION file: look for `VERSION` at project root, then `apps/web/VERSION`. Use the first one found. If neither exists, initialize `VERSION` at the project root with content `0.1.0` and use that.

**Pre-flight cleanup.** Remove stale APEX session artifacts that would block the VERSION bump Edit or trigger budget hooks from unrelated sessions: `find .claude-tmp/apex-active -maxdepth 1 -type f \( -name "*-scope.json" -o -name "*-budget.json" \) -delete 2>/dev/null || true`. apex-git is a boundary operation -- any active APEX session state that reaches this point is stale by definition.

**If diff files found:** In a single message, Read all matched diff files AND Read the VERSION file (parallel Read calls). Collect their contents. The VERSION Read is mandatory -- Step 1's Edit on VERSION requires a prior Read.

**If no diff files found:** In a single message, run `git status` and `git diff --stat` AND Read the VERSION file (parallel). The VERSION Read is mandatory -- Step 1's Edit on VERSION requires a prior Read. If there are uncommitted changes, continue using the diff stat as context for commit message generation. If no uncommitted changes either, print "No diff summaries and no uncommitted changes. Nothing to commit." and stop.

**Standalone build gate.** If invoked standalone (not as a subagent of apex-eod): check whether diff summaries or `git diff --name-only` include code files (`.ts`, `.tsx`, `.js`, `.jsx`, `.py`). If yes, detect and run the project's build system:
- `package.json` with `build` script: use the project's package manager (`pnpm build`, `npm run build`, or `yarn build`). For Next.js projects, also `rm -f apps/web/.next/lock` before build.
- `Makefile` with `build` target: `make build`.
- `pyproject.toml` or `setup.py`: skip build (Python projects rely on lint/test, not compilation).
- No build system detected: skip build.
If build fails, print "Build failed -- fix errors before committing (try /apex-fix)." and stop. If all changes are doc/config-only (`.md`, `.json`, `.yaml`, `.yml`, `.env.example`, `.sh`, `.txt` -- no code files), skip the build. If invoked as a subagent (spawned by apex-eod), skip this gate entirely -- upstream steps already verified.

## Step 1: Bump Version

Using the VERSION content already read (or initialized) in Step 0. Format is `A.B.C` where:
- A (major): only under explicit user request (usually a complete redesign)
- B (minor): new features
- C (patch): fixes, tweaks, adjustments

Based on the diff summaries, determine which segment to increment. When incrementing B, reset C to 0. Write the updated version back.

## Step 2: Generate Commit Message

Write a short commit message:
- First line: concise subject (max 72 chars), imperative mood
- **From summaries:** If diff summaries were found, synthesize them. If multiple summaries cover different concerns, combine into one coherent subject line.
- **From diff stat:** If no summaries but uncommitted changes exist, analyze the diff stat and changed file names to generate an accurate subject line.

Do not include "Co-Authored-By" or other trailers.

## Step 3: Stage, Commit, Push

**Staging:**

Always stage all changes:
```bash
git add .
```
This overrides the global CLAUDE.md "prefer specific files" preference. `git add .` respects .gitignore, so secrets in `.env*` are excluded. `.claude-tmp/` is NOT gitignored -- its directory structure and persistent artifacts (audit/PRD docs, archives, lessons-tmp) are committed. Ephemeral session files are cleaned up in Step 3.

**Post-stage verification:** Run `git diff --cached --stat`. If output is empty, print "Nothing staged after git add -- all changes may be in .gitignore'd paths." and stop. Otherwise, print the staged file summary as confirmation.

**Post-build drift check.** If the standalone build gate ran (Step 0) and the staged files don't include changes that were present before the build (i.e., the build regenerated files to their original state), use AskUserQuestion: "Build appears to have reverted some changes ({missing files}). Only {staged files} remain staged. Options: Commit staged changes only / Abort (undo VERSION bump via AskUserQuestion, not silently) / Review diff". Do not silently revert the VERSION bump or any other staged changes -- per shared-guardrails #5, all file reversions require explicit user consent.

Then commit and push using HEREDOC to prevent shell interpolation of special characters in the message:
```bash
git commit -m "$(cat <<'EOF'
{commit message}
EOF
)" && git push
```

If commit or push fails, report the error and stop.

## Step 4: Clean Up

Delete diff summaries and scout findings. Archive treated party/brainstorm files.

If a session-id is available (from commit message or manifest), use the cleanup script: `bash ~/.claude/skills/apex/scripts/cleanup-session.sh {session-id} {project-root}`. This handles manifests, scout findings, diff summaries, and teammate context for the specific session.

Then clean remaining shared artifacts:
```bash
# Shared artifacts not scoped to a session-id
rm -f .claude-tmp/git-diff/git-diff-*.md
rm -rf .claude-tmp/scout/
rm -rf .claude-tmp/apex-context/
mkdir -p .claude-tmp/party/archives .claude-tmp/brainstorm/archives
mv -f .claude-tmp/party/party-*.md .claude-tmp/party/archives/ 2>/dev/null || true
mv -f .claude-tmp/brainstorm/brainstorm-*.md .claude-tmp/brainstorm/archives/ 2>/dev/null || true
```

## Step 5: Report

Print: "Git: committed and pushed -- {commit message subject line}"

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not amend existing commits
- Do not force push
- Do not skip the push step
- Do not revert, unstage, or overwrite files to undo changes (git restore, git checkout --, echo/write to revert content) -- per shared-guardrails #5, use AskUserQuestion when changes become questionable
