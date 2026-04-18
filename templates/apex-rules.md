
Be critical. Challenge assumptions, flag risks, push back when suboptimal. Correct answers over comfortable answers. Always use a single dash "-" in place of double dashes "--".

## Workflow

**Use `/apex`** when project CLAUDE.md's "Workflow Routing" section triggers it, or for any non-trivial task (verification, doc updates, lesson capture automatic).

**All sessions (APEX or not):**

- TaskCreate for 3+ distinct concerns (track progress, visibility) (APEX sessions override: see SKILL.md Step 5A). Count concerns, not files -- a single-concern change touching multiple files (e.g., component + barrel export) is one step.
- Parallel Explore agents for multi-area investigation (single message, multiple Agent tool calls)
- Parallel execution for independent changes (single message, multiple Agent tool calls)
- Sequential execution for dependent changes
- If stuck/failed: Check `.claude/lessons-index.md`, grep relevant sections

**Infrastructure commands:** When implementation requires runtime activation (db migrations, seeders, code generation, dependency installs), run the commands directly -- never defer to the user with "you should run X" or "don't forget to run Y". The only exception is destructive production operations (dropping tables, resetting databases).

**Bug reports and CI failures:** When given a bug report, just fix it -- investigate, diagnose, resolve. No hand-holding, no "should I look into this?". For failing CI tests, go fix them without being told how. Zero context switching required from the user.

**Non-APEX specifics:**

- Complete all file mods before verification (no per-file builds)
- After: Build + lint (skip for simple UI-only changes), note tricky patterns, check doc updates, verify env/infra changes
- Before a bulk refactor (e.g., replacing a pattern across all files in a list), grep the target pattern in each file first. A prior session may have already converted some targets, and stale scope lists reference files that no longer have the pattern -- acting on them causes no-ops or incorrect diffs.

## Tool Preferences

- **Find files**: Glob (not `find`/`ls`). Exception: Glob fails on paths with bracket characters (`[locale]`, `[id]`) -- brackets are interpreted as glob character classes. Use bash `find` as fallback for Next.js dynamic route directories.
- **Search content**: Grep (not `grep`/`rg`)
- **Symbol navigation**: LSP (not Grep) when an LSP server is available for the language. Use `goToDefinition`, `findReferences`, `hover`, `incomingCalls`, `outgoingCalls`, `workspaceSymbol` for symbol-specific lookups. ~15 tokens per query vs ~2,000+ tokens via Grep for the same lookup. Reserve Grep for text pattern searches (string literals, comments, config values, regex patterns across files).
- **Read files**: Read (not `cat`/`head`/`tail`)
- **Edit files**: Edit (not `sed`/`awk`)
- **Stale LSP diagnostics**: The TypeScript LSP can report imports as unused mid-session while they are consumed elsewhere in the same file -- the LSP index has not yet processed the dependent edit. Do not act on "unused import" LSP warnings during an active multi-file edit session; defer to the build step for ground truth. Removing imports based on stale LSP state causes build failures.
- **Investigate**: Agent tool with Explore subagent_type (read-only research) (not during APEX Quick Scan -- direct Glob/Grep only)
- **Track work**: TaskCreate/TaskList (3+ steps)
- **Ask user**: AskUserQuestion, never inline text questions. Treat phrases like "Want me to...", "Should I...", "Shall I...", "Which do you want?", or "Your call" as self-triggers -- stop and call the tool. Multi-option presentations (numbered "paths forward", alternative approaches) belong in AskUserQuestion with one option per path (preview for code/mockup comparisons). Applies to APEX, admin-apex, and plain direct sessions alike.
- **Bulk JSON edits** (e.g., i18n files en.json/fr.json with many keys): use a Python script (`python3 -c "import json..."`) rather than multiple Edit calls -- Python's `json` module handles escaping correctly and avoids partial-write failures on large files.

## Code Quality

- **Cognitive complexity**: Max 15/function (lint enforced). Early returns, extract helpers.
- **Pattern following**: Find one example, match exactly.
- **No over-engineering**: Only what was requested.
- **No dead code**: Remove unused code when making changes (commented-out blocks, unreachable paths, unused imports/variables/functions). Don't leave remnants. After any extraction or split, verify the source file has no orphaned imports, unused variables, or dead declarations.
- **No collateral changes**: If it works and isn't part of the task, leave it.
- **Parameter/bypass removal**: When removing a function parameter or role-based bypass (e.g., `isAdmin`), grep ALL callers across the entire codebase -- each usage site is independent. Multi-point bypasses gate different code paths that must each be found separately.
- **Preserve abstractions**: Never downgrade project components to native elements (see project CLAUDE.md for exceptions).
- **Verify at end**: All mods done -> build + lint once -> fix errors -> report done.
- **File health (enforced gate)**: Before writing >10 lines of new code to any file, run `wc -l`. If >400 lines, split first -- extract separable concerns, then add to the extracted unit. If >500 lines, split regardless of change size (unless trivial edit <10 lines). This is a hard gate, not a suggestion -- do not proceed with the addition until the split is done. Exception: single-concern continuous documents (e.g., terms/privacy legal prose) are exempt.
- **Extract shared**: Pattern appears 2+ times across files -- extract to shared utility/component. Check during implementation, not after.
- **Barrel exports**: When creating or extracting files in a folder with index.ts, update the barrel. New public exports go through the barrel -- callers import from the folder, not the file.

## Documentation

- **Purpose**: Guide AI agents to correct changes in one shot. Token-efficient, pattern-oriented, blast-radius-aware.
- **Include**: Decisions, gotchas, blast radius, cross-layer dependencies, "follow pattern in X file."
- **Exclude**: Anything Glob/Grep-discoverable (routes, file listings, pages, enum values). If it changes when code changes, point to the code.
- **Curated vs exhaustive**: Curated key-file references (3-5 files pointing WHERE to start) are acceptable. Exhaustive enumerations (all services, all routes) that replace Glob/Grep are violations.
- **Source of truth**: A doc declaring "Source of Truth: X" must not hardcode all values from X in its body -- that contradicts itself and creates the duplication it claims to avoid. Reference patterns, point to the source.
- **Size**: Docs >500 lines -- review for narrative bloat vs. pattern-oriented content.

## Security (Non-Negotiable)

**Never:**

- Read/modify `.env*` files (use `env.example`)
- Commit secrets
- Skip auth/authz validation
- Guess security values

**Always:**

- Validate inputs at boundaries
- Preserve existing auth patterns
- Ask if security unclear
- Fail closed on missing secrets: `if (!secret) return true` in HMAC/signature verification silently disables security for all requests. Correct pattern: reject the request if the secret is not configured.

**Always:**

- Client-side input constraints (`maxlength`, `max`, `accept`) are not security controls -- any direct API call bypasses them. Server-side validation (e.g., VineJS `vine.string().maxLength(128)`, file-type checks) is the enforcement layer; client constraints are supplemental UX only.

**Auditing:**

- When auditing a feature doc against actual code, cross-check with recent git commits before concluding a documented feature is present. Docs go stale after feature removal; auditing a removed feature produces false findings.
- When auditing security-sensitive flows documented as "inline" or "atomic" in docs, read the actual SQL/code directly -- prose descriptions can mask gaps where the check happens application-side post-query rather than in the DB operation. Security audit rules: trust the code, not the prose.

## Git Safety (Non-Negotiable)

**Never** use `git checkout --`, `git restore`, `git reset --hard`, `git clean -f`, or `rm` to revert/rollback/discard file changes unless the user explicitly requests it. **This extends to equivalent workarounds** -- `git show HEAD:<path> > file`, `git cat-file blob > file`, `git archive | tar -x`, or any command sequence that extracts committed file contents to overwrite working tree changes. The prohibition is on the destructive outcome (overwriting uncommitted changes), not the specific command syntax. If the hook blocks a direct command, that is not an invitation to find an alternative route to the same result. This includes "scope enforcement" reverts in APEX workflows. Always report unexpected changes and ask the user how to proceed via AskUserQuestion. Unstaged changes are unrecoverable -- destroying them without consent is data loss.

## Authority Order

1. User request (current)
2. Project rules (project `CLAUDE.md`, project config docs)
3. Existing code patterns
4. Industry norms (fallback only)

## Output

Concise. No fluff. Blocked? Ask, don't guess.

ASCII only. No unicode, no emojis, no smart quotes.

## Compaction Preservation

When compacting, preserve: task description, session start time, current APEX path (1/2), active step number, file ownership claims (files), scout findings file path, tail mode, and user decisions. The PreCompact hook echoes these before compaction; the PostCompact hook re-injects them after.

