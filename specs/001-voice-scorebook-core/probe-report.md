# Spec-Coherence Probe Report — Deterministic Scoring Core

- **Date:** 2026-06-01
- **Spec under test:** [`spec.md`](./spec.md) (001-voice-scorebook-core)
- **Method:** throwaway tracer-bullet engine (text input, no voice) on branch `spike/scoring-core-probe`, built + adversarially verified by a 4-phase workflow (`wf_c29a9bd1-07b`, 7 agents).
- **Verdict:** **BUILDABLE_WITH_GAPS** — core works and is honest, but the cardinal invariant (FR-010/SC-003 "no silent judgment") **adversarially FAILED as implemented**, and the SC-003 gate was vacuous. Not BLOCKED (no hard stop condition hit); the failure is a design defect reachable from spec gaps.
- **Disposition:** the spike engine under `spike/scoring-core/` is disposable. This report (the gap list + verdict) is the artifact; it feeds `/speckit-clarify` and `/speckit-plan`.

> Honesty (Art. VI): the 100%/100% accuracy numbers are over a tiny, **agent-constructed** 11-play gold (self-consistency, not field accuracy). Retrosheet validation used a **reduced offline validator, not Chadwick** (unavailable offline). Both disclosed below.

---

## 1) What is proven buildable (real metrics, re-run locally)

- **Determinism (FR-003): PROVEN.** `eval.py` run twice → byte-identical, EXIT=0.
- **Proof-box reconciliation (FR-005a/SC-011): PROVEN, hand-recomputed.** Top 1st 5=5, Bot 1st 6=6, independently re-derived from the base-state trace.
- **Reduced-Retrosheet emission (FR-016/SC-004): PROVEN against the reduced grammar only.** All 12 `play,` records hand-checked (`63/G`, `S7`, `E6.1-2`, `D8.2-H;1-3`, `6-4-3/DP`…) → 0 grammar errors; validator self-test 38/38; malformed fixture correctly yields 5 errors. **Not Chadwick parity.**
- **Judgment surfacing on correctly-typed plays: PROVEN.** The 2 gold judgment plays are surfaced, left OPEN, and refuse resolution without a non-empty decider (FR-011, negative-tested). No Rule 9.16 reconstruction.
- **Scope honesty: PROVEN.** No voice/ASR/audio/9.16 code present (grep clean).

Representability is established: every named play class has a render path + reduced-Retrosheet token and round-trips deterministically.

## 2) The decisive finding — the cardinal invariant is breakable as specified

**The "no silent judgment" guarantee was a function of the caller's TYPE LABEL, not of play facts — and the SC-003 gate counter was dead code.**

- **BREAK 1 — classification routes on `play["type"]`, not facts** (`engine.classify()` engine.py:247-251). A misplayed grounder (the textbook hit-vs-error) typed `single`/`[6]` → `S6`, hit credited, **no flag**. Adversarial probe: **5/5 judgment calls silently resolved.**
- **BREAK 2 — earned/unearned silently skipped on every scoring play.** A clean single that scores a runner in an inning containing an error → `runs += 1` with no earned/unearned tag and no flag (violates the FR-017 flag-and-defer the build claims to honor).
- **BREAK 3 — SC-003 gate is vacuous.** `silent_resolutions` is initialized and read but **never incremented anywhere** → the headline `silent_judgment_resolutions: 0` and SC-003 PASS measure a counter mathematically pinned to 0.

**Root cause is a spec gap, not just a coding bug:** FR-006 asserts an 85/15 deterministic/judgment split but never says *how* a play is classified, so a builder defaults to trusting the input's type label — which is exactly how a judgment call gets silently resolved. This is failure-reason #1 from the discovery brief ("accuracy of judgment calls erodes trust") reproduced at the spec level.

## 3) What is underspecified (each with the quoted spec line)

| # | Gap | Spec line |
|---|---|---|
| 1 | Concrete reduced-Retrosheet play-string grammar never given (builder invented one) | FR-016 |
| 2 | "Standard Retrosheet tooling" validator never named (Chadwick/cwevent/pyretrosheet?) → acceptance gate undefined | SC-004 |
| 3 | **The 85/15 deterministic-vs-judgment play classes are not enumerated** (root cause of §2) | FR-006 |
| 4 | "Contested putout/assist" trigger never defined | FR-010 |
| 5 | Proof-box term→event mapping (sacrifices/HBP/interference) + "runners stranded" computation undefined | FR-005a |
| 6 | No structured schema for the Reisner situation-diamond + catalyst (prose only) | FR-005 |
| 7 | No ambiguity/confidence definition for text/structured input | FR-008 |
| 8 | No gold-standard hand-scored dataset → SC-001/SC-002 unmeasurable vs independent truth | Assumptions |
| 9 | Authority/permission model unspecified (only a non-empty decider string enforced) | FR-020 |
| 10 | Downstream-recompute-on-correction semantics undefined (`correct_event` only flags) | FR-012/FR-014 |

## 4) Intractable under current scope

Nothing intractable *in principle* — but two things do not hold as written and must change before build: the **fact-derived judgment classification** and a **measurable SC-003 gate** (both detailed in §2).

## 5) Recommended spec/plan changes (feed `/speckit-clarify` → `/speckit-plan`)

**P0 (blocking — fix before build):**
1. **Make judgment classification fact-derived, not label-derived** (FR-006/FR-010): `classify()` must inspect normalized play *facts* (reach-on-fielder-touch, run in an error inning, FC, contested credit) and raise a judgment flag regardless of the incoming type. Add a **mislabeled-judgment adversarial corpus** to the eval gate.
2. **Make SC-003 measurable:** increment a silent-resolution counter on any book mutation that resolves a fact-classified judgment without an open flag + decider; wire the adversarial probes into the eval as a **hard FAIL gate**.
3. **Represent earned/unearned as first-class deferred state:** any run in an error inning attaches `earned_unearned: PENDING` (no Rule 9.16 reconstruction; FR-017 stays flag-and-defer).
4. **Pin the exact Retrosheet grammar + validator tool/version** (likely Chadwick `cwevent`) for FR-016/SC-004; mark the offline reduced validator explicitly non-authoritative.

**P1 (clarify before/with planning):**
5. Define the "contested putout/assist" trigger (FR-010), proof-box term mapping + stranded-at-3rd-out rule (FR-005a), ambiguity definition for text/structured input (FR-008), and the Reisner diamond/catalyst schema (FR-005).
6. Specify the authority/permission model (FR-020) beyond a non-empty decider string.
7. Define downstream-recompute semantics (FR-012/FR-014).
8. Provide/commission a real, independent, multi-inning hand-scored gold dataset so SC-001/SC-002 measure ground truth, not self-consistency.

## Metrics observed

| Check | Target | Observed | Honest status |
|---|---|---|---|
| Determinism (FR-003) | identical | byte-identical ×2 | PASS (verified) |
| Proof-box (FR-005a/SC-011) | balances | 5=5, 6=6 | PASS (hand-recomputed) |
| Structural acc. (SC-001) | ≥90% | 100% | PASS over n=9 self-authored gold — **not field-credible** |
| End-to-end (SC-002) | ≥85% | 100% | PASS over n=11 self-authored gold — **not field-credible** |
| No silent judgment (SC-003/FR-010) | 0% | **adversarial: 5/5 silent; gate counter dead** | **FAIL (cardinal invariant breakable)** |
| Retrosheet errors (SC-004) | 0 via standard tooling | 0 via reduced validator only | PARTIAL — Chadwick parity unverified |
| Append-only correction (SC-007) | retain prior | present | PASS; downstream recompute not done |
