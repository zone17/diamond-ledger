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

> ✅ **CLI persistence (ADR-0009, #128):** the `dl` CLI now **persists the append-only event log
> to a state file** (`$DL_STATE_FILE`, default `./.dl-state.json`) between invocations, so you can
> build up a game across separate `dl` commands. Each primitive loads the log, appends, and saves
> (append-only — nothing is rewritten). The full game loop is also exercised by the engine tests
> (`make test`) and, interactively, by the iOS app.

---

## 4. The iOS app (V3 glance loop) — Xcode, iOS 26

The voice client lives in `ios/`: the app **logic + views are a SwiftPM package**
(`Package.swift`, fully testable) wrapped by a thin **iOS app target** (`DiamondLedger.xcodeproj`,
generated from `project.yml` via XcodeGen). It runs against `MockCore` (the real Rust core swaps in
at handoff H1) and implements the make-or-break interaction: push-to-talk → **Card A** (deterministic
confirm) / **Card B** (judgment — *your call*).

```
1. Accept the Xcode license once if you haven't:  sudo xcodebuild -license accept
2. Open the APP project (NOT Package.swift):  open ios/DiamondLedger.xcodeproj
   (regenerate it after changing targets:  cd ios && xcodegen generate)
3. Pick a destination: click "My Mac" in the top toolbar → choose an iOS Simulator
   (e.g. iPhone 17 Pro). Building for "My Mac" fails — it's an iOS-only app.
4. Press ▶ (Run / ⌘R). The simulator boots and the app launches (~30s first time).
5. Tap New Game. Hold the push-to-talk mic. Long-press the status text (~1.5s) to reveal
   the Wizard-of-Oz panel → pick "Ground out 6-3" (Card A → Confirm) or "Misplayed grounder"
   (Card B → "Hit or Error?").
6. Verify Card B cannot be dismissed without an explicit choice (or "Leave PENDING"), and
   that you cannot record the next play while a judgment is unresolved (the I2 invariant).
```

Headless build/test (what CI-equivalent verification looks like):
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project ios/DiamondLedger.xcodeproj -scheme DiamondLedger \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build   # the app
xcodebuild -scheme DiamondLedger -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test  # 30 tests
```

> **Status (DL-B2):** the app **builds clean and runs in the iOS 26 simulator**, and the full
> XCTest suite passes (**47/47**, up from 30/30, incl. the I2/I5 invariants + new T047/T048
> engine-selection tests + T056 offline-integrity + T057 finalize/export tests), verified via
> `xcodebuild`. The `ios-build` CI job remains advisory.
>
> **What's real:** the `AppleTranscriber` adapter shape, protocol conformance, contextual biasing,
> the `EngineSelector` runtime seam, `ExportView` UI, `FinalizedScorebook` round-trip, and the
> offline integrity test (100-play game, no data loss, SC-006).
>
> **What's stubbed (human handoff required):**
>   - **Real ASR accuracy + the SpeechAnalyzer/AssetInventory migration** — `AppleTranscriber`
>     currently uses the **legacy `SFSpeechRecognizer`** API; `preloadAssets()` only requests
>     authorization (NOT a real `AssetInventory` model preload, FR-021). Accuracy testing
>     (mic → transcript) requires a **physical iPhone + iOS 26 + mic**; the simulator has no
>     microphone, so `isAvailable` returns `false` there (correct behaviour). The real
>     `SpeechAnalyzer` + `AssetInventory` preload is a pending on-device handoff (see the
>     `#warning` in `AppleTranscriber.swift` and ADR-0010).
>   - **sherpa-onnx framework** — `SherpaTranscriber` compiles and the stub path works in tests,
>     but the real decode requires the sherpa-onnx XCFramework + Parakeet ONNX model bundle (see the
>     handoff checklist in `ios/Sources/Speech/SherpaTranscriber.swift`).
>   - **GRDB-backed SQLiteEventLog** — T055 / deferred to H1; `InMemoryEventLog` used in tests.
>   - **Real UniFFI core** — MockCore until H1 (T071).
>
> **Pre-ship / on-device human handoffs (one-liner):** COPPA consent gate (FR-029 / T081), real
> on-device ASR accuracy, and the sherpa model bundle are all pre-ship/on-device handoffs — none
> are exercisable headlessly in the simulator and each needs a human + device before shipping.

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
| iOS V3 glance app + ASR adapters + Export UI | `xcodebuild test` **47/47** — **build + test pass on Mac** | **your Mac + Xcode + iOS 26 sim** |
| Apple ASR on-device accuracy (mic → transcript; legacy SFSpeechRecognizer today) | not testable in sim | **physical iPhone 26+ + mic + iOS 26** |
| Real SpeechAnalyzer + AssetInventory preload (FR-021) | not implemented (legacy SFSpeechRecognizer; `preloadAssets` = auth only) | on-device handoff — see `#warning` / ADR-0010 |
| sherpa-onnx real decode (Parakeet model) | stub path tested; real decode needs framework binary | XCFramework download + model asset |
| SQLite / GRDB crash-safe event log (SC-006 full) | InMemoryEventLog; GRDB deferred to H1 | T055 + device crash test |
| COPPA consent gate (FR-029 / T081) | not implemented | pre-ship human handoff |
