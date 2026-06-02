# Manual Testing — Diamond Ledger

How to exercise the system by hand. The **deterministic core is fully testable headless
(no Mac needed)**; the **iOS app needs Xcode** (you have a Mac, so the steps are below).

> Prereq: the pinned Rust toolchain installs automatically via `rustup` on first `cargo`
> use (`rust-toolchain.toml` pins it). To validate Retrosheet exports locally, install
> Chadwick: `brew install chadwick` (CI builds the pinned v0.10.0 itself).

---

## 1. One command: `make demo` (no Mac required)

The push-button "does the whole pipeline work?" check:

```bash
make demo
```

It builds the workspace and runs, exiting non-zero on any failure:
- **`cargo test --workspace`** — the engine: determinism (replay-twice byte-identical),
  proof-box reconciliation, and the adversarial judgment invariants.
- **`cargo clippy -- -D warnings`** — the no-float (integer-only core) + all-warnings gate.
- **SC-003 judgment gate** — every fact-classified judgment in the corpus is *surfaced*,
  never silently resolved (`silent_resolution_counter == 0`), all four triggers exercised.
- **Retrosheet gate** — the reduced-grammar fixtures validate through pinned Chadwick
  `cwevent` (3-layer, stderr-driven). *Skipped with a note if `cwevent` isn't installed.*

Individual targets: `make test` · `make lint` · `make gates` · `make cli`.

---

## 2. Drive the core / try to break the cardinal invariant

The cardinal guarantee is *no silent judgment resolution*. Test it directly:

```bash
# Run the SC-003 gate over the full 20-entry corpus (or your own corpus file):
bash evals/runners/judgment-gate.sh
bash evals/runners/judgment-gate.sh path/to/your-corpus.jsonl

# The gate HARD-FAILS if any fact-classified judgment is NOT surfaced (classified
# Deterministic/OutOfFormat) or the silent-resolution counter is non-zero. It reports
# (non-fatally) any kind-disagreements — where a judgment is surfaced but the engine's
# trigger differs from the corpus's expected kind (tracked accuracy debt, not a silent
# resolution).
```

To add adversarial cases, append JSONL lines (per `evals/INTERFACE.md` §1.1) whose
**facts are a judgment but whose `supplied_label` looks deterministic** — e.g. a misplayed
grounder labelled `"single"`. A correct engine still flags it; that's the invariant.

---

## 3. The `dl` CLI (agent-parity surface)

Build and see the interface:

```bash
make cli            # or: cargo run -p dl-cli -- --help
cargo run -p dl-cli -- new-game Hawks Owls owner-1
```

Every primitive is JSON-in / JSON-out and callable from the CLI exactly as the app/agent
calls it (Art. II parity). `record-play` takes a **normalized-play JSON** (natural-language
parsing lives in the iOS adapter, not the core).

> ⚠️ **Current limitation (tracked):** the CLI is **in-memory per process** — it does not
> yet persist game state between invocations, so you can't build up a game across separate
> `dl` commands. A stateful CLI session (persist to a file) is a tracked follow-up. For now
> the CLI demonstrates each primitive in a single call; the full game loop is exercised by
> the engine tests (`make test`) and, interactively, by the iOS app.

---

## 4. The iOS app (V3 glance loop) — Xcode, iOS 26

The voice client (`ios/`) is a SwiftPM package built against `MockCore` (the real Rust core
swaps in later at handoff H1). It implements the make-or-break interaction: push-to-talk →
**Card A** (deterministic confirm) / **Card B** (judgment — *your call*).

```
1. Accept the Xcode license once if you haven't:  sudo xcodebuild -license accept
2. Open the package in Xcode 16+:  open ios/Package.swift
3. Select an iOS 26 simulator (e.g. iPhone 16) and Run.
4. Sign in (a #if DEBUG dev fast-path is wired for iteration), tap New Game.
5. Hold the push-to-talk button. A Wizard-of-Oz panel (long-press to reveal) lets you pick
   a scripted play — choose a deterministic play (Card A → one-tap Confirm) and the
   "misplayed grounder" script (Card B → "Your call: Hit or Error?").
6. Verify Card B cannot be dismissed without an explicit choice (or "Leave PENDING"), and
   that you cannot record the next play while a judgment is unresolved (the I2 invariant).
```

> ⚠️ **Honest caveat:** this Swift was authored without a local Xcode/Swift toolchain
> (none was available in the build environment), so it is **compile-verified only by your
> Xcode build** — not by CI (the `ios-build` CI job is advisory). One compile error was
> already fixed in review; the first real Xcode build may surface a few more nits. Paste any
> build errors back and they'll be fixed quickly — your Xcode build is the authoritative gate.

---

## 5. Retrosheet export validation (Chadwick `cwevent`)

```bash
brew install chadwick    # pinned v0.10.0 is what CI builds
bash evals/runners/retrosheet-gate.sh evals/retrosheet-fixtures/2024 2024
```

The gate is **stderr-driven** (cwevent exits 0 even on malformed plays — see
`docs/PROJECT_CONTEXT.md` / research D4), 3 layers: proof-box → cwevent parse-success →
golden diff. A malformed fixture (`evals/retrosheet-fixtures/malformed/`) must *fail* it.

---

## What's verified vs. what needs your environment

| Surface | Verified how | Needs |
|---|---|---|
| Deterministic core (engine, judgment, Reisner, Retrosheet emit) | `cargo test` (54), clippy, SC-003 gate — **run in CI as hard gates** | nothing (headless) |
| Retrosheet export conformance | pinned `cwevent` 3-layer gate — **hard in CI** | `cwevent` locally (optional) |
| iOS V3 glance app | read-review + 1 fix; tests written | **your Mac + Xcode 16 + iOS 26 sim** |
