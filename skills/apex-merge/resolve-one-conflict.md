---
name: resolve-one-conflict
description: Per-conflict-file contract for /apex-merge step 4. Lazy-loaded by the orchestrator before resolving EACH conflicted file in the unbounded merge loop, so the contract is recent at every iteration (Workstream B item-4 / B/item-6 per-iteration reload). Covers what merge-loop.sh already resolved (trivial-union), the index-state cases the resolver cannot touch (DU/UD/DD), the content-resolver spawn + Bash-splice, and the accept/reject/abort decision.
---

# resolve one conflict (apex-merge step 4, per file)

Spec: `skills/apex-merge/SKILL.md` step 4 (merge loop). Read this BEFORE resolving each conflicted file - the loop is unbounded (count of conflict files unknown at start), so the per-file contract is lazy-loaded per iteration rather than held in working memory from the top of the step.

`merge-loop.sh` halts at the FIRST branch that conflicts (exit 20), prints the conflicted path list, and emits one reload reminder per remaining conflicted file. The orchestrator owns resolution from there.

## What merge-loop.sh already resolved (informational)

**Trivial-union skip (merge-loop.sh inline).** A single-hunk conflict whose two sides each independently nest `()` `[]` `{}` and carry an even backtick count, AND whose combined add-span is <=50 lines (the conflicted hunk span, not whole-file size - so big append-only files like lessons.md with a one-line date-bump conflict still qualify), is resolved by inline union of both sides' adds without spawning the resolver - saves ~5-10k tokens an agent would spend to confirm what concatenation produces. This bracket + backtick balance check (merge-loop.sh `_balanced`) replaces the prior markdown-only gate, so balanced code files now qualify too (single/double-quote parity is deliberately NOT checked - see merge-loop.sh `_balanced`). merge-loop.sh stages and records `detail: trivial-union=N`. Anything the predicate rejects (multi-hunk, unbalanced, hunk-span >50 lines) falls through to the resolver - those are the files you handle below.

## DU/UD + DD index-state conflicts (NOT the resolver)

**DU/UD (delete/modify) + DD index-state conflicts**: merge-loop.sh tags these separately in stdout + the result `detail` (`du-ud=<paths>`) because one side deleted the path - there are NO `<<<<` markers to splice, so the content resolver cannot handle them. Do NOT spawn the resolver for them; per tagged path AskUserQuestion (`keep-deleted` | `keep-modified`; dismiss = `keep-modified` to preserve work) and resolve via `git rm <path>` (keep-deleted) or `git add <path>` (keep-modified).

## Content conflicts (the resolver)

The content resolver only handles `<<<<`-marked UU/AA hunks. Remaining content conflicts spawn `agents/apex-merge-resolver.md` (Sonnet, foreground) with the full-context bundle (conflicted body, base-side + apex-side diffs, apex hypothesis, base/apex commit logs). Resolver returns per-hunk `resolved_block` entries by default (full `proposed_body` only for multi-hunk synthesis); orchestrator splices into the conflicted file via Bash (`printf`/redirect or `git apply`), NEVER the `Edit` / `Write` tools - stale merged-in `{session}-scopes/{cc_session_id}.txt` pointers under main's `.claude-tmp/apex-active/` can arm the scope-check hook and block an `Edit` on the conflicted path, whereas a Bash write bypasses it.

## Decision (per file)

Then AskUserQuestion (`accept` | `reject-edit-manually` | `abort-merge`; dismiss = reject-edit-manually). Per-option `description` carries a one-line diff sketch + recommendation only; full rationale lives in `<run>-merge-result.json`. On accept: write file, `git add P`. On reject: user manual edit, then `git add P`. On abort: `git merge --abort`, skip cleanup, continue.
