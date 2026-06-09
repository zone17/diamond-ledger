/// SpeechTypes.swift — platform-agnostic ASR value layer (DL-37).
///
/// These are the pure, engine-agnostic, Foundation-only value types that sit at the seam
/// between the ASR engines (`DiamondSpeech`, iOS-only) and the deterministic grammar parser
/// (`Parse`). They were extracted out of `DiamondSpeech/Transcriber.swift` so that `Parse`
/// (and the headless `dl-score` CLI, DL-37) can depend on `Transcript` WITHOUT pulling in the
/// iOS-26-only `SpeechAnalyzer` / `AVFoundation` engine code — restoring agent/CLI parity for
/// the scoring pipeline (Art. II / FR-018): the transcript→score path must be invokable off
/// the device, from a macOS CLI / CI / agent, not just from inside the iOS app.
///
/// `DiamondSpeech` re-exports these (`@_exported import SpeechTypes`) so existing
/// `import DiamondSpeech` consumers keep resolving `Transcript` / `TranscriberEngine`
/// unchanged. Nothing here may import an Apple framework other than `Foundation`.
///
/// - SeeAlso: `ios/Sources/Speech/Transcriber.swift` (the `Transcriber` protocol + engines)
/// - SeeAlso: `ios/Sources/Parse/GrammarParser.swift` (consumes `Transcript`)

import Foundation

// MARK: - Transcript

/// The output of a transcription pass: a best-hypothesis string plus a confidence signal.
///
/// The `Parse` layer (T049) consumes `Transcript` and produces a `NormalizedPlay`.
/// If `confidence` is below the parse layer's threshold, a clarifying question is surfaced
/// (T050 / FR-008) — never a silent guess.
///
/// TODO: T046 — extend with word-level timing / alternatives if `SpeechAnalyzer` exposes them.
public struct Transcript: Sendable {
    /// Best-hypothesis text from the ASR engine.
    public let text: String

    /// Engine-reported confidence as an integer in the range 0...100 (inclusive).
    ///
    /// ## Why integer, not float (ADR-0007 / Art. VII / FR-008)
    ///
    /// The FR-008 ambiguity threshold is a deterministic integer comparison (e.g. `confidence < 70`),
    /// not a cross-engine float comparison. Using an integer scale:
    ///   - Eliminates float-precision divergence between Apple `SpeechAnalyzer` and sherpa-onnx
    ///     when the two engines report the same logical confidence level differently (e.g. 0.699...
    ///     vs 0.700... for the same utterance quality).
    ///   - Keeps the seam integer-only, consistent with the Rust core boundary (I6/ADR-0007).
    ///   - Makes the ambiguity gate in `Parse` (T050) a simple `Int` comparison with no
    ///     floating-point epsilon concerns.
    ///
    /// **Engine adapter obligation**: each `Transcriber` conformer converts its native float
    /// confidence to this integer scale at the edge, before constructing `Transcript`:
    ///   - `AppleTranscriber` (T047): `Int(clamp(nativeConfidence * 100, 0, 100).rounded())`
    ///   - `SherpaTranscriber` (T048): same formula applied to the Parakeet posterior score.
    ///
    /// This value is a Swift-side signal only — it is never passed to the Rust core.
    public let confidence: Int  // 0...100

    /// Which engine produced this transcript.
    public let engine: TranscriberEngine
    /// Wall-clock time the transcript was finalized (audit / SC-005 latency measurement).
    public let finalizedAt: Date

    public init(text: String, confidence: Int, engine: TranscriberEngine, finalizedAt: Date) {
        precondition((0...100).contains(confidence), "Transcript.confidence must be 0...100; got \(confidence)")
        self.text = text
        self.confidence = confidence
        self.engine = engine
        self.finalizedAt = finalizedAt
    }
}

/// Identifies which ASR engine produced a `Transcript` (for observability / fallback audit).
public enum TranscriberEngine: String, Sendable, Codable {
    /// Apple `SpeechAnalyzer` / `DictationTranscriber` (iOS 26+, primary). T047.
    case apple
    /// sherpa-onnx / Parakeet portable (fallback / Android). T048.
    case sherpa
    /// Wizard-of-Oz / canned `StubTranscriber` — NOT a real ASR engine. Reported distinctly so
    /// observability never mistakes the stub/fallback path for real Apple recognition (ADR-0010).
    case stub
}

// MARK: - Confidence mapping (shared by all adapters)

/// Single shared conversion from a native float confidence/posterior in [0.0, 1.0] to the
/// integer 0…100 scale used at the `Transcript` boundary (see `Transcript.confidence`).
///
/// Both `AppleTranscriber` (SFSpeechRecognizer segment confidence) and `SherpaTranscriber`
/// (Parakeet posterior) use THIS one helper so the two engines can never diverge on rounding at
/// the `GrammarParser` integer threshold. Exposed `public` so unit tests can pin the boundaries
/// (0.0→0, 0.695→70, 0.705→71, 1.0→100).
///
/// Formula: `Int((clamp(native, 0, 1) * 100).rounded())` (banker's? no — `.rounded()` is
/// round-half-away-from-zero, so 0.705·100 = 70.5 → 71 and 0.695·100 = 69.499.. → 69; see the
/// boundary test for the exact float behaviour).
public enum ConfidenceMapping {
    /// Maps a native float confidence in [0.0, 1.0] to an integer percentage in [0, 100].
    public static func toInt(_ native: Float) -> Int {
        let clamped = min(max(native, 0.0), 1.0)
        return Int((clamped * 100.0).rounded())
    }
}
