---
name: apex-lessons
description: "Orchestrate lessons curation: consolidate pending lessons (extract phase) then triage/dedupe/route survivors (analyze phase). Self-reflects per phase."
triggers:
  - apex-lessons
---

<!-- Called by: apex-improve/SKILL.md Step 9, standalone via /apex-lessons -->

# apex-lessons - Lessons curation orchestrator

Bundles the two lessons-curation phases (`extract.md` then `analyze.md`) into a single command.

Project-scoped: operates on the project's `.claude/lessons.md` and `.claude-tmp/lessons-tmp.md`. Each phase mints its own run token + reflects independently, so signals stay separable in `~/.claude/tmp/apex-workflow-improvements.md` and the per-phase active dirs (`.claude-tmp/lessons-extract-active/`, `.claude-tmp/lessons-analyze-active/`) keep their own lifecycles.

## Project guard

First anchor to the repo root: `cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"`. The per-phase active dirs (`.claude-tmp/lessons-extract-active/`, `.claude-tmp/lessons-analyze-active/`) are CWD-relative; running `/apex-lessons` from a monorepo subdir (e.g. `apps/web`) would otherwise leak a stray `.claude-tmp/` there instead of resolving to the project-root `.claude-tmp/`.

If `.claude/lessons.md` does not exist at the repo root, print "No project context (no .claude/lessons.md) - cannot run lessons curation" and stop. This SKILL-level guard runs BEFORE invoking the subskills and intentionally skips reflection (no project context = no curation signal worth a reflector pass; surfacing the reason once is clearer). The subskills' own no-context branches (extract.md / route.md "jump to Reflect") are the standalone-entry fallback this guard pre-empts on the normal path.

## Step 1: Extract phase

Read and follow all instructions in `skills/apex-lessons/extract.md`. Execute every step including the trailing reflect + cleanup. Print the extract Step 5 summary line.

The extract phase consolidates `.claude-tmp/lessons-tmp.md` into `.claude/lessons.md` and regenerates `.claude/lessons-index.md`. Self-reflects via `agents/reflector.md` (`--phase lessons-extract`).

## Step 2: Analyze phase

Read and follow all instructions in `skills/apex-lessons/analyze.md`. The analyze subskill dispatches to `consolidate.md`, `triage.md`, `route.md`, and `reflect.md` (flat siblings under `skills/apex-lessons/`). Self-reflects via `agents/reflector.md` (`--phase lessons-analyze`).

**Sweep flag**: when invoked as `/apex-lessons sweep` (or the spawn prompt passes `--sweep`), propagate `--sweep` to the analyze phase - it widens routing to re-evaluate the entire `[verified]` backlog in `.claude/lessons.md` against the `.claude/rules/` globs for graduation (see analyze.md "Sweep mode"). Default (no arg) stays incremental.

Print the analyze Step 9 final summary.

After Step 2, proceed to Step 3 (git sync).

## Step 3: Git sync

Always commits + pushes at session end (apex-improve Step 9 does NOT own project commit, so apex-lessons commits there too).

Project-scoped inline commit + push: tracked-modified + untracked-non-ignored, dotenv closed-set + `git check-ignore` filter, per-file `git add`, commit with diff-derived one-liner, then push (commit + push at session end is this skill's global policy).

```
mapfile -t paths < <(
  { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u
)

staged=()
for p in "${paths[@]}"; do
  case "$(basename "$p")" in
    .env|.env.local|.env.production|.env.development) continue ;;
  esac
  git check-ignore -q "$p" && continue
  git add -- "$p" && staged+=("$p")
done

if (( ${#staged[@]} > 0 )); then
  git diff --staged --stat
  git commit -m "<derive 60-char one-liner from staged --stat>" && \
    git push origin "$(git rev-parse --abbrev-ref HEAD)"
else
  echo "Step 3: skip - no stageable changes"
fi
```

Closed dotenv set (NOT `.env*` glob) so committable templates like `.env.example` survive. Per-file `git add` (NOT `git add -A`) avoids racing in files that survived the filter. Push runs only if the commit succeeds (`&&` short-circuit); a no-upstream / non-fast-forward failure surfaces git stderr verbatim - do NOT auto-set-upstream or `--force`. Errors are reported but do NOT block Step 4.

## Step 4: Report

Print "lessons curation complete."

## Forbidden Actions

Standard apex safety guardrails apply (hook + global-`CLAUDE.md` enforced - no stash, no env-file edits, destructive-op gating, tool-output integrity). Additionally:

- Do not skip the project guard - missing `.claude/lessons.md` is a real signal, not noise.
- Do not skip per-phase reflect + cleanup - early-exit reasons are gap signals worth reflecting on.
- Do not run extract and analyze in parallel - extract writes to `lessons.md`; analyze reads it.
- Do not collapse the two phases into one run token - separate runs preserve per-phase reflection signals.
- Do not skip the push in Step 3 (commit + push is the global session-end policy).
