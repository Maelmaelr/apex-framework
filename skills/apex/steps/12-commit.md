# apex step 12 - Commit + persist bump_hint

Lazy-loaded contract for orchestrator step 12. Dispatched from `skills/apex/SKILL.md`
step 12; Read this file before executing the step so the rule is maximally recent
(B/R3 read-before-work). The item-3 step-read gate enforces the read once armed;
until then the dispatch is a soft convention. This file is the full per-step contract. Cross-cutting rules: `apex-core.md` ## Conventions; routing summary: `apex-core-overview.md`.

## Contract

Inline (no subagent hop; orchestrator owns it). Worktree isolation means each session has its own branch + index + working tree, so plain `git add -A; git commit; git push` is correct - no allowlist / private-index / CAS-retry machinery needed. The orchestrator classifies the diff and persists `bump_hint: patch|minor` into the manifest for the project-side deploy skill (e.g. `.claude/skills/deploy/` in the project repo): the deploy skill reads every merged session's `bump_hint`, picks the highest tier across the batch (`minor` > `patch`), and runs `bash skills/apex/scripts/bump-version.sh --kind <tier>` ONCE on the final integration commit (`/apex-merge` no longer owns the bump). Tier definitions live in `apex-core.md` ## Conventions (bump tiers).
    ```
    # Classify diff -> patch (bug fix / refactor / internal-only / tweak) | minor (new public symbol/route/component OR breaking API change). Never major - user-set only.
    BUMP_HINT=<patch|minor>
    # Persist hint into manifest for the project-side deploy skill to consume.
    tmpf=$(mktemp) && jq --arg h "$BUMP_HINT" '. + {bump_hint: $h}' .claude-tmp/apex-active/{session}.json > "$tmpf" && mv "$tmpf" .claude-tmp/apex-active/{session}.json
    # Draft commit MESSAGE from `git diff {diff_anchor}..HEAD` + `git status --porcelain`
    # (orchestrator inline; the working tree IS this session's scope).
    # Scope-drift emit (one line per foreign-modified path; non-blocking) - the scope-check
    # hook cannot see tool-side auto-mutations (formatters / codegen / installs).
    SCOPE_JSON=".claude-tmp/apex-active/{session}-main-scope.json"
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
      git push -u origin "apex/{session}" || echo "step-12: push failed; /apex-merge will retry"
    fi
    ```
    Returns `{status, commit_sha, bump_kind}` to working memory for step 15. Push failure is non-blocking: `/apex-merge` re-attempts the push as part of its merge loop. Empty diff (all-already-satisfied path) is a valid outcome; no commit lands and `bump_hint` is still persisted so the deploy skill picks no-op intent up correctly. The scope-drift emit before `git add -A` is non-blocking - the commit always proceeds; the line only surfaces foreign tool-side mutations (skipping `docs/**` / `.claude-tmp/**` safety paths) in `/apex-improve` for cluster tracking.
