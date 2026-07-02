# apex-improve: Polish + Cleanup + Stamp + Report

Called from `SKILL.md` after Step 2 (no-signals exit), after Step 4 (0-ops exit), or after a normal Step 4 apply. Always runs - the consumed signal files reset on every apex-improve invocation, regardless of whether ops were emitted, so stale blocks don't replay as deja-vu noise on the next run. Returns to SKILL.md for Steps 7-8 (sync-git, standalone-mode only; skipped when 0 ops applied since nothing to commit). Extracted from `SKILL.md` to keep the orchestrator within the file-health content budget.

## Step 5a: Polish (post-implementation check)

```
bash $HOME/.claude/skills/admin-apex/scripts/polish-check.sh --run "$RUN"
```

Re-snapshots inventory, re-runs the orphan-refs / missing-refs / schema-mismatch / dead-hook / approaching-budget (WARN) / hash-roster (WARN) / negative-scope (WARN) detectors (mirrors `~/.claude/skills/admin-apex/audit.md`), diffs against any pre-existing `{run}-drift-report.json` so only NEW drift introduced by Step 4 apply surfaces. Skipped automatically when 0 ops applied this run.

- Exit `0` -> clean; continue to Step 5b.
- Exit `1` -> new drift in `{run}-polish-report.json`. Hold the clusters in working memory - do NOT append yet. The escalation append happens in Step 5d, AFTER 5b archives + truncates the workflow file; appending here would copy the block to the archive and wipe it from the live file in the same pass, so the next run would read an empty file and NOT pick it up. Continue to Step 5b - do NOT block the current run; the report (Step 6) surfaces the polish cluster count.
- Exit `2` -> bad args / state corruption; abort with explicit error.

## Step 5b: Cleanup + version stamp (inline)

```
# 5a. Archive consumed signals (the reflector + apex-tech-watch append fresh blocks)
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

# 5c. Backlog consolidation cleanup (analyze Step 2 "Prior-run deferred-findings").
# Prune findings that became ops this run from the carried deferred file, THEN
# delete the prior files this run consumed. Order matters: the consolidated
# {run}-deferred-findings.json already holds every ingested finding, so deleting
# the originals only after the prune is loss-free; a crash before here leaves the
# originals intact for the next run to re-ingest.
# $RUN is orchestrator-bound (same token Step 1 minted). If unset, skip 5c
# entirely - never fall back to a .current-run pointer (those are stale across
# runs) and never operate on an empty token; cleanup defers to the next run.
if [[ -n "${RUN:-}" ]]; then
ROOT="$HOME/.claude/.claude-tmp/admin-apex-active"
DEFERRED="$ROOT/$RUN-deferred-findings.json"; PLAN="$ROOT/$RUN-evolve-plan.json"
APPLIED="$ROOT/$RUN-applied-ops.json"; CONSUMED="$ROOT/$RUN-consumed-deferred.txt"
# Prune only when >=1 op was applied; drop deferred ids listed in the plan's
# _meta.source_clusters (the findings that motivated this run's ops). Plan-level
# tie (ops carry no per-op finding id); a planned-but-failed sibling op is the
# rare edge - it re-surfaces via the live signal track, never a silent loss.
if [[ -s "$APPLIED" && -s "$PLAN" && -s "$DEFERRED" ]] && python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) else 1)" "$APPLIED" 2>/dev/null; then
  python3 - "$DEFERRED" "$PLAN" <<'PY' || true
import json, sys
deferred_path, plan_path = sys.argv[1], sys.argv[2]
try:
    deferred = json.load(open(deferred_path))
    applied_ids = set(json.load(open(plan_path)).get("_meta", {}).get("source_clusters", []))
except Exception:
    sys.exit(0)
kept = [f for f in deferred if f.get("id") not in applied_ids]
json.dump(kept, open(deferred_path, "w"), indent=2)
PY
fi
# Delete consumed originals (never this run's own consolidated file).
if [[ -f "$CONSUMED" ]]; then
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == "$DEFERRED" ]] && continue
    rm -f -- "$p" 2>/dev/null || true
  done < "$CONSUMED"
fi
fi  # end RUN-bound guard
```

## Step 5d: Polish escalation (post-truncate; only when 5a exited 1)

If Step 5a returned exit 1, NOW - after 5b's archive+truncate has run - append one finding-shaped block per held polish cluster to the freshly-truncated `~/.claude/tmp/apex-workflow-improvements.md` via `skills/apex/scripts/append-with-lock.sh`, framed as a `## {run} - apex-improve-polish - {ts}` block (same shape reflector.md emits). Post-truncate placement is what makes "the next run picks it up" actually hold. Frame `approaching-budget` clusters as standing-state, NOT "introduced by apply", when this run's net `delta_lines` for the named files was `<= 0` - the Step-4 pre-flight baseline (apply.md) already suppresses those at the detector level, so a surviving approaching-budget item here is genuinely net-new.

## Notes

All three signal files archive to `improvements-archive/` (timestamped) before truncation, so unapplied / deferred blocks and historical errors remain recoverable. `reflector-errors.log` is reset alongside the structured logs because any rescued-from-errlog analyses have by definition been consumed by analyze.md once they reach this point; carrying old errors across runs reads as recurring noise to the next analyze pass. apex-tech-watch's 30-day rotation still bounds `tech-updates.md` between consumption runs (this archive is post-consumption, not a substitute for that rotation). The CC-version stamp lives under `~/.claude/tmp/` which IS tracked (`.gitignore:54` keeps `tmp/` itself tracked, only `*.lock` ignored); the stamp + signal-file truncations produce a real git diff that piggybacks on the next framework-evolution commit (not its own commit when 0 ops applied). Add to `{run}-dirty-paths.txt` only if content changed (`git diff --quiet` check).

Step 5 ordering: 5a runs polish DETECTION first so Step 6's report reflects it, but the escalation APPEND (Step 5d) happens only AFTER 5b archives + truncates `apex-workflow-improvements.md`. Appending before the truncate would archive the escalation in the same pass and the next run would read an empty live file - it would NOT pick it up. The 5c backlog-consolidation cleanup runs LAST within 5b - prune-then-delete-originals strictly after the consolidated `{run}-deferred-findings.json` is on disk, so no crash window can drop the carried backlog.

## Step 6: Report (inline)

Print a structured summary to stdout:

```
apex-improve run {run} complete.

Findings consumed: <N> (workflow-improvements: <a>, tech-updates: <b>, version-drift: <c>)
Deferred backlog: <ingested I from M prior files> -> <carried forward K> (chronic C: need manual decision)
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

When `chronic C > 0`, list the chronic finding ids (one per line) under the report so the user sees what is stuck: a finding `deferrals >= 3` keeps failing the same design-decision / AskUserQuestion gate, so it is carried forward (non-lossy) but no longer auto-planned. Surfacing it nudges a manual decision instead of silent re-cycling.
