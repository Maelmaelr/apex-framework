---
name: apex-party
description: Multi-persona group discussion. Expert panels debate your topics with distinct voices and perspectives.
triggers:
  - apex-party
---

# apex-party - Multi-Persona Panel Discussion

**Step 0:** `ToolSearch select:AskUserQuestion` (fetch deferred tool before use).

Roleplay as multiple specialists with distinct voices, creating dynamic panel conversations.

## Step 1: Parse Topic

Extract topic from arguments. If none, AskUserQuestion: "What would you like the panel to discuss?"

Generate session ID:
```bash
echo "$(date +%Y%m%d)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
```
Store as `$SESSION_ID` for Step 5.

## Step 2: Scout Context

**Scout gate:** Grep 2-3 key topic terms against codebase. All find no matches: skip with "Scout: skip -- topic terms not found in codebase." Any match: proceed.

- Read `docs/project-context.md` (if exists) for project overview
- Launch parallel Explore agents (Agent tool, subagent_type='Explore', model: "sonnet") for topic-relevant areas (architecture, features, patterns, implementations)
- Grep `.claude/lessons-index.md` for topic keywords, load matching sections from `.claude/lessons.md`
- Glob `.claude-tmp/party/party-*.md` and `.claude-tmp/brainstorm/brainstorm-*.md`, read ## Decisions / ## Key Takeaways (## Top Ideas for brainstorm). Include topically related as "Prior session insights."

Compile into internal **Context Brief** for persona reference. If topic involves technical depth or contentious trade-offs, read ~/.claude/skills/apex/effort-trigger.txt and output its content on a separate line.

## Step 3: Select Panel

From the Persona Roster (loaded in this step), choose 4-6 personas relevant to the topic. If a Context Brief was gathered, factor it into persona selection (e.g., include Architect for infrastructure topics, Developer for implementation topics).

Print:

"Panel: [topic]"
"[Name] ([Title]) - [One-line role summary]"

If topic was provided as argument (not via AskUserQuestion fallback in Step 1):
- Immediately begin the discussion -- have 2-3 relevant personas give their opening takes on the topic. This IS the first round of Step 4's Discussion Loop.

If topic came from AskUserQuestion (Step 1 fallback):
- Print: "What would you like to discuss with the panel?"
- Wait for user input before starting discussion.

## Step 4: Discussion Loop

For each user message:

1. **Analyze** for domain and expertise requirements
2. **Live research** (if needed): When a persona's response would benefit from concrete project data, use Grep/Read/Explore to look up specifics (file paths, patterns, configurations, metrics). Weave findings into the persona's response naturally.
3. **Select** 2-3 most relevant personas to respond
4. **Generate** in-character responses using each persona's voice and principles, grounded in Context Brief and any live research
5. **Enable cross-talk** between personas within the same round

### Response Format

[Name] ([Title]): [In-character response]

### Selection Rules

- If user addresses a persona by name, prioritize them + 1-2 complementary ones
- Rotate participation for diverse perspectives
- Never have all personas respond -- pick 2-3
- **Enforced dissent:** At least one responding persona must explicitly challenge the strongest position or emerging consensus in the round. If all selected personas would naturally agree, add a contrarian perspective: identify unstated assumptions, flag risks, or argue the opposing case. Skip only if the topic is purely factual (no judgment involved).

### Cross-Talk Patterns

- Building: "As [Name] mentioned..."
- Disagreeing: "I see it differently than [Name]..."
- Follow-ups: Personas can ask each other questions within the same round

### Question Protocol

- **Direct questions to user:** End the round. Wait for response.
- **Inter-persona questions:** Resolve within the same round.
- **Rhetorical questions:** Continue without pausing.

### Moderation

- Circular discussion -> have one persona summarize and redirect
- Follow user's energy -- go deeper on topics they engage with

### Round Wrap-up

After persona responses, close each round with a structured wrap-up:

Propositions -- One line per persona who spoke this round: what they proposed or concluded, specific enough to act on without re-reading their full response.

Open questions / Actions -- Concrete items that emerged: unresolved disagreements, decisions needed, suggested next steps. Each with enough context to understand standalone.

Then use AskUserQuestion to present the follow-up. Derive 2-4 options from the propositions and open questions -- each option is a concrete direction to explore next (label: short direction name, description: what exploring it entails). The user can always pick "Other" for free-form input.

## Step 5: Exit

Triggers: "exit", "goodbye", "end", "quit", "done".

2-3 most active personas give brief in-character farewells.

### Save Transcript

Ensure directory exists, then write the discussion transcript:

```bash
mkdir -p .claude-tmp/party
```

IMPORTANT: Output is a structured reference for future agents. Include decisions and rationale, but NOT implementation details (file paths, code snippets, component internals, migration steps). Implementation details from a discussion are never exhaustive and would bias an agent into treating partial info as a complete spec instead of doing its own codebase investigation.

Write to `.claude-tmp/party/party-$SESSION_ID.md` with this structure:

```
# Panel Discussion: [Topic]
Date: [YYYY-MM-DD HH:MM]
Personas: [Names and titles]

## Decisions
[Numbered list. Each decision: what was decided and why (rationale). Include concrete values when they ARE the decision (e.g., "p-3", "rounded-xl"). Do NOT include file paths, code changes, migration steps, or component-level implementation details.]

## Open Questions
[Unresolved disagreements or items needing further exploration. Omit section if none.]

## Key Takeaways
[3-5 bullets: main insights from the discussion]
```

Print: "Panel complete. Saved: .claude-tmp/party/party-$SESSION_ID.md"

## Persona Roster

Read personas from ~/.claude/skills/apex-party/personas.md.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not break character within a persona's response
- Do not have all personas respond to every message (pick 2-3)
- Do not ignore exit triggers
- Do not generate generic responses without persona-specific voice
- Do not create new personas not in the roster
