# Evaluation records (`docs/evaluations/`)

**Authority:** constitution [Article XXI — Evaluation-Driven Development for Agents](../../.specify/memory/constitution.md)
("Store durable artifacts under `evals/` and `docs/evaluations/`"); label rules in
[`evals/INTERFACE.md` §2.4](../../evals/INTERFACE.md); gate exit semantics in
[`evals/INTERFACE.md` §3](../../evals/INTERFACE.md); gate decision record
[`DECISIONS.md` ADR-0017](../../DECISIONS.md).

## Purpose

`evals/` holds the **machinery** — runners, corpora, fixtures, golden files.  This directory holds the
**records**: dated, human-readable reports of what an evaluation measured, over which corpus, under
which label, and what was concluded.  A number in a PR comment, a CI log or a chat is not durable;
a file here is.  Article XXI says a new agent capability is incomplete without evaluation coverage,
and coverage that leaves no artifact cannot be audited.

Records are evidence and are **append-only**.  Re-running a campaign later produces a new file; an
old report is never edited to look better or deleted to hide a bad result (the same rule as
`.specify/workflows/runs/`).

## Label rules (mandatory)

Every accuracy-shaped number in any file here — a percent, a ratio, a count of rows that did or did
not do something — MUST carry one of the four labels below, verbatim.  Omitting the label is a
documentation defect equivalent to a fabricated Retrosheet record (INTERFACE §2.4).

| Label | Printed by | What it means | What it is NOT |
|-------|-----------|---------------|----------------|
| `FIELD ACCURACY` | `evals/runners/accuracy.sh` when `meta.json.h3_ready == true` | Agreement with an **independent human scorer's** ground truth on a real gold game (INTERFACE §2.3). | — this is the only field claim |
| `SELF-CONSISTENCY (advisory — not field accuracy)` | `accuracy.sh` when no gold game exists or `h3_ready == false` | The system agrees with itself across two runs. | Field accuracy |
| `FIXTURE ROBUSTNESS (advisory — not field accuracy)` | `evals/runners/voice-accuracy.sh` / `voice-accuracy-compare.py` | The deterministic transcript→score pipeline (`dl-score`, `dl-bias`) measured on frozen **text** fixtures: mis-hearing variants and biasing pairs.  No ASR runs; the WER hook reports `not measured`. | Recognition accuracy of any kind; field accuracy |
| `SYNTHETIC SPEECH (advisory — not field accuracy)` | reserved — no runner prints it yet | A future text → TTS → on-host recognizer → `dl-score` leg. | Field audio: no crowd noise, no real speaker, no real microphone |

Only `FIELD ACCURACY` is a field-accuracy claim.  The other three are advisory by construction.
The voice-accuracy runner's hard-signal lines (confident-wrong rows, canonical regressions, pair
mismatches, determinism) are gate signals, not accuracy numbers, and are printed without a label;
copy them into a report as gate results, not as accuracy.

## File naming

`YYYY-MM-<topic>.md` — the year-month the measurement was taken plus a short kebab-case topic.
Examples: `2026-09-voice-accuracy-baseline.md`, `2026-10-crowd-noise-wer.md`.  One measurement
campaign per file.

Every report opens with a header block: date; runner and its commit; corpus and its commit; the
label; the exact command that regenerates it; the environment (OS, Xcode, device if any).

## Index

| File | Label | Status |
|------|-------|--------|
| `2026-09-voice-accuracy-baseline.md` | `FIXTURE ROBUSTNESS (advisory — not field accuracy)` | **to be added** — the first run of `make voice-accuracy-gate` over the real `evals/voice-accuracy/` corpus, including the clarify-rate finding at confidence 60 and 100 (DL-157) |
| `YYYY-MM-crowd-noise-wer.md` | `FIELD ACCURACY` (on device) | **pending T076** — see below |

## Where T076 field results go

T076 (`specs/001-voice-scorebook-core/tasks.md`): *field-test crowd-noise WER on short baseball
phrases — the real ASR risk; ties SC-005/A5 — record results in `docs/evaluations/`.*

It needs a physical iPhone on iOS 26 with a microphone, a real crowd environment, and microphone
capture on the push-to-talk path (T046, not yet implemented — see `MANUAL-TESTING.md`).  Record it
here as `YYYY-MM-crowd-noise-wer.md` with:

- device model and iOS build; engine (`AppleTranscriber` or `SherpaTranscriber`); app commit;
- the phrase list (short baseball phrases, the same utterances the transcript corpus uses);
- the environment (venue, crowd level, measured dB if available);
- per-phrase and aggregate word error rate (WER), plus how many phrases scored to the correct
  play through `GrammarParser` and how many surfaced Clarify;
- the biased-leg confidence distribution (plan A7) — the input for deciding whether the
  silent-scoring switch in `BiasingDecision` may ever flip (ADR-0017);
- the label.  This will be the first file here that may carry a field label for ASR.  Until it
  exists, **no ASR accuracy number anywhere in this repo is field accuracy.**

## How to regenerate the voice-accuracy report

```
make voice-accuracy-gate                       # = bash evals/runners/voice-accuracy.sh
bash tools/tests/voice-accuracy-tripwire.sh    # proves the gate goes red on a known-bad corpus
```

macOS + Xcode + rustup are required (the CLIs link the macOS slice of the core XCFramework).
Exit `0` PASS; `1` FAIL — a confident-wrong row, a canonical regression, a biasing-pair mismatch,
non-deterministic output, or a corpus schema violation; `2` NO WORK (zero variants or pairs —
never green).  On non-macOS the runner prints `SKIP` and exits 0.  CI runs the tripwire and then
the gate in the `voice-accuracy` job on `macos-latest` for every PR.  Full semantics:
INTERFACE §3.6.

## Related

- `evals/INTERFACE.md` — the frozen eval contract (labels §2.4, corpus schemas §2.5, gates §3)
- `evals/runners/README.md` — every runner and what it proves
- `evals/voice-accuracy/README.md` — authoring rules for variants and biasing pairs
- `DECISIONS.md` ADR-0017 — the voice-accuracy gate, `dl-score` flags, `dl-bias`, biasing policy
- `MANUAL-TESTING.md` — what is verified headlessly and what still needs a human and a device
