# apex step 14 - Cleanup session (full contract)

## Contract

Runs ONLY when step 13 was skipped (trivial path; non-trivial paths get cleanup from the backgrounded reflector at step 13). `bash skills/apex/scripts/cleanup-session.sh --session {session}`. Idempotent. Worktree-only: forks on worktree state (clean+no-commits-past-base = `git worktree remove --force` + `git branch -D`; clean+commits = keep, warn awaiting `/apex-merge`; dirty = keep, warn). Since step 3.1 now commits the trivial edit, the trivial path reaches this step clean+commits-past-base -> the keep branch (awaiting `/apex-merge`), matching non-trivial. Hypothesis travels with the worktree subtree on the remove branch and is preserved on the keep branches. Step 15.0 below owns the cd-back sweep.
