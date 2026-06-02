# evals/runners

Eval gate runner scripts (T005, T010, T041, T042, T043, T060 — Squads A and C).

## Purpose

This directory holds the shell scripts that the CI jobs (and local dev workflows)
invoke to run each evaluation gate.  Each script is either a **CI hard-fail** (once
fully wired) or an **advisory runner** (labeled explicitly below).

## Honesty caveat

> **Self-consistency vs. field accuracy — runners are only as good as their inputs.**
>
> - `judgment-gate.sh` measures whether the classifier is internally consistent
>   against the adversarial corpus (evals/judgment-corpus/).  It does NOT measure
>   whether the classifier agrees with a trained human scorer on real plays.
>
> - `accuracy.sh` reports SC-001 / SC-002 metrics.  Until evals/gold/ contains a
>   real independent gold game and H3 (Squad C handoff) is complete, these metrics
>   are **self-consistency (advisory)** and MUST be labeled as such in any output.
>   They become hard / field-credible only once the real gold dataset is wired.
>
> - `proof-box.sh` measures whether the proof-box identity balances on generated
>   plays (Layer 1, offline, non-authoritative).  The authoritative check is
>   `retrosheet-gate.sh` Layer 2 (cwevent).
>
> - `retrosheet-gate.sh` measures structural export conformance.  A clean gate pass
>   does NOT imply field accuracy.

## Scripts

| Script | Gate tier | CI job | Hard-fail? | Status |
|--------|-----------|--------|-----------|--------|
| `judgment-gate.sh` | SC-003 silent-resolution counter | `core-eval` | Yes (once wired) | Placeholder |
| `accuracy.sh` | SC-001 / SC-002 accuracy | `core-eval` | Advisory until gold | Placeholder |
| `proof-box.sh` | Proof-box Layer 1 | `core-eval` | Yes (once wired) | Placeholder |
| `retrosheet-gate.sh` | cwevent 3-layer gate | `retrosheet-gate` | Yes (once wired) | Placeholder |
| `parity.sh` | Agent/CLI vs UI parity (SC-008) | — | Yes (once wired) | Placeholder |

## judgment-gate.sh (T041)

**Intent (once implemented):**

```
evals/runners/judgment-gate.sh <corpus.jsonl>
```

- Loads each entry from the judgment corpus (evals/judgment-corpus/corpus.jsonl).
- Invokes `classify()` via the CLI adapter (adapters/cli/) on each play's facts.
- FAILS (exit 1) if any entry is NOT classified as `Judgment(...)`.
- FAILS (exit 1) if the `silent_resolution_counter` (SC-003) is non-zero after the
  run.
- Prints a per-entry summary and a final PASS/FAIL verdict.

This is a **CI hard-fail** — a non-zero counter or any silently-resolved entry
blocks the build.

## accuracy.sh (T042)

**Intent (once implemented):**

```
evals/runners/accuracy.sh <gold-game-dir>
```

- Loads the gold game from evals/gold/<game>/ per the evals/INTERFACE.md format.
- Runs the system end-to-end (speak → score) over the gold game's audio/transcript.
- Compares output to the hand-scored Reisner (SC-001: play type >= 90%) and
  Retrosheet event file (SC-002: Reisner token >= 85%).
- Labels results "self-consistency (advisory)" when no real gold game is present;
  "field accuracy" once evals/gold/ is populated and H3 is complete.

## proof-box.sh (T043)

**Intent (once implemented):**

```
evals/runners/proof-box.sh <game-event-log>
```

- Replays the event log via the core's proof-box module.
- Verifies AB + BB + Sacrifices + HBP + Interference = Runs + Putouts + Runners-stranded
  for every completed half-inning.
- FAILS (exit 1) on any imbalance.
- This is Layer 1 (offline, fast, non-authoritative).  The authoritative check is
  the cwevent Layer 2 in retrosheet-gate.sh.

## retrosheet-gate.sh (T060)

**Intent (once implemented):**

```
evals/runners/retrosheet-gate.sh <fixture-dir> <year>
```

- Requires: pinned Chadwick cwevent v0.10.0 binary on PATH (built by CI from the
  SHA256-pinned tarball).
- Runs `cwevent -y <year> -n <game.EVN>` with the mandatory TEAM<year> file.
- Layer 2 (authoritative): FAILS if stderr matches `WARNING|Invalid|Can't find|could not open`
  OR if zero event rows are emitted — NOT on exit code alone.
- Layer 3 (regression): diffs cwevent output against expected.csv; FAILS on any diff.

See research.md D4 for the load-bearing finding: cwevent exits 0 on malformed plays.

## parity.sh (T040)

**Intent (once implemented):**

```
evals/runners/parity.sh <play-facts-file>
```

- Invokes each of the 4 primitives via the CLI/agent path and the core directly.
- Asserts that resulting state, notation, classification, and verify semantics are
  byte-identical across both paths (SC-008 agent-native parity).

## Interface contract

All runners consume inputs per the format defined in `evals/INTERFACE.md` (T010).
That file is the single source of truth for corpus format, gold-game format, and
gate exit semantics.

## Related

- `evals/INTERFACE.md` — eval-harness interface contract (T010)
- `evals/judgment-corpus/` — mislabeled-judgment adversarial corpus
- `evals/gold/` — gold-standard game dataset
- `evals/retrosheet-fixtures/` — cwevent regression fixtures
- `.github/workflows/ci.yml` — CI jobs that invoke these runners
- `core/src/classify/guard.rs` — instrumented SC-003 counter (T024)
- `specs/001-voice-scorebook-core/tasks.md` T041–T043, T060
