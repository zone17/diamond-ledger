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
/// Engine wiring (this increment):
///   The real `Transcriber` protocol (T046) is wired here via `StubTranscriber` —
///   a simple manual-entry path that lets the demo drive Card A/B without real ASR.
///   Real `AppleTranscriber` / `SherpaTranscriber` (T047/T048) drop in at their tasks
///   behind the same `Transcriber` protocol; the PTT view does not change.
///
/// Audio lifecycle (FR-022 / COPPA / process-don't-store):
///   The protocol ensures raw PCM is consumed and released immediately after the
///   transcription callback fires. No audio is written to disk. The `consuming`
///   parameter annotation on `Transcriber.transcribe(buffer:)` makes this compiler-
///   enforced; `StubTranscriber` honours the contract trivially (no real audio).
///
/// - SeeAlso: `ios/Sources/Speech/Transcriber.swift` — protocol + `AudioBuffer`
/// - SeeAlso: `ios/Sources/Speech/StubTranscriber.swift` — stub engine (this increment)
/// - SeeAlso: `ios/Sources/Parse/GrammarParser.swift` — parse layer consumer

import SwiftUI
import DiamondSpeech
import Parse
import Core

struct PushToTalkView: View {
    @Environment(AppState.self) private var appState

    // For stub demo: the WoZ script selector (facilitator-only in production, behind a gesture).
    // The real Transcriber engine (AppleTranscriber/SherpaTranscriber) is injected at T047/T048.
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
                            triggerPlay(script: script)
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
        // For the stub engine: immediately advance to processing and dispatch the WoZ script.
        appState.pttState = .processing
        triggerPlay(script: wozScript)
    }

    private func triggerPlay(script: WoZScript) {
        Task {
            // Synthesize a stub AudioBuffer (no real audio in this increment — FR-022 honoured
            // trivially since StubTranscriber discards rawBytes immediately).
            let stubBuffer = AudioBuffer(
                rawBytes: Data(),
                durationSeconds: 1.0,
                capturedAt: Date()
            )

            do {
                // StubTranscriber converts the WoZ script to a canned Transcript.
                let stubTranscriber = StubTranscriber(script: script)
                let transcript = try await stubTranscriber.transcribe(buffer: consume stubBuffer)

                // Grammar parse: Transcript → NormalizedPlay.
                let parser = GrammarParser()
                let facts: [String: String]
                do {
                    facts = try parser.parse(transcript)
                } catch ParseError.outOfGrammar {
                    // Out-of-grammar fallback: use the WoZ script's canned facts. For groundOut63
                    // that's a deterministic ground out (Card A); for misplayedGrounder it's the
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
                appState.presentedError = AppState.AppError(
                    message: "Recording error: \(error.localizedDescription)"
                )
            }
        }
    }
}

// WoZScript is defined in ios/Sources/Speech/StubTranscriber.swift (DiamondSpeech module).
// It is accessible here because the UI target depends on DiamondSpeech.
