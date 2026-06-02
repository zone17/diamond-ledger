// TODO(T006): Implement the FACT-derived judgment classifier — the cardinal seam.
//             Reads normalized play facts; emits one of: Deterministic | RequiresJudgment.
//             INVARIANT: NO judgment may be silently resolved without an open JudgmentFlag
//             and a recorded decider (Art. VII / SC-003). An instrumented silent-resolution
//             counter is wired here and tested by the adversarial corpus gate in evals/.
//             See specs/001-voice-scorebook-core/spec.md FR-006 / FR-006a.
