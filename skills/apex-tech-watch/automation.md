# apex-tech-watch: Manual + Automated Invocation

Called from `SKILL.md` (reference link) by users wiring up cron / launchd. Not part of the per-run fetch loop. Extracted from `SKILL.md` to keep the orchestrator within the file-health content budget.

## Manual invocation

```
/apex-tech-watch
```

Useful for ad-hoc refreshes (e.g., right after a major Anthropic announcement). This is the **primary** invocation path until the user sets up an automated schedule (see below).

## Automated weekly schedule (user-owned)

The output file lives at `~/.claude/tmp/tech-updates.md` - a path on the user's local machine. Anthropic's `/schedule` remote triggers run in cloud sandboxes and **cannot** write to local paths, so the remote-trigger route does not fit this skill's contract. Two viable options for automation, both user-owned:

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

Anthropic's `/schedule` remote triggers spawn in cloud sandboxes that have no path back into the user's local `~/.claude/tmp/`. Workarounds (commit-and-pull a tech-updates artifact through a git repo) add complexity and noise to the public repo. The cron is intentionally separate from `/apex-improve` - fetch failures should not block improve runs, and improve runs should not depend on fetching being fresh-of-this-second.
