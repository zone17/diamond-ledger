# evals/transcript-regression

Frozen regression corpus for the **headless transcript→score pipeline** (DL-37 / ADR-0015).

Each line in `cases.jsonl` is an English play call plus the expected output of running it through
the full deterministic pipeline:

```
transcript → GrammarParser → FactBridge → real Rust core → classification + Reisner cell
```

The `dl-score` CLI (`ios/Sources/DLScore`) runs this pipeline off-device; the runner
`evals/runners/transcript-score.sh` scores every case and **hard-fails** on any divergence from
the expected baseline.

## Why this exists

This is the **first headless coverage of the transcript→score seam.** Before DL-37, that seam ran
only inside the iOS app, so a regression in `GrammarParser` or `FactBridge` was invisible to CI.
This corpus would have caught DL-154/#162 (all play types collapsing to a `6-3` groundout)
instantly.

## What it does NOT cover

The **audio→transcript (ASR) leg** — Apple `SpeechAnalyzer` (`DiamondSpeech`, iOS-26) — is
device/sim-bound and not exercised here. This corpus measures the deterministic, platform-
independent leg where most scoring risk lives and which we fully control.

## Fields

| Field | Meaning |
|-------|---------|
| `id` | Stable case id |
| `transcript` | The spoken play call (input) |
| `expect_ok` | `true` if the pipeline should accept it; `false` for surfaced out-of-grammar |
| `expect_classification` | `deterministic` \| `judgment` \| `parse_error` |
| `expect_judgment_required` | `true` iff the core should surface Card B (the SC-003 signal) |
| `expect_reisner_catalyst` | (optional) expected rendered Reisner catalyst, e.g. `6-3`, `HR`, `K` |
| `expect_error` | (optional) expected error substring for out-of-grammar cases |

## Guard cases

Note the `tr-guard-*` entries: `"dropped third strike, batter reached first"` and gibberish MUST
surface as `out_of_grammar` (parse_error), never as a silently-misclassified play — the DL-151
invariant. A regression that started classifying those as plays is a cardinal-seam failure and
fails this gate.

## Run

```bash
bash evals/runners/transcript-score.sh
```

Adding a case: pick a transcript, run `dl-score` once to capture the *current correct* output,
and freeze it here only after confirming the output is right (don't bless a wrong baseline).
