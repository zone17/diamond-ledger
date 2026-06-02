<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan:
specs/001-voice-scorebook-core/plan.md
<!-- SPECKIT END -->

# Diamond Ledger — agent-native capability system

**Start here.** The binding authority for all work in this repo is the engineering constitution at
[`.specify/memory/constitution.md`](.specify/memory/constitution.md). Read it before any non-trivial
work — it governs architecture, agent behavior, security, testing, evaluation, documentation, branch
discipline, CI/CD, and the definition of done. It is the source of truth; this file is just the map.

This is an **agent-native capability system**: the product is a graph of small, permissioned,
discoverable tool/API primitives where humans and agents are equal first-class users — not a UI-first
app with AI attached.

## Methodology

Work follows **Spec Kit** (spec-driven development) inside a **Compound Engineering** loop —
Brainstorm → Plan → Work → Review → Compound, roughly 80% planning/verification/review and 20% code.
Non-trivial work flows through explicit, versioned artifacts rather than ad-hoc prompting:

**constitution → spec → plan → tasks → implement**, each a Spec Kit command:

- `/speckit.constitution` — create or amend the constitution
- `/speckit.specify` — feature spec (what & why) → `specs/<feature>/spec.md`
- `/speckit.plan` — technical design & approach → `plan.md`
- `/speckit.tasks` — dependency-ordered executable tasks → `tasks.md`
- `/speckit.implement` — execute the tasks

Branch discipline (Article XVIII): **never commit or push to `main`** — use
`{type}/{squad}/{ticket}-{slug}` branches and land via PR. After any push/PR/merge, run `/watch-ci`.
First clone? run `git config core.hooksPath .githooks` (ADR-0004). Full workflow in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Project map

- `.specify/memory/constitution.md` — the binding constitution (40 articles, enforcement matrix,
  definition of done). Highest authority; governs all work.
- `.specify/templates/` — Spec Kit templates (spec, plan, tasks, checklist, constitution).
- `.specify/scripts/` — workflow scripts the speckit commands call.
- `.specify/workflows/`, `.specify/extensions/` — Spec Kit workflow registry + git extension.
- `docs/PROJECT_CONTEXT.md` — fast-orientation single source: current status, intended architecture,
  decisions index, critical invariants, learnings/anti-pattern index. Load this first to get current.
- `DECISIONS.md` — architectural decision records (ADRs). Updated for every architectural change
  (Article XXXVIII).
- `CONTRIBUTING.md` — workflow, branch discipline, CI, compound-loop gate, one-time hook setup.
- `docs/solutions/` — documented solutions to past problems (bugs, best practices, conventions,
  workflow patterns), organized by category with YAML frontmatter (`module`, `tags`, `problem_type`).
  Relevant when implementing or debugging in documented areas.
- `.claude/settings.json`, `.claude/hooks/` — project hooks (the merge-triggered compound-loop gate).
