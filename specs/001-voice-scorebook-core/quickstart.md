# Quickstart — Voice-to-Scorebook Core

**Feature:** `001-voice-scorebook-core` · **Plan:** [`plan.md`](./plan.md) · **Date:** 2026-06-01

How a developer or agent builds, runs, and evaluates the core once Phase A exists. This is the
**agent-native** entry point: the CLI exercises the *same* primitives as the iOS app (Art. II parity),
so the whole engine is testable headless before any UI. *(Recommended Rust path; adjust if D1 → KMP.)*

## Prerequisites

- Rust (pinned toolchain — see `core/rust-toolchain.toml`).
- **Chadwick `cwevent` v0.10.0** (pinned, for the Retrosheet acceptance gate):
  ```bash
  curl -L -o chadwick.tar.gz \
    https://github.com/chadwickbureau/chadwick/releases/download/v0.10.0/chadwick-0.10.0.tar.gz
  # (verify SHA256 against the pinned hash) then:
  tar xzf chadwick.tar.gz && cd chadwick-0.10.0 && ./configure && make && sudo make install
  cwevent --help | head -1
  ```

## Build & test the core

```bash
cd core
cargo build
cargo test                 # contract tests + proptest invariants + insta golden snapshots
cargo clippy -- -D warnings   # includes the no-float lint (determinism, I6)
```

## Drive a game from the CLI (agent-parity surface)

```bash
# the CLI is a thin client over the same primitives an agent/API calls
dl new-game --home "Hawks" --visitor "Owls"
dl record-play  --game <id> --text "ground ball to short, threw him out at first"   # → 6-3, needs Confirm
dl confirm      --game <id> --seq <n>
dl record-play  --game <id> --text "ball gets by the shortstop, runner safe at first"  # → Judgment (hit/error)
dl resolve      --game <id> --decision <id> --call error --decider <owner|agent>
dl finalize     --game <id> --out game.EVN     # human book + reduced-Retrosheet file
```

Every command emits a structured result (the same `RecordPlayResult` / `FinalizeResult` the app gets) and
an audit `CapabilityInvocation`. State never advances on an unconfirmed play; a judgment never resolves
without an explicit decider.

## Run the eval gates (Article XXI — these are CI hard-fails)

```bash
cd evals
# 1. Cardinal invariant: mislabeled-judgment adversarial corpus + SC-003 silent-resolution counter
./runners/judgment-gate.sh        # FAILS the build on any silent judgment resolution (I2/SC-003)

# 2. Retrosheet acceptance — 3-layer, cwevent authoritative (I4/SC-004)
./runners/retrosheet-gate.sh game.EVN
#   layer 1: Reisner proof-box reconciliation (offline, fast)
#   layer 2: pinned cwevent -y <yr> -n  → FAIL if stderr ~ WARNING|Invalid|Can't find|could not open OR 0 rows
#   layer 3: golden diff of cwevent -f 0-96 -n vs expected.csv

# 3. Accuracy vs the gold game (only meaningful once a REAL gold game exists — D6)
./runners/accuracy.sh gold/<game>/   # SC-001 ≥90% unambiguous structural; SC-002 ≥85% end-to-end
```

> **The gold-dataset gate is honest about its inputs.** Until `evals/gold/` holds a **real, independent,
> multi-inning** hand-scored game with a matching `cwevent`-clean Retrosheet file (D6), accuracy numbers
> measure self-consistency, **not** field accuracy — the probe's lesson. The accuracy gate stays advisory
> until that dataset lands; the judgment + cwevent gates are hard from day one.

## Determinism check (I6 / FR-003)

```bash
dl finalize --game <id> --out a.EVN && dl finalize --game <id> --out b.EVN && diff a.EVN b.EVN  # must be empty
```

## What you can demo after Phase B (US1 + US2 + US3 export)

On device: set up a game, **push-to-talk** a sequence of plays, watch the **V3 glance** HUD update and
card A (confirm) / card B (judgment) appear, resolve a hit-vs-error in one tap, keep eyes on the field —
then **finalize and export** a `cwevent`-clean Retrosheet event file + the human book. This is the
ADR-0006 artifact to put in front of ~20 real serious scorers.
