# Here is the revised version

# /apex <prompt>

Apex is the main orchestrator in the main session.

## Entry flow

0. Initialisation
   - /apex (main orchestrator) | `~/.claude/skills/apex`
     - taskCreate below tasks 1. to 5.
1. Analyze
   - inline task prompt
     - analyzes prompt
     - askUserQuestion if ambiguous (assuming = forbidden)
2. Create session manifest (concurrent session mitigation) | Blocked by #1
   - script creates {session} token + session manifest in `.claude-tmp/apex-active/`
3. Hypothesis (be careful, prompt may bias/narrow actual scope implied by user) | Blocked by #2
   - inline task prompt
     - emits hypothesis
4. Load lessons | Blocked by #3
   - inline task prompt
     - runs `grep-lessons.sh` from hypothesis keywords from previous step
     - runs `update-hit.sh` (lesson hit-tracking) with matched lesson IDs from grep-lessons.sh
5. Trivial task detection -> if trivial, jump to Path 1 | Blocked by #4
   - inline task prompt
     - scout-skip detection: single file, no cross-file deps in hypothesis, no new abstractions
     - trivial detection trades fidelity for latency; if the inline task is uncertain, default to non-trivial
     - returns trivial|non-trivial
   - if trivial: call p1.md | `~/.claude/skills/apex/p1.md`
   - if non-trivial: taskCreate below tasks 6. to 9.
6. Scout phase 1 (enumerate -> shard -> screen) against hypothesis
   - scout1.md | `~/.claude/skills/apex/scout1.md`
     - taskCreate (insert before task 7.) the 3 below tasks
       - 6.a enumerate (deterministic enumeration)
         - runs scripts (generates `findings-{session}.json`)
           - Static imports, LSP refs, grep patterns, dynamic-import regex sweep, framework-convention scans
           - All script-driven, ground truth list
           - If failure, fall back to grep-only enumeration with explicit warning written to `findings-{session}.json` header
         - returns `findings-{session}.json` to apex
       - 6.b shard (preflight sizing + shard plan) | Blocked by #6.a
         - shard script
           - reads `findings-{session}.json`
           - decides mechanically: shard count (files / threshold), shard boundaries (by top-level dir, file-type, or import-edge cluster)
           - emits shared screening prompt template with hypothesis injected verbatim (passed as CLI arg from orchestrator)
           - generates `shard-plan-{session}.json` with `{shards: [...], screening_prompt: "..."}`
           - returns `shard-plan-{session}.json` path to apex
       - 6.c screen (parallel LLM screening) | Blocked by #6.b
         - spawns parallel screener subagents per `shard-plan-{session}.json`
         - screener.md | `~/.claude/agents/screener.md` (Sonnet latest subagent)
           - follows given screening task: gets its shard + hypothesis, returns keep/drop + relevance annotation per file
           - writes claim-provenance trace to `.claude-tmp/apex-active/{session}-traces/entryflow/screener-{shard-id}.md` (kept/dropped lists + one-line reason per drop)
           - returns a pointer + minimal decision signal to apex (path + one-line status), never the findings body
           - careful about hallucination
         - aggregates and returns the overall pointer
         - returns `screened-{session}.json` to apex
   - Persist findings in `.claude-tmp/scout/`
7. Scout phase 2 preflight -> select medium or complex mode (re-scout if gaps) | Blocked by #6
   - scout2.md | `~/.claude/skills/apex/scout2.md`
     - reads `screened-{session}.json` + prompt
     - Writes `preflight-{session}.json`: `{missed_regions: [...], effective_blast: small|large, mode: medium|complex}`
     - Gate:
       - `missed_regions=[]` AND `effective_blast=small` -> medium mode, jump to 8
       - Else -> complex mode, taskCreate 7.x
   - 7.x Targeted re-scout (only if gate triggered, insert before task 8.)
     - rescout.md | `~/.claude/agents/rescout.md` (Sonnet latest subagent)
       - re-enumerates `missed_regions`
       - writes `rescout-{session}.json`
       - writes trace to `.claude-tmp/apex-active/{session}-traces/entryflow/rescout-{round}.md` (regions queried, files newly found, why prior pass missed them)
       - run `merge-scout-findings.py` to merge into `screened-{session}.json`
       - tasks 7.x doesn't re-trigger preflight (complex mode is sticky)
8. Verify claims (anti-hallucination) | Blocked by #7
   - `verify-claims.sh` (script) verifies claims
     - Reads `screened-{session}.json` and `preflight-{session}.json` from `.claude-tmp/scout/`
     - For each claim (file path + line range + reason): verify file exists, re-read the cited line range, confirm content is non-empty and the line range is in-bounds
     - Drop mechanically-failed claims from both files (file missing, line range out-of-bounds, empty range), log dropped count per layer
     - Emit unresolved claims (file + range valid, but reason-string semantic match unclear) to `claim-review-{session}.json` for optional main-orchestrator review
     - Gate (absolute counts; percent thresholds are arbitrary on small claim sets):
       - `preflight_bad >= 2` -> exit non-zero, abort and surface to user (preflight drives path selection; cannot proceed on shaky ground)
       - `screened_bad >= 3` OR `screened_bad_rate >= 30%` (whichever first) -> exit code signals re-run 6c; cap at one re-run per session, second trip aborts (prevents infinite loop on systemically bad screening)
       - Otherwise -> exit 0, proceed with cleaned files
   - Optional: main orchestrator reviews `claim-review-{session}.json` inline for reason-string semantics (no subagent spawn; Opus already in main session)
9. Decide path (medium -> Path 1, complex -> Path 2) | Blocked by #8
   - script (reads `preflight-{session}.json` mode and branches)
   - if medium
     - call p1.md | `~/.claude/skills/apex/p1.md`
   - if complex
     - taskCreate 10.|**p2.0.1**|**p2.0.2**|**p2.0.3**.
   - Main orchestrator returns inline the selected path
10. If Path 2, self-reflect
    - reflector.md | `~/.claude/agents/reflector.md` (Haiku, background, silent)
      - parameter = entryflow
      - inputs: TaskList for the phase, `git diff --stat`, `.claude-tmp/apex-active/{session}.json` (path-only)
      - first action: `cat .claude-tmp/apex-active/{session}-traces/entryflow/*.md > /tmp/{session}-entryflow-snapshot.txt` (snapshot defends against p2.6 cleanup race)
      - processes snapshot, not live files
      - emits structured append (no prose) to `~/.claude/tmp/apex-workflow-improvements.md`:

        ## {session} - entryflow - {timestamp}
        - gaps: <one-line per gap, max 3>
        - fixes-applied: <one-line per autonomous fix, max 3>
        - improvements: <one-line per suggestion, max 3>

      - errors logged to `~/.claude/tmp/reflector-errors.log` (silent failure otherwise)
      - shuts down silently (no main-session output)

## Trace files (opt-in)

For agents whose internal reasoning matters (provenance, failure analysis), the agent writes a trace before returning its summary:

- Path: `.claude-tmp/apex-active/{session}-traces/{phase}/{agent}-{step}.md`
- Phases: `entryflow` (screener, rescout), `p1` (executor), `p2` (executor)
- Content: decision rationale, dropped candidates with reasons, error context (not the full conversation)
- Trace-writing agents: executor.md (on failure or split), screener.md (claim provenance: which files dropped + why), rescout.md (newly-found regions + why missed)
- Non-trace agents: shard (script), verify (script), learn/documentation/diff (output is the artifact), reflector (consumer, not producer)

Reflector reads phase-scoped trace subdirs:

- entryflow phase (Path 2 Step 10): `{session}-traces/entryflow/*.md`
- p1 phase: `{session}-traces/entryflow/*.md` + `{session}-traces/p1/*.md` (Path 1 has no Step 10)
- p2 phase: `{session}-traces/p2/*.md` (entryflow already covered by Step 10)

## Path 1 (p1)

- **p1.0** Initialisation
  - p1.md | `~/.claude/skills/apex/p1.md`
    - taskCreate below tasks **p1.1** to **p1.6**
- **p1.1** Implement task(s) (actual task addressing the `<prompt>`)
  - implement.md | `~/.claude/skills/apex/implement.md`
    - taskCreate for each task to dispatch execution agents (in parallel if possible; use "Blocked by #"; insert before **p1.2**)
  - executor.md | `~/.claude/agents/executor.md` (Sonnet latest)
    - implements assigned task, respects file-health PreToolUse hook
    - on failure or file-split decision: writes trace to `.claude-tmp/apex-active/{session}-traces/p1/executor-{task-id}.md` before returning summary
- **p1.2** Verify (lint/build) + fix | Blocked by #p1.1
  - script `verify-build.sh` runs lint + build
    - exit 0 = clean
    - exit non-zero = errors written to `.claude-tmp/apex-active/{session}-verify-errors.txt`
  - if non-zero exit
    - orchestrator reads errors file
    - executor.md | `~/.claude/agents/executor.md` (reused for fix tasks)
    - spawn subagent per attempt with errors file as input; trace path: `.claude-tmp/apex-active/{session}-traces/{p1|p2}/fix-{attempt-N}.md`
    - attempt counter tracked in `.claude-tmp/apex-active/{session}-fix-attempts.json`
    - cap at 3 attempts, abort + surface to user on failure
- **p1.3** Tail (learn/update/diff) | Blocked by #p1.2
  - script `detect-tail-mode.sh` reads diff stats; emits `economy` or `full`
  - if `economy`: inline diff only -- skip learn + documentation (small change yields no novel pattern + no structural doc impact)
  - if `full`: spawns 2 subagents in parallel (Sonnet latest) + inline diff
    - learn.md | `~/.claude/agents/learn.md`
    - documentation.md | `~/.claude/agents/documentation.md`
  - diff.md | `~/.claude/skills/apex/diff.md` (always inline, both modes)
- **p1.4** Self-reflect | Blocked by #p1.3
  - reflector.md | `~/.claude/agents/reflector.md` (Haiku, silent)
    - parameter = p1
    - inputs: TaskList for the phase, `git diff --stat`, `.claude-tmp/apex-active/{session}.json` (path-only)
    - reads phase-scoped traces directly: `.claude-tmp/apex-active/{session}-traces/entryflow/*.md` + `.claude-tmp/apex-active/{session}-traces/p1/*.md` (foreground; p1.5 cleanup blocked by #p1.4 so no race)
    - emits structured append (no prose) to `~/.claude/tmp/apex-workflow-improvements.md`:

      ## {session} - p1 - {timestamp}
      - gaps: <one-line per gap, max 3>
      - fixes-applied: <one-line per autonomous fix, max 3>
      - improvements: <one-line per suggestion, max 3>

    - errors logged to `~/.claude/tmp/reflector-errors.log` (silent failure otherwise)
    - shuts down silently (no main-session output)

- **p1.5** Clean-up session | Blocked by #p1.4
  - script
  - run `cleanup-session.sh` (`.claude-tmp/scout/*-{session}.*`, `.claude-tmp/apex-active/{session}-*-scope.json`, `.claude-tmp/apex-active/{session}-traces/`, `.claude-tmp/apex-active/{session}.json`)
- **p1.6** Inline summary | Blocked by #p1.5
  - inline task prompt
    - Original prompt summary
    - Short executive summary

## Path 2 (p2)

Delegation to at least 2 teammates via plan mode. The whole plan survives context clearing.

- **p2.0.1** Enter plan mode
  - planMode (Apex orchestrator enters plan mode)
- **p2.0.2** Embed delegation plan (team size, models, scoped tasks) | Blocked by #p2.0.1
  - planner.md | `~/.claude/skills/apex/planner.md`
    - Apex orchestrator embeds the high-level instructions in the plan: size a team, split scoped tasks to teammates (plan modifications are done inline before any execution; modification = agent updates plan)
    - first instruction: call p2.md | `~/.claude/skills/apex/p2.md` (start by creating Path 2 tasks via TaskCreate)
    - `{session}` token
    - team size + per-teammate model
    - per-teammate scoped task description + allowed-files list
- **p2.0.3** Exit plan mode (context clears, plan survives) | Blocked by #p2.0.2
  - exitPlanMode (user then presses enter, which clears context and starts the plan; context is cleared, that's why we embed the plan in plan mode, so it survives context clearing)

- **p2.0** Initialisation
  - p2.md | `~/.claude/skills/apex/p2.md`
    - taskCreate below tasks **p2.1** to **p2.7**
- **p2.1** Setup teammates
  - teammates.md | `~/.claude/skills/apex/teammates.md` (Sonnet latest)
    - Planner decides model (Opus, Sonnet) for each teammate, depending on the task difficulty
    - Each teammate inits = create all Path 1 tasks for the given task, no entry-flow steps at all
    - {teammate-id}
      - first task: call p1.md | `~/.claude/skills/apex/p1.md`
      - each teammate is given other active teammates ids with a 1 line summary for each one of them (what they do), so teammates can talk to each other
      - Each teammate gets an allowed-files list written to `.claude-tmp/apex-active/{session}-{teammate-id}-scope.json`; the scope-check hook reads it and blocks writes outside that list
      - executor trace path: `.claude-tmp/apex-active/{session}-traces/p2/executor-{teammate-id}-{task-id}.md` (teammate-id disambiguates parallel teammates)
      - teammates can talk to the main orchestrator
  - Monitor and coordinate teammates until done
- **p2.2** Shut down teammates | Blocked by #p2.1
- **p2.3** Verify (lint/build) + fix | Blocked by #p2.2
  - script `verify-build.sh` runs lint + build
    - exit 0 = clean
    - exit non-zero = errors written to `.claude-tmp/apex-active/{session}-verify-errors.txt`
  - if non-zero exit
    - orchestrator reads errors file
    - executor.md | `~/.claude/agents/executor.md` (reused for fix tasks)
    - spawn subagent per attempt with errors file as input; trace path: `.claude-tmp/apex-active/{session}-traces/{p1|p2}/fix-{attempt-N}.md`
    - attempt counter tracked in `.claude-tmp/apex-active/{session}-fix-attempts.json`
    - cap at 3 attempts, abort + surface to user on failure
- **p2.4** Tail (learn/update/diff) | Blocked by #p2.3
  - script `detect-tail-mode.sh` reads diff stats; emits `economy` or `full`
  - if `economy`: inline diff only -- skip learn + documentation (small change yields no novel pattern + no structural doc impact)
  - if `full`: spawns 2 subagents in parallel (Sonnet latest) + inline diff
    - learn.md | `~/.claude/agents/learn.md`
    - documentation.md | `~/.claude/agents/documentation.md`
  - diff.md | `~/.claude/skills/apex/diff.md` (always inline, both modes)
- **p2.5** Self-reflect | Blocked by #p2.4
  - reflector.md | `~/.claude/agents/reflector.md` (Haiku, silent)
    - parameter = p2
    - inputs: TaskList for the phase, `git diff --stat`, `.claude-tmp/apex-active/{session}.json` (path-only)
    - reads phase-scoped traces directly: `.claude-tmp/apex-active/{session}-traces/p2/*.md` (foreground; p2.6 cleanup blocked by #p2.5 so no race)
    - emits structured append (no prose) to `~/.claude/tmp/apex-workflow-improvements.md`:

      ## {session} - p2 - {timestamp}
      - gaps: <one-line per gap, max 3>
      - fixes-applied: <one-line per autonomous fix, max 3>
      - improvements: <one-line per suggestion, max 3>

    - errors logged to `~/.claude/tmp/reflector-errors.log` (silent failure otherwise)
    - shuts down silently (no main-session output)

- **p2.6** Clean-up session | Blocked by #p2.5
  - script
  - run `cleanup-session.sh` (`.claude-tmp/scout/*-{session}.*`, `.claude-tmp/apex-active/{session}-*-scope.json`, `.claude-tmp/apex-active/{session}-traces/`, `.claude-tmp/apex-active/{session}.json`)
- **p2.7** Inline summary | Blocked by #p2.6
  - inline task prompt
    - Original prompt summary
    - Short executive summary
