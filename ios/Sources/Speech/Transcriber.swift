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
/// ## Ownership and PCM retention contract (FR-022 / COPPA / process-don't-store)
///
/// `AudioBuffer` is declared `~Copyable` (noncopyable) to make the ownership transfer to
/// `Transcriber.transcribe(buffer:)` **compiler-enforced**: the caller cannot retain a copy of
/// `rawBytes` after passing `buffer` because the `consuming` parameter annotation on
/// `transcribe(buffer:)` moves the value into the callee and invalidates the caller's binding.
///
/// Conformance checklist (enforced at T047 / T048 review gate):
///   - [ ] The conformer must NOT assign `buffer.rawBytes` to any `var`/`let` that outlives the
///         current stack frame (no closure captures, no `self.` storage, no `Task {}` captures).
///   - [ ] The conformer must deinit / zero the underlying buffer before returning (where the OS
///         API permits — AVAudioPCMBuffer zeroing is implementation-defined on iOS 26).
///   - [ ] The conformer must NOT pass `buffer` to a child `Task`/`async let` that may outlive
///         the `transcribe` call — doing so with a noncopyable type is a compile-time error,
///         which is intentional.
///
/// TODO: T046 — bind to AVAudioPCMBuffer or CMSampleBuffer; decide format (16 kHz mono Int16).
/// TODO: T047 — verify at conformer review that no retained copy of rawBytes escapes the frame.
/// `Sendable` (all stored properties — `Data`, `Double`, `Date` — are `Sendable`) so the
/// `~Copyable` buffer can be transferred into an `actor`-isolated `Transcriber` conformer
/// (e.g. `StubTranscriber`) across the async boundary without a Swift 6 concurrency error.
public struct AudioBuffer: ~Copyable, Sendable {
    /// Opaque raw bytes — format TBD at T046 (16 kHz mono Int16 expected).
    ///
    /// CONTRACT: conformers of `Transcriber` MUST NOT retain a reference to this `Data` value
    /// after `transcribe(buffer:)` returns. The `~Copyable` annotation on `AudioBuffer` makes
    /// the ownership transfer explicit at the call site; this comment states the byte-level
    /// obligation that the type system cannot fully enforce once `Data` (a reference type) is
    /// read from the struct.
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
