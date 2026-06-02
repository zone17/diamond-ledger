# evals/retrosheet-fixtures

Retrosheet event-file regression fixtures for the pinned cwevent 3-layer gate
(T005, T059, T061, T062 — Squad C).

## Purpose

This directory holds **export-conformance and cwevent regression fixtures** — sample
Retrosheet event files used to verify that:

1. The reduced-Retrosheet emitter (core/src/retrosheet/emit.rs, T029) produces
   files that the pinned Chadwick `cwevent` v0.10.0 parses without warnings.
2. The cwevent gate script (evals/runners/retrosheet-gate.sh, T060) correctly
   distinguishes clean files from malformed ones.
3. Golden output (Layer 3) stays stable across emitter changes.

These fixtures are **NOT gold games** and must **never** be used as end-to-end
accuracy evidence.  They have no audio source and represent structural conformance
only.

## Honesty caveat

> **Export conformance, not field accuracy.**  Passing the cwevent gate on a
> fixture proves that the emitter produces structurally valid Retrosheet syntax for
> the covered play types.  It does NOT prove that the system scores real spoken
> plays correctly.  Field accuracy is measured only against evals/gold/ (SC-001 /
> SC-002).
>
> Published Retrosheet .EVN files used here are used under the mandatory verbatim
> attribution terms (see NOTICE at the repo root and evals/retrosheet-fixtures/
> ATTRIBUTION).  They may be used for export-conformance and regression; they may
> not be used as end-to-end accuracy benchmarks.

## cwevent gate — load-bearing finding (research.md D4)

**cwevent exits 0 even on malformed plays.**  A gate based solely on exit code is
vacuous.  Errors appear on stderr:

- `WARNING: ... skipping invalid record`
- `Invalid integer value`
- `Can't find teamfile`
- `could not open`

The gate script (evals/runners/retrosheet-gate.sh) therefore:

1. Runs `cwevent -y <yr> -n game.EVN` with the mandatory `TEAM<yr>` file present.
2. FAILS if stderr matches `WARNING|Invalid|Can't find|could not open`.
3. FAILS if zero event rows are emitted (even with a clean stderr).
4. Performs a golden diff against `expected.csv` (Layer 3 regression).

## Directory layout (per fixture year)

```
evals/retrosheet-fixtures/
  <YEAR>/
    TEAM<YEAR>         # mandatory — cwevent exits 1 without it
    *.ROS              # optional roster files
    clean.EVN          # fixture covering every reduced-grammar play type (T061)
    malformed.EVN      # fixture that MUST trip the gate — negative test (T062)
    expected.csv       # golden cwevent -f 0-96 -n output for Layer-3 diff (T062)
  ATTRIBUTION          # verbatim Retrosheet attribution for files sourced from Retrosheet
```

## Reduced-grammar v1 play types covered (targets frozen grammar, T009)

- Basic hits: S/D/T/H + fielder sequence
- Strikeout: K
- Walk: W, IW
- Hit by pitch: HP
- Single-fielder putout: e.g. 8
- Clean chains: e.g. 63, 643
- Errors: E$
- Stolen base / caught stealing: SB%, CS%
- Modifiers: /G /L /F /P /SF /SH
- Advances: -, X, simple (E$)

Hard ~5% (flag-for-manual, not in v1 reduced grammar):
- Multi-out plays with (runner) annotations + DP/TP
- Mid-string errors / throwing-error reclassification
- FC disambiguation
- Interference / obstruction
- Combined/rare baserunning

## Related

- `evals/runners/retrosheet-gate.sh` — the 3-layer gate runner (T060)
- `core/src/retrosheet/emit.rs` — the emitter under test (T029)
- `core/src/retrosheet/out_of_format.rs` — flags the hard ~5% (T030)
- `specs/001-voice-scorebook-core/contracts/retrosheet-reduced-grammar.md` — frozen grammar (T009)
- `specs/001-voice-scorebook-core/research.md` D4 — cwevent gate design
- NOTICE (repo root) — Retrosheet attribution
