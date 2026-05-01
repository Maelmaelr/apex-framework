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

Rotate before fetching so the target file's footprint stays bounded.

```
# Move blocks older than 30 days to a single dated archive file.
# Implementation: parse `## <id> - <ISO-8601>` headers; cutoff = now - 30d.
python3 - <<'PY'
import datetime, os, pathlib, re, shutil

target = pathlib.Path(os.path.expanduser("~/.claude/tmp/tech-updates.md"))
archive_dir = pathlib.Path(os.path.expanduser("~/.claude/tmp/tech-updates-archive"))
archive_dir.mkdir(parents=True, exist_ok=True)
if not target.exists() or target.stat().st_size == 0:
    raise SystemExit(0)

content = target.read_text(encoding="utf-8")
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=30)
# Block headers: ## <id> - <ISO-8601-Z>
header_re = re.compile(r"^## ([^\s]+) - (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\b", re.MULTILINE)
matches = list(header_re.finditer(content))
if not matches:
    raise SystemExit(0)

keep_parts, archive_parts = [], []
for i, m in enumerate(matches):
    start = m.start()
    end = matches[i + 1].start() if i + 1 < len(matches) else len(content)
    block = content[start:end]
    block_ts = datetime.datetime.fromisoformat(m.group(2).replace("Z", "+00:00"))
    (archive_parts if block_ts < cutoff else keep_parts).append(block)

if archive_parts:
    archive_file = archive_dir / f"{datetime.date.today().isoformat()}-rotation.md"
    archive_file.write_text("".join(archive_parts), encoding="utf-8")
    target.write_text("".join(keep_parts), encoding="utf-8")
    print(f"rotated {len(archive_parts)} block(s) to {archive_file}")
else:
    print("nothing to rotate")
PY
```

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

If WebFetch fails (404 / timeout / parse error), append a degraded block:

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
  # Force a rotation -- treat all blocks older than 7 days as expired
  python3 -c "<rotation script with --aggressive flag>"
fi
```

The 256 KB cap is a backstop; the 30-day rotation should keep the file well under this in practice. If we hit the cap, the source list is too aggressive for weekly cadence -- surface a one-line warning ("apex-tech-watch: tech-updates.md hit 256 KB cap; aggressive rotation applied") so it's visible at the next /apex-improve run.

## Step 4: Report

Print a single-line summary:

```
apex-tech-watch: <N> source(s) fetched, <M> failure(s), <K> block(s) rotated.
```

If any source failed, append the failure list (source.id + one-line error) on subsequent lines.

## Manual invocation

```
/apex-tech-watch
```

Useful for ad-hoc refreshes (e.g., right after a major Anthropic announcement). This is the **primary** invocation path until the user sets up an automated schedule (see below).

## Automated weekly schedule (user-owned)

The output file lives at `~/.claude/tmp/tech-updates.md` -- a path on the user's local machine. Anthropic's `/schedule` remote triggers run in cloud sandboxes and **cannot** write to local paths, so the remote-trigger route does not fit this skill's contract. Two viable options for automation, both user-owned:

### Option A: macOS launchd (recommended for local-only setup)

Create `~/Library/LaunchAgents/com.user.apex-tech-watch.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.apex-tech-watch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/env</string>
        <string>bash</string>
        <string>-lc</string>
        <string>claude --print "/apex-tech-watch" >> ~/.claude/tmp/apex-tech-watch.log 2>&amp;1</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>0</integer>
        <key>Hour</key>
        <integer>6</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
```

Load: `launchctl load ~/Library/LaunchAgents/com.user.apex-tech-watch.plist`. Adjust `Hour` for your local time (the plist is in local time, no UTC conversion needed). Verify with `launchctl list | grep apex-tech-watch`.

### Option B: cron (if you prefer crontab over launchd)

```
# Sunday 06:00 local
0 6 * * 0 /usr/bin/env bash -lc 'claude --print "/apex-tech-watch" >> ~/.claude/tmp/apex-tech-watch.log 2>&1'
```

### Why not /schedule?

Anthropic's `/schedule` remote triggers spawn in cloud sandboxes that have no path back into the user's local `~/.claude/tmp/`. Workarounds (commit-and-pull a tech-updates artifact through a git repo) add complexity and noise to the public repo. The cron is intentionally separate from `/apex-improve` -- fetch failures should not block improve runs, and improve runs should not depend on fetching being fresh-of-this-second.

## What this skill does NOT do

- Does NOT process or interpret the fetched content beyond summarization -- consumption is `/apex-improve`'s job.
- Does NOT modify any apex framework file -- only `~/.claude/tmp/tech-updates.md` and the archive directory.
- Does NOT cache fetch results -- every run re-fetches. The 7-day cron cadence + WebFetch's own caching is the cost-bound.
- Does NOT push or commit -- output lives under `~/.claude/tmp/` which is `.gitignored`.
- Does NOT validate URLs against a denylist -- the source list is closed and editable; trust the operator.
- Does NOT extract scope or run any apex-active session machinery -- this is a standalone fetcher.

See `sources.json` for the editable source list; `~/.claude/skills/apex-improve/SKILL.md` for the consumer.
