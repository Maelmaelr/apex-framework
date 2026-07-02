export const meta = {
  name: 'admin-apex-semantic-drift',
  description: 'admin-apex audit task 3 (A3): per-unit semantic-drift detection - spec prose that \
contradicts a script flag/behavior, cross-doc contradiction, or SKILL.md behavior absent from its \
scripts. One Explore agent per skill unit, as a barrier fan-out.',
  phases: [
    { title: 'Drift', detail: 'one Explore agent per skill unit reads its SKILL.md + scripts and \
judges spec-vs-code contradiction' },
  ],
}

// Workflow-tool adoption, audit-track A3 (tmp/plans/workflow-adoption-plan.md).
// The Phase 1 audit-half drop established that the STRUCTURAL detectors are
// deterministic grep/JSON (now scriptified in audit-detectors.py), so wrapping
// them in agents is pure overhead. A3 is the opposite: the one detector class
// greps cannot reach - SEMANTIC drift - where per-unit work is genuine LLM
// judgment (read a SKILL.md + its scripts, decide whether the prose still
// matches the behavior). That is a legitimate parallel() fan-out: each unit is
// independent and slow-per-unit. This is the designated runtime proof of Open
// risk 1 (skill-instructs-Workflow opt-in when apex, not a human, is the caller):
// unlike the deterministic lessons-freshness check, this fan-out's per-unit work
// is non-deterministic, so the orchestrator cannot correctly inline it.
//
// Invoked by audit.md task 3 ONLY when: SKILL task 1's semantic-drift toggle ==
// run (opt-in; offered only after an audit+apply mode select, default skip - the
// expensive fan-out is off on a normal session; never audit-only, never a silent
// cron path - Open risk 4), AND the Workflow tool is reachable.
// The serial fallback (audit.md: dispatch the same per-unit Explore agents in a
// single response) produces identical findings when Workflow is absent
// (headless/cron). Agents reuse agentType 'Explore' (read-only search, no Edit)
// and inherit the orchestrator CWD (= ~/.claude,
// the framework root; admin-apex cd's there at task 1), so the repo-relative
// `files` paths resolve with no path plumbing (Phase 0 spike finding).
//
// Open risk 4 (semantic-drift false positives) mitigations, enforced here:
//   - every finding MUST cite spec_ref (file:line) AND code_ref (file:line);
//   - confidence is high|low; the orchestrator routes high -> candidate apply
//     (semantic-drift cluster items) and low -> defer (logged, never auto-applied).
//
// Inputs via `args` (built by audit.md before the call):
//   args = {
//     units: [ { name: string, files: string[] } ],  // repo-relative paths from ~/.claude
//     maxFleet?: number                               // optional fan-out cap (default 16)
//   }
// Returns:
//   { findings: [ { unit, summary, spec_ref, code_ref, confidence } ],
//     unitsChecked: number, dropped: [<unit name>] }
// The orchestrator partitions `findings` by confidence: high -> semantic-drift
// cluster items, low -> deferred note. `dropped` = fleet-cap overflow units the
// orchestrator must check serially (no silent truncation).

const FINDING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'spec_ref', 'code_ref', 'confidence'],
  properties: {
    summary: { type: 'string' },
    spec_ref: { type: 'string', description: 'file:line + quoted spec text' },
    code_ref: { type: 'string', description: 'file:line + quoted code/behavior' },
    confidence: { enum: ['high', 'low'] },
  },
}

const AGENT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: { type: 'array', items: FINDING_SCHEMA },
  },
}

const ASCII = 'ASCII only. No tables, no diagrams. Your final message IS the structured return ' +
  'value, not a human-facing report.'

// The Workflow runtime delivers `args` as a JSON STRING (verified by probe, run
// 248bdf47), not the object the tool's "verbatim" contract implies; a caller that
// reads `args.units` directly off the string gets undefined and silently no-ops
// (units=0, the recurring fall-back-to-serial defect). Normalize defensively so
// both string and object delivery resolve identically.
const A = (typeof args === 'string') ? JSON.parse(args) : (args || {})
const units = Array.isArray(A.units) ? A.units : []
const MAX_FLEET = (Number.isInteger(A.maxFleet) && A.maxFleet > 0) ? A.maxFleet : 16

if (units.length === 0) {
  log('semantic-drift: no units supplied; nothing to check')
  return { findings: [], unitsChecked: 0, dropped: [] }
}

// Fleet cap: a bounded fan-out. Process the first MAX_FLEET units; surface the
// rest by name so the orchestrator checks the deferred tail serially.
let active = units
let dropped = []
if (units.length > MAX_FLEET) {
  active = units.slice(0, MAX_FLEET)
  dropped = units.slice(MAX_FLEET).map((u) => u.name)
  log(`semantic-drift: ${units.length} units > cap ${MAX_FLEET}; deferring ${dropped.length} ` +
    `to serial tail: ${dropped.join(', ')}`)
}

function driftPrompt(unit) {
  const fileList = (unit.files || []).map((f) => `  - ${f}`).join('\n')
  return [
    `Audit the apex framework unit "${unit.name}" for SEMANTIC drift - the contradictions greps cannot catch.`,
    'CWD is the framework root (~/.claude). Read every file below in full before judging:',
    fileList,
    '',
    'Flag ONLY these three classes of genuine contradiction:',
    '  1. Spec prose that contradicts a script\'s actual flags/behavior (e.g. doc says --foo but ' +
      'the script has no such flag, or describes an exit code the script never returns).',
    '  2. Cross-doc contradiction (two docs describing the same thing differently).',
    '  3. Behavior a SKILL.md / doc claims to invoke that is ABSENT from the scripts it names.',
    '',
    'Do NOT flag: style, naming, TODO/FIXME markers, aspirational or future-tense prose, ' +
      'line-count, or anything a path/symbol grep already catches (orphan refs, dead hooks, ' +
      'schema-id mismatch). A clean unit returns findings: [].',
    'Every finding MUST cite spec_ref = "<file>:<line> \'<quoted spec text>\'" AND code_ref = ' +
      '"<file>:<line> \'<quoted code/behavior>\'". confidence = "high" ONLY when both refs are ' +
      'concrete and the contradiction is unambiguous; otherwise "low".',
    ASCII,
    '',
    'Return { findings: [ { summary, spec_ref, code_ref, confidence } ] }.',
  ].join('\n')
}

// Barrier fan-out: all units judged concurrently, results collected together so
// the orchestrator builds one semantic-drift cluster. A thunk that throws (agent
// error) resolves to null and is filtered - failing to check a unit is
// conservative (no false drift emitted), and the unit name is NOT silently
// dropped from `unitsChecked` accounting below.
const perUnit = await parallel(
  active.map((unit) => () =>
    agent(driftPrompt(unit), {
      label: `drift:${unit.name}`,
      phase: 'Drift',
      agentType: 'Explore',
      model: 'sonnet',
      schema: AGENT_SCHEMA,
    }).then((r) => ({ name: unit.name, findings: (r && r.findings) || [] }))
  )
)

const checked = perUnit.filter(Boolean)
const findings = checked.flatMap((u) =>
  u.findings.map((f) => ({ unit: u.name, ...f }))
)
const highN = findings.filter((f) => f.confidence === 'high').length

log(
  `semantic-drift: ${checked.length}/${active.length} units checked; ` +
    `${findings.length} findings (${highN} high-confidence)` +
    (dropped.length ? `; ${dropped.length} deferred to serial tail` : '')
)

return { findings, unitsChecked: checked.length, dropped }
