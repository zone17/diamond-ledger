/// PushToTalkView.swift — T052 (Squad B, Story B4)
///
/// Hold-to-talk (PTT) control: idle → listening → processing → result.
///
/// States map 1:1 to `AppState.PTTState`:
///   .idle       — large mic button, invite to press
///   .listening  — button changes to "stop" indicator + mic wave animation, recording live
///   .processing — spinner, mic released, ASR/parse in flight
///   .result     — card sheet appears (driven by AppState); button resets to idle
///
/// Engine wiring (DL-157 R21):
///   A press-and-release resolves its `Transcriber` through `AppState.transcriberFactory`
///   (production: `TranscriberEngineSelector.resolve` — the WoZ `StubTranscriber` in the
///   simulator, `AppleTranscriber` on an iOS-26 device), hands it the active game's roster via
///   `setContextualStrings` immediately before EVERY `transcribe`, and parses with the same
///   roster (`GrammarParser.parse(_:roster:)`, R22). The hidden facilitator panel (1.5 s
///   long-press on the status label) still drives the canned `StubTranscriber` directly, so the
///   Wizard-of-Oz demo keeps working on a device where the selector would pick a real engine.
///   The panel, its reveal gesture, and that Stub branch are compiled into DEBUG builds only
///   (DL-176 KTD6 / A5).
///   The whole flow lives in `PushToTalkPipeline` so tests drive it without SwiftUI.
///
/// Microphone capture (DL-176 U4):
///   Touch-down re-reads voice readiness and starts a fresh `AudioCaptureSource` from
///   `AppState.captureFactory`; touch-up stops it and hands the 16 kHz buffer to the engine. The
///   state leaves `.idle` synchronously on touch-down, so a second press never starts a second
///   capture. Every way out of `.listening` returns to `.idle` with a visible reason: not ready,
///   start failure, a cap (treated as a release), an interruption, or the app leaving the
///   foreground. One touch is one press — drags after a cap or interruption never restart
///   capture until the finger lifts. The facilitator panel bypasses capture and readiness.
///
/// Audio lifecycle (FR-022 / COPPA / process-don't-store):
///   The protocol ensures raw PCM is consumed and released immediately after the
///   transcription callback fires. No audio is written to disk. The `consuming`
///   parameter annotation on `Transcriber.transcribe(buffer:)` makes this compiler-
///   enforced; `StubTranscriber` honours the contract trivially (no real audio).
///
/// - SeeAlso: `ios/Sources/Speech/Transcriber.swift` — protocol + `AudioBuffer`
/// - SeeAlso: `ios/Sources/Speech/EngineSelector.swift` — engine resolution seam
/// - SeeAlso: `ios/Sources/Speech/StubTranscriber.swift` — WoZ stub engine
/// - SeeAlso: `ios/Sources/Parse/GrammarParser.swift` — parse layer consumer

import SwiftUI
import DiamondSpeech
import Parse
import Core

struct PushToTalkView: View {
    @Environment(AppState.self) private var appState

    // The WoZ script selected for the Stub engine. In DEBUG builds the facilitator panel (behind a
    // long-press) changes it; it also selects which canned transcript the Stub plays for a normal
    // press in the simulator. Real engines ignore it.
    @State private var wozScript: WoZScript = .groundOut63

    // True while a finger is on the button. `@GestureState` resets even when the gesture is
    // cancelled (the button disabling mid-hold, the app backgrounding), so a touch-up is never lost.
    @GestureState private var isTouching = false
    @Environment(\.scenePhase) private var scenePhase

#if DEBUG
    // DL-176 KTD6 / A5: the Wizard-of-Oz facilitator panel exists in DEBUG builds only — a
    // release build cannot fabricate a play from a canned transcript.
    @State private var showWoZPanel: Bool = false
#endif

    var body: some View {
        VStack(spacing: 16) {
            statusLabel
            pttButton
#if DEBUG
            // WoZ reveal gesture (long-press on status label for demo facilitation)
                .confirmationDialog("WoZ Script", isPresented: $showWoZPanel, titleVisibility: .visible) {
                    ForEach(WoZScript.allCases, id: \.self) { script in
                        Button(script.displayName) {
                            wozScript = script
                            triggerFacilitatorPlay(script: script)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
#endif
        }
        .padding(.horizontal, 24)
        .onChange(of: scenePhase) { _, phase in
            PushToTalkPipeline.scenePhaseChanged(phase, appState: appState)
        }
    }

    // MARK: - Status label

    private var statusLabel: some View {
        Group {
            switch appState.pttState {
            case .idle:
                Text("Hold to score a play")
                    .foregroundStyle(.secondary)
            case .listening:
                Text("Listening…")
                    .foregroundStyle(.tint)
            case .processing:
                Text("Processing…")
                    .foregroundStyle(.secondary)
            case .result:
                Text("Ready")
                    .foregroundStyle(.green)
            }
        }
        .font(.subheadline)
        .animation(.easeInOut, value: appState.pttState)
#if DEBUG
        .onLongPressGesture(minimumDuration: 1.5) {
            // Reveal WoZ facilitator panel on 1.5s long-press of status label (DEBUG only).
            showWoZPanel = true
        }
#endif
    }

    // MARK: - PTT button

    private var pttButton: some View {
        let isListening = appState.pttState == .listening
        let isProcessing = appState.pttState == .processing

        return ZStack {
            Circle()
                .fill(buttonFill)
                .frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                .scaleEffect(isListening ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isListening)

            if isProcessing {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .animation(.easeInOut(duration: 0.15), value: isListening)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isTouching) { _, touching, _ in touching = true }
        )
        .onChange(of: isTouching) { _, touching in
            if touching {
                PushToTalkPipeline.touchDown(script: wozScript, appState: appState)
            } else {
                PushToTalkPipeline.touchUp(appState: appState)
            }
        }
        .disabled(appState.pttState == .processing || appState.pttState == .result)
        .accessibilityLabel(isListening ? "Stop recording" : "Start recording")
        .accessibilityHint("Hold to record a play")
    }

    private var buttonFill: Color {
        switch appState.pttState {
        case .idle:       return .accentColor
        case .listening:  return .red
        case .processing: return .secondary
        case .result:     return .green
        }
    }

    // MARK: - Actions

#if DEBUG
    /// DEBUG-only facilitator path: plays the chosen canned script through the Stub.
    private func triggerFacilitatorPlay(script: WoZScript) {
        let appState = self.appState
        Task {
            await PushToTalkPipeline.scoreFacilitatorScript(script, appState: appState)
        }
    }
#endif
}

// MARK: - PTTPress (one press, touch-down to transcript)

/// One press of the mic button (DL-176 U4). Identity (`===` against `AppState.currentPress`) is
/// how every async step checks that its press is still the live one: a press replaced, cancelled
/// or already handed off is left alone.
@MainActor
final class PTTPress {
    /// The WoZ script the Stub plays for this press (real engines ignore it).
    let script: WoZScript
    /// Readiness check + `start()`. The release path awaits it, so `stop()` never overtakes
    /// `start()` and runs exactly once.
    var startTask: Task<Void, Never>?
    /// Set once readiness passed and the factory built this press's capture.
    var capture: (any AudioCaptureSource)?
    /// Set by the first release (touch-up or cap); later releases are no-ops.
    var released = false

    init(script: WoZScript) {
        self.script = script
    }
}

// MARK: - PushToTalkPipeline (one utterance, end to end — DL-157 R21/R22)

/// The push-to-talk flow, factored out of the view so tests drive it without SwiftUI:
///
///     touchDown → readiness → capture.start()
///     touchUp (or cap) → capture.stop() → resolve engine → setContextualStrings(activeRoster)
///         → transcribe → parse(roster:) → core
///
/// Everything here mutates `AppState` on the main actor. The functions that start async work
/// return its `Task` so tests can await it with a bound; the view ignores them.
@MainActor
enum PushToTalkPipeline {

    // MARK: Touch

    /// A finger landed on (or dragged within) the mic button. Only the first call of a touch
    /// presses; the rest are ignored until `touchUp`, so a capture ended by a cap or interruption
    /// never restarts while the finger is still down (plan U4).
    @discardableResult
    static func touchDown(script: WoZScript, appState: AppState) -> Task<Void, Never>? {
        guard !appState.pttTouchActive else { return nil }
        appState.pttTouchActive = true
        return press(script: script, appState: appState)
    }

    /// The finger lifted (or the gesture was cancelled): release the press, if one is live.
    @discardableResult
    static func touchUp(appState: AppState) -> Task<Void, Never>? {
        appState.pttTouchActive = false
        guard let press = appState.currentPress else { return nil }
        return release(press, appState: appState)
    }

    /// Scene phase: leaving the foreground ends a held capture and discards it (R3); becoming
    /// active re-reads readiness so access granted in Settings counts at once (R4).
    @discardableResult
    static func scenePhaseChanged(_ phase: ScenePhase, appState: AppState) -> Task<Void, Never>? {
        switch phase {
        case .background:
            guard let press = appState.currentPress, !press.released else { return nil }
            return cancel(press, message: AppState.interruptionMessage(for: .background), appState: appState)
        case .active:
            return Task { _ = await appState.refreshVoiceReadiness() }
        default:
            return nil
        }
    }

    // MARK: Press

    /// Starts one press: leaves `.idle` synchronously (so a second press is ignored), then checks
    /// readiness and starts a fresh capture. Returns the start task, or `nil` if nothing started.
    @discardableResult
    static func press(script: WoZScript, appState: AppState) -> Task<Void, Never>? {
        guard appState.pttState == .idle else { return nil }
        guard appState.activeGame != nil else {
            appState.presentedSheet = .newGame
            return nil
        }
        // Guard: cannot start PTT with a pending unconfirmed/unjudged entry.
        if appState.activeGame?.pendingResult != nil {
            appState.presentedError = AppState.AppError(
                message: "Confirm or resolve the current play before recording a new one."
            )
            return nil
        }
        // A stale press (its state reset elsewhere) must not keep a microphone open.
        if let stale = appState.currentPress {
            appState.currentPress = nil
            discardCapture(of: stale)
        }
        appState.pttState = .listening
        let press = PTTPress(script: script)
        appState.currentPress = press
        let task = Task { await begin(press, appState: appState) }
        press.startTask = task
        return task
    }

    /// Readiness, then capture start, then the event watch for the life of the capture.
    private static func begin(_ press: PTTPress, appState: AppState) async {
        // R4/R5: re-read live permission and model status on every press; never capture when a
        // capture cannot succeed.
        let readiness = await appState.refreshVoiceReadiness()
        guard appState.currentPress === press else { return }
        guard readiness == .ready else {
            abandon(press, message: AppState.readinessMessage(for: readiness) ?? "", appState: appState)
            return
        }

        let capture = appState.captureFactory()
        press.capture = capture
        do {
            try await capture.start()
        } catch {
            abandon(press, message: startFailureMessage(for: error), appState: appState)
            return
        }
        // Cancelled while starting (the app backgrounded): whoever cancelled stops the capture.
        guard appState.currentPress === press else { return }

        let events = capture.events
        Task {
            for await event in events {
                switch event {
                case .capReached:
                    // R2: the cap is a release, even with the finger still down.
                    release(press, appState: appState)
                case .interrupted(let reason):
                    // R3: audio already discarded by the source; idle with the reason.
                    abandon(press, message: AppState.interruptionMessage(for: reason), appState: appState)
                }
            }
        }
    }

    // MARK: Release

    /// Ends the capture and scores its audio. The first release of a press wins; `stop()` waits
    /// for `start()` so a release during start still stops exactly once.
    @discardableResult
    private static func release(_ press: PTTPress, appState: AppState) -> Task<Void, Never>? {
        guard appState.currentPress === press, !press.released else { return nil }
        press.released = true
        appState.pttState = .processing
        return Task {
            await press.startTask?.value
            // A start that failed or was cancelled has already been reported.
            guard appState.currentPress === press, let capture = press.capture else { return }
            // stop() and transcribe share this task: the ~Copyable buffer never crosses a Task.
            guard let buffer = await capture.stop() else {
                abandon(press, message: AppState.captureInterruptedMessage, appState: appState)
                return
            }
            guard appState.currentPress === press else { return }
            appState.currentPress = nil
            let transcriber = await appState.transcriberFactory(press.script)
            await score(with: transcriber, buffer: buffer, script: press.script, appState: appState)
        }
    }

    // MARK: Exits without a transcript

    /// Returns a live press to idle with a visible reason. Nothing is transcribed.
    private static func abandon(_ press: PTTPress, message: String, appState: AppState) {
        guard appState.currentPress === press else { return }
        appState.currentPress = nil
        appState.pttState = .idle
        appState.presentedError = AppState.AppError(message: message)
    }

    /// `abandon`, and also stop the capture and drop its audio (the source is still running).
    private static func cancel(_ press: PTTPress, message: String, appState: AppState) -> Task<Void, Never> {
        abandon(press, message: message, appState: appState)
        return discardCapture(of: press)
    }

    /// Stops `press`'s capture once its start settles and drops the buffer unread (FR-022).
    @discardableResult
    private static func discardCapture(of press: PTTPress) -> Task<Void, Never> {
        Task {
            await press.startTask?.value
            if let capture = press.capture {
                _ = await capture.stop()
            }
        }
    }

    /// Why a capture did not start. A denied microphone reads as the readiness message.
    static func startFailureMessage(for error: Error) -> String {
        if case TranscriberError.permissionDenied = error {
            return AppState.readinessMessage(for: .micDenied) ?? ""
        }
        return "The microphone couldn't start — no audio input is available right now. "
            + "You can keep scoring with manual entry."
    }

    // MARK: Scoring

#if DEBUG
    /// DEBUG-only facilitator path (DL-176 KTD6): the canned `StubTranscriber` plays `script`
    /// with a synthesized buffer, bypassing capture and readiness, so the Wizard-of-Oz demo works
    /// on a device where the selector would pick Apple. The only Stub construction on the PTT
    /// path; compiled out of release builds.
    static func scoreFacilitatorScript(_ script: WoZScript, appState: AppState) async {
        let buffer = DiamondSpeech.AudioBuffer(rawBytes: Data(), durationSeconds: 1.0, capturedAt: Date())
        await score(with: StubTranscriber(script: script), buffer: buffer, script: script, appState: appState)
    }
#endif

    /// Scores one captured utterance with an already-resolved engine.
    static func score(with transcriber: any Transcriber, buffer: consuming DiamondSpeech.AudioBuffer,
                      script: WoZScript, appState: AppState) async {
        // Snapshot once so the engine and the parser see the same roster (R21 + R22).
        let roster = appState.activeRoster

        do {
            // R21: the active game's roster reaches the engine before EVERY transcribe.
            await transcriber.setContextualStrings(roster)
            let transcript = try await transcriber.transcribe(buffer: consume buffer)
            // DL-176 U5: diagnostics hook — record capture duration and release-to-transcript
            // latency here (numbers only; never audio or transcript text).

            // Grammar parse: Transcript → NormalizedPlay, with roster names masked (R22).
            let parser = GrammarParser()
            let facts: [String: String]
            do {
                facts = try parser.parse(transcript, roster: roster)
            } catch ParseError.outOfGrammar {
                guard transcript.engine == .stub else {
                    // A REAL engine's out-of-grammar transcript goes to manual entry with the
                    // words the scorer can see (FR-017) — never the WoZ canned facts, which would
                    // record a play nobody said (Article VII).
                    appState.pttState = .idle
                    appState.presentedSheet = .manualEntry(prefilledTranscript: transcript.text)
                    return
                }
                // Stub/WoZ fallback: use the script's canned facts. For groundOut63 that's a
                // deterministic ground out (Card A); for misplayedGrounder it's the
                // ["script": "misplayed-grounder"] marker (Card B). NOTE: in practice this branch
                // rarely fires for the two demo scripts — both canned transcripts DO parse (the
                // misplayed-grounder transcript contains "grounder", so GrammarParser.tryGroundout
                // matches and returns a plain groundout). So live WoZ "Misplayed grounder"
                // currently produces Card A, NOT Card B — the "misplayed" signal is dropped by the
                // v1 grammar. Fact-derived Card B IS reachable via a "reached on error" transcript
                // (FactBridge maps reached_on_error → the HitVsError pattern). Routing "misplayed"
                // transcripts to that path is grammar work tracked in issue #151 (out of this PR's lane).
                facts = script.normalizedFacts
            } catch ParseError.ambiguous(let candidates) {
                // Ambiguous: surface clarifying question.
                let items = candidates.prefix(3).map {
                    ClarifyCandidate(label: $0["batter_result"] ?? "Play", facts: $0)
                }
                appState.pttState = .idle
                appState.presentedSheet = .clarify(candidatePlays: Array(items))
                return
            }

            // Forward to the core.
            await appState.recordPlay(facts: facts)

        } catch {
            appState.pttState = .idle
            appState.presentedError = AppState.AppError(message: message(for: error))
        }
    }

    /// User-facing text for a failed capture/transcription. `TranscriberError` has no
    /// `LocalizedError` conformance, so its cases are spelled out here rather than shown as an
    /// opaque "operation couldn't be completed" — the scorer must be able to tell WHY nothing
    /// was scored (FR-008 / Article VII: a visible reason, never silence).
    static func message(for error: Error) -> String {
        switch error {
        case TranscriberError.audioTooShort:
            return "No audio was captured — the recording was empty or too short. Hold the button "
                + "while you say the play, then let go; or use manual entry."
        case TranscriberError.permissionDenied:
            return "Speech recognition permission is denied. Allow it in Settings to score by voice."
        case TranscriberError.engineUnavailable(let engine):
            return "The \(engine.rawValue) speech engine isn't available on this device."
        case TranscriberError.transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        default:
            return "Recording error: \(error.localizedDescription)"
        }
    }
}

// WoZScript is defined in ios/Sources/Speech/StubTranscriber.swift (DiamondSpeech module).
// It is accessible here because the UI target depends on DiamondSpeech.
