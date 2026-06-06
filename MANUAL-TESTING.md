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
generated from `project.yml` via XcodeGen). As of **H1 (T071 / DL-35)** it runs against the **real
UniFFI Rust core** (`DiamondCoreClient`, wrapping the generated `DiamondCore`), not `MockCore` —
which remains for previews/tests. It implements the make-or-break interaction: push-to-talk →
**Card A** (deterministic confirm) / **Card B** (judgment — *your call*).

**Build the real-core XCFramework first** (needs full Xcode; artifacts are `.gitignore`d):
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make xcframework
# emits ios/Generated/DiamondLedgerCore.xcframework + DiamondLedgerCore.swift (delete-before-regen)
cd ios && xcodegen generate    # regenerate the app project after the binary target lands
```

```
1. Accept the Xcode license once if you haven't:  sudo xcodebuild -license accept
2. Open the APP project (NOT Package.swift):  open ios/DiamondLedger.xcodeproj
   (regenerate it after changing targets:  cd ios && xcodegen generate)
3. Pick a destination: click "My Mac" in the top toolbar → choose an iOS Simulator
   (e.g. iPhone 17 Pro). Building for "My Mac" fails — it's an iOS-only app.
4. Press ▶ (Run / ⌘R). The simulator boots and the app launches (~30s first time).
5. Dev Sign-In. Tap New Game. Hold the push-to-talk mic. Long-press the status text (~1.5s) to
   reveal the Wizard-of-Oz panel → pick "Ground out 6-3" (Card A → Confirm) or "Misplayed grounder"
   (Card B → "Hit or Error?").
6. Verify **both** Card A and Card B cannot be swiped away — they require an explicit action
   (Confirm / Resolve), because the real core holds the unconfirmed play and has no discard. You
   cannot record the next play while one is pending; a mic press REOPENS the pending card. Card B
   cannot resolve without an explicit choice (or "Leave PENDING"); a premature confirm returns the
   real core's JUDGMENT_REQUIRED (I2). "Correct" on Card A explains amend lands post-confirm.
7. **End Game** on an incomplete game (a pending play, an open judgment, or a mid-half-inning)
   surfaces the REAL core reason and offers "Back to game" or "Exit without saving" — never a
   generic "Something went wrong". A completed/empty half-inning exports normally.
```

Headless build/test (what CI-equivalent verification looks like):
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
make xcframework   # build the real-core binary first (see above)
cd ios && xcodegen generate && cd ..
xcodebuild -project ios/DiamondLedger.xcodeproj -scheme DiamondLedger \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build   # the app (real core linked)
xcodebuild -project ios/DiamondLedger.xcodeproj -scheme DiamondLedgerTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test    # 63 tests
```

> **Status (DL-35 / H1):** the app **builds clean and launches in the iOS 26 simulator with the
> REAL Rust core injected** (`DiamondCoreClient`), and the full XCTest suite passes (**63/63**,
> incl. 6 `RealCoreIntegrationTests` + 8 `RealPathRegressionTests` that drive the full Card A →
> confirm → Card B → resolve → finalize loop against the real core and assert I2/SC-003, FR-007,
> owner-as-decider, and SC-011). Verified via `xcodebuild`. The `ios-build` CI job remains advisory.
>
> **Real-core vs MockCore behavior parity (verified):** the loop behaves identically to MockCore for
> the demo scripts — clean 6-3 → Card A/confirm; misplayed grounder → Card B/open HitVsError, never
> auto-resolved. One **intended divergence**: `finalizeScorecard` on the real core actually computes
> the half-inning proof box and **enforces SC-011**, so finalizing a *still-in-progress* half-inning
> is rejected with `proofBoxImbalance` (MockCore always returned a canned balanced book). A completed/
> empty half-inning finalizes fine.
>
> **Stateful-core reconciliation (DL-35 H1-completion — the live-on-sim fixes):** the iOS UX was
> built against the *stateless* MockCore, so flows that assumed "the core tracks no state" broke
> against the real *stateful* core. Reconciled:
>   - **The real core has NO discard/cancel/replace primitive for a pending play.** The event log is
>     append-only; the only way to clear a recorded-but-unconfirmed play is `confirm_play` (or
>     resolving its open judgment, then confirming). Verified by reading `core/src/primitives/mod.rs`
>     + the FFI surface — there is no `ffi_discard`/`ffi_cancel`.
>   - **Card A can no longer be swiped away** (`interactiveDismissDisabled`, like Card B). Swiping it
>     used to orphan the play: the UI forgot it while the core still held it, so the next mic press
>     hit FR-007 "A prior play is unconfirmed" with no recovery. `handleSheetDismiss` no longer drops
>     `pendingResult`; a mic press with a pending play **reopens the pending card** so the user can
>     Confirm/Resolve it. "Correct" keeps the card up and explains that amend lands post-confirm
>     (`correct_event` is post-MVP) — it never replaces facts pre-confirm (the core can't).
>   - **End Game no longer blind-calls finalize.** `AppState.endGame()` pre-checks the locally-known
>     blocker (a pending play) → clear message + reopen the card. Anything only the core knows
>     (proof-box balance, open judgments) is surfaced by `ExportView` from the real `CoreError`
>     message — never a generic "Something went wrong". The error screen offers **Back to game**
>     (resolve the item) or **Exit without saving** (discard, no finalize) for an incomplete game.
>   - **Real-path verification gap closed.** `RealPathRegressionTests` drive the ACTUAL UI path
>     (`StubTranscriber → GrammarParser → FactBridge → real DiamondCore`), not idealized facts — the
>     gap that let the live bugs through. Incl. the `parseFielders("63") == [6,3]` bug-class guard
>     (the concatenated grammar chain that earlier produced an out-of-range `Position(63)` → the
>     user-facing "CoreError 4" on a plain mic press) and a fact-derived Card B from a real
>     "reached on error" transcript with **no** WoZ `"script"` marker.
>
> **What's real:** the `AppleTranscriber` now uses the **real iOS-26 `SpeechAnalyzer` +
> `SpeechTranscriber` + `AssetInventory`** API (DL-80) — see below; the `EngineSelector` runtime
> seam, `ExportView` UI, `FinalizedScorebook` round-trip, and the offline integrity test (100-play
> game, no data loss, SC-006).
>
> **What's stubbed (human handoff required):**
>   - **Real on-device ASR accuracy (mic → transcript)** — `AppleTranscriber` is now wired to the
>     real `SpeechAnalyzer(modules: [SpeechTranscriber])` pipeline with a **real `AssetInventory`
>     model preload** (`preloadAssets()` checks `SpeechTranscriber.supportedLocales` /
>     `installedLocales` and downloads the on-device model over Wi-Fi when absent, FR-021) and an
>     `SFSpeechRecognizer.contextualStrings` biasing pass for the baseball lexicon + roster (iOS 26's
>     `SpeechTranscriber` has no native biasing API — Apple's documented hybrid). **What's compile-
>     and unit-verified on the Mac/sim:** the real SpeechAnalyzer/SpeechTranscriber/AssetInventory
>     API compiles against the iOS 26 SDK (zero warnings/errors), engine selection, contextual-
>     strings assembly, the FR-008 biasing-confidence boundary, PCM construction + the
>     `consuming AudioBuffer` release (FR-022), and the duration-guard/error paths (21 new unit
>     tests). **What still needs a human + device:** *recognition accuracy itself* (does "ground ball
>     to short" transcribe correctly?) — `SpeechAnalyzer` **cannot truly run in the simulator** (no
>     model/mic), so in the sim `EngineSelector` correctly degrades to the WoZ `StubTranscriber`. The
>     real Apple path activates only on a **physical iPhone + iOS 26 + mic**. **This is the DL-80
>     on-device human-verification step.**
>   - **sherpa-onnx framework** — `SherpaTranscriber` compiles and the stub path works in tests,
>     but the real decode requires the sherpa-onnx XCFramework + Parakeet ONNX model bundle (see the
>     handoff checklist in `ios/Sources/Speech/SherpaTranscriber.swift`).
>   - **GRDB-backed SQLiteEventLog** — T055 / deferred to H1; `InMemoryEventLog` used in tests.
>   - **Real UniFFI core** — **DONE at H1 (T071 / DL-35)**: `DiamondCoreClient` wraps the generated
>     `DiamondCore` and is injected in `DiamondLedgerApp.swift`. `MockCore` retained for previews/tests.
>
> **Pre-ship / on-device human handoffs (one-liner):** COPPA consent gate (FR-029 / T081), real
> on-device ASR accuracy, and the sherpa model bundle are all pre-ship/on-device handoffs — none
> are exercisable headlessly in the simulator and each needs a human + device before shipping.

### 4a. Running on a physical iPhone (code signing) — the real-ASR test

The simulator can't do real `SpeechAnalyzer` recognition (no model/mic — it degrades to the WoZ stub),
so verifying **real voice → transcript** requires deploying to a physical iPhone (iOS 26). Two gotchas
cost real time the first time; both are captured here.

**(1) Signing must be baked into `project.yml`, not just the Xcode UI.** Selecting the Team in
Xcode → *Signing & Capabilities* does **not** survive `xcodegen generate` (the `.xcodeproj` is a
gitignored, regenerated artifact), and the build fails with `Signing for "DiamondLedger" requires a
development team` even though the UI shows a team. Fix — set it in `ios/project.yml` so XcodeGen writes
`DEVELOPMENT_TEAM` into every build config:

```yaml
targets:
  DiamondLedger:
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: XXXXXXXXXX   # your 10-char Team ID
```
Get your Team ID from the cert Xcode generates (it's the **OU** field, not the CN parenthetical):
```bash
security find-certificate -c "Apple Development: <your-apple-id>" -p | openssl x509 -noout -subject
# subject=… OU=NY8AYZ5U4V …   ← that OU is DEVELOPMENT_TEAM
```
Then `cd ios && xcodegen generate`, **quit & reopen** the project in Xcode (it caches the old one),
and ⌘R.

**(2) The free personal team's "Verify App" step needs to reach Apple — and is easily blocked.** After
install, iOS shows *Untrusted Developer*; tapping **Settings → General → VPN & Device Management → [Apple
ID] → Verify App** contacts Apple's free-provisioning endpoint (`ppq.apple.com`). It frequently fails
with *"requires an internet connection / cannot verify"* **even with working internet**, and the app
then refuses to launch (`profile has not been explicitly trusted by the user`). Causes & fixes, in order:
- **iCloud Private Relay** (Settings → [name] → iCloud) — turn **OFF**; it reroutes traffic and breaks
  the verify handshake. Biggest single cause.
- **"Limit IP Address Tracking"** on the Wi-Fi (Settings → Wi-Fi → ⓘ) — **OFF**; set DNS to Automatic.
- **Restrictive Wi-Fi** (mesh routers, Pi-hole, captive portals, corporate filtering) block
  `ppq.apple.com`. **Turn Wi-Fi fully OFF and Verify on cellular** — bypasses all of it; this is the
  highest-success fix. Also confirm Settings → General → Date & Time → Set Automatically.

**Escape hatch — paid Apple Developer Program ($99/yr).** Paid signing does **not** use the on-device
"Verify App" trust step at all, so the entire class-(2) problem disappears (and you get TestFlight). If
the free-team verify won't cooperate on your network, enrolling (developer.apple.com or the *Apple
Developer* iOS app) is the clean path; afterward the Team ID changes — update `DEVELOPMENT_TEAM` above to
the new paid team.

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
| iOS V3 glance app + ASR adapters + Export UI | `xcodebuild test` **160/160** (incl. 21 DL-80 AppleTranscriber seam tests) — **build + test pass on Mac** | **your Mac + Xcode + iOS 26 sim** |
| Real UniFFI core swap (H1 / DL-35) | `make xcframework` + `xcodebuild test` — app **launches with `DiamondCoreClient`** + 6 `RealCoreIntegrationTests` + 8 `RealPathRegressionTests` drive the full loop AND the real UI fact path (StubTranscriber→GrammarParser→FactBridge→core) + the stateful-core reconciliations (Card-A dismiss, End Game) | **your Mac + Xcode + iOS 26 sim** |
| Real `SpeechAnalyzer`/`SpeechTranscriber`/`AssetInventory` API (DL-80) | **compiles against iOS 26 SDK** (`xcodebuild build`, 0 warnings/errors) + 21 unit tests (selection, contextual-strings assembly, FR-008 biasing boundary, PCM/consume lifecycle, error paths) | nothing extra (headless on Mac) — but see accuracy row |
| Apple ASR on-device **accuracy** (mic → transcript, real SpeechAnalyzer) | **not testable in sim** — SpeechAnalyzer needs a device; sim degrades to WoZ stub (correct) | **physical iPhone 26+ + mic + iOS 26** — the DL-80 human-verification step |
| `AssetInventory` model download over Wi-Fi (FR-021) | wired (`assetInstallationRequest` + `downloadAndInstall`); compile-verified | **physical device** to exercise a real model fetch |
| sherpa-onnx real decode (Parakeet model) | stub path tested; real decode needs framework binary | XCFramework download + model asset |
| SQLite / GRDB crash-safe event log (SC-006 full) | InMemoryEventLog; GRDB deferred to H1 | T055 + device crash test |
| COPPA consent gate (FR-029 / T081) | not implemented | pre-ship human handoff |
