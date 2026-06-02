# apex step 12 - Commit + persist bump_hint

Lazy-loaded contract for orchestrator step 12. Dispatched from `skills/apex/SKILL.md`
step 12; Read this file before executing the step so the rule is maximally recent
(B/R3 read-before-work). The item-3 step-read gate enforces the read once armed;
until then the dispatch is a soft convention. Full per-step contract (artifacts,
exit codes, abort paths): `apex-core.md` step 12.

## Contract

Inline (no subagent hop; orchestrator owns it). Worktree isolation means each session has its own branch + index + working tree, so plain `git add -A; git commit; git push` is correct - no allowlist / private-index / CAS-retry machinery needed. The orchestrator classifies the diff and persists `bump_hint: patch|minor` into the manifest for the project-side deploy skill (e.g. `.claude/skills/deploy/` in the project repo) to pick up.
    ```
    # Classify diff -> patch (bug fix / refactor / internal-only / tweak) | minor (new public symbol/route/component OR breaking API change). Never major - user-set only.
    BUMP_HINT=<patch|minor>
    # Persist hint into manifest for the project-side deploy skill to consume.
    tmpf=$(mktemp) && jq --arg h "$BUMP_HINT" '. + {bump_hint: $h}' .claude-tmp/apex-active/{session}.json > "$tmpf" && mv "$tmpf" .claude-tmp/apex-active/{session}.json
    # Draft commit MESSAGE from `git diff {diff_anchor}..HEAD` + `git status --porcelain`
    # (orchestrator inline; the working tree IS this session's scope).
    git add -A
    if git diff --cached --quiet; then
      echo "step-12: nothing to commit (empty diff)"
    else
      git commit -m "$MESSAGE"
      git push -u origin "apex/{session}" || echo "step-12: push failed; /apex-merge will retry"
    fi
    ```
    Returns `{status, commit_sha, bump_kind}` to working memory for step 15. Push failure is non-blocking: `/apex-merge` re-attempts the push as part of its merge loop. Empty diff (all-already-satisfied path) is a valid outcome; no commit lands and `bump_hint` is still persisted so the deploy skill picks no-op intent up correctly.
