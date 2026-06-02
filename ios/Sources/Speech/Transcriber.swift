/// Transcriber.swift — T003 / T046 (Squad B, Story B2)
///
/// SwiftPM module name: `DiamondSpeech` (not `Speech`) to avoid shadowing Apple's
/// system `Speech.framework`. Conformers in `AppleTranscriber.swift` (T047) must
/// `import Speech` (system) directly — that import is unambiguous because the conformer
/// file lives inside the `DiamondSpeech` target which does not itself re-export `Speech`.
///
/// `Transcriber` protocol: the single abstraction over the two ASR engines (ADR-0007, D2).
///
/// **Two conformers** (both TODO at their respective tasks):
///   - `AppleTranscriber` (T047) — `SpeechAnalyzer` / `DictationTranscriber` (iOS 26+),
///     contextual phrase biasing with the baseball lexicon + roster,
///     `AssetInventory` preload-over-Wi-Fi.
///   - `SherpaTranscriber` (T048) — sherpa-onnx / Parakeet portable adapter
///     (fallback path on iOS pre-26; primary path on Android fast-follow).
///
/// **Audio lifecycle contract (FR-022 / COPPA / process-don't-store):**
///   - Raw PCM audio buffers MUST be released immediately after the transcription callback fires.
///   - No audio file is written to disk. No audio leaves the device.
///   - The `AudioBuffer` type passed to `transcribe(buffer:)` is consumed (ownership transferred);
///     the conformer must not retain a reference after returning.
///
/// **Min iOS floor**: iOS 26 is required for `SpeechAnalyzer` (primary engine). The fallback
/// path via `SherpaTranscriber` supports earlier OS versions but is NOT the primary path.
/// See `Package.swift` for the platform constraint and ADR-0007 for the decision record.
///
/// - SeeAlso: `ios/Sources/Speech/AppleTranscriber.swift` (T047)
/// - SeeAlso: `ios/Sources/Speech/SherpaTranscriber.swift` (T048)
/// - SeeAlso: `ios/Sources/Parse/` (T049) — consumes `Transcript` produced here
/// - TODO: T046 — implement the full push-to-talk audio-buffer lifecycle.

import Foundation

// MARK: - Audio buffer

/// An opaque handle to a single push-to-talk audio capture.
///
/// Ownership: the caller transfers ownership to `Transcriber.transcribe(buffer:)`.
/// The conformer MUST release the underlying PCM data before returning (FR-022).
///
/// TODO: T046 — bind to AVAudioPCMBuffer or CMSampleBuffer; decide format (16 kHz mono Int16).
public struct AudioBuffer: Sendable {
    /// Opaque raw bytes — format TBD at T046 (16 kHz mono Int16 expected).
    public let rawBytes: Data
    /// Duration of the captured audio, in seconds.
    public let durationSeconds: Double
    /// Monotonic capture timestamp (used for correlation / audit trail, Art. XXIII).
    public let capturedAt: Date

    public init(rawBytes: Data, durationSeconds: Double, capturedAt: Date) {
        self.rawBytes = rawBytes
        self.durationSeconds = durationSeconds
        self.capturedAt = capturedAt
    }
}

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
    /// Engine-reported confidence in [0.0, 1.0]. Use for parse-ambiguity routing (T050).
    /// Note: fixed-point representation preferred internally (Art. VII / ADR-0007 no-float);
    /// this is a Swift-side convenience value only — never passed to the Rust core.
    public let confidence: Double
    /// Which engine produced this transcript.
    public let engine: TranscriberEngine
    /// Wall-clock time the transcript was finalized (audit / SC-005 latency measurement).
    public let finalizedAt: Date

    public init(text: String, confidence: Double, engine: TranscriberEngine, finalizedAt: Date) {
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
}

// MARK: - Transcriber errors

/// Errors that a `Transcriber` conformer may throw.
public enum TranscriberError: Error, Sendable {
    /// The ASR engine is not available (e.g. `SpeechAnalyzer` on pre-26 OS — use fallback).
    case engineUnavailable(TranscriberEngine)
    /// The capture was too short or silent to produce a transcript.
    case audioTooShort
    /// Transcription failed for an engine-specific reason.
    case transcriptionFailed(String)
    /// The user has not granted microphone / speech-recognition permission.
    case permissionDenied
}

// MARK: - Transcriber protocol

/// Abstracts the two ASR engines behind a single async interface.
///
/// Conformers: `AppleTranscriber` (T047), `SherpaTranscriber` (T048).
///
/// **Thread safety**: conformers MUST be `actor`-isolated or otherwise `Sendable`-safe (Swift 6).
///
/// **Audio lifecycle (FR-022)**: the `buffer` parameter is consumed; the conformer releases
/// the underlying PCM bytes before the method returns (no raw audio retained).
public protocol Transcriber: Sendable {

    /// The engine this conformer wraps.
    var engine: TranscriberEngine { get }

    /// Returns `true` if the engine is available on the current device and OS version.
    /// Callers use this to select the primary vs fallback engine at runtime.
    var isAvailable: Bool { get async }

    /// Transcribe a single push-to-talk capture.
    ///
    /// - Parameter buffer: Owned audio buffer (released by the conformer before returning).
    /// - Returns: `Transcript` with best-hypothesis text and confidence.
    /// - Throws: `TranscriberError` on failure.
    ///
    /// **Latency target (SC-005)**: median speak→rendered-card ≤3 s; transcription is the
    /// dominant term. Conformers SHOULD use on-device inference only (no network round-trips).
    func transcribe(buffer: consuming AudioBuffer) async throws -> Transcript

    /// Pre-load ASR model assets over Wi-Fi so on-device inference is ready offline (FR-021).
    /// Safe to call multiple times (idempotent). Progress is implementation-defined.
    /// - TODO: T047 — `AssetInventory` preload for `SpeechAnalyzer`.
    func preloadAssets() async throws

    /// Provide contextual phrase biasing — the baseball lexicon plus current roster names.
    /// Applied before the next `transcribe` call.
    /// - Parameter phrases: Domain-specific strings (positions, play phrases, player names).
    /// - TODO: T047 — `contextualStrings` on `SpeechAnalyzer`.
    func setContextualStrings(_ phrases: [String]) async
}
