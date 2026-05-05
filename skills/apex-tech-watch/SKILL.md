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
```

## Step 1: 30-day rotation (BEFORE fetching)

Rotate before fetching so the target file's footprint stays bounded. Read and follow `~/.claude/skills/apex-tech-watch/rotation.md` for the canonical rotation Python block (and the aggressive 7-day variant called from Step 3's hard-cap fallback).

## Step 2: Fetch + summarize each source

Read `sources.json`. For each entry in the `sources` array:

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

Use `WebSearch` with the source's `query` and the `summarize_prompt`. Block format:

```
## {source.id} - {TS}
- url: search:{source.query}
- summary:
  {WebSearch summary, indented 2 spaces}
```

Same failure handling as webfetch.

## Step 3: Token budget guard

After all sources processed, check `tech-updates.md` size:

```
LIMIT=$(( 256 * 1024 ))  # 256 KB hard cap
size=$(wc -c < "$TARGET" 2>/dev/null || echo 0)
if (( size > LIMIT )); then
  # Force a rotation - treat all blocks older than 7 days as expired
  python3 -c "<rotation script with --aggressive flag>"
fi
```

The 256 KB cap is a backstop; the 30-day rotation should keep the file well under this in practice. If we hit the cap, the source list is too aggressive for weekly cadence - surface a one-line warning ("apex-tech-watch: tech-updates.md hit 256 KB cap; aggressive rotation applied") so it's visible at the next /apex-improve run.

## Step 4: Report

Print a single-line summary:

```
apex-tech-watch: <N> source(s) fetched, <M> failure(s), <K> block(s) rotated.
```

If any source failed, append the failure list (source.id + one-line error) on subsequent lines.

## Manual + automated invocation

See `~/.claude/skills/apex-tech-watch/automation.md` for the manual `/apex-tech-watch` slash-command path, the macOS launchd plist, the cron alternative, and why Anthropic's `/schedule` remote-trigger does not fit this skill's local-output contract.

## What this skill does NOT do

- Does NOT process or interpret the fetched content beyond summarization - consumption is `/apex-improve`'s job.
- Does NOT modify any apex framework file - only `~/.claude/tmp/tech-updates.md` and the archive directory.
- Does NOT cache fetch results - every run re-fetches. The 7-day cron cadence + WebFetch's own caching is the cost-bound.
- Does NOT push or commit - output lives under `~/.claude/tmp/` which is `.gitignored`.
- Does NOT validate URLs against a denylist - the source list is closed and editable; trust the operator.
- Does NOT extract scope or run any apex-active session machinery - this is a standalone fetcher.

See `sources.json` for the editable source list; `~/.claude/skills/apex-improve/SKILL.md` for the consumer.
