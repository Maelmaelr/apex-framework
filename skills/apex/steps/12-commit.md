# apex step 12 - Commit + persist bump_hint (full contract)

## Contract

Inline (no subagent hop; orchestrator owns it). Worktree isolation means each session has its own branch + index + working tree, so plain `git add -A; git commit; git push` is correct - no allowlist / private-index / CAS-retry machinery needed. The orchestrator classifies the diff and persists `bump_hint: patch|minor` into the manifest as an in-manifest record. The project-side deploy skill (e.g. `.claude/skills/deploy/` in the project repo) owns the bump: it derives the tier from the merged commits' types (commit-type buckets), picks the highest across the batch (`minor` > `patch`), and runs `bash skills/apex/scripts/bump-version.sh --kind <tier>` ONCE on the final integration commit (`/apex-merge` no longer owns the bump). It does not read `bump_hint` - these manifests are removed with their worktrees at `/apex-merge` cleanup, so they are gone by deploy time.
    ```
    # Classify diff -> patch (bug fix / refactor / internal-only / tweak) | minor (new public symbol/route/component OR breaking API change). Never major - user-set only.
    BUMP_HINT=<patch|minor>
    # Anchor apex-active to the worktree (resolver reads the manifest's worktree_path); bare-relative
    # .claude-tmp/apex-active paths resolve against project_root and leak into the main tree (cluster: worktree-marker-leak).
    APEX_ACTIVE="$(bash skills/apex/scripts/resolve-apex-active.sh {session})"
    # Persist classified tier into the manifest as a record (deploy derives the bump from commit-type buckets, not this field).
    tmpf=$(mktemp) && jq --arg h "$BUMP_HINT" '. + {bump_hint: $h}' "$APEX_ACTIVE/{session}.json" > "$tmpf" && mv "$tmpf" "$APEX_ACTIVE/{session}.json"
    # Draft commit MESSAGE from `git diff {diff_anchor}..HEAD` + `git status --porcelain`
    # (orchestrator inline; the working tree IS this session's scope).
    # Scope-drift emit (one line per foreign-modified path; non-blocking) - the scope-check
    # hook cannot see tool-side auto-mutations (formatters / codegen / installs).
    SCOPE_JSON="$APEX_ACTIVE/{session}-main-scope.json"
    git status --porcelain | awk '{print $2}' | python3 -c "
import json,sys,os,datetime
allow=set(json.load(open('$SCOPE_JSON')).get('allowed_files',[])) if os.path.exists('$SCOPE_JSON') else set()
ts=datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
for p in (l.strip() for l in sys.stdin if l.strip()):
    if p in allow or p.startswith('docs/') or p.startswith('.claude-tmp/'): continue
    print(f'{ts} {session} scope-drift foreign-mutation: {p}')
" >> "$HOME/.claude/tmp/git-agent-errors.log" 2>/dev/null || true
    git add -A
    if git diff --cached --quiet; then
      echo "step-12: nothing to commit (empty diff)"
    else
      git commit -m "$MESSAGE"
      git push -u origin "apex/{session}" || echo "step-12: push failed; non-blocking (/apex-merge integrates the local branch)"
    fi
    ```
    Returns `{status, commit_sha, bump_kind}` to working memory for step 15. Push failure is non-blocking: `/apex-merge` integrates the local `apex/{session}` branch into its base and pushes that base branch (merge-loop.sh never mutates remote refs), so the session commits reach origin via the base-branch push - the `apex/{session}` ref itself is never re-pushed (it is deleted after merge). Empty diff (all-already-satisfied path) is a valid outcome; no commit lands and `bump_hint` is still persisted as a record - a no-op session contributes no commits, so deploy's commit-type bucketing correctly reads no bump from it. The scope-drift emit before `git add -A` is non-blocking - the commit always proceeds; the line only surfaces foreign tool-side mutations (skipping `docs/**` / `.claude-tmp/**` safety paths) in `/apex-improve` for cluster tracking.
