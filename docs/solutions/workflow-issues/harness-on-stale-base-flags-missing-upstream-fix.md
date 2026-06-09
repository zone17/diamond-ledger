---
title: A regression harness built on a stale branch base flags the missing upstream fix as a new bug
date: 2026-06-09
category: workflow-issues
module: evals/runners (transcript-score) + ios (dl-score)
problem_type: workflow_pattern
component: ci_eval_harness
applies_when:
  - "Building a regression gate / measurement harness for a specific code seam"
  - "Working on a feature branch cut from a local main that may lag origin/main"
  - "The harness's first run produces a surprising failure on a seam another PR recently fixed"
tags: [eval-harness, regression-gate, stale-base, rebase, branch-discipline, baseline, vacuous-gate, dl-37, agent-native-parity, measurement]
---

# A regression harness built on a stale branch base flags the missing upstream fix as a new bug

## Context
DL-37 added a headless `dl-score` CLI + a transcript→score regression gate — the first off-device
coverage of the `GrammarParser → FactBridge → real core` seam. On its **very first run** the harness
reported that every deterministic play rendered the same `6-3` groundout (home run, walk, flyout all
scored as a groundout). That looked like a catastrophic core bug.

It was not a new bug. The branch had been cut from a **local `main` that predated DL-154/#162** — the
PR that fixed `FactBridge` to map all play types. `origin/main` already had the fix; the local base
didn't. Rebasing the branch onto `origin/main` made the harness immediately go green with correct
per-play rendering (HR→HR, walk→BB, K→K, error→Card B).

## Guidance
**Before trusting a new regression gate's first baseline, confirm your branch base includes the
latest fix on the exact seam you're hardening.** A harness measures the code it's built on; if that
code is stale, the harness faithfully reports the *absence of an upstream fix* as if it were a fresh
regression. Two distinct failure modes follow:

1. **Wasted investigation** — you hunt a "bug" that is really a missing merge (what happened here;
   cheap because the rebase was obvious once suspected).
2. **Frozen-wrong baseline (worse)** — if you *capture* the harness's current output as the expected
   baseline while on the stale base, you bless the wrong answer and the gate then actively protects
   the bug against the real fix. The DL-37 corpus was deliberately frozen **after** the rebase, from
   verified-correct output, to avoid exactly this.

```bash
# Cheap pre-flight before cutting/trusting a branch that hardens a seam:
git fetch origin main
git log --oneline HEAD..origin/main        # what am I missing?
git merge-base --is-ancestor origin/main HEAD && echo "base current" || echo "REBASE FIRST"
```

## Why This Matters
A measurement harness is only as trustworthy as the code under it. The same green-CI-≠-correct logic
([[parallel-squad-integration]] §4) runs in reverse here: **red-harness-≠-new-bug.** The first signal
from a new gate must be triaged against "is my base current?" before "is the core broken?" — and a
baseline must never be frozen from a base you haven't confirmed is up to date, or the gate becomes a
vacuous guardian of the wrong answer (the inverse of the instrument-every-path rule in
[[mock-to-real-stateful-core-swap]]).

## The flip side — the harness earned its keep in minutes
The positive lesson is equally strong: **a real end-to-end harness over the production seam surfaces
latent issues immediately.** Within minutes of first running, `dl-score` converted DL-154/#162 from
"compiled but unrun" into "measured-correct end-to-end," and the gate now catches that whole
collapse-to-groundout class on every future PR. This is the institutionalization of
[[mock-to-real-stateful-core-swap]]'s "test the REAL input path, not an idealized proxy."

## Prevention
- **Rebase-then-trust:** when a feature hardens a seam, rebase onto `origin/main` (or verify
  ancestry) *before* running the new gate and *before* freezing any baseline.
- **Freeze baselines from verified output, not from "whatever the code currently does."** Cross-check
  the frozen expectations against the spec/semantics, especially for the cells that distinguish play
  types — the DL-37 history (everything rendering `6-3`) is the cautionary tale.
- **Triage a new gate's first red as base-staleness first.** Add "is my base current?" above "is the
  core broken?" in the runbook for any first-run harness failure.

## Related
- DL-37 (ADR-0015) — the harness, `dl-score`, the macOS core slice.
- [[mock-to-real-stateful-core-swap]] — test the real input path; instrument every path or a gate
  passes vacuously (the FactBridge `"63"` vs `"6-3"` precedent for this exact seam).
- [[parallel-squad-integration]] — green CI ≠ correct (this is its mirror: red harness ≠ new bug).
