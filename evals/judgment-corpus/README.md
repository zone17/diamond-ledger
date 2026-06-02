# evals/judgment-corpus

Adversarial corpus of mislabeled-judgment plays (T005, T011, T063 — Squad C).

## Purpose

This directory holds the **mislabeled-judgment adversarial corpus** that drives the
**SC-003 silent-resolution counter gate** — a CI hard-fail (once wired).

Each entry is a play whose **facts** unambiguously classify it as a judgment call
(hit-vs-error, earned/unearned, contested credit, ambiguous advance) but whose
**supplied type label** is a deterministic outcome.  Running `classify()` against
the corpus must:

1. Surface every entry as `Judgment(...)` — never as a deterministic play.
2. Never silently resolve any entry.
3. Trip the `silent_resolution_counter` (SC-003) on any attempted silent resolution.

**A zero-size or trivially-passing corpus is a red flag.**  The corpus is not a
regression fixture — it is an adversarial probe that must actively exercise the
cardinal seam.

## Honesty caveat

> **Self-consistency, not field accuracy.**  Until a real independent gold game
> (evals/gold/) is present and wired into evals/runners/accuracy.sh (H3), every
> metric produced by running the judgment-gate runner against this corpus measures
> whether the system is internally consistent (the classifier agrees with itself),
> **not** whether it makes the same call a trained human scorer would make on a
> real play.  Label results with "self-consistency (advisory)" until H3 is complete.

## Format

Entries live in `corpus.jsonl` (one JSON object per line).  The interface contract
is defined in `evals/INTERFACE.md` (T010).  A seed synthetic corpus
(`seed.jsonl`, T011) is produced by Squad A to make the gate exercisable before
the real corpus (T063) lands.

## Judgment triggers covered (v1)

- Hit vs. error (scorer's exclusive call under Rule 9.12)
- Earned / unearned (error or passed ball in the half-inning)
- Contested RBI credit (sacrifice fly vs. fielder's choice vs. error)
- Ambiguous advance (runner advances on a play with multiple possible attributions)

## Files

| File | Status | Owner |
|------|--------|-------|
| `seed.jsonl` | Synthetic seed — Squad A (T011) | Squad A |
| `corpus.jsonl` | Real adversarial corpus — Squad C (T063) | Squad C |

## Related

- `core/src/classify/guard.rs` — instrumented silent-resolution counter (T024)
- `evals/runners/judgment-gate.sh` — gate runner (T041)
- `evals/INTERFACE.md` — corpus format contract (T010)
- `specs/001-voice-scorebook-core/spec.md` FR-006a, SC-003
