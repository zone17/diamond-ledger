---
title: Push-to-Talk Microphone Capture - Plan
type: feat
date: 2026-09-27
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Push-to-Talk Microphone Capture - Plan

## Goal Capsule

- **Objective:** A scorer holding the mic button on a physical iPhone has their spoken play captured, transcribed on-device, and routed to the Clarify sheet or Card A, and never has a play recorded that they did not say.
- **Means:** A capture seam behind a Sendable protocol, started on press and stopped on release, feeding the existing `Transcriber` contract; explicit permission and model preparation before the first press; no Stub fallback on a real device (KTD1–KTD4).
- **Authority hierarchy:** constitution Article VII and FR-008 (never a silent wrong play) and FR-022 (no retained raw audio) > Requirements > Key Technical Decisions > unit text.
- **Stop conditions:** stop and surface if (a) the privacy gate cannot stay green without an allowlist entry, (b) the capture path cannot be exercised by simulator tests through the seam, (c) a device run shows capture works but every transcript is empty (format or model problem outside this plan).
- **Execution profile:** one PR; squad B. Simulator-verifiable up to the live audio engine; the live engine is verified by the device checklist in U5.
- **Who finishes and ships:** the implementing agent lands the PR through `/ce-code-review` with CI green (including the iOS XCTest hard gate); the product owner runs the device checklist and records the result in `docs/evaluations/`.

---

## Product Contract

### Summary

Wire real microphone capture into push-to-talk: press starts a capture session, release stops it and hands a 16 kHz mono Int16 buffer to the existing transcriber, with permissions and the on-device model prepared up front, interruptions ending the utterance cleanly, and no raw audio kept anywhere. A device checklist records the speech engine's measured confidence so the owner can later decide on hands-free scoring.

### Problem Frame

Voice does not work on a phone. `PushToTalkPipeline` builds an empty `AudioBuffer` (`ios/Sources/UI/PushToTalk/PushToTalkView.swift`), so on device the Apple engine throws `audioTooShort`. Research for this plan found four more gaps that capture alone would not close:

- Nothing in the app requests microphone or speech permission, and nothing calls `AppleTranscriber.preloadAssets()`, so the on-device model is never installed.
- With speech permission denied on a device, `TranscriberEngineSelector.resolve` falls back to `StubTranscriber`, whose canned transcript parses into a real play nobody said. That is an Article VII violation waiting for the first denied permission.
- The listening state leaves only on release; a permission prompt, a phone call, or backgrounding mid-hold strands it (the same class as `docs/solutions/ui-bugs/swiftui-sheet-ondismiss-state-reconciliation.md`).
- An audio tap closure created inside a `@MainActor` type is inferred main-actor isolated and traps on the first audio-thread callback under Swift 6, with no compiler warning.

### Requirements

**Capture**

- R1. Pressing the mic button starts capture; releasing it stops capture and produces one `AudioBuffer` of 16 kHz mono interleaved Int16 samples whose `durationSeconds` is computed from the frame count, not assumed (FR-004 push-to-talk, never continuous).
- R2. A capture auto-stops at a maximum duration of 15 seconds (matching the transcriber's results timeout) and proceeds as a release, even while the finger is still down. Capture keeps recording for a short tail (about 250 ms) after release so the last word is not clipped.
- R3. An interruption, a route change that reconfigures the engine, media-services reset, or the app leaving the foreground ends the utterance immediately, while the finger may still be down: captured audio is discarded, the state returns to idle, and a readable message says why. Capture never auto-resumes, and a new capture starts only on a fresh touch-down.

**Permissions and readiness**

- R4. Microphone and speech-recognition permission are requested at New Game, never mid-hold. Starting a game waits only for those two prompts; the on-device model downloads in the background and never blocks the game (manual entry always works). Readiness is re-read from the live permission and model status on every press and when the app becomes active, so granting access in Settings takes effect without a new game.
- R5. Denied microphone or speech permission, or a model still downloading, surfaces a readable message (with a way to Settings for permissions) and no capture; engine resolution never falls back to the Stub on a device. The Stub remains reachable only in the simulator, via the DEBUG `forceStub` seam, and via the Wizard-of-Oz facilitator panel, which is compiled out of release builds.

**Privacy**

- R6. Raw audio is never written to disk, logged, or retained after `transcribe(buffer:)` returns; the accumulator is released (and zeroed where the API permits) when the buffer is built. `scripts/check-no-raw-audio.sh` stays green with no allowlist entry (FR-022).

**Verification**

- R7. The whole press → capture → transcribe → parse path is unit-testable in the simulator through an injected capture source that yields synthetic PCM.
- R8. Diagnostics record numeric evidence only — the base leg's confidence as reported (logged `unreported` when nil, never the 0.60 fallback), the biased leg's measured confidence, the biasing reason, capture duration, and release-to-transcript latency — never audio or transcript text, so a device run can be turned into a labeled `docs/evaluations/` record (DL-157 Assumption A7). The biased-leg distribution is the measured signal.

### Key Decisions

- **Buffer on release, not streaming, for v1.** Keeps the existing `Transcriber.transcribe(buffer:)` contract and the biasing decision unchanged; streaming during the press is a latency follow-up once the device numbers exist. Governs R1.
- **Prepare permissions and model at New Game, not on first press.** A prompt during a hold would strand the gesture. Governs R4.
- **No Stub on a device outside an explicit debug demo.** A canned transcript is a fabricated play; the facilitator panel is compiled out of release builds. Governs R5.
- **Hands-free scoring stays closed** (ADR-0017 R20); this plan only produces the evidence for that decision. Governs R8.

### Success Criteria

- On a physical iPhone, "ground ball to short, threw him out at first" spoken while holding the button reaches the Clarify sheet with a groundout 6-3 candidate.
- The simulator test suite drives capture end to end with synthetic PCM, and CI stays green including the privacy gate.
- The device checklist produces a `docs/evaluations/` record with the biased-leg confidence distribution.

### Scope Boundaries

Not in scope: streaming recognition during the press, flipping the silent-scoring switch, the sherpa engine, threading the roster through the core (#177), background audio.

#### Deferred to Follow-Up Work

- **Streaming capture into SpeechAnalyzer during the press** for lower release-to-transcript latency.
- **A visibly labeled demo mode for release/TestFlight owner demos**, replacing the hidden debug-only facilitator panel, that never writes to a real game.
- **Tuning the audio-session mode** (`.measurement` vs `.spokenAudio` vs `.voiceChat`) by measured accuracy once the synthetic-speech leg (#179) or field clips exist.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **`AudioCaptureSource` protocol (Sendable) in DiamondSpeech with `start() async throws`, `stop() async -> AudioBuffer?`, and an `events: AsyncStream<CaptureEvent>`** (`capReached`, `interrupted(reason)`), injected through `AppState` exactly like `transcriberFactory`. AppState observes `events`: `capReached` runs the release pipeline, `interrupted` goes to idle with a message — both while the finger may still be down. `LiveAudioCapture` is the device implementation and itself takes injected seams: an audio-engine/session abstraction, a record-permission provider, and a notification source, so its interruption, cap, and permission logic is testable with fakes. No CI test touches `AVAudioEngine.inputNode` or a real permission API (the test host has no microphone usage string; touching them crashes or hangs the suite). The press path calls `stop()` inside its own task, which sidesteps passing the `~Copyable` buffer across a `Task {}` boundary.
- KTD2. **Pure conversion and accumulation are separate from the engine.** A `PCM16Accumulator` (value type) appends converted frames; a `PCMConversion` helper converts any `AVAudioPCMBuffer` to 16 kHz mono Int16 with one `AVAudioConverter` per press (output capacity = frames × 16000 ÷ input rate + 1024 slack; input block returns `.haveData` once then `.noDataNow`). Both are unit-tested with synthesized 48 kHz float sine input. Names avoid the privacy gate's write-verb receivers (no `audioData.append`).
- KTD3. **Swift 6 isolation: the tap block and permission handlers are built in `nonisolated static` functions** and marked `@Sendable`; converted chunks cross to the capture actor through an `AsyncStream` continuation. A test invokes the tap handler from a background thread to prove no main-actor assertion.
- KTD4. **Audio session:** `.playAndRecord`, mode `.spokenAudio`, options `.allowBluetoothHFP` and `.duckOthers`, activated on press and deactivated with `.notifyOthersOnDeactivation` after the tap is removed and the engine stopped (Apple's WWDC25 SpeechAnalyzer sample; mode is revisited by measurement later). Tap format is read from `inputNode.outputFormat(forBus: 0)` after activation.
- KTD5. **Permissions and readiness:** the New Game flow awaits only `AVAudioApplication.requestRecordPermission()` (async, iOS 17+) and `SFSpeechRecognizer.requestAuthorization`; `AppleTranscriber.preloadAssets()` starts detached and never blocks `createGame`. `SpeechReadiness` computes `ready | micDenied | speechDenied | modelPreparing` from live status providers (injected, so tests never touch real APIs) on every press and on scene activation, retrying the preload when the model is not ready. iOS itself does not fail a capture with a denied mic (the engine just delivers zeroed samples), so the design never relies on it: readiness is checked before capture starts, and `LiveAudioCapture.start()` also checks the permission provider and throws `permissionDenied` without activating the session.
- KTD6. **Engine selection on device:** `TranscriberEngineSelector.resolve` takes an injected speech-authorization-status provider and returns a new `UnavailableTranscriber` (throws `permissionDenied` or `engineUnavailable`) instead of the Stub when not in the simulator and `forceStub` is off. The Wizard-of-Oz facilitator panel, its long-press reveal, and the `facilitatorScripted` Stub branch in `PushToTalkPipeline.score` are wrapped in `#if DEBUG`, matching `forceStub`.
- KTD7. **Diagnostics:** an `os.Logger` (subsystem `app.diamondledger`, category `voice`) records only numbers and enum reasons with `.public` privacy; text and audio are never interpolated. The base-leg confidence is the raw optional from `AppleTranscriber.confidence(from:)` (`unreported` when nil), recorded separately from the biased leg's measured value. A DEBUG-only in-memory ring of the last 50 records can be exported from the facilitator panel as JSON for the evaluation record.

### High-Level Technical Design

```mermaid
sequenceDiagram
  participant V as PushToTalkView
  participant A as AppState
  participant C as AudioCaptureSource
  participant T as Transcriber
  participant G as GrammarParser
  V->>A: press (readiness checked: permissions + model)
  A->>C: start()
  Note over C: session active, tap installed, frames → 16 kHz Int16 accumulator
  V->>A: release (or 15 s cap / interruption)
  A->>C: stop()
  C-->>A: AudioBuffer (frames/16000 s) or nil if interrupted
  A->>T: setContextualStrings(roster); transcribe(buffer)
  T-->>A: Transcript + diagnostics (numbers only)
  A->>G: parse(transcript, roster)
  G-->>V: Clarify / Card A / manual entry
```

PTT state transitions (existing enum extended with an interrupted exit):

```text
idle --fresh touch-down & ready--> listening   (state leaves idle synchronously, before start() is awaited)
listening --release (+250 ms tail) / capReached--> processing --> result|clarify|error --> idle
listening --interrupted event / background / route change--> idle (+ message, audio discarded, gesture consumed)
idle --press & not ready--> idle (+ permission / model-preparing message, no capture)
consumed gesture: further drag changes in the same touch never start a new capture; cleared on touch-up
```

### Assumptions

Scoping confirmation was skipped (`confirm:auto`); these are unconfirmed bets.

- A1. Requesting permissions at New Game is acceptable UX; the alternative is a first-launch onboarding step.
- A2. A 15-second cap is long enough for any single play call.
- A3. `.playAndRecord` + `.spokenAudio` is an acceptable starting mode; accuracy tuning is deferred.
- A4. The DEBUG diagnostics export is acceptable as the evaluation-record source; release builds only log.
- A5. Removing the facilitator panel from release builds is acceptable; owner demos use DEBUG/TestFlight-debug builds until the labeled demo mode (deferred) exists.
- A6. When active games are later restored from disk, restore must run readiness too; today a relaunch drops the game, so a new game always re-runs it.

### Sequencing

U1 → U2 → U3 → U4 → U5, one PR. U2's live engine is device-verified; everything else is simulator-verified in CI.

---

## Implementation Units

### U1. Capture seam, accumulator, and conversion

**Goal:** A testable capture contract and the pure audio math it needs.

**Requirements:** R1, R6, R7.

**Dependencies:** none.

**Files:**
- `ios/Sources/Speech/AudioCapture.swift` (create): `AudioCaptureSource` protocol, `PCM16Accumulator`, `PCMConversion`, `FakeAudioCapture` (in the test target if it has no production use).
- `ios/Tests/T176AudioCaptureTests.swift` (create).

**Approach:**
1. Protocol per KTD1; `stop()` returns `nil` when the capture was interrupted; `events` is a finite stream per capture.
2. Accumulator per KTD2; `makeBuffer()` builds the `AudioBuffer` with duration = frames ÷ 16000, then releases and zeroes its storage.
3. Conversion per KTD2; one converter per press.

**Execution note:** write the conversion and accumulator tests first against synthesized input.

**Patterns to follow:** `AppleTranscriber.makePCMBuffer(from:)` for the target byte layout; `ios/Tests/AppleTranscriberTests.swift` PCM tests.

**Test scenarios:**
- 1 s of 48 kHz mono Float32 sine converts to 16000 Int16 frames (±1 frame) and duration 1.0 s.
- 44.1 kHz stereo input converts to mono 16 kHz with the expected frame count.
- Two appended chunks produce one contiguous buffer; order preserved.
- `makeBuffer()` on an empty accumulator returns a buffer with duration 0, which the transcriber rejects as too short.
- After `makeBuffer()`, the accumulator's storage is empty (retention check).
- Round trip: the accumulator's bytes fed to `AppleTranscriber.makePCMBuffer(from:)` produce a buffer with the same frame count.

**Verification:** tests pass in `make ios-test`; privacy gate green.

### U2. Live capture on the audio engine

**Goal:** The device implementation of the seam.

**Requirements:** R1, R2, R3, R6.

**Dependencies:** U1.

**Files:**
- `ios/Sources/Speech/LiveAudioCapture.swift` (create).
- `ios/Tests/T176AudioCaptureTests.swift` (extend).

**Approach:**
1. `start()`: configure and activate the session per KTD4 through the injected engine/session seam, read the input format, and throw `engineUnavailable` if it reports 0 channels or a 0 Hz sample rate (installing a tap on that format raises an uncatchable exception). Install the tap built by a `nonisolated static` factory (KTD3), start the engine, arm a 15 s cap timer.
2. `stop()`: wait the ~250 ms release tail, remove the tap, stop the engine, finish the stream and await its consumer so every yielded chunk is in the accumulator, deactivate the session, return the buffer.
3. Observe interruption, `AVAudioEngineConfigurationChange`, and media-services reset through the injected notification source; each emits `interrupted` on `events` and tears down in the same order. The cap timer emits `capReached`.

**Patterns to follow:** research dossier stop order (tap → engine → stream → session).

**Test scenarios:**
- The tap handler built by the static factory, invoked from a background `DispatchQueue`, converts a synthetic buffer without trapping (Swift 6 isolation proof).
- A synthetic interruption notification from the fake source emits `interrupted` and makes a later `stop()` return `nil`.
- The cap timer (injected short duration) emits `capReached` once.
- `start()` with the fake permission provider denied throws `permissionDenied` and the fake engine records no tap.
- A fake input format of 0 channels / 0 Hz makes `start()` throw `engineUnavailable` with no tap installed.
- Chunks yielded just before `stop()` appear in the returned buffer (tail drained).

**Verification:** compiles for device and simulator; all U2 tests run against fakes (none touch the real engine or permissions); live behavior checked in U5.

### U3. Permissions, model readiness, and no Stub on device

**Goal:** Capture can only start when it can succeed, and a denied permission can never produce a play.

**Requirements:** R4, R5.

**Dependencies:** none (parallel to U1/U2).

**Files:**
- `ios/Sources/Speech/SpeechReadiness.swift` (create): permission requests and `preloadAssets()` orchestration, readiness state.
- `ios/Sources/Speech/EngineSelector.swift` (modify): `UnavailableTranscriber` instead of Stub on device (KTD6).
- `ios/Sources/UI/NewGame/NewGameView.swift`, `ios/Sources/UI/App/AppState.swift` (modify): run readiness at game start, store it.
- `ios/Tests/T176ReadinessTests.swift` (create); `ios/Tests/AppleTranscriberTests.swift` (EngineSelector tests updated).

**Test scenarios:**
- Readiness with both permissions granted and model ready → `ready`.
- Mic denied → `micDenied`; press produces the mic message and no capture start.
- Model download failing (fake preload throws) → `modelPreparing`; a press shows the voice-model message and no capture; a later retry that succeeds → `ready`.
- Granting the mic in Settings (fake provider flips to granted) is picked up on the next press without a new game.
- `createGame` completes while the fake preload is still pending (New Game never waits for the model).
- Speech denied on device (selector forced to the device branch, fake authorization provider returning denied) → `UnavailableTranscriber`, never `StubTranscriber`; transcribing throws `permissionDenied`.
- Simulator default still resolves the Stub (existing behavior preserved).
- The facilitator WoZ path still uses the Stub in DEBUG builds; the panel and its branch do not exist in release (compile-time `#if DEBUG`, checked by building the Release configuration in the verification step).

**Verification:** tests pass; a code search of `TranscriberEngineSelector.resolve` and the press path finds no Stub construction outside `#if DEBUG`; `xcodebuild -configuration Release build` succeeds for the simulator.

### U4. Push-to-talk wiring and stuck-state guards

**Goal:** Press and release drive real capture, and every way out of listening returns to idle.

**Requirements:** R1, R2, R3, R5, R7.

**Dependencies:** U1, U3.

**Files:**
- `ios/Sources/UI/PushToTalk/PushToTalkView.swift` (modify): press → `start`, release → pipeline with `stop()`; scene-phase background → cancel.
- `ios/Sources/UI/App/AppState.swift` (modify): `captureFactory` injection, interrupted exit, messages.
- `ios/Tests/T157PushToTalkWiringTests.swift` (modify): the `makeAppState` helper injects a `FakeAudioCapture` that yields at least 0.5 s of synthetic PCM by default so existing tests keep their meaning; replace the empty-buffer test; update the too-short message test (the message no longer says capture is not wired).

**Approach:**
1. The press handler moves `pttState` out of idle synchronously, before awaiting `start()`; a per-gesture `consumed` flag set on cap/interruption blocks restarts until touch-up.
2. Only the press path calls `stop()`; the DEBUG facilitator path bypasses capture and readiness and keeps today's synthesized buffer for the Stub.
3. AppState observes the capture's `events` for the life of each capture.

**Test scenarios:**
- Fake capture with 1.2 s of synthetic PCM → the recording transcriber receives a buffer of 1.2 s, after `setContextualStrings(roster)`.
- Fake capture returns `nil` (interrupted) → state idle, "capture interrupted" message, transcriber never called.
- Scene phase to background mid-hold → capture stopped, state idle.
- Press while not ready → readiness message, no `start`.
- Release before `start` finishes → the capture is still stopped exactly once.
- A too-short capture (0.1 s) → the existing too-short message, state idle.
- Fake capture emits `capReached` while the finger is still down → the release pipeline runs once; further drag changes in the same gesture never call `start()` again.
- Fake capture emits `interrupted` while the finger is down → idle with the message; no transcriber call; no restart until touch-up.
- The press handler fired twice before the fake `start()` resumes → `start()` called exactly once.

**Verification:** `make ios-test` green; all existing PTT tests still pass.

### U5. Diagnostics, device checklist, and ADR

**Goal:** Evidence for the silent-scoring decision, and a record of the design.

**Requirements:** R8.

**Dependencies:** U2, U4.

**Files:**
- `ios/Sources/Speech/VoiceDiagnostics.swift` (create) per KTD7; hooks in `AppleTranscriber` and the pipeline.
- `docs/evaluations/2026-09-device-voice-checklist.md` (create): the human device run (build, permissions, 20 scripted utterances including roster names, export diagnostics, record confidence distribution and latency, label FIELD).
- `MANUAL-TESTING.md` (modify), `DECISIONS.md` (ADR-0019), `ios/Sources/Speech/Transcriber.swift` (modify the AudioBuffer format comment from "TBD").
- `ios/Tests/T176AudioCaptureTests.swift` (extend).

**Test scenarios:**
- A diagnostics record for a transcription contains only numeric fields and the reason enum; a test asserts no field contains the transcript text.
- A transcription whose base confidence is nil records the base leg as `unreported`, never 0.60.
- The DEBUG ring keeps the last 50 records and exports valid JSON.

**Verification:** tests pass; the checklist names every step a non-engineer needs.

---

## Verification Contract

- `make ios-test` (the CI `ios-build` hard gate): all tests green, including the new T176 suites.
- `bash scripts/check-no-raw-audio.sh` green with no allowlist change.
- `bash evals/runners/transcript-score.sh` and `bash evals/runners/voice-accuracy.sh` unchanged and green.
- `/ce-code-review` with the adversarial lens on the capture teardown order and the no-Stub-on-device rule.
- Device: the U5 checklist, run by the product owner.

## Definition of Done

- U1–U5 landed; CI fully green.
- Engine resolution never returns the Stub on a device; the facilitator panel exists only in DEBUG builds; readiness is re-read on every press.
- Privacy gate green, no allowlist entry, no audio or transcript text in any log.
- ADR-0019 merged; MANUAL-TESTING updated; #176 closed with the device checklist pending as the human step.
- No abandoned experimental code in the diff.
