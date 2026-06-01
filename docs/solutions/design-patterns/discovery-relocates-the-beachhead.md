---
title: "Discovery's job is to relocate the beachhead, not validate the idea"
date: 2026-06-01
category: design-patterns
module: product-discovery
problem_type: design_pattern
component: development_workflow
severity: high
applies_when:
  - "Running a PR/FAQ or product idea through the-pipeline (product-idea then discovery)"
  - "The lead customer segment is emotionally compelling or the founder's origin story"
  - "Asked to \"run the experiments\" or \"deploy\" in a planning-stage repo with no real users or deploy target"
  - "Opportunity scoring (ODI) or willingness-to-pay data conflicts with the chosen beachhead"
related_components:
  - documentation
tags:
  - product-discovery
  - beachhead-selection
  - opportunity-scoring
  - willingness-to-pay
  - experiment-design
  - evidence-over-fabrication
  - the-pipeline
  - tam-correction
---

# Discovery's job is to relocate the beachhead, not validate the idea

## Context

Agent-run product discovery has two systematic failure modes that pull in opposite directions
but share a root: the agent optimizes for a satisfying narrative instead of a true one.

1. **Confirmation drift.** A PR/FAQ is a persuasion artifact — it is *built* to be compelling, and
   it usually leads with the most emotionally resonant, highest-volume, founder-flattering
   customer. An agent asked to "validate" that idea tends to gather evidence *for* the beachhead it
   was handed, mistaking a vivid story for a winnable bet.
2. **Fabrication under action verbs.** When the user says "run the experiments" or "deploy it," an
   agent feels pressure to produce a result — and with no real customers and no deploy target, the
   path of least resistance is to *manufacture* one: invent interview quotes, report a conversion
   number, or claim a deployment that never happened.

Both failures defeat the entire purpose of discovery, which exists to *remove* false confidence
before the build, not to add it. (Surfaced while running the Diamond Ledger PR/FAQ through
`the-pipeline:product-idea` → `the-pipeline:discovery`.)

## Guidance

### 1. Run discovery to *falsify* the beachhead, not confirm the idea

Treat the PR/FAQ's lead customer as the primary hypothesis to attack.

- **Separate fact from inference.** Tag every research claim as FACT (cited/observed) or INFERENCE
  (reasoned), each with a confidence rating. Never let an inference inherit a fact's authority.
- **Test the beachhead against two killers:** *willingness-to-pay* (does this segment actually
  pay?) and *incumbent moat* (does a dominant free/distributed player already own them?). The most
  emotionally compelling segment is frequently the *worst* launch beachhead on both axes.
- **Score opportunities with ODI, deliberately excluding effort/feasibility** so attractiveness
  isn't laundered by how easy something is to build:

  ```
  Opportunity = Importance + max(Importance − Satisfaction, 0)
  # rate Importance & Satisfaction 1–10; score ≥ 15 → highly attractive AND under-served
  ```

- **Generate competing solutions (compare-and-contrast), not whether-or-not.** A single proposal
  invites rationalization; a slate forces a real choice.
- **Output a verdict with teeth** — PROCEED / REFINE / PIVOT / KILL. When REFINE, *move the
  go-to-market beachhead* onto the under-served-but-paying segment, and keep the emotional/origin
  customer as expansion TAM and founder narrative — not the launch customer.

### 2. When you can't truly run or ship, build the runnable artifact and surface the honest gap

"Run the experiments" with zero real customers does **not** mean *invent* results; it means hand
back a *pre-registered experiment kit*:

- A **real** smoke-test landing page (actual HTML), a Mom-Test interview guide (ask about past
  behavior, not hypothetical enthusiasm), and **XYZ hypotheses**: *"At least X% of [Y] will [Z]"* —
  falsifiable, with a number.
- **Pass/fail thresholds locked *before* running**, plus an explicit no-fabrication guard:

  ```
  Hypothesis: ≥8% of targeted visitors give a commitment signal (paid deposit / LOI / intro).
  PASS ≥ 8%   FAIL < 8%   (threshold locked 2026-06-01, before any traffic)
  Results: — none yet; do not populate without real data —
  ```

- For **"deploy"**: if there is no application and no deploy job in CI, say so. Name what real
  deployment would require (e.g., live Stripe + analytics + form wiring) and clarify that
  *launching the smoke test is itself the experiment*.

This is the constitution applied: **Article VI** (AI output is a draft until verified; agents
propose, evidence verifies) and **Article XXXV** (never make production the first place a risky
assumption is tested).

## Why This Matters

A beautiful PR/FAQ aimed at the wrong beachhead is the most expensive kind of mistake: it passes
review, energizes the team, and funds a full build — all pointed at a segment that won't pay and is
already owned by an incumbent. Discovery's whole job is to catch that *before* the build cost is
sunk. And fabricated evidence is worse than no evidence: a fake "PASS" manufactures exactly the
false confidence the discovery process exists to destroy, and it compounds — every downstream
decision inherits a lie. Honesty about a gap is a finding; a fabricated result is a landmine.

## When to Apply

- Any **product-idea → discovery** handoff (a PR/FAQ, working-backwards doc, or vision doc arrives
  to be validated/pressure-tested).
- Any request to **"validate," "de-risk," "find the riskiest assumptions," or "map the
  opportunity."**
- Any **"run the experiments" / "deploy it" / "ship it"** request issued at the *planning* stage,
  before a real application, real users, or a real deploy target exist.
- Generally, whenever an action verb ("run," "ship," "launch," "test") tempts a
  concrete-but-fictional output — pause and ask whether the real-world precondition exists.

## Examples

**Beachhead falsification (before → after).**

- **Before (PR/FAQ):** beachhead = the tee-ball parent — highest emotional pull, highest volume,
  and the founder's own origin story.
- **Discovery findings:** that segment is *lowest* willingness-to-pay and is owned by the
  incumbent's moat — GameChanger (~$100M 2024 revenue, ≈ the entire monetized US market) with a
  free tier plus retail distribution. ODI scoring surfaced the real openings: **accuracy/
  officialness = 15** and **Retrosheet portability = 14** — both owned by an *under-served segment
  that already pays* (serious/official scorekeepers, iScore users, SABR/Retrosheet archivists).
  Discovery also corrected TAM down (global $300–500M → ~$200–250M) and named a rival the PR/FAQ
  had missed (Pocket Blue).
- **After (verdict REFINE):** launch beachhead moves to the serious/official scorekeeper; the
  tee-ball parent is retained as expansion TAM and founder narrative, not the launch customer.

**"Deploy this" (the honest-gap exchange).**

- **Request:** "go ahead merge and deploy."
- **Wrong move:** claim a deployment / paste a fake URL.
- **Right move:** "There's no deploy target — no application exists and CI has no deploy job. The
  experiment *is* the smoke-test landing page; deploying it for real means wiring live Stripe,
  analytics, and the email form. Here's the pre-registered experiment kit (landing-page HTML,
  interview guide, XYZ hypotheses, locked thresholds, results tracker with a no-fabrication guard).
  Results are intentionally empty until real traffic exists."

## Related

- `.specify/memory/constitution.md` — binding authority; **Article VI** (agents propose, evidence
  verifies) and **Article XXXV** (don't test risky assumptions in production first) ground the
  no-fabrication discipline.
- `the-pipeline:product-idea` and `the-pipeline:discovery` skills — the methodology this pattern
  runs on (PR/FAQ → research synthesis → opportunity map → assumption tests → brief).
- `docs/product/discovery/` and `docs/product/experiments/` — the worked artifacts this learning
  was extracted from (the Diamond Ledger discovery + experiment kit).
- `docs/solutions/workflow-issues/watch-ci-gate-choreography.md` — light see-also; the same session
  re-encountered the watch-ci gate (armed on a feature-branch push with no CI run; cleared with
  `gh run list`).
