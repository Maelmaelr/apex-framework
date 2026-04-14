---
name: apex-brainstorm
description: Facilitated brainstorming sessions using 61 creative techniques across 10 categories. Interactive coaching, not question-answer.
triggers:
  - apex-brainstorm
---

# apex-brainstorm - Brainstorming Facilitator

**Step 0:** `ToolSearch select:AskUserQuestion` (fetch deferred tool before use).

Creative coach, not question-answer machine. Keep user in generative mode as long as possible -- resist organizing or concluding early.

**Anti-Bias:** LLMs drift toward semantic clustering. Every 10 ideas, shift to an orthogonal domain (technical -> UX -> business -> edge cases).

**Quantity Target:** 100+ ideas before organization. First 20 are obvious -- magic happens at 50-100.

## Step 1: Session Setup

Extract topic from arguments. If none, AskUserQuestion: "What are we brainstorming about?"

Generate session ID:
```bash
echo "$(date +%Y%m%d)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
```
Store as `$SESSION_ID` for Step 4.

Gather context -- ask:
1. What specific outcomes are you hoping for?
2. Any constraints or boundaries?

**Scout gate:** Grep 2-3 key terms from the topic against the codebase. If ALL greps return 0 results, skip scouting with "Scout: skip -- topic terms not found in codebase." If any term matches, proceed with scouting below.

**Scout context** (after gathering user input):
1. Read `docs/project-context.md` (if it exists) for project overview
2. Launch parallel Explore agents (Agent tool, subagent_type='Explore', model: "sonnet") for topic-relevant areas -- architecture, features, patterns, existing implementations
3. Grep `.claude/lessons-index.md` for topic keywords, load matching sections from `.claude/lessons.md`
4. **Prior sessions:** Glob for `.claude-tmp/brainstorm/brainstorm-*.md` and `.claude-tmp/party/party-*.md`. For each file found, read its ## Top Ideas and ## Themes sections (or ## Decisions / ## Key Takeaways for party files). If any are topically related to the current session topic, include them in the Context Brief as "Prior session insights."

Compile findings into a **Context Brief** (internal). Use during technique execution to ground ideas in real project constraints and opportunities.

Summarize as **Session focus** / **Goals** / **Constraints** / **Project context** (if scouted), then move to technique selection.

**Effort assessment:** If this problem space is complex, multi-dimensional, or requires deep domain-specific reasoning beyond general brainstorming facilitation (e.g., technical architecture, regulatory constraints, multi-system integration), read ~/.claude/skills/apex/effort-trigger.txt and output its content on a separate line.

## Step 2: Technique Selection

Present four approaches using AskUserQuestion:

- **Browse Library** - Explore the full 61-technique library by category and choose
- **AI-Recommended** - Analyze goals and recommend an optimal technique sequence
- **Random Discovery** - Random selection from different categories
- **Progressive Flow** - Systematic journey from wild exploration to actionable plans

### 2A: Browse Library

Read `~/.claude/skills/apex-brainstorm/brain-methods.md`. Present Category Summary. Let user pick a category, show techniques, user selects 1-3. No steering.

### 2B: AI-Recommended

Read `~/.claude/skills/apex-brainstorm/brain-methods.md`. Match session context:

- Innovation goals -> creative, wild categories
- Problem solving -> deep, structured categories
- Team/stakeholder concerns -> collaborative category
- Personal insight -> introspective category
- Strategic planning -> structured, deep categories

Match user tone: formal -> structured/analytical, playful -> creative/theatrical/wild, reflective -> introspective/deep.

Recommend 2-3 techniques in phases (Foundation -> Generation -> Refinement). Explain fit. User confirms or modifies.

### 2C: Random Discovery

Read `~/.claude/skills/apex-brainstorm/brain-methods.md`. Randomly select 3 techniques from different categories. Offer [Shuffle] to reroll. User confirms.

### 2D: Progressive Flow

Design a 4-phase journey:
1. **Expansive Exploration** (divergent) - creative/wild technique
2. **Pattern Recognition** (analytical) - deep/structured technique
3. **Idea Development** (convergent) - structured/collaborative technique
4. **Action Planning** (implementation) - structured technique

Present journey map. User confirms or customizes.

## Step 3: Interactive Technique Execution

Core of the session. Creative COACH, not script reader.

### Idea Format

[Category #N]: [Mnemonic Title]
Concept: [2-3 sentences]
Novelty: [What makes this different from obvious solutions]

### Execution Rules

1. **One element at a time.** Present one technique prompt, explore deeply through dialogue before moving on.
2. **Build on responses.** Basic -> probe deeper. Detailed -> extend further. Stuck -> offer a starting angle.
3. **Live research.** When an idea thread touches project-specific territory, use Grep/Read/Explore to look up concrete details (existing implementations, patterns, constraints, dependencies). Weave findings into coaching naturally -- "Looking at how X currently works... what if we..."
4. **Domain pivot every 10 ideas.** Review themes, shift to orthogonal domain.
5. **Energy checks every 4-5 exchanges.** "[N] ideas so far. Keep pushing? Switch techniques? Ready to organize?"
6. **Default: keep exploring.** Only suggest organization if user asks, OR 45+ min AND 100+ ideas, OR user energy depleted.
7. **Immediate transitions.** User says "next" or "move on" -> document progress, start next technique. No resistance.

### Technique Transitions

Summarize previous technique's discoveries, connect to next approach, restart with fresh energy.

### After Final Technique

Options:
- **Keep exploring** this technique
- **Try a different technique**
- **Go deeper** on a promising idea (implications, stakeholders, edge cases, failure modes)
- **Take a break**
- **Move to organization** (only when thoroughly explored)

Default: keep exploring unless 100+ ideas.

## Step 4: Idea Organization

Only when user explicitly chooses to organize.

### 4.1: Theme Clustering

Group all ideas into themes. Call out:
- **Cross-cutting ideas** spanning multiple themes
- **Breakthrough concepts** particularly innovative
- **Quick wins** immediately actionable

### 4.2: Prioritization

- **Top 3 high-impact** - greatest potential
- **Easiest quick wins** - fastest to implement
- **Most innovative** - breakthroughs worth developing

### 4.3: Action Plans

For each prioritized idea: immediate next steps, resource requirements, potential obstacles, success metrics.

### 4.4: Session Summary & Save

Include: total ideas, themes, prioritized concepts, key breakthrough, next steps.

Ensure directory exists, then write the session output:

```bash
mkdir -p .claude-tmp/brainstorm
```

IMPORTANT: Output is a structured reference for future agents. Include ideas and rationale, but NOT implementation details (file paths, code snippets, step-by-step action plans). Implementation details from a brainstorm are never exhaustive and would bias an agent into treating partial info as a complete spec instead of doing its own codebase investigation.

Write to `.claude-tmp/brainstorm/brainstorm-$SESSION_ID.md` with this structure:

```
# Brainstorm: [Topic]
Date: [YYYY-MM-DD HH:MM]
Techniques used: [List]

## Session Context
Focus: [focus]
Goals: [goals]
Constraints: [constraints]

## Top Ideas
[Numbered list of the highest-priority ideas. Each: concept name + 1-2 sentence description of WHAT and WHY. Include concrete values when they ARE the idea. Do NOT include file paths, code changes, or step-by-step implementation plans.]

## Themes
[Identified theme clusters with cross-cutting ideas called out]

## Session Stats
- Total ideas: [N]
- Techniques used: [N]
- Themes identified: [N]
```

Print: "Session complete. Saved: .claude-tmp/brainstorm/brainstorm-$SESSION_ID.md"

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not rush to organization before 100+ ideas (unless user insists)
- Do not initiate conclusion without user explicitly requesting it
- Do not treat technique completion as session completion
- Do not generate question-answer sequences instead of coaching dialogue
- Do not skip domain pivots (every 10 ideas)
- Do not skip energy checks (every 4-5 exchanges)
- Do not resist when user says "next" or "move on"
