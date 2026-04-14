# apex-update - Update Project Documentation

<!-- Called by: apex-tail.md (Agent 2, spawned from SKILL.md Step 6A or apex-apex.md plan Phase 4), apex-file-health/SKILL.md Step 6 -->

**Output rules:** Only output the project guard skip message, Step 1.5 skip message, Step 3 skip message, Step 5 report, or staleness findings. No other text output.

## Step 1: Read Project Context

Your spawn prompt must include: (1) files modified list, (2) features/behaviors added or changed, (3) relevant doc files from CLAUDE.md Doc Update Rules routing. Use this structured mapping directly -- do not self-discover which docs to check.

**Project guard:** Grep CLAUDE.md for `Doc Update Rules` and `Doc Quick Reference` (case-insensitive). If neither section exists, print "Docs: No doc update rules configured -- skipping" and stop.

If the spawn prompt is missing doc routing, Grep for `Doc Update Rules` (case-insensitive) in CLAUDE.md, then Read with offset/limit to extract only that section. Do not read the full CLAUDE.md.

Run `git diff --stat HEAD` to ground yourself in what actually changed. Ignore files not listed in the spawn prompt summary. Cross-reference against the spawn prompt summary -- if files appear in the diff but not the summary, include them in your scope.

## Step 1.5: Change Classification

Classify all changes from the diff as: (a) public API/interface/feature change, (b) internal-only refactor (no exported symbol or behavior change), (c) test/config/style-only. If ALL changes are (b) or (c), print "Docs: No updates required (internal/test-only changes)" and stop.

## Step 2: Check Triggers

Review changes against the doc routing provided in your spawn prompt. For each routed doc, verify the change is reflected.

**Cross-reference check:** For each significant change in the implementation summary, identify the doc that should cover it (use the doc routing from your spawn prompt). Read that doc and verify the change is reflected. If not, add it to your update list.

**New feature area:** If a change introduces a new feature area and no existing doc covers it, add to the update list: "Create: {file path} -- {one-line scope}". Follow the structure of the nearest sibling doc in the same directory.

**Opportunistic staleness detection:** When reading a doc section to verify changes are reflected, flag content in that section that directly contradicts the current implementation changes. Do not audit unrelated content in the same section. Report stale findings as "Stale: {file}:{section}: {what's stale}" in your output for the user to decide on. Cap staleness findings at 3 per doc file. Prioritize contradictions over omissions.

**Discoverability guard:** For each trigger identified in Step 2, verify the information is NOT Glob/Grep-discoverable from code (routes, file paths, page listings, enum values, config keys) before reading the target doc. If discoverable, point to the code location instead of hardcoding. Skip the doc read for that trigger.

**Env var sync:** If the diff includes `process.env`, `Env.get(`, or `NEXT_PUBLIC_` patterns, verify env.example, env.production.example, apps/api/env.test.example, and relevant Docker files are updated per CLAUDE.md "Env & Docker Sync" rules. Report missing updates.

**Feature removal:** If the implementation removed a feature or endpoint, check if the corresponding doc section should be removed or updated. Stale docs describing removed features are actively harmful.

## Step 3: Skip If None

If no documentation updates are needed:
Print: "Docs: No updates required"
Stop here.

## Step 4: Apply Updates

If updates are needed:
Follow shared-guardrails.md output formatting (#12 ASCII only, #15 no tables/diagrams).
1. Use Edit tool to make minimal, targeted edits
2. Only update what the changes require
3. Do not add unnecessary information or restructure
4. Do not output explanatory text between edits -- just make the edits. Your only text output should be the Step 5 report

## Step 4.5: Health Check

After making edits, check if any updated doc exceeds 500 lines. If so, append to the report: "Health: {file} at {N} lines -- review for narrative bloat vs. pattern-oriented content."

## Step 4.6: Verify Cross-References

After making edits, verify within edited sections: (a) file paths mentioned in text still exist (Glob), (b) section headers referenced by other docs still match their target (Grep). Fix broken cross-references before reporting.

## Step 4.7: Doc Quick Reference Sync

If any doc file was created or removed in Step 4, verify CLAUDE.md Doc Quick Reference has a matching entry. Add or remove the entry.

## Step 5: Report

Print a brief summary (this gets surfaced to the user by the caller):
"Docs: Updated {list of files} ({one-line summary of what changed, e.g. 'added new API endpoint docs'})"

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not create new documentation files unless the implementation introduces a new feature area with no existing doc coverage (per CLAUDE.md Doc Update Rules)
- Do not restructure existing documentation
- Do not update documentation before verifying the implementation works
