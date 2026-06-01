---
title: Spec-coherence probe — throwaway agent build to break a spec before production code
date: 2026-06-01
category: design-patterns
module: spec-kit / specs
problem_type: design_pattern
component: development_workflow
severity: high
applies_when:
  - A spec is written and you are about to plan or build from it
  - A spec asserts an invariant or a measurement gate (e.g. "never X", "0 of Y")
  - You want to validate a spec cheaply before committing engineering to it
tags: [spec-driven-development, verification, adversarial-testing, agentic-engineering, eval-gates, classification]
---

# Spec-coherence probe — throwaway agent build to break a spec before production code

## Context

We had a clarified, checklist-passing feature spec (`specs/001-voice-scorebook-core/spec.md`) and were
about to plan and build from it. Instead of trusting the spec, we ran a **spec-coherence probe**: an
agent built a *throwaway* implementation of the spec's hard core (a deterministic baseball-scoring
engine, text input only) for the sole purpose of testing whether the spec was buildable *as written*,
then adversarially attacked the result. The build is disposable; the **gap list is the artifact**.

It paid for itself immediately — it **broke the spec's cardinal invariant** ("never silently
auto-resolve a scorer-judgment call") before a single line of production code existed. Full evidence:
`specs/001-voice-scorebook-core/probe-report.md` (workflow `wf_c29a9bd1-07b`).

## Guidance

Before planning/building from a non-trivial spec, point an agent at the spec's **hard core** and have
it (a) attempt a throwaway tracer-bullet build, then (b) adversarially try to break the spec's stated
invariants. Define the probe as a harness up front — *Outcome · Verification surface · Constraints ·
Iteration policy · Blocked stop condition* — so it produces a tractability verdict + a spec-line-cited
gap list, not a finished engine. Fold every gap back into the spec.

Two **generalizable defects** this probe surfaced are worth checking for in any spec:

1. **Derive policy from FACTS, never from a caller-supplied LABEL.** The spec said "classify each play
   as deterministic (~85%) or judgment (~15%)" but never said *how*. The builder defaulted to
   classifying on the caller's `play.type` string — so a misplayed grounder *labeled* `"single"` was
   silently scored as a clean hit. **5/5 adversarial probes silently resolved a judgment call.** Any
   spec that classifies, routes, or gates on an input the caller controls is exploitable; require the
   decision to be derived from the underlying facts.

2. **An un-instrumented gate passes vacuously — wire an adversarial corpus that actually trips it.**
   The spec's "0 silently auto-resolved" success criterion was implemented as a counter that was
   initialized and read but **never incremented anywhere** — it passed mathematically pinned to 0. A
   measurement gate is theater unless a known-bad input makes it fail. Every invariant gate needs a
   corpus of cases that *should* trip it, wired as a hard-fail.

## Why This Matters

Feasibility and desirability/viability get tested elsewhere; **spec coherence usually doesn't get
tested at all** until the build reveals it expensively. A spec can pass human review and a quality
checklist while still encoding an unenforceable invariant — the most dangerous kind, because everyone
believes it holds. Catching it with a disposable build (minutes/cheap agent time) instead of in
production (months + a shipped trust-breaking bug) is the entire ROI. This is the concrete form of the
2026 "send the spec to an agent to see if we can build it" step: the value is the *break*, not the
build.

## When to Apply

- After `/speckit.clarify`, before `/speckit.plan`, on any spec with a load-bearing invariant.
- Whenever a spec asserts a "never happens" rule or a "0 / 100%" measurement gate.
- Text/structured inputs only for the probe — keep gated or expensive subsystems (e.g. ASR, external
  services) out so the probe stays cheap and aimed at coherence, not feasibility.

## Examples

Spec before (label-derived, unenforceable):

> FR-006: classify each play as deterministic (~85%) or scorer-judgment (~15%).

Spec after (fact-derived + instrumented gate), folded back from the probe:

> FR-006: classify **from the normalized play facts**, never from a caller-supplied type/label.
> FR-006a: validate the classifier with a **mislabeled-judgment adversarial corpus**; any corpus play
> resolved without a judgment is a hard eval-gate failure.
> SC-003: enforced by an **instrumented silent-resolution counter** + the corpus wired as a hard-fail.

## Related

- `specs/001-voice-scorebook-core/probe-report.md` — the full probe verdict (BUILDABLE_WITH_GAPS).
- `docs/solutions/conventions/speckit-branch-naming-and-merge-gotchas.md` — process gotchas hit while
  shipping the probe + spec via PR.
