/// AppleTranscriber.swift — T047 (Squad B, Story B2) — DL-80 real on-device ASR.
///
/// `Transcriber` conformer for the Apple on-device path (primary engine — ADR-0007/ADR-0010, D2).
///
/// ## What this is (read this first)
///   This adapter uses the **real iOS-26 `SpeechAnalyzer` + `SpeechTranscriber` + `AssetInventory`**
///   API (the "SpeechAnalyzer-era" framework introduced at WWDC25), NOT the legacy
///   `SFSpeechRecognizer` recognition path for the primary transcription. Specifically:
///     - Transcription runs through `SpeechAnalyzer(modules: [SpeechTranscriber])` fed a finite
///       single-utterance `AsyncStream<AnalyzerInput>` of `AVAudioPCMBuffer`, finalized with
///       `finalizeAndFinishThroughEndOfInput()`; results are read from `transcriber.results`.
///     - `preloadAssets()` performs a **real `AssetInventory` model preload** — it checks
///       `SpeechTranscriber.supportedLocales` / `installedLocales` and, when the locale's model is
///       absent, issues `AssetInventory.assetInstallationRequest(supporting:)` +
///       `downloadAndInstall()` over Wi-Fi (FR-021). The old auth-only shim and its `#warning`
///       are removed.
///     - On-device only: `SpeechTranscriber` transcribes entirely on device; no network
///       recognition path is used. (`AssetInventory` model *download* is the only network step,
///       and it is a one-time preload, not per-utterance recognition.)
///
/// ## Contextual biasing — the honest iOS-26 reality (FR: domain accuracy)
///   As of iOS 26, **`SpeechAnalyzer` / `SpeechTranscriber` does NOT expose a contextual-strings /
///   custom-vocabulary biasing API** (confirmed: Apple's `SpeechAnalyzer` has no custom-vocabulary
///   equivalent of `SFSpeechRecognitionRequest.contextualStrings` yet — see the DL-80 report doc
///   source list). Apple's own guidance is a **hybrid**: use `SpeechAnalyzer` for general
///   transcription, and keep `SFSpeechRecognizer.contextualStrings` for vocabulary-sensitive
///   recognition; the two frameworks coexist and may be mixed per feature.
///
///   The baseball lexicon + roster are stored on the actor via `setContextualStrings` and assembled
///   by `RosterContextBuilder`. The `SFSpeechRecognizer.contextualStrings` hybrid biasing pass
///   (`applyBiasing`) is implemented but **deferred from the hot path** (follow-up #157): because
///   `SpeechTranscriber` never provides a confidence signal, the nil-base branch of
///   `BiasingStrategy.choose` would unconditionally override the analyzer's text with a biased
///   hypothesis regardless of agreement — a fabricated wrong play (P0b / Article VII). A
///   conservative, roster-wired, edit-distance-gated strategy is needed before enabling.
///
/// ## Concurrency (Swift 6 / actor isolation)
///   Declared as an `actor` — all SpeechAnalyzer/AssetInventory calls are actor-isolated, so there
///   are no Swift 6 concurrency errors at the call site. `Sendable` flows from `actor`.
///
/// ## Audio lifecycle (FR-022 / COPPA / process-don't-store)
///   `transcribe(buffer:)` takes a `consuming AudioBuffer`: ownership transfers in, `rawBytes` is
///   read **once** to build a single `AVAudioPCMBuffer`, the buffer is `consume`d immediately, the
///   stream is closed after yielding that one buffer, and no reference to `rawBytes` escapes the
///   stack frame. No raw PCM is written to disk / UserDefaults / logs. (FR-022.)
///
/// ## FR-008 / low-confidence (never a silent guess)
///   A terminal-but-empty transcription (no final result, or an empty/whitespace string) is treated
///   as a **thrown error** (`TranscriberError.transcriptionFailed`), never a silently-returned empty
///   transcript. The ambiguity gate proper lives in `GrammarParser` (T050); this adapter's job is an
///   accurate integer confidence and never a silent drop.
///
/// ## iOS 26 availability
///   The entire type is guarded by `@available(iOS 26, *)`. `EngineSelector` checks `isAvailable`
///   at runtime and degrades to the WoZ `StubTranscriber` in the Simulator (SpeechAnalyzer cannot
///   truly run there) or to `SherpaTranscriber` on older OS, so the app always works.
///
/// - SeeAlso: `ios/Sources/Speech/Transcriber.swift` — protocol definition
/// - SeeAlso: `ios/Sources/Speech/SherpaTranscriber.swift` — T048 fallback / portable path
/// - SeeAlso: `ios/Sources/Speech/EngineSelector.swift` — engine selection seam (T047-B)

import Foundation
import AVFoundation

// SpeechAnalyzer, SpeechTranscriber, AssetInventory and (legacy, for the biasing pass)
// SFSpeechRecognizer all live in Apple's system `Speech` framework (iOS 26+). `import Speech`
// is unambiguous here: this file is inside the `DiamondSpeech` SPM target, which does not
// re-export Speech (see Transcriber.swift module-name note).
import Speech

// MARK: - AppleTranscriber

/// Primary on-device ASR adapter using Apple's iOS-26 `SpeechAnalyzer` (+ `AssetInventory` preload).
///
/// **Availability gate:** check `isAvailable` before relying on it. On pre-26 OS (or when speech
/// authorization is denied/restricted) `isAvailable` returns `false` and `transcribe(buffer:)`
/// throws. `EngineSelector` uses this to fall back to Sherpa / the WoZ stub.
///
/// ## FR-008 / confidence — the unmeasured-confidence default (P0 fix, DL-80 code review)
///   iOS 26's `SpeechTranscriber` does NOT expose a scalar confidence in its public result type
///   (`confidence(from:)` always returns nil). The default for an unmeasured transcript is therefore
///   set BELOW `GrammarParser.lowConfidenceThreshold` (70) so the parser's clarify path fires for
///   any transcript without a real confidence signal — never a silent wrong play (Article VII).
///   See `defaultConfidenceWhenUnreported`.
///
/// ## Contextual biasing — deferred from the hot path (P0b fix, DL-80 code review)
///   The `applyBiasing` / `SFSpeechRecognizer` second-recognizer pass is NOT run on the hot path.
///   Because `SpeechAnalyzer` never provides a base confidence, `BiasingStrategy.choose`'s
///   nil-base branch would unconditionally override with the biased text, creating a path where a
///   lexicon/roster phrase the speaker didn't say becomes the confident hypothesis. Until a
///   conservative, roster-wired, edit-distance-gated strategy is designed (follow-up #157), the
///   `SpeechAnalyzer` result is returned directly. `applyBiasing` is kept for the follow-up but
///   MUST NOT be called from `runTranscription`.
@available(iOS 26, *)
public actor AppleTranscriber: Transcriber {

    public nonisolated let engine: TranscriberEngine = .apple

    // MARK: - Expected capture format (T046 PTT lifecycle contract)

    /// The PCM layout `AudioBuffer.rawBytes` is captured in: 16 kHz, mono, Int16, interleaved.
    /// `SpeechAnalyzer` reformats internally to its `bestAvailableAudioFormat`; we only need to
    /// produce a valid `AVAudioPCMBuffer` in this known layout. (TODO: confirm with T046.)
    static let captureSampleRate: Double = 16_000
    static let captureChannels: AVAudioChannelCount = 1

    // MARK: - State

    /// Current contextual strings (baseball lexicon + roster). Applied (via the `SFSpeechRecognizer`
    /// biasing pass) on every transcription request. Bounded + deduplicated by `RosterContextBuilder`.
    private var contextualStrings: [String] = RosterContextBuilder.build(roster: [])

    /// The locale whose on-device speech model this adapter uses. Captured at init from the
    /// current locale so `preloadAssets()` and `transcribe` agree on which model to require.
    private let locale: Locale

    /// Tracks whether the `AssetInventory` model preload has completed for `locale` (idempotent).
    private var modelInstalled: Bool = false

    // MARK: - Init

    public init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    // MARK: - Transcriber: isAvailable

    /// Returns `true` when on-device transcription can be attempted:
    ///   1. The OS is iOS 26+ (compile-time guard on the type — belt-and-suspenders runtime view).
    ///   2. Speech-recognition authorization is not `.denied` / `.restricted`. (`.notDetermined`
    ///      is acceptable — `preloadAssets()` / `transcribe` drives the permission prompt.)
    ///
    /// Note: we intentionally do NOT require the model to already be installed here — a not-yet-
    /// downloaded model is a *preload* concern, not an availability one, and `EngineSelector` should
    /// still pick Apple as primary so `preloadAssets()` can fetch the model over Wi-Fi (FR-021).
    public var isAvailable: Bool {
        get async {
            let status = SFSpeechRecognizer.authorizationStatus()
            return status != .denied && status != .restricted
        }
    }

    // MARK: - Transcriber: preloadAssets (REAL AssetInventory model preload — FR-021)

    /// Preloads the on-device `SpeechTranscriber` model for `locale` over Wi-Fi so offline
    /// recognition is ready (FR-021). This is a **real** `AssetInventory` preload, not the old
    /// auth-only shim:
    ///   1. Request speech authorization (drives the permission prompt once).
    ///   2. Verify the locale is supported by `SpeechTranscriber`.
    ///   3. If the model is already installed, return (idempotent).
    ///   4. Otherwise issue `AssetInventory.assetInstallationRequest(supporting:)` and
    ///      `downloadAndInstall()` — Apple downloads on-device model assets over Wi-Fi.
    ///
    /// Idempotent: once `modelInstalled` is set, subsequent calls are a no-op.
    ///
    /// - Throws: `TranscriberError.permissionDenied` if speech access is denied/restricted.
    /// - Throws: `TranscriberError.engineUnavailable(.apple)` if the locale is unsupported.
    /// - Throws: `TranscriberError.transcriptionFailed(_:)` if the model download fails.
    public func preloadAssets() async throws {
        guard !modelInstalled else { return }

        // 1. Authorization (idempotent; OS only prompts once).
        try await SpeechAuthorization.request()

        // 2. Build the transcriber module we will preload assets for.
        let transcriber = Self.makeTranscriber(locale: locale)

        // 3. Locale support + already-installed checks.
        guard await Self.isLocaleSupported(locale, for: transcriber) else {
            throw TranscriberError.engineUnavailable(.apple)
        }
        if await Self.isLocaleInstalled(locale, for: transcriber) {
            modelInstalled = true
            return
        }

        // 4. Request + download the on-device model over Wi-Fi (FR-021).
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            // Re-confirm install state; if the model still isn't present, surface a clear error.
            if await Self.isLocaleInstalled(locale, for: transcriber) {
                modelInstalled = true
            } else {
                throw TranscriberError.transcriptionFailed(
                    "AssetInventory completed but the SpeechTranscriber model for " +
                    "\(locale.identifier(.bcp47)) is still not installed.")
            }
        } catch let error as TranscriberError {
            throw error
        } catch {
            throw TranscriberError.transcriptionFailed(
                "AssetInventory preload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Transcriber: setContextualStrings

    /// Injects contextual phrase biasing (baseball lexicon + current roster) for subsequent
    /// transcriptions. The strings are merged with the baseline lexicon, deduplicated, and bounded
    /// by `RosterContextBuilder`, then applied through the `SFSpeechRecognizer` biasing pass
    /// (iOS 26 `SpeechTranscriber` has no native biasing API — see the file header).
    public func setContextualStrings(_ phrases: [String]) async {
        contextualStrings = RosterContextBuilder.build(roster: phrases)
    }

    // MARK: - Transcriber: transcribe

    /// Transcribes a single push-to-talk capture with the real iOS-26 `SpeechAnalyzer` pipeline.
    ///
    /// ## PCM lifecycle (FR-022 / COPPA / process-don't-store)
    /// `buffer` is `consuming` — ownership transfers in. `rawBytes` is read **once** to build one
    /// `AVAudioPCMBuffer`; the buffer is `consume`d immediately; the input stream is closed after
    /// yielding that single buffer. No reference to `rawBytes` escapes this stack frame, and no raw
    /// audio is written anywhere.
    ///
    /// ## Confidence integer mapping (ADR-0007)
    /// `SpeechAnalyzer` result confidence (when exposed via the audio-time-range / attributed run
    /// metadata) is a `Float` in [0, 1]; we convert with the shared `ConfidenceMapping.toInt`. When
    /// the framework does not surface a per-result confidence, we fall back to a conservative
    /// default (see `defaultConfidenceWhenUnreported`) rather than fabricating a high score.
    ///
    /// - Throws: `TranscriberError.permissionDenied` if speech access is denied.
    /// - Throws: `TranscriberError.engineUnavailable(.apple)` if no model/locale is available.
    /// - Throws: `TranscriberError.audioTooShort` if the buffer is under 0.3 s.
    /// - Throws: `TranscriberError.transcriptionFailed(_:)` on engine error or empty final (FR-008).
    public func transcribe(buffer: consuming AudioBuffer) async throws -> Transcript {
        // Capture scalars + bytes, then drop the move-only buffer immediately (FR-022).
        let durationSeconds = buffer.durationSeconds
        let rawBytes = buffer.rawBytes
        _ = consume buffer  // rawBytes is now a local owned by this frame only.

        // Duration guard — protect against accidental very-short taps.
        guard durationSeconds >= 0.3 else {
            throw TranscriberError.audioTooShort
        }

        // Permission check.
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        guard authStatus != .denied && authStatus != .restricted else {
            throw TranscriberError.permissionDenied
        }

        // Build the single capture PCM buffer (rawBytes consumed here; no escape — FR-022).
        // The buffer is created in this isolated frame but immediately `sending`-transferred into
        // the `nonisolated` transcription pipeline; the actor never touches it again, so it crosses
        // the isolation boundary exactly once (Swift 6 data-race-safe).
        let pcmBuffer = try Self.makePCMBuffer(from: rawBytes)

        // Snapshot actor state needed by the nonisolated pipeline.
        let strings = contextualStrings
        let captureLocale = locale

        // Run the real SpeechAnalyzer transcription, biased by the domain vocabulary.
        let (text, confidence) = try await Self.runTranscription(
            pcmBuffer: pcmBuffer, contextualStrings: strings, locale: captureLocale)

        // FR-008: a terminal-but-empty hypothesis is an error, never a silent empty transcript.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriberError.transcriptionFailed(
                "SpeechAnalyzer returned a final result with no recognized speech")
        }

        return Transcript(
            text: trimmed,
            confidence: ConfidenceMapping.toInt(confidence),
            engine: .apple,
            finalizedAt: Date()
        )
    }

    // MARK: - Private: SpeechAnalyzer pipeline

    /// Confidence used when the framework does not surface a per-result confidence for an utterance.
    ///
    /// ## Why 0.60 (below the 70 FR-008 threshold) — P0 fix
    ///   `GrammarParser.lowConfidenceThreshold` is 70 (`confidence < 70` → clarify path).
    ///   iOS 26's `SpeechTranscriber` never reports a scalar confidence (`confidence(from:)` always
    ///   returns nil in the current SDK), so EVERY production `SpeechAnalyzer` transcript reaches
    ///   this default. Setting it at or above 70 would stamp every unmeasured hypothesis as
    ///   "confident enough to parse silently" — bypassing FR-008 with zero real signal (Article VII).
    ///   0.60 → `ConfidenceMapping.toInt(0.60) = 60 < 70` → the parser's clarify path fires for
    ///   any unmeasured SpeechAnalyzer result, letting the scorer confirm before it becomes a play.
    ///   When the SDK eventually exposes a real confidence, `confidence(from:)` is the single place
    ///   to wire it, and this default becomes a genuine fallback rather than the universal path.
    static let defaultConfidenceWhenUnreported: Float = 0.60

    /// Constructs the `SpeechTranscriber` module configured for offline single-utterance use.
    /// `nonisolated static` so both the actor-isolated `preloadAssets` and the nonisolated
    /// transcription pipeline can build an identically-configured module.
    private nonisolated static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // `.audioTimeRange` is requested so result runs carry timing/metadata we can inspect for a
        // confidence signal where available. No volatile (partial) results: single-shot PTT only
        // needs the final hypothesis.
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Wall-clock timeout for the `SpeechAnalyzer` results loop. A finite single-utterance buffer
    /// should always resolve quickly; if the `results` AsyncSequence never terminates (e.g. a
    /// framework bug or an unfinalised analyzer), we cancel after this deadline rather than hanging
    /// the PTT flow forever. The timeout fires `TranscriberError.transcriptionFailed` — never a
    /// silent drop (FR-008 / Article VII).
    static let resultsTimeoutSeconds: Double = 15

    /// Drives the real `SpeechAnalyzer` pipeline for one captured PCM buffer and returns the
    /// best-hypothesis text plus a native confidence in [0, 1].
    ///
    /// Continuation/lifecycle safety:
    ///   - The analyzer + transcriber are retained for the whole call (locals captured by the
    ///     `async` frame), so they are never deallocated before results arrive.
    ///   - A single finite input stream yields exactly one buffer, then finishes; we then call
    ///     `finalizeAndFinishThroughEndOfInput()` so the analyzer terminates the result sequence
    ///     deterministically (no hang-forever).
    ///   - The results loop is additionally bounded by `resultsTimeoutSeconds` so a stream that
    ///     never terminates throws rather than blocking the PTT flow indefinitely.
    ///   - Cancellation propagates through the `for try await` over `transcriber.results` (an
    ///     `AsyncSequence`) and via the surrounding Task; `analyzer.cancelAndFinishNow()` is called
    ///     in a `defer` so a thrown/cancelled path always tears the analyzer down.
    ///
    /// NOTE: The `applyBiasing` / SFSpeechRecognizer second-recognizer pass is intentionally NOT
    /// called here (P0b fix — see the type-level doc comment and follow-up #157).
    private nonisolated static func runTranscription(
        pcmBuffer: sending AVAudioPCMBuffer,
        contextualStrings: [String],
        locale: Locale
    ) async throws -> (String, Float) {
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Ensure the analyzer is always torn down, even on throw/cancel.
        // `cancelAndFinishNow()` is safe to call after a normal finish.
        defer {
            Task { [analyzer] in await analyzer.cancelAndFinishNow() }
        }

        // Resolve the format the analyzer wants and convert our capture buffer to it. `convert`
        // reads (does not retain) `pcmBuffer`; the whole pipeline is `nonisolated`, so no buffer
        // crosses an actor boundary.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let inputBuffer = try convert(pcmBuffer, to: analyzerFormat)

        // Build a finite single-utterance input stream: yield one buffer, then finish.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: inputBuffer))
        continuation.finish()

        // Start analysis, then finalize through end-of-input so `results` terminates.
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            throw TranscriberError.transcriptionFailed(
                "SpeechAnalyzer failed to start: \(error.localizedDescription)")
        }

        // Finalize so the results AsyncSequence is driven to completion (no hang).
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            throw TranscriberError.transcriptionFailed(
                "SpeechAnalyzer finalize failed: \(error.localizedDescription)")
        }

        // Collect the final hypothesis from the results AsyncSequence.
        // The collection is raced against a timeout sentinel: if the `results` stream never
        // terminates (e.g. a framework bug or an unfinalised analyzer), we cancel after
        // `resultsTimeoutSeconds` and throw rather than blocking the PTT flow indefinitely
        // (never a silent drop — FR-008 / Article VII). Cancellation of the outer Task also
        // propagates through child task cancellation.
        //
        // The worker task returns a `(String, Float?)` tuple so the mutable accumulation state
        // never needs to cross a task boundary — avoiding the Swift 6 mutable-capture-in-Sendable-
        // closure error that `var` locals captured by `group.addTask` would produce.
        let (finalText, nativeConfidence): (String, Float?) = try await {
            try await withThrowingTaskGroup(of: (String, Float?)?.self) { group in
                // Worker: consume results and return the accumulated (text, minConfidence) tuple.
                group.addTask {
                    var text = ""
                    var minConf: Float? = nil
                    for try await result in transcriber.results {
                        guard result.isFinal else { continue }
                        text += String(result.text.characters)
                        if let c = Self.confidence(from: result) {
                            minConf = min(minConf ?? c, c)
                        }
                    }
                    return (text, minConf)
                }
                // Timeout sentinel: throws after the deadline, cancelling the worker.
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(resultsTimeoutSeconds * 1_000_000_000))
                    throw TranscriberError.transcriptionFailed(
                        "SpeechAnalyzer results timed out after \(Int(resultsTimeoutSeconds))s")
                }
                // Collect the first non-nil result (the worker's tuple), then cancel the sentinel.
                // If the timeout task throws first, the error propagates and the worker is cancelled.
                var collected: (String, Float?)? = nil
                for try await taskResult in group {
                    if let r = taskResult {
                        collected = r
                        group.cancelAll()
                        break
                    }
                }
                return collected ?? ("", nil)
            }
        }() as (String, Float?)

        // Return the SpeechAnalyzer result directly.
        // The SFSpeechRecognizer contextual-biasing second-recognizer pass (applyBiasing) is NOT
        // called here. Because iOS 26's SpeechTranscriber exposes no confidence signal, baseConfidence
        // is always nil → BiasingStrategy.choose's nil-base branch would unconditionally override the
        // text with the biased hypothesis, regardless of agreement — fabricating a wrong play with
        // apparent confidence (P0b / Article VII). A conservative, roster-wired, edit-distance-gated
        // strategy is tracked in follow-up #157.
        return (finalText, nativeConfidence ?? defaultConfidenceWhenUnreported)
    }

    /// `nonisolated` contextual-biasing pass. Building the `SFSpeechAudioBufferRecognitionRequest`
    /// here (outside the actor) means the request is never `self`-isolated, so it can be
    /// `sending`-transferred into `SFRecognitionBridge` without a data race. The non-Sendable PCM
    /// buffer arrives via a `sending` parameter (ownership transferred from `transcribe`, which no
    /// longer touches it). Best-effort: any failure or empty result keeps the base hypothesis.
    /// NOT called from the hot path (see type-level doc and follow-up #157).
    /// Kept for the follow-up conservative biasing implementation. P1 robustness: guards
    /// `supportsOnDeviceRecognition` to avoid a never-resolving callback when the recognizer
    /// would route to the network (no on-device model loaded), which with
    /// `requiresOnDeviceRecognition = true` would produce an immediate error — but the explicit
    /// guard makes the intent unambiguous and avoids any state where we'd enqueue a recognition
    /// task that Apple cannot service on-device.
    private nonisolated static func applyBiasing(
        baseText: String,
        baseConfidence: Float?,
        pcmBuffer: sending AVAudioPCMBuffer,
        contextualStrings: [String],
        locale: Locale
    ) async -> BiasingStrategy.Outcome {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {       // P1: never a dangling callback
            return .init(text: baseText, confidence: baseConfidence)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true        // on-device only (FR-021/FR-022)
        request.shouldReportPartialResults = false
        request.addsPunctuation = false
        request.contextualStrings = contextualStrings      // <-- the real biasing application
        request.append(pcmBuffer)                          // buffer consumed here (nonisolated)
        request.endAudio()
        // pcmBuffer is not referenced after this point (FR-022).

        let biased: (String, Float)?
        do {
            biased = try await SFRecognitionBridge.recognizeOnce(recognizer: recognizer, request: request)
        } catch {
            return .init(text: baseText, confidence: baseConfidence)
        }
        return BiasingStrategy.choose(
            baseText: baseText, baseConfidence: baseConfidence, biased: biased)
    }

    /// Extracts a native confidence in [0, 1] from a `SpeechTranscriber` result, if the framework
    /// surfaces one in the attributed run metadata. iOS 26's public result type does not guarantee a
    /// scalar confidence, so this returns `nil` when none is available (handled by the caller's
    /// conservative default). Centralized here so the extraction is a single testable seam.
    private static func confidence(from result: SpeechTranscriber.Result) -> Float? {
        // The public `SpeechTranscriber.Result` does not expose a documented scalar confidence in
        // iOS 26; `text` is an `AttributedString` whose runs carry `.audioTimeRange` (timing), not a
        // confidence score. We therefore return nil and let the caller apply the conservative
        // default / biasing pass. (If a future SDK adds a confidence attribute, read it here — this
        // is the single place to wire it.)
        _ = result
        return nil
    }

    // MARK: - Private: audio buffer construction (FR-022 — rawBytes consumed, never retained)

    /// Converts `rawBytes` (16 kHz, mono, Int16, interleaved) to an `AVAudioPCMBuffer`.
    /// `rawBytes` is read once and not retained past this function (FR-022).
    static func makePCMBuffer(from rawBytes: Data) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: captureSampleRate,
            channels: captureChannels,
            interleaved: true
        ) else {
            throw TranscriberError.transcriptionFailed(
                "Could not create 16kHz mono Int16 capture format")
        }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            throw TranscriberError.transcriptionFailed("Invalid bytes-per-frame in capture format")
        }

        let frameCount = AVAudioFrameCount(rawBytes.count / bytesPerFrame)
        guard frameCount > 0 else { throw TranscriberError.audioTooShort }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriberError.transcriptionFailed("Could not allocate AVAudioPCMBuffer")
        }
        pcmBuffer.frameLength = frameCount

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

    /// Converts a PCM buffer to the analyzer's preferred format. If the analyzer reports no preferred
    /// format (or it already matches), the input buffer is returned unchanged.
    ///
    /// Actor-isolated (instance method): the non-Sendable `AVAudioPCMBuffer` arguments and the
    /// `AVAudioConverter` input closure all execute within `self`'s isolation, so no buffer crosses
    /// an isolation boundary (Swift 6 data-race-safe). The one-shot input closure uses a reference
    /// box for its "already fed" flag rather than a captured `var` (which the concurrency checker
    /// rejects in the `@escaping`-shaped converter block).
    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat?) throws -> AVAudioPCMBuffer {
        guard let targetFormat, targetFormat != buffer.format else { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            // Conversion unavailable — fall back to the original buffer rather than failing the
            // whole transcription; SpeechAnalyzer may still accept it.
            return buffer
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return buffer
        }
        let fed = FedFlag()
        // Box the non-Sendable input buffer so the converter's `@Sendable`-shaped input block can
        // capture it without a concurrency warning. The block runs synchronously, inline, on this
        // thread for this single conversion — there is no actual cross-thread sharing.
        let box = BufferBox(buffer)
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, statusPtr in
            if fed.value {
                statusPtr.pointee = .noDataNow
                return nil
            }
            fed.value = true
            statusPtr.pointee = .haveData
            return box.buffer
        }
        if convError != nil { return buffer }
        return out
    }

    // MARK: - Private: AssetInventory locale checks (testable seams kept static)

    /// Whether `locale` is supported by the on-device `SpeechTranscriber` model catalog.
    static func isLocaleSupported(_ locale: Locale, for transcriber: SpeechTranscriber) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        let target = locale.identifier(.bcp47)
        return supported.map { $0.identifier(.bcp47) }.contains(target)
    }

    /// Whether the on-device model for `locale` is already installed (no download needed).
    static func isLocaleInstalled(_ locale: Locale, for transcriber: SpeechTranscriber) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        let target = locale.identifier(.bcp47)
        return installed.map { $0.identifier(.bcp47) }.contains(target)
    }
}

// MARK: - RosterContextBuilder (testable contextual-strings assembly)

/// Assembles the bounded, deduplicated contextual-strings set fed to the contextual-biasing pass:
/// the baseball lexicon first, then the active game roster (player names). Pure and `Sendable`, so
/// it is unit-testable without any Speech-framework dependency — this is the compile/logic-testable
/// seam for "contextual-strings assembly from a roster" required by DL-80.
public enum RosterContextBuilder {
    /// Upper bound on the number of contextual phrases. iOS contextual-biasing APIs degrade or ignore
    /// very large phrase sets. The full baseball lexicon (~99 terms) plus a typical roster (≤30
    /// names) fits comfortably under this ceiling; the cap only guards against pathological inputs.
    public static let maxPhrases = 200

    /// Reserved slots guaranteed for roster phrases (player names). Even if the lexicon alone would
    /// fill `maxPhrases`, this many trailing slots are kept for the roster so names are never wholly
    /// crowded out by domain vocabulary.
    public static let reservedRosterSlots = 40

    /// Builds the contextual-strings list from a roster (player names / extra phrases).
    ///   - Lexicon terms come first; roster phrases follow.
    ///   - Each phrase is whitespace-trimmed; empties dropped.
    ///   - Case-insensitive de-duplication, preserving first-seen order (lexicon wins ties).
    ///   - Bounded by `maxPhrases`, but `reservedRosterSlots` are always kept for the roster so
    ///     player names are never fully dropped in favor of lexicon overflow.
    public static func build(roster: [String]) -> [String] {
        // Normalize + dedup the two sources independently so we can budget them.
        func normalize(_ source: [String], into seen: inout Set<String>) -> [String] {
            var out: [String] = []
            for raw in source {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard seen.insert(trimmed.lowercased()).inserted else { continue }
                out.append(trimmed)
            }
            return out
        }

        var seen = Set<String>()
        let lexicon = normalize(BaseballLexicon.terms, into: &seen)
        let rosterPhrases = normalize(roster, into: &seen)

        // Budget: lexicon may take up to (maxPhrases - reservedRosterSlots) when a roster is present.
        let rosterBudget = min(rosterPhrases.count, maxPhrases)
        let lexiconCap = rosterPhrases.isEmpty
            ? maxPhrases
            : max(0, maxPhrases - rosterBudget)

        var out = Array(lexicon.prefix(lexiconCap))
        let remaining = max(0, maxPhrases - out.count)
        out.append(contentsOf: rosterPhrases.prefix(remaining))
        return out
    }
}

// MARK: - BiasingStrategy (SFSpeechRecognizer contextual-biasing pass — Apple's iOS-26 hybrid)

/// Applies domain-vocabulary contextual biasing to a `SpeechAnalyzer` hypothesis using
/// `SFSpeechRecognizer.contextualStrings` — the iOS-26-sanctioned hybrid (SpeechAnalyzer has no
/// native biasing API; SFSpeechRecognizer's still does, and Apple recommends mixing them per
/// feature for vocabulary-sensitive recognition).
///
/// **Best-effort, never fatal:** if the bias engine is unavailable (no recognizer, denied auth,
/// off-device-only refusal) or produces nothing, the base SpeechAnalyzer hypothesis is returned
/// unchanged. The biasing pass can only *improve* or *confirm* — it never blocks a transcription.
enum BiasingStrategy {
    struct Outcome: Sendable, Equatable {
        let text: String
        let confidence: Float?
    }

    /// Pure decision: given a base hypothesis (from `SpeechAnalyzer`) and an optional biased
    /// hypothesis (from the `SFSpeechRecognizer` contextual pass), choose which to keep.
    ///
    /// ## Conservative override rule (P0b fix — Article VII / FR-008)
    ///   - If the biased result is nil or empty/whitespace → keep the base.
    ///   - If the base has NO confidence signal (`baseConfidence == nil`) → keep the base.
    ///     Rationale: a nil base means the framework gave us no quality measure. Overriding the
    ///     analyzer's text with a biased hypothesis without any real confidence signal fabricates
    ///     a confident wrong play (the P0b defect in the first DL-80 submission). The biased result
    ///     must only override when there is a KNOWN base confidence to compare against.
    ///   - If base confidence IS known AND biasedConf ≥ baseConfidence → prefer biased.
    ///   - Else → keep the base.
    ///
    /// NOTE: Until follow-up #157 adds an edit-distance agreement guard and confirms the biasing
    /// pass is roster-wired, `applyBiasing` is not called from the hot path, so this method is
    /// only exercised in tests and future re-enabling logic.
    static func choose(baseText: String, baseConfidence: Float?, biased: (String, Float)?) -> Outcome {
        guard let (biasedText, biasedConf) = biased,
              !biasedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Outcome(text: baseText, confidence: baseConfidence)
        }
        // P0b: nil base confidence → keep base unchanged. Never override without a real signal.
        guard let knownBase = baseConfidence else {
            return Outcome(text: baseText, confidence: nil)
        }
        if biasedConf >= knownBase {
            return Outcome(text: biasedText, confidence: biasedConf)
        }
        return Outcome(text: baseText, confidence: baseConfidence)
    }
}

// MARK: - FedFlag (reference box for the one-shot AVAudioConverter input closure)

/// A tiny reference box so the `AVAudioConverter` input closure's "already fed" flag is mutated
/// through a reference rather than a captured `var` (which Swift 6 strict concurrency rejects in the
/// converter's `@escaping`-shaped input block). Used only within `AppleTranscriber.convert`, single
/// converter call, no concurrency — hence `@unchecked Sendable` is sound.
private final class FedFlag: @unchecked Sendable {
    var value = false
}

/// `@unchecked Sendable` box for a non-Sendable `AVAudioPCMBuffer` so it can be captured by the
/// `AVAudioConverter` input block. Single synchronous conversion, no cross-thread sharing.
private final class BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

// MARK: - SFRecognitionBridge (single-resume continuation bridge for the biasing pass)

/// Bridges `SFSpeechRecognizer.recognitionTask(with:)`'s multi-callback API into a single
/// `async` value, guaranteeing the continuation resumes **exactly once** and the recognition task is
/// cancelled on Task cancellation. Reused continuation-safety machinery (the shim's review found
/// real bugs here — double-resume, hang-forever, silent-drop; this is the hardened version).
@available(iOS 26, *)
enum SFRecognitionBridge {
    /// Run a one-shot recognition, returning `(text, confidence in [0,1])` or `nil` if the final
    /// result had no recognized speech. Cancellation throws `CancellationError`.
    ///
    /// `recognizer` and `request` are `sending`: ownership transfers out of the caller's isolation
    /// (the actor) into this bridge, so the non-Sendable `SFSpeechAudioBufferRecognitionRequest`
    /// never has concurrent uses (Swift 6 data-race-safe). The caller must not touch them afterward.
    static func recognizeOnce(
        recognizer: sending SFSpeechRecognizer,
        request: sending SFSpeechAudioBufferRecognitionRequest
    ) async throws -> (String, Float)? {
        let state = SFContinuationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, Float)?, Error>) in
                state.attach(cont)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    withExtendedLifetime(recognizer) {}        // keep recognizer alive for callback
                    if let error {
                        state.finish(.failure(TranscriberError.transcriptionFailed(error.localizedDescription)))
                        return
                    }
                    guard let result, result.isFinal else { return }   // wait for terminal callback
                    let best = result.bestTranscription
                    let text = best.formattedString
                    let segments = best.segments
                    if segments.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // FR-008: final-but-empty is signalled as nil (caller treats as "no bias").
                        state.finish(.success(nil))
                        return
                    }
                    // Conservative aggregate: minimum per-segment confidence.
                    let minConf = segments.map(\.confidence).min() ?? 0.0
                    state.finish(.success((text, minConf)))
                }
                state.store(task)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Thread-safe exactly-once continuation coordinator for `SFRecognitionBridge`. The recognizer
/// invokes its handler on its own queue and `onCancel` may run on any thread; an `NSLock` serializes
/// the `resumed` flag so the continuation resumes once and the task is torn down deterministically.
@available(iOS 26, *)
private final class SFContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<(String, Float)?, Error>?
    private var task: SFSpeechRecognitionTask?
    private var cancelledBeforeStore = false

    func attach(_ continuation: CheckedContinuation<(String, Float)?, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func store(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        if cancelledBeforeStore || resumed {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func finish(_ result: Result<(String, Float)?, Error>) {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let cont = continuation
        let liveTask = task
        continuation = nil
        task = nil
        lock.unlock()

        liveTask?.cancel()
        switch result {
        case .success(let value): cont?.resume(returning: value)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    func cancel() {
        lock.lock()
        guard task != nil || continuation != nil else {
            cancelledBeforeStore = true
            lock.unlock()
            return
        }
        lock.unlock()
        finish(.failure(CancellationError()))
    }
}

// MARK: - SpeechAuthorization (authorization gate)

/// Thin wrapper over `SFSpeechRecognizer.requestAuthorization`. Drives the permission prompt so the
/// first `transcribe` / `preloadAssets` call isn't blocked on permission. (Authorization is shared
/// across the SpeechAnalyzer and SFSpeechRecognizer paths — both require speech-recognition access.)
@available(iOS 26, *)
private enum SpeechAuthorization {
    static func request() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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

/// Static baseball domain vocabulary for contextual phrase biasing.
///
/// These terms prime the contextual-biasing pass toward baseball-specific recognition, improving
/// accuracy for domain vocabulary that may be uncommon in general speech models. Roster names are
/// appended at runtime via `setContextualStrings(_:)` → `RosterContextBuilder`.
///
/// **Sources:** SABR official scoring terminology, Retrosheet event file vocabulary,
/// Official Baseball Rules scoring glossary.
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
