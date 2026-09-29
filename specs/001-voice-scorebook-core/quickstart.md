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
# the CLI is a thin client over the same primitives an agent/API calls; state persists
# between invocations in $DL_STATE_FILE (default ./.dl-state.json)
dl new-game Hawks Owls owner-1 \
    --visitor-roster "Ana Ruiz, Ben Ortiz, Cy Park" --home-roster "1:Dee Lang, 2:Eli Moss, 5:Fay Ng"
dl setup <game-id>                                        # teams + lineups, read back from the core
dl record-play <game-id> '<normalized-play-json>' owner-1 # → recorded_seq, needs confirm
dl confirm-play <game-id> <seq> owner-1
dl resolve-judgment <game-id> <decision-id> <call-token> <call-label> owner-1
dl correct-event <game-id> <corrects-seq> '<amended-play-json>' owner-1
dl finalize <game-id> owner-1
dl state <game-id>
```

The roster flags are optional, and either can be given alone. Each takes a comma-separated list
(like `dl-score --roster`): names are trimmed, empty entries are dropped, and the names are numbered
1..N in batting order. To keep gaps (the app's rows 1, 2 and 5, say), number every entry with its
batting order: `1:Dee Lang, 2:Eli Moss, 5:Fay Ng`. Number all entries or none; a mix, or a number
that is not an integer 1..255, is a usage error. An entry that starts with digits and a colon is always
read as numbered, so a name that itself starts that way needs an explicit number (`1:12:30 Club`); any
other colon stays part of the name (`Ana: The Great`). A name cannot contain a comma. The core
validates the lineup (at most 20 names, batting orders 1..20 in increasing order, each name at most 60
characters, no control characters); an invalid one exits non-zero with the core's `invalid_argument`
error as JSON on stderr and writes nothing. Every command reports a core error that way
(`{"code":"not_found",...}` after `Error: `), and no error repeats a player's name. The state file
is created owner-only (`0600`) because it holds player names. `dl setup` prints the game's `GameSetup`
(`contracts/get_game_setup.md`); a team started without a roster has no `lineup` key. Player names
stay in the local state file and are not exported (ADR-0020).

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

The same confirmed inputs must produce byte-identical output. Run one game's commands against two
fresh state files and compare the finalize results, which include the Retrosheet export:

```bash
for f in a b; do
  export DL_STATE_FILE="/tmp/dl-$f.json"; rm -f "$DL_STATE_FILE"
  dl new-game Hawks Owls owner-1 --visitor-roster "Ana Ruiz, Ben Ortiz" >/dev/null
  dl finalize 1 owner-1 > "/tmp/finalize-$f.json"
done
diff /tmp/finalize-a.json /tmp/finalize-b.json   # must be empty
```

`bash evals/runners/parity.sh` is the CI form of the same guarantee: the CLI and the replay path must
produce identical state and setup for the same operations.

## What you can demo after Phase B (US1 + US2 + US3 export)

On device: set up a game, **push-to-talk** a sequence of plays, watch the **V3 glance** HUD update and
card A (confirm) / card B (judgment) appear, resolve a hit-vs-error in one tap, keep eyes on the field —
then **finalize and export** a `cwevent`-clean Retrosheet event file + the human book. This is the
ADR-0006 artifact to put in front of ~20 real serious scorers.
