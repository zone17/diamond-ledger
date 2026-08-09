# Idea → Delivery Pipeline — Quick Reference

This repo was created from `zone17/project-template`. It carries the full pipeline configuration: run `specify workflow run idea-to-delivery --json` and work the gates. Machine layer (skills + hooks in `~/.claude/`) applies globally — nothing to install per-project. Full reference: the Pipeline v2.2 doc; implementation contract: the Pipeline Build Spec (Units 0–11).

## Phase A — Foundation (once per project)

| # | Step | Command | Gate |
|---|------|---------|------|
| 1 | Bootstrap | `/pipeline-init` (already done if you're reading this) | — |
| 2 | PR/FAQ — the bet | `/the-pipeline:product-idea` | — |
| 3 | Discovery — validate the bet | `/the-pipeline:discovery` | ▓ pre-registered falsification gates required |
| 4 | Design foundation | `/design-foundation` | — |
| 5 | Constitution — binding law | `/constitution-from-prfaq` → `/speckit.constitution` | ▓ human ratification |
| 5b | Feature backlog — derive `docs/roadmap.md` | `/feature-backlog` | ▓ human ranks + approves the order |

The backlog closes the "I want X" authoring gap: the PR/FAQ, discovery brief, and constitution
already contain every feature implicitly, so `/feature-backlog` derives ordered,
feature-design-ready briefs (riskiest-assumption-first) plus a promised-but-unplanned ledger and
an explicit v1 line. The human **reorders `docs/roadmap.md`** to rank — that file's order is the
ranking act. `gate-start-feature` then presents the topmost unfinished v1 item
(`tools/pipeline-status.sh --next-feature`) instead of asking for a hand-typed brief, and the
status board shows the roadmap burn-down (`backlog` section of `docs/pipeline-status.json`).

## Phase B — Definition (per feature)

| # | Step | Command | Gate |
|---|------|---------|------|
| 6 | Feature design | `/feature-design` (brief fed verbatim from the approved roadmap item) | prototype approval |
| 7 | Specify (EARS ACs) | `/speckit.specify` | — |
| 8 | Clarify | `/speckit.clarify` | — |
| 9 | Design sign-off | `speckit.wireframe.generate` → `review` | ▓ signs `## UI Mockup` into spec.md |
| 10 | Plan | `/speckit.plan` | — |
| 11 | Checklists | `/speckit.checklist` UX · Security · A11y | — |
| 12 | Tasks | `/speckit.tasks` (→ `taskstoissues`) | — |
| 13 | Analyze | `/speckit.analyze` | ▓ no open conflicts |

## Phase C — Build & Verify (per feature)

| # | Step | Command | Gate |
|---|------|---------|------|
| 14 | Implement | `ce-plan` → `ce-work` (or `/speckit.implement`) | TDD + supply-chain hooks |
| 15 | Verify | `/verify-acceptance` + `/design-qa` | ▓ report green (both, not either) |
| 16 | Ship | `gh pr merge` → `/watch-ci` | ▓ CE review + CI watch |
| 17 | Converge & compound | `speckit.sync.analyze` · `retrospective.analyze` → `ce-compound` | — |

## What this template carries

- `.specify/workflows/idea-to-delivery.yml` — the chained workflow (v1.2.0), resumable, gates included
- `.specify/templates/spec-template.md` — EARS acceptance criteria mandated, stable `AC-###` IDs
- `.specify/extension-catalogs.yml` — default + community catalogs, install-allowed
- `.github/workflows/` — mutation testing (sacred paths, score ≥60→80), changed-lines coverage (≥80%), promptfoo evals; all path-gated so an empty repo stays green
- `tools/ci/` — sacred-path + model-powered manifests (shared with the machine-layer TDD gate), Stryker config, branch-protection commands (**read `tools/ci/README.md` before requiring checks** — the path-filter/required-check collision is documented there)
- `evals/` — promptfoo scaffold: schema compliance, grounding, tone per DESIGN.md, injection resistance, regression baselines
- `docs/` skeleton — `flows/` (+prototypes), `solutions/`, `verification/` · `todos/` · `DECISIONS.md` stub

## After creating a repo from this template

1. `specify init --here --integration claude` (merges with these files), then `specify check` (exits 0 unconditionally — read its output, don't trust the exit code)
2. `specify extension add <name>` once per extension — sync, reconcile, retrospective, test-coverage-drift-control — then wireframe via its ZIP URL (one extension per invocation; a multi-name call errors)
3. Verify the machine layer is live (`design-foundation`, `feature-design`, `verify-acceptance`, `design-qa` skills; enforcement hooks) — restore from `zone17/claude-config` if missing
4. `specify workflow run idea-to-delivery --json`

Keep this template the single source of truth: improvements to workflows/templates/CI land here, and existing projects pull them deliberately.
