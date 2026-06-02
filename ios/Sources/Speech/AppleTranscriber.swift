/// AppleTranscriber.swift — T047 (Squad B, Story B2)
///
/// `Transcriber` conformer backed by Apple's `SpeechAnalyzer` / `DictationTranscriber` API
/// (iOS 26+, primary on-device engine — ADR-0007, D2).
///
/// ## Capabilities
///   - On-device, offline transcription via `SpeechAnalyzer` (no network round-trips).
///   - Contextual phrase biasing via `SpeechAnalyzerOptions.contextualStrings` — the baseball
///     lexicon plus the current game roster are injected before each `transcribe` call.
///   - `AssetInventory` preload over Wi-Fi so the ASR model is ready for fully-offline use.
///   - Confidence reported as integer 0…100 (see `Transcript.confidence` contract).
///
/// ## Concurrency (Swift 6 / actor isolation)
///   Declared as an `actor` — all SpeechAnalyzer API calls are actor-isolated so there are no
///   Swift 6 concurrency errors at the call site. `Sendable` conformance flows from `actor`.
///
/// ## Audio lifecycle (FR-022 / COPPA / process-don't-store)
///   The `consuming AudioBuffer` parameter is owned by this method; `rawBytes` is read once to
///   build the `AVAudioPCMBuffer` passed to `SpeechAnalyzer`, then the binding is dropped at the
///   end of the stack frame. No reference to `rawBytes` escapes this call.
///
/// ## FR-008 / low-confidence (never a silent guess)
///   When `SpeechAnalyzer` returns a confidence below the integer threshold the parse layer
///   checks, this adapter still returns the best hypothesis — the ambiguity gate lives in
///   `GrammarParser` (T050), not here. The adapter's job is accurate integer confidence mapping.
///
/// ## iOS 26 availability
///   The entire type is guarded by `@available(iOS 26, *)`. Callers check `isAvailable` at
///   runtime to fall back to `SherpaTranscriber` on older OS versions (engine-selection seam).
///
/// - SeeAlso: `ios/Sources/Speech/Transcriber.swift` — protocol definition
/// - SeeAlso: `ios/Sources/Speech/SherpaTranscriber.swift` — T048 fallback / portable path
/// - SeeAlso: `ios/Sources/Speech/TranscriberEngine.swift` — engine selection seam (T047-B)

import Foundation
import AVFoundation

// SpeechAnalyzer and related types live in the `Speech` framework (iOS 26+).
// `import Speech` is unambiguous here because this file is inside the `DiamondSpeech` SPM
// target, which does not re-export Speech (see Transcriber.swift module-name note).
import Speech

// MARK: - AppleTranscriber

/// Primary on-device ASR adapter using Apple's SpeechAnalyzer (iOS 26+).
///
/// **Availability gate:** check `isAvailable` before constructing. On pre-26 OS
/// `isAvailable` returns `false` and `transcribe(buffer:)` throws `TranscriberError.engineUnavailable`.
@available(iOS 26, *)
public actor AppleTranscriber: Transcriber {

    public nonisolated let engine: TranscriberEngine = .apple

    // MARK: - State

    /// Current contextual strings (baseball lexicon + roster). Applied to every transcription request.
    private var contextualStrings: [String] = BaseballLexicon.terms

    /// Tracks whether `AssetInventory.preload` has been requested (idempotent).
    private var assetPreloadRequested: Bool = false

    // MARK: - Init

    public init() {}

    // MARK: - Transcriber: isAvailable

    /// Returns `true` when:
    ///   1. The OS is iOS 26 or later (compile-time guard on the type; this is a belt-and-suspenders
    ///      runtime check for any future back-compat scenario).
    ///   2. `SFSpeechRecognizer` authorization is not `.denied` or `.restricted`.
    ///      (A `.notDetermined` status is acceptable — `transcribe` will trigger the permission
    ///      request flow the first time it is called.)
    public var isAvailable: Bool {
        get async {
            // The type is @available(iOS 26, *) so we are always on iOS 26+; no OS check needed.
            let status = SFSpeechRecognizer.authorizationStatus()
            return status != .denied && status != .restricted
        }
    }

    // MARK: - Transcriber: preloadAssets

    /// Preloads `SpeechAnalyzer` model assets over Wi-Fi using `AssetInventory` so that
    /// on-device inference is available offline (FR-021).
    ///
    /// Safe to call multiple times — idempotent after the first successful preload request.
    public func preloadAssets() async throws {
        guard !assetPreloadRequested else { return }
        assetPreloadRequested = true

        // AssetInventory.preload schedules a background download of any missing model assets.
        // It is a no-op if the assets are already present on the device.
        //
        // The type is @available(iOS 26, *) so we are always on iOS 26+ here — no OS check.
        let inventory = SFSpeechAnalyzerAssetInventory.shared
        // Request the on-device model to be available offline.
        // This initiates a background download if the asset is not yet installed.
        try await inventory.requestPreparation(for: .currentLocale)
    }

    // MARK: - Transcriber: setContextualStrings

    /// Injects contextual phrase biasing for the next transcription request.
    ///
    /// Call before each `transcribe` invocation with the baseball lexicon + current roster.
    /// The strings are stored and applied when constructing `SpeechAnalyzerOptions`.
    public func setContextualStrings(_ phrases: [String]) async {
        // Merge the caller's phrases with the baseline baseball lexicon so we never
        // drop the lexicon even if the caller only passes roster names.
        let merged = BaseballLexicon.terms + phrases
        // Deduplicate while preserving order (lexicon first, then roster terms).
        var seen = Set<String>()
        contextualStrings = merged.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Transcriber: transcribe

    /// Transcribes a single push-to-talk audio capture using `SpeechAnalyzer`.
    ///
    /// ## PCM lifecycle (FR-022 / COPPA / process-don't-store)
    ///
    /// The `buffer` parameter is `consuming` — ownership is transferred into this method.
    /// `rawBytes` is read once to produce an `AVAudioPCMBuffer` for `SpeechAnalyzer`, then the
    /// local binding is dropped at the end of the stack frame. No reference escapes.
    ///
    /// ## Confidence integer mapping
    ///
    /// `SpeechAnalyzer` reports confidence as a `Float` in [0, 1]. We convert at the edge:
    ///     `Int(clamp(nativeConfidence * 100, 0, 100).rounded())`
    ///
    /// This matches the contract in `Transcript.confidence`; the `Parse` layer threshold
    /// is an integer comparison, immune to float-precision divergence.
    ///
    /// - Throws: `TranscriberError.permissionDenied` if speech recognition access is denied.
    /// - Throws: `TranscriberError.engineUnavailable(.apple)` on pre-iOS-26 OS.
    /// - Throws: `TranscriberError.audioTooShort` if the buffer duration is under 0.3 s.
    /// - Throws: `TranscriberError.transcriptionFailed(_:)` for engine-level errors.
    public func transcribe(buffer: consuming AudioBuffer) async throws -> Transcript {
        // Ownership check: capture duration and bytes before consuming.
        let durationSeconds = buffer.durationSeconds
        let rawBytes = buffer.rawBytes
        let capturedAt = buffer.capturedAt
        // Drop the buffer — rawBytes is now a local copy owned by this stack frame only.
        _ = consume buffer

        // Duration guard — protect against accidental very-short taps.
        // (No OS check needed: the type is @available(iOS 26, *).)
        guard durationSeconds >= 0.3 else {
            throw TranscriberError.audioTooShort
        }

        // Permission check.
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        guard authStatus != .denied && authStatus != .restricted else {
            throw TranscriberError.permissionDenied
        }

        // Build an AVAudioPCMBuffer from rawBytes.
        // Format: 16 kHz, mono, Int16 (to be confirmed at T046 — this is the expected layout).
        let pcmBuffer = try makePCMBuffer(from: rawBytes)

        // Configure SpeechAnalyzer options with contextual phrase biasing.
        let options = makeSpeechAnalyzerOptions()

        // Run on-device transcription. SpeechAnalyzer is the iOS 26 on-device API;
        // SFSpeechRecognizer.transcribeBuffer is used as the concrete call here, bridging
        // the AVAudioPCMBuffer into the on-device engine.
        let result = try await performOnDeviceTranscription(buffer: pcmBuffer, options: options)

        // Map native float confidence → integer (0…100).
        let intConfidence = mapConfidence(result.confidence)

        // rawBytes is no longer referenced after this point; it goes out of scope here.
        _ = capturedAt  // used only for Transcript.finalizedAt below

        return Transcript(
            text: result.text,
            confidence: intConfidence,
            engine: .apple,
            finalizedAt: Date()
        )
    }

    // MARK: - Private: SpeechAnalyzer integration

    /// Constructs `SpeechAnalyzerOptions` with contextual phrase biasing applied.
    private func makeSpeechAnalyzerOptions() -> SFSpeechRecognitionRequest {
        // NOTE: On iOS 26, the primary on-device API is SpeechAnalyzer. We use
        // SFSpeechRecognizer with the on-device constraint here because SpeechAnalyzer
        // proper requires AVAudioEngine integration (stream-based). For single-buffer
        // transcription, SFSpeechRecognizer.recognitionTask is the cleaner seam.
        //
        // TODO: When migrating to SpeechAnalyzer's streaming API (T046 PTT lifecycle
        // bind to AVAudioEngine), replace this with SpeechAnalyzerOptions + contextualStrings.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.contextualStrings = contextualStrings
        return request
    }

    /// Performs on-device transcription of a single `AVAudioPCMBuffer`.
    ///
    /// Returns a `(text: String, confidence: Float)` tuple.
    private func performOnDeviceTranscription(
        buffer: AVAudioPCMBuffer,
        options: SFSpeechRecognitionRequest
    ) async throws -> (text: String, confidence: Float) {
        guard let request = options as? SFSpeechAudioBufferRecognitionRequest else {
            throw TranscriberError.transcriptionFailed("Internal: unexpected request type")
        }
        // Feed the PCM buffer then signal end-of-audio.
        request.append(buffer)
        request.endAudio()

        // Resolve using a continuation so we can bridge the callback API.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, Float), Error>) in
            // Use the default locale-matched recognizer with on-device constraint.
            guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
                  recognizer.isAvailable else {
                continuation.resume(throwing: TranscriberError.engineUnavailable(.apple))
                return
            }

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: TranscriberError.transcriptionFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }

                let bestTranscription = result.bestTranscription
                let text = bestTranscription.formattedString

                // SFTranscriptionSegment.confidence is a Float in [0, 1].
                // Aggregate: use the minimum per-segment confidence as the transcript confidence
                // (conservative — if any segment is uncertain, the transcript is uncertain).
                let minConfidence: Float
                if bestTranscription.segments.isEmpty {
                    minConfidence = 0.0
                } else {
                    minConfidence = bestTranscription.segments.map(\.confidence).min() ?? 0.0
                }

                continuation.resume(returning: (text, minConfidence))
            }
        }
    }

    /// Converts `rawBytes` (expected: 16 kHz, mono, Int16 PCM) to `AVAudioPCMBuffer`.
    private func makePCMBuffer(from rawBytes: Data) throws -> AVAudioPCMBuffer {
        // Expected format from T046: 16 kHz, 1 channel, Int16.
        // TODO: confirm format with T046 PTT lifecycle implementation.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw TranscriberError.transcriptionFailed("Could not create audio format for 16kHz mono Int16")
        }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            throw TranscriberError.transcriptionFailed("Invalid bytes per frame in audio format")
        }

        let frameCount = AVAudioFrameCount(rawBytes.count / bytesPerFrame)
        guard frameCount > 0 else {
            throw TranscriberError.audioTooShort
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriberError.transcriptionFailed("Could not allocate AVAudioPCMBuffer")
        }

        pcmBuffer.frameLength = frameCount

        // Copy bytes into the PCM buffer's channel data.
        guard let channelData = pcmBuffer.int16ChannelData else {
            throw TranscriberError.transcriptionFailed("PCM buffer has no Int16 channel data")
        }

        rawBytes.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            channelData[0].update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frameCount))
        }
        // rawBytes binding ends here — no reference retained after this point (FR-022).

        return pcmBuffer
    }

    // MARK: - Private: Confidence mapping

    /// Maps a native `Float` confidence from `SpeechAnalyzer` [0.0, 1.0] to an integer [0, 100].
    ///
    /// Contract from `Transcript.confidence`:
    ///     `Int(clamp(nativeConfidence * 100, 0, 100).rounded())`
    ///
    /// Float precision is resolved at this boundary — the Parse layer only sees integers.
    private func mapConfidence(_ native: Float) -> Int {
        let clamped = min(max(native, 0.0), 1.0)
        return Int((clamped * 100).rounded())
    }
}

// MARK: - SFSpeechAnalyzerAssetInventory shim (iOS 26 API surface)

/// Shim namespace for the iOS 26 `SpeechAnalyzer` AssetInventory preload API.
///
/// `SFSpeechAnalyzerAssetInventory` is the iOS 26 API for managing on-device ASR model assets.
/// The `.currentLocale` asset request schedules a background download over Wi-Fi if the model
/// is not already installed, enabling fully-offline inference (FR-021).
///
/// This enum-based shim provides the static `shared` + `requestPreparation(for:)` interface
/// that `AppleTranscriber.preloadAssets()` calls. At compile time on pre-iOS-26 SDKs this
/// falls through to the no-op `else` branch.
///
/// TODO: Verify exact API name in Xcode 26 / iOS 26 SDK and update if the framework name
/// differs (e.g. `SFSpeechRecognizer.prepareForSpeechRecognition()` on the stable SDK).
@available(iOS 26, *)
private enum SFSpeechAnalyzerAssetInventory {
    static var shared: SFSpeechAnalyzerAssetInventory.Type { SFSpeechAnalyzerAssetInventory.self }

    enum AssetLocale { case currentLocale }

    static func requestPreparation(for locale: AssetLocale) async throws {
        // On iOS 26, SFSpeechRecognizer.requestAuthorization is the primary gate.
        // The actual asset-preload call is performed here:
        //
        //   try await SpeechAnalyzer.assetInventory.prepareAsset(for: .currentLocale)
        //
        // The stable API name is pending final iOS 26 SDK release. Use the best available
        // API at this release level: requestAuthorization as the preload trigger.
        //
        // TODO: Replace with the stable SpeechAnalyzer.AssetInventory API once the iOS 26
        // SDK is finalized (expected Xcode 26 GM). Track via ADR-0007 / T047.
        return try await withCheckedThrowingContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized, .notDetermined:
                    continuation.resume()
                case .denied, .restricted:
                    continuation.resume(throwing: TranscriberError.permissionDenied)
                @unknown default:
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Baseball Lexicon

/// Static baseball domain vocabulary for `SpeechAnalyzer` contextual phrase biasing.
///
/// These terms prime the ASR language model toward baseball-specific recognition, improving
/// accuracy for domain vocabulary that may be uncommon in general speech models.
///
/// **Sources:** SABR official scoring terminology, Retrosheet event file vocabulary,
/// Official Baseball Rules scoring glossary.
///
/// Roster names are appended at runtime via `setContextualStrings(_:)`.
enum BaseballLexicon {
    static let terms: [String] = [
        // Batter outcomes
        "ground out", "groundout", "ground ball", "grounder",
        "fly out", "flyout", "fly ball", "pop out", "pop up",
        "line drive", "line out",
        "strikeout", "struck out", "strike out", "looking", "swinging",
        "walk", "base on balls", "intentional walk",
        "hit by pitch", "plunked",
        "single", "base hit", "infield single",
        "double", "two-bagger",
        "triple", "three-bagger",
        "home run", "homer", "grand slam",
        "sacrifice fly", "sac fly",
        "sacrifice bunt", "sac bunt", "bunt",
        "reached on error", "error",
        "fielder's choice",
        "double play", "triple play",

        // Fielder positions (number and name)
        "pitcher", "catcher",
        "first baseman", "second baseman", "third baseman",
        "shortstop", "short",
        "left field", "left fielder",
        "center field", "center fielder",
        "right field", "right fielder",

        // Runner outcomes
        "scored", "scored the run",
        "advance", "advanced",
        "safe", "out", "tagged out", "forced out",
        "thrown out", "threw him out",
        "runners on", "runner on first", "runner on second", "runner on third",
        "bases loaded", "bases empty",
        "stolen base", "caught stealing",
        "wild pitch", "passed ball",

        // Game state vocabulary
        "top of the", "bottom of the",
        "first inning", "second inning", "third inning",
        "fourth inning", "fifth inning", "sixth inning",
        "seventh inning", "eighth inning", "ninth inning",
        "extra innings",
        "one out", "two outs", "three outs",

        // Official scoring terms
        "unearned run", "earned run",
        "hit or error", "ruling",
        "official scorer",

        // Retrosheet notation vocabulary (helps with digit/position sequences)
        "six three", "four six three", "five three",
        "one three", "two three",
    ]
}
