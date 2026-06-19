---
name: apex-tech-watch
description: Weekly tech-watch fetcher. Reads sources.json (closed list of WebFetch / WebSearch targets), summarizes each via the LLM, appends timestamped blocks to ~/.claude/tmp/tech-updates.md. Rotates blocks older than 30 days into ~/.claude/tmp/tech-updates-archive/. Slash-invokable + cron-driven (Sunday 06:00 local). Output is consumed by /apex-improve.
triggers:
  - apex-tech-watch
---

# apex-tech-watch - Weekly Tech-Watch Fetcher

Pulls the latest signal from a closed list of sources and appends to a single file the improve loop reads. Lean by design: one file edit per source, no caching layer, no RSS parsers, no third-party deps.

## Output contract

`~/.claude/tmp/tech-updates.md` is the single output. Block format (one block per source per run):

```
## {source.id} - <YYYY-MM-DDTHH:MM:SSZ>
- url: <source.url or 'search:<query>'>
- summary:
  <multi-line summary as returned by the LLM, indented two spaces>
```

Multiple runs in the same week append multiple blocks (intentional; cheap deduplication is the consumer's job).

## Step 0: Run-level prep

```
mkdir -p "$HOME/.claude/tmp" "$HOME/.claude/tmp/tech-updates-archive"
TARGET="$HOME/.claude/tmp/tech-updates.md"
ARCHIVE="$HOME/.claude/tmp/tech-updates-archive"
SOURCES="$HOME/.claude/skills/apex-tech-watch/sources.json"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN=$(openssl rand -hex 4)
RUNDIR="$HOME/.claude/.claude-tmp/apex-tech-watch-active"
mkdir -p "$RUNDIR"
SUMMARY="$RUNDIR/${RUN}-summary.md"
printf '{"run":"%s","producer":"apex-tech-watch","ts":"%s"}\n' "$RUN" "$TS" > "$RUNDIR/${RUN}.json"
```

`RUN` / `SUMMARY` / `RUNDIR` arm Step 5's reflector spawn + cleanup; manifest disqualifies SKIPPED-no-inputs (per `agents/reflector.md`).

## Step 1: 30-day rotation (BEFORE fetching)

Rotate before fetching so the target file's footprint stays bounded. Read and follow `~/.claude/skills/apex-tech-watch/rotation.md` for the canonical rotation Python block; its aggressive 7-day variant is not a separate runnable block - Step 3's hard-cap fallback applies the 30->7 day cutoff swap inline (see rotation.md).

## Step 2: Fetch + summarize each source

Read `sources.json`. For each entry in the `sources` array (prepend `Today is {date portion of TS}. ` to the entry's `summarize_prompt` at invocation so date-bounded windows resolve on the first pass - runtime-only, NEVER persisted back to sources.json):

### kind == webfetch

Use `WebFetch` with the source's `url` and `summarize_prompt`. Append the block to `tech-updates.md`:

```
## {source.id} - {TS}
- url: {source.url}
- summary:
  {WebFetch result, indented 2 spaces, line-wrapped at ~100 chars}
```

**Redirect handling**: If `WebFetch` returns a `REDIRECT DETECTED` envelope (e.g. `docs.anthropic.com` -> `platform.claude.com`, or a docs URL that 307s to a GitHub raw file), do NOT write the redirect notice as the block summary. Instead:

1. Re-fetch the redirect target URL with the same `summarize_prompt`.
2. Use the second-fetch result as the block summary.
3. Update `sources.json` in-place to replace the stale URL with the redirect target so the next run hits it on first try. Edit the JSON file directly (one Edit call per stale URL); do not commit or push - the cron / next manual run picks up the new URL.

This applies to permanent (301) and temporary (307) redirects alike. If a follow-up redirect chain is encountered, follow up to two hops total before degrading to a `fetch failed:` block.

If WebFetch fails (404 / timeout / parse error / redirect-loop), append a degraded block:

```
## {source.id} - {TS}
- url: {source.url}
- summary:
  fetch failed: <one-line error>
```

Do NOT abort the run on a single source failure; other sources still produce useful signal.

### kind == websearch

`WebSearch` takes only `query` / `allowed_domains` / `blocked_domains` (no summary-prompt param). Run it with the source's `query`, then summarize the returned result set in-context using the source's `summarize_prompt` (plus the Step 2 date prefix) as the summarization instruction. Block format:

```
## {source.id} - {TS}
- url: search:{source.query}
- summary:
  {in-context summary of the WebSearch result set, indented 2 spaces}
```

Same failure handling as webfetch.

## Step 3: Token budget guard

After all sources processed, check `tech-updates.md` size:

```
LIMIT=$(( 256 * 1024 ))  # 256 KB hard cap
size=$(wc -c < "$TARGET" 2>/dev/null || echo 0)
if (( size > LIMIT )); then
  # Force a rotation - treat all blocks older than 7 days as expired
  # apply rotation.md's aggressive variant inline: re-run the Step-1 rotation block with cutoff = timedelta(days=7)
  echo "step-3: budget-guard aggressive-rotation-applied (size=${size}B > ${LIMIT}B)" >> "$SUMMARY"
else
  echo "step-3: budget-guard OK (size=${size}B <= ${LIMIT}B)" >> "$SUMMARY"
fi
```

The 256 KB cap is a backstop; the 30-day rotation should keep the file well under this in practice. If we hit the cap, the source list is too aggressive for weekly cadence - surface a one-line warning ("apex-tech-watch: tech-updates.md hit 256 KB cap; aggressive rotation applied") so it's visible at the next /apex-improve run. Either way record the guard outcome (`budget-guard: OK` | `aggressive-rotation-applied`) to `$SUMMARY` so the improve loop confirms the check ran rather than inferring a silent skip.

## Step 4: Report

Print a single-line summary AND append it (plus any failure lines) to `$SUMMARY` so Step 5's reflector has a trace input:

```
line="apex-tech-watch: <N> source(s) fetched, <M> failure(s), <K> block(s) rotated."
printf '%s\n' "$line" | tee -a "$SUMMARY"   # on failures, tee each "  <id>: <err>" too
```

Then surface degraded fetch quality: grep the blocks appended THIS run for quality markers anchored to summary indented lines (`grep -E '^  (stale|unverified|likely-stale)'` - two-space indent + marker at line start, the shape the LLM emits as a status prefix) and emit one `  warn <id>: <marker line>` per hit into `$SUMMARY`. Anchoring excludes mid-line feature-name occurrences (e.g. Next.js `stale 'use cache'`) that would otherwise trip a false warn. A `fetch returned a likely-stale snapshot` / out-of-window source is NOT a hard failure (the block still appended) so it never trips the `<M> failure(s)` count - without this scan it passes silently and the improve loop cannot see partial-quality runs deterministically. Zero hits -> no extra line.

## Step 5: Self-reflect

Spawn `agents/reflector.md` (Sonnet, foreground) with phase `apex-tech-watch`. Captures stale-source / rotation-policy / sources.json drift signals into `~/.claude/tmp/apex-workflow-improvements.md` for the next `/apex-improve` to consume.

Spawn-prompt template (substitute `{run}` with Step 0's `RUN`):

```
You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md
and follow the `apex-tech-watch Step 5` row of the invocation table.

Token:    {run}
Phase:    apex-tech-watch
Manifest: $HOME/.claude/.claude-tmp/apex-tech-watch-active/{run}.json

Errors -> ~/.claude/tmp/reflector-errors.log (silent failure).
Shut down silently (no main-session output).
```

After reflector returns, sweep this run's artifacts: `rm -f "$RUNDIR/${RUN}"*` (matches both `${RUN}.json` and `${RUN}-summary.md`; idempotent - reflector self-silences on error so cleanup is unconditional).

## Manual + automated invocation

See `~/.claude/skills/apex-tech-watch/automation.md` for the manual `/apex-tech-watch` slash-command path, the macOS launchd plist, the cron alternative, and why Anthropic's `/schedule` remote-trigger does not fit this skill's local-output contract.

## Boundaries

Summarizes fetched content only - consumption is `/apex-improve`'s job. Writes only `~/.claude/tmp/tech-updates.md` + the archive dir (plus the in-place `sources.json` stale-URL refresh from Step 2 redirect handling); that output is `.gitignored`, so the skill neither pushes nor commits. Every run re-fetches (no result cache - the 7-day cron cadence + WebFetch caching is the cost bound). The source list is closed and operator-trusted (no URL denylist). Standalone fetcher: no scope extraction, no apex-active session machinery.

See `sources.json` for the editable source list; `~/.claude/skills/apex-improve/SKILL.md` for the consumer.
