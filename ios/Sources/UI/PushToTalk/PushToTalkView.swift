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
///   The whole flow lives in `PushToTalkPipeline` so tests drive it without SwiftUI.
///
/// Honest status of voice: live microphone capture (T046) is NOT wired yet. The pipeline still
/// synthesizes an EMPTY `AudioBuffer`; the Stub ignores it, a real engine rejects it with
/// `TranscriberError.audioTooShort`, which is surfaced as a visible error — never silence.
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

    // The WoZ script selector (facilitator-only, behind a long-press gesture). It also selects
    // which canned transcript the Stub engine plays for a normal press in the simulator.
    @State private var showWoZPanel: Bool = false
    @State private var wozScript: WoZScript = .groundOut63

    var body: some View {
        VStack(spacing: 16) {
            statusLabel
            pttButton
            // WoZ reveal gesture (long-press on status label for demo facilitation)
                .confirmationDialog("WoZ Script", isPresented: $showWoZPanel, titleVisibility: .visible) {
                    ForEach(WoZScript.allCases, id: \.self) { script in
                        Button(script.displayName) {
                            wozScript = script
                            triggerPlay(script: script, facilitatorScripted: true)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
        }
        .padding(.horizontal, 24)
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
        .onLongPressGesture(minimumDuration: 1.5) {
            // Reveal WoZ facilitator panel on 1.5s long-press of status label (hidden feature).
            showWoZPanel = true
        }
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
                .onChanged { _ in
                    if appState.pttState == .idle {
                        startListening()
                    }
                }
                .onEnded { _ in
                    if appState.pttState == .listening {
                        stopListening()
                    }
                }
        )
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

    private func startListening() {
        guard appState.activeGame != nil else {
            appState.presentedSheet = .newGame
            return
        }
        // Guard: cannot start PTT with a pending unconfirmed/unjudged entry.
        if let game = appState.activeGame, game.pendingResult != nil {
            appState.presentedError = AppState.AppError(
                message: "Confirm or resolve the current play before recording a new one."
            )
            return
        }
        appState.pttState = .listening
    }

    private func stopListening() {
        // Release → processing → the live pipeline (engine resolved per capture, R21).
        appState.pttState = .processing
        triggerPlay(script: wozScript, facilitatorScripted: false)
    }

    private func triggerPlay(script: WoZScript, facilitatorScripted: Bool) {
        let appState = self.appState
        Task {
            await PushToTalkPipeline.score(
                script: script, facilitatorScripted: facilitatorScripted, appState: appState)
        }
    }
}

// MARK: - PushToTalkPipeline (one utterance, end to end — DL-157 R21/R22)

/// The push-to-talk scoring flow, factored out of the view so `T157PushToTalkWiringTests` can
/// drive it with a recording fake `Transcriber` and assert the call order without SwiftUI:
///
///     resolve engine → setContextualStrings(activeRoster) → transcribe → parse(roster:) → core
///
/// Everything here mutates `AppState` on the main actor exactly as the view did before.
@MainActor
enum PushToTalkPipeline {

    /// Scores one utterance, resolving the engine first.
    ///
    /// - Parameters:
    ///   - script: the WoZ script the Stub engine plays (real engines ignore it).
    ///   - facilitatorScripted: `true` when the hidden WoZ panel chose the script — the canned
    ///     `StubTranscriber` is used directly so the facilitator demo works on a device where the
    ///     selector would otherwise pick Apple. `false` for a real press-and-release, which goes
    ///     through `appState.transcriberFactory` (the selector in production).
    static func score(script: WoZScript, facilitatorScripted: Bool = false, appState: AppState) async {
        let transcriber: any Transcriber = facilitatorScripted
            ? StubTranscriber(script: script)
            : await appState.transcriberFactory(script)
        await score(with: transcriber, script: script, appState: appState)
    }

    /// Scores one utterance with an already-resolved engine.
    static func score(with transcriber: any Transcriber, script: WoZScript, appState: AppState) async {
        // Capture (T046) is still absent: the buffer is synthesized and EMPTY. The Stub ignores
        // it; a real engine throws `audioTooShort`, surfaced below as a visible error (FR-008:
        // never a silent drop). FR-022 is honoured trivially — there are no bytes to retain.
        let buffer = AudioBuffer(
            rawBytes: Data(),
            durationSeconds: 1.0,
            capturedAt: Date()
        )
        // Snapshot once so the engine and the parser see the same roster (R21 + R22).
        let roster = appState.activeRoster

        do {
            // R21: the active game's roster reaches the engine before EVERY transcribe.
            await transcriber.setContextualStrings(roster)
            let transcript = try await transcriber.transcribe(buffer: consume buffer)

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
            return "No audio was captured — the recording was empty or too short. Live microphone "
                + "capture isn't wired up yet, so speech can't be recognized on this build; use the "
                + "facilitator script (long-press the status label) or manual entry."
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
