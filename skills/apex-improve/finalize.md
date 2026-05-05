# apex-improve: Polish + Cleanup + Stamp + Report

Called from `SKILL.md` after Step 2 (no-signals exit), after Step 4 (0-ops exit), or after a normal Step 4 apply. Always runs - the consumed signal files reset on every apex-improve invocation, regardless of whether ops were emitted, so stale blocks don't replay as deja-vu noise on the next run. Returns to SKILL.md for Steps 7-8 (sync-git, standalone-mode only; skipped when 0 ops applied since nothing to commit). Extracted from `SKILL.md` to keep the orchestrator under the 150-line cap.

## Step 5a: Polish (post-implementation check)

```
bash $HOME/.claude/skills/admin-apex/scripts/polish-check.sh --run "$RUN"
```

Re-snapshots inventory, re-runs the orphan-refs / missing-refs / schema-mismatch / dead-hook detectors (mirrors `~/.claude/skills/admin-apex/audit.md`), diffs against any pre-existing `{run}-drift-report.json` so only NEW drift introduced by Step 4 apply surfaces. Skipped automatically when 0 ops applied this run.

- Exit `0` -> clean; continue to Step 5b.
- Exit `1` -> new drift in `{run}-polish-report.json`. Append one finding-shaped block per cluster to `~/.claude/tmp/apex-workflow-improvements.md` (via `skills/apex/scripts/append-with-lock.sh`) so the next `/apex-improve` run picks it up. Continue to Step 5b - do NOT block the current run; the report (Step 6) surfaces the polish cluster count.
- Exit `2` -> bad args / state corruption; abort with explicit error.

## Step 5b: Cleanup + version stamp (inline)

```
# 5a. Archive consumed signals (next session reflect-traces.sh + apex-tech-watch append fresh blocks)
ARCHIVE_DIR="$HOME/.claude/tmp/improvements-archive"; mkdir -p "$ARCHIVE_DIR"
DATE=$(date -u +%Y-%m-%dT%H-%M-%SZ)
WORKFLOW="$HOME/.claude/tmp/apex-workflow-improvements.md"
TECH="$HOME/.claude/tmp/tech-updates.md"
ERRLOG="$HOME/.claude/tmp/reflector-errors.log"
[[ -s "$WORKFLOW" ]] && { cp "$WORKFLOW" "$ARCHIVE_DIR/${DATE}-workflow-improvements.md"; : > "$WORKFLOW"; }
[[ -s "$TECH" ]]     && { cp "$TECH"     "$ARCHIVE_DIR/${DATE}-tech-updates.md";         : > "$TECH"; }
[[ -s "$ERRLOG" ]]   && { cp "$ERRLOG"   "$ARCHIVE_DIR/${DATE}-reflector-errors.log";    : > "$ERRLOG"; }

# 5b. Stamp CC version (closes version-drift signal until next CC update)
claude --version | awk '{print $1}' > "$HOME/.claude/tmp/apex-claude-code-version.txt"
```

All three signal files archive to `improvements-archive/` (timestamped) before truncation, so unapplied / deferred blocks and historical errors remain recoverable. `reflector-errors.log` is reset alongside the structured logs because any rescued-from-errlog analyses (the 2026-05-02 lost-block incident, recovered by hand from this file) have by definition been consumed by analyze.md once they reach this point; carrying old errors across runs reads as recurring noise to the next analyze pass. apex-tech-watch's 30-day rotation still bounds `tech-updates.md` between consumption runs (this archive is post-consumption, not a substitute for that rotation). The CC-version stamp lives under `~/.claude/tmp/` which IS tracked (`.gitignore:54` keeps `tmp/` itself tracked, only `*.lock` ignored); the stamp + signal-file truncations produce a real git diff that piggybacks on the next framework-evolution commit (not its own commit when 0 ops applied). Add to `{run}-dirty-paths.txt` only if content changed (`git diff --quiet` check).

Step 5 is two phases: 5a (polish) and 5b (cleanup + stamp). 5a runs FIRST so the report at Step 6 reflects polish findings; 5b's archive + truncate must NOT happen until polish has had a chance to escalate new drift via `apex-workflow-improvements.md` (otherwise polish-driven escalations would be archived in the same breath they were written, becoming consume-on-write noise next run).

## Step 6: Report (inline)

Print a structured summary to stdout (apex-eod step 3 captures and prints this verbatim):

```
apex-improve run {run} complete.

Findings consumed: <N> (workflow-improvements: <a>, tech-updates: <b>, version-drift: <c>)
Operations applied: <N>
  - semantic: <n>
  - replace:  <n>
  - structural: <n> (split: x, rename: y, retire: z, create: w)
Polish: <clean | N new <kind> cluster(s) escalated to apex-workflow-improvements.md>

Per-file delta_lines (top 5 by absolute value):
  +<n>  <path>
  -<n>  <path>
  ...

Net delta_lines across run: <signed int>
```

If `Net delta_lines > +50` OR `additive` ops > 1, append a Principle 3 note: `this run grew the framework by N lines / created M new files; review whether the findings could have been satisfied semantically`. Informational only - the run still commits.
