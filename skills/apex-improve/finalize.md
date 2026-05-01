# apex-improve: Cleanup + Stamp + Report

Called from `SKILL.md` after Step 4 (Apply ops). Returns to SKILL.md for Steps 7-8 (sync-git, standalone-mode only). Extracted from `SKILL.md` to keep the orchestrator under the 150-line cap.

## Step 5: Cleanup + version stamp (inline)

```
# 5a. Archive consumed signals (next session reflect-traces.sh + apex-tech-watch append fresh blocks)
ARCHIVE_DIR="$HOME/.claude/tmp/improvements-archive"; mkdir -p "$ARCHIVE_DIR"
DATE=$(date -u +%Y-%m-%dT%H-%M-%SZ)
WORKFLOW="$HOME/.claude/tmp/apex-workflow-improvements.md"
TECH="$HOME/.claude/tmp/tech-updates.md"
[[ -s "$WORKFLOW" ]] && { cp "$WORKFLOW" "$ARCHIVE_DIR/${DATE}-workflow-improvements.md"; : > "$WORKFLOW"; }
[[ -s "$TECH" ]]     && { cp "$TECH"     "$ARCHIVE_DIR/${DATE}-tech-updates.md";         : > "$TECH"; }

# 5b. Stamp CC version (closes version-drift signal until next CC update)
claude --version | awk '{print $1}' > "$HOME/.claude/tmp/apex-claude-code-version.txt"
```

Both signal files archive to `improvements-archive/` (timestamped) before truncation, so unapplied / deferred blocks remain recoverable. apex-tech-watch's 30-day rotation still bounds `tech-updates.md` between consumption runs (this archive is post-consumption, not a substitute for that rotation). The CC-version stamp lives under `~/.claude/tmp/` (gitignored); local-state only, not committed. Add to `{run}-dirty-paths.txt` only if content changed (`git diff --quiet` check).

## Step 6: Report (inline)

Print a structured summary to stdout (apex-eod step 3 captures and prints this verbatim):

```
apex-improve run {run} complete.

Findings consumed: <N> (workflow-improvements: <a>, tech-updates: <b>, version-drift: <c>)
Operations applied: <N>
  - semantic: <n>
  - replace:  <n>
  - structural: <n> (split: x, rename: y, retire: z, create: w)

Per-file delta_lines (top 5 by absolute value):
  +<n>  <path>
  -<n>  <path>
  ...

Net delta_lines across run: <signed int>
```

If `Net delta_lines > +50` OR `additive` ops > 1, append a Principle 3 note: `this run grew the framework by N lines / created M new files; review whether the findings could have been satisfied semantically`. Informational only - the run still commits.
