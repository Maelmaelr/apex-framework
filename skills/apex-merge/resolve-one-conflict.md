---
name: resolve-one-conflict
description: Per-conflict-file contract for autonomous /apex-merge step 4. Covers trivial unions, index-state decisions, resolver dispatch, automatic application, and verification.
---

# resolve one conflict (apex-merge step 4, per file)

Spec: `skills/apex-merge/SKILL.md` step 4 (merge loop). Read this BEFORE resolving each conflicted file - the loop is unbounded (count of conflict files unknown at start), so the per-file contract is lazy-loaded per iteration rather than held in working memory from the top of the step.

`merge-loop.sh` halts at the FIRST branch that conflicts (exit 20), prints the conflicted path list, and emits one reload reminder per remaining conflicted file. The orchestrator owns resolution from there.

## What merge-loop.sh already resolved (informational)

**Trivial-union skip (merge-loop.sh inline).** A single-hunk conflict whose two sides each independently nest `()` `[]` `{}` and carry an even backtick count, AND whose combined add-span is <=50 lines (the conflicted hunk span, not whole-file size - so big append-only files like lessons.md with a one-line date-bump conflict still qualify), is resolved by inline union of both sides' adds without spawning the resolver - saves ~5-10k tokens an agent would spend to confirm what concatenation produces. This bracket + backtick balance check (merge-loop.sh `_balanced`) replaces the prior markdown-only gate, so balanced code files now qualify too (single/double-quote parity is deliberately NOT checked - see merge-loop.sh `_balanced`). merge-loop.sh stages and records `detail: trivial-union=N`. Anything the predicate rejects (multi-hunk, unbalanced, hunk-span >50 lines) falls through to the resolver - those are the files you handle below.

## DU/UD + DD index-state conflicts (NOT the resolver)

**DU/UD (delete/modify) + DD index-state conflicts**: merge-loop.sh tags these separately in stdout + the result `detail` (`du-ud=<paths>`) because one side deleted the path - there are NO `<<<<` markers to splice. Inspect the complete stage bodies, both diffs, commit messages, references, and tests. Keep the deletion only when the path is intentionally obsolete; otherwise keep the modified side as the loss-minimizing fallback. Resolve and stage immediately. Do not ask the user.

## Content conflicts (the resolver)

Remaining content conflicts spawn `agents/apex-merge-resolver.md` (Sonnet, foreground) with the full-context bundle: conflicted body, merge-base/base/apex bodies, both diffs, both sides' commit messages, the apex commit log, and focused related tests/call sites/contracts. The resolver returns per-hunk `resolved_block` entries by default and a full `proposed_body` for cross-hunk synthesis or malformed markers. The orchestrator applies the returned data mechanically, never with a fuzzy context edit.

## Apply and verify (per file)

Apply the resolver's best result immediately. Reject it internally and repair it before staging if any conflict marker remains, a cheap parser fails, related contracts break, or the base-loss review finds an unexplained vanished base hunk. Run the narrowest relevant test when available. Retry the resolver/repair loop up to three times with the verbatim failure evidence; a persistent failure is a hard stop with the merge and worktree preserved, never an abort-or-skip choice. Then `git add P`.

## Terminal stamp (per branch, after the last file)

merge-loop.sh left a transient `conflict` entry for this branch; the orchestrator owns the terminal rewrite. Once EVERY conflicted file on the branch is resolved, `GIT_EDITOR=true git merge --continue`, then record the terminal status so step 4.6's lint pass has a scope:
`bash skills/apex-merge/scripts/stamp-merge-result.sh <run> --branch <B> --status merged --decision autonomous --paths <csv of the files you git-added>`. Pass ONLY the files resolved by the orchestrator, NOT trivial-union files already staged by merge-loop.sh. Those paths become step 4.6's lint scope; a markdown-only set correctly skips lint.
