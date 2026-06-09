/// SherpaTranscriber.swift — T048 (Squad B, Story B2)
///
/// `Transcriber` conformer backed by sherpa-onnx / Parakeet (portable on-device ASR).
///
/// ## Purpose
/// This is the **fallback** engine for two scenarios:
///   1. **iOS pre-26**: `SpeechAnalyzer` / `DictationTranscriber` requires iOS 26+.
///      `SherpaTranscriber` runs on iOS 16+ and provides ASR on older devices.
///   2. **Android fast-follow / cross-platform reuse**: The sherpa-onnx runtime is portable
///      (C++ / Swift / Kotlin). The same adapter shape lands on Android by swapping the
///      model loading path; no protocol changes are needed.
///
/// ## Implementation status
///
/// The **adapter shape, protocol conformance, and engine-selection logic are complete and compile**.
/// The actual sherpa-onnx XCFramework integration is **STUBBED** behind a clearly-marked
/// `#if SHERPA_ONNX_ENABLED` compile flag because the framework binary is not part of this
/// repository (it must be fetched from https://github.com/k2-fsa/sherpa-onnx — see TODO below).
///
/// When the `SHERPA_ONNX_ENABLED` flag is absent (the default for this increment), the adapter:
///   - Reports `isAvailable == false` if the model bundle is missing.
///   - Reports `isAvailable == true` in simulator targets when explicitly set (test seam).
///   - Returns a **clearly-marked stub transcript** from `transcribe(buffer:)` so tests of the
///     *selection* and *ambiguity* logic can exercise this engine path without a real model.
///
/// ## Human handoff required
///
/// The following steps require a human with internet access and build tooling:
///   1. Download the sherpa-onnx iOS XCFramework from:
///          https://github.com/k2-fsa/sherpa-onnx/releases
///      Pin the version in `Package.swift` or add to `ios/Frameworks/` (see ADR-0007).
///   2. Download the Parakeet (or equivalent) ONNX model bundle and add to the Xcode target
///      as a bundle resource. The bundle path is `SherpaModelBundle.defaultBundleName` below.
///   3. Set `SHERPA_ONNX_ENABLED=1` in the Xcode build settings (or `Package.swift` swiftSettings).
///   4. Remove the stub path and wire the real `SherpaOnlineSpeechRecognizer` / offline recognizer.
///
/// ## Concurrency (Swift 6 / actor isolation)
///   Declared as an `actor` — all mutable state is actor-isolated. `Sendable` via `actor`.
///
/// ## Audio lifecycle (FR-022 / COPPA / process-don't-store)
///   `transcribe(buffer:)` consumes the `AudioBuffer`. `rawBytes` is read once (to pass to
///   the sherpa-onnx decode API), then the local binding drops at the end of the stack frame.
///   No raw audio is retained or persisted.
///
/// - SeeAlso: `ios/Sources/Speech/Transcriber.swift` — protocol definition
/// - SeeAlso: `ios/Sources/Speech/AppleTranscriber.swift` — T047 primary engine
/// - SeeAlso: `ios/Sources/Speech/EngineSelector.swift` — runtime selection seam
/// - SeeAlso: ADR-0007 — two-engine ASR architecture decision

import Foundation
import SpeechTypes

// MARK: - SherpaTranscriber

/// Fallback on-device ASR adapter using sherpa-onnx / Parakeet.
///
/// Works on iOS 16+ (Android fast-follow path). The actual sherpa-onnx XCFramework
/// integration is scaffolded but **stubbed** — see the file header for the handoff checklist.
public actor SherpaTranscriber: Transcriber {

    public nonisolated let engine: TranscriberEngine = .sherpa

    // MARK: - Configuration

    /// Describes the model bundle expected on the device.
    public struct ModelConfig: Sendable {
        /// The name of the model bundle resource (e.g. "parakeet-tdt-0.6b").
        /// The bundle must be added to the Xcode app target as a resource.
        public let bundleName: String
        /// Sample rate expected by the model (sherpa-onnx Parakeet: 16 000 Hz).
        public let sampleRate: Int
        /// Beam width for the CTC / transducer decoder.
        public let beamSize: Int

        public static let `default` = ModelConfig(
            bundleName: SherpaModelBundle.defaultBundleName,
            sampleRate: 16_000,
            beamSize: 5
        )

        public init(bundleName: String, sampleRate: Int, beamSize: Int) {
            self.bundleName = bundleName
            self.sampleRate = sampleRate
            self.beamSize = beamSize
        }
    }

    // MARK: - State

    private let modelConfig: ModelConfig
    private var contextualStrings: [String] = []
    private var modelURL: URL?

    // MARK: - Init

    public init(modelConfig: ModelConfig = .default) {
        self.modelConfig = modelConfig
    }

    // MARK: - Transcriber: isAvailable

    /// Returns `true` when the sherpa-onnx model bundle is present on the device.
    ///
    /// The model bundle must be shipped in the app bundle or pre-downloaded to the
    /// documents / caches directory. On simulators the check is relaxed so tests can
    /// exercise the selection seam without a real model file.
    public var isAvailable: Bool {
        get async {
#if targetEnvironment(simulator) && DEBUG
            // Simulator + DEBUG: report available when the model bundle is present,
            // OR when the SherpaStubSeam test-seam override is active (DEBUG-only).
            return SherpaModelBundle.isModelBundlePresent(named: modelConfig.bundleName)
                || SherpaStubSeam.isOverrideActive
#else
            // Device, or any release build: model bundle must be present for on-device inference.
            return SherpaModelBundle.isModelBundlePresent(named: modelConfig.bundleName)
#endif
        }
    }

    // MARK: - Transcriber: preloadAssets

    /// Ensures the sherpa-onnx model bundle is accessible for on-device inference.
    ///
    /// If the model is already bundled with the app, this is a no-op.
    /// If the model requires a background download (large models shipped separately),
    /// this method initiates the download.
    ///
    /// TODO: implement progressive download for large Parakeet model variants (>100 MB).
    public func preloadAssets() async throws {
        // Resolve the model URL (in-bundle or downloaded).
        if let url = SherpaModelBundle.resolveURL(named: modelConfig.bundleName) {
            modelURL = url
            return
        }

        // Model not present: log and throw so callers can fall back gracefully.
        // TODO: implement Wi-Fi background download for the model assets.
        throw TranscriberError.transcriptionFailed(
            "sherpa-onnx model '\(modelConfig.bundleName)' is not present. " +
            "See SherpaTranscriber.swift handoff checklist for download instructions."
        )
    }

    // MARK: - Transcriber: setContextualStrings

    /// Accepts contextual phrase biasing strings.
    ///
    /// sherpa-onnx does not natively support contextual biasing on standard CTC/transducer
    /// models; these strings are stored for post-processing (n-best reranking against the
    /// domain vocabulary). The Apple engine (primary) applies them natively.
    ///
    /// TODO: investigate sherpa-onnx hotword biasing API for Parakeet (T048-B).
    public func setContextualStrings(_ phrases: [String]) async {
        contextualStrings = phrases
    }

    // MARK: - Transcriber: transcribe

    /// Transcribes a single push-to-talk capture using sherpa-onnx / Parakeet.
    ///
    /// ## PCM lifecycle (FR-022)
    /// `buffer` is `consuming` — ownership transferred into this method.
    /// `rawBytes` is read once for the decoder, then the local binding drops.
    ///
    /// ## Confidence mapping
    /// sherpa-onnx CTC/transducer decoders return a posterior log-probability score.
    /// We convert: `Int(clamp(posteriorScore * 100, 0, 100).rounded())`
    /// matching the contract in `Transcript.confidence`.
    ///
    /// ## STUB NOTE
    /// When `SHERPA_ONNX_ENABLED` is not set, this returns a clearly-marked stub
    /// transcript so selection and ambiguity tests can exercise this path without a
    /// real model binary. The stub is NOT acceptable for production.
    public func transcribe(buffer: consuming AudioBuffer) async throws -> Transcript {
        let durationSeconds = buffer.durationSeconds
        let rawBytes = buffer.rawBytes
        _ = consume buffer   // rawBytes owned by this frame; buffer dropped here (FR-022)

        guard durationSeconds >= 0.3 else {
            throw TranscriberError.audioTooShort
        }

#if SHERPA_ONNX_ENABLED
        // --- Real sherpa-onnx path ---
        //
        // TODO (human handoff): replace the stub below with the real sherpa-onnx decode call.
        //
        // Integration sketch (pseudo-code):
        //
        //   let recognizer = try SherpaOnnxRecognizer(config: modelConfig.toSherpaConfig())
        //   let pcm16 = rawBytes.toInt16Array()     // rawBytes is 16kHz mono Int16
        //   recognizer.acceptWaveform(pcm16, sampleRate: modelConfig.sampleRate)
        //   recognizer.inputFinished()
        //   let result = recognizer.getResult()
        //
        //   let confidence = ConfidenceMapping.toInt(result.confidence)  // Float → Int (0…100)
        //   return Transcript(text: result.text, confidence: confidence,
        //                     engine: .sherpa, finalizedAt: Date())
        //
        // See: https://github.com/k2-fsa/sherpa-onnx/blob/master/ios-swiftui/SherpaOnnx.swift
        throw TranscriberError.transcriptionFailed(
            "SHERPA_ONNX_ENABLED is set but the real integration has not been wired. " +
            "Complete the handoff steps in SherpaTranscriber.swift."
        )
#else
        // --- Stub path (no real model binary; compile/test seam only) ---
        //
        // Returns a clearly-marked placeholder so engine-selection logic and
        // ambiguity-path tests can exercise this engine branch without a real model.
        //
        // !! PRODUCTION WARNING: this stub path MUST NOT be used in production builds.
        // !! Set SHERPA_ONNX_ENABLED and complete the handoff steps before shipping.
        _ = rawBytes  // suppress unused-variable warning; no real decoding

        return Transcript(
            text: SherpaStub.stubTranscript,
            confidence: SherpaStub.stubConfidence,
            engine: .sherpa,
            finalizedAt: Date()
        )
#endif
    }

    // Confidence mapping is shared across adapters — see `ConfidenceMapping.toInt` in
    // Transcriber.swift (single source of truth so Apple/Sherpa never diverge on rounding).
}

// MARK: - SherpaModelBundle

/// Utilities for locating the sherpa-onnx model bundle.
enum SherpaModelBundle {
    /// Default model bundle resource name (Parakeet TDT 0.6B CTC — production target).
    ///
    /// TODO: confirm with the download handoff — the exact resource name may differ.
    static let defaultBundleName: String = "parakeet-tdt-0.6b"

    /// Returns `true` if the named model bundle is accessible in the main bundle or
    /// the app's Documents / Library directories.
    static func isModelBundlePresent(named name: String) -> Bool {
        // Check main app bundle first (small models shipped with the app).
        if Bundle.main.url(forResource: name, withExtension: "onnx") != nil { return true }
        if Bundle.main.url(forResource: name, withExtension: nil) != nil { return true }

        // Check app documents directory (downloaded models).
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let modelPath = docs.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: modelPath.path)
        }
        return false
    }

    /// Resolves the full URL for the named model bundle.
    static func resolveURL(named name: String) -> URL? {
        // In-bundle check.
        if let url = Bundle.main.url(forResource: name, withExtension: "onnx") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: nil) { return url }

        // Documents directory.
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

// MARK: - SherpaStub (test seam)

/// Stub constants used when `SHERPA_ONNX_ENABLED` is not set.
/// These are public so test targets can assert on them.
public enum SherpaStub {
    /// Stub transcript text. Clearly non-production — tests can assert on this string.
    public static let stubTranscript = "[SHERPA-STUB] ground ball to short threw him out at first"
    /// Stub confidence integer (high, so parse-layer tests get a clean path through).
    public static let stubConfidence = 80
}

#if DEBUG
/// Test-seam override (DEBUG-only): set `isOverrideActive = true` in test setUp to make
/// `SherpaTranscriber.isAvailable` return `true` in simulator tests even without a model file.
///
/// Compiled out of release builds entirely so availability in production reflects only a real
/// model bundle's presence (ADR-0010).
public enum SherpaStubSeam {
    /// Set to `true` in test code to override the model-presence check.
    ///
    /// Swift 6 note: `nonisolated(unsafe)` is appropriate here because this flag is only
    /// mutated from test setUp/tearDown (serial context) and never concurrently.
    public nonisolated(unsafe) static var isOverrideActive: Bool = false
}
#endif
