/// VoiceDiagnostics.swift — DL-176 U5 (R8, KTD7): numeric-only evidence from each voice capture.
///
/// The device checklist (`docs/evaluations/2026-09-device-voice-checklist.md`) turns these records
/// into the evidence for the silent-scoring decision (ADR-0017 R20, DL-157 Assumption A7).
///
/// Two record kinds, because the numbers are known in two places:
///   - `TranscriptionRecord`: inside `AppleTranscriber` — the base leg's confidence as reported
///     (`unreported` when nil, never the 0.60 fallback), the biased leg's measured confidence, and
///     why the biasing pass kept or replaced the base.
///   - `CaptureRecord`: in the push-to-talk pipeline — capture duration, release-to-transcript
///     latency, and what the press led to.
///
/// **Privacy (FR-022, KTD7):** records hold numbers and closed enum labels only. No field is a
/// `String`, so transcript text and audio cannot be routed into a record, and the `os.Logger`
/// lines interpolate only those numbers and labels (with `.public` privacy so a device run can
/// read them in Console).
///
/// **Retention:** every record is logged. Only DEBUG builds also keep the last `ringCapacity`
/// records in memory for `exportJSON()`; a Release build retains nothing and exports `[]`.

import Foundation
import os

public actor VoiceDiagnostics {

    /// The instance the app records into. Tests make their own with `init()`.
    public static let shared = VoiceDiagnostics()

    /// How many records the DEBUG ring keeps.
    public static let ringCapacity = 50

    /// The label a missing number is exported and logged as.
    public static let unreported = "unreported"

    private nonisolated let logger = Logger(subsystem: "app.diamondledger", category: "voice")

    #if DEBUG
    private var ring: [Record] = []
    #endif

    public init() {}

    // MARK: - Record kinds

    /// Why the biasing pass kept or replaced the base text. Mirrors every `BiasingReason` (same
    /// raw spelling as the `dl-bias` harness) plus the three ways the pass can end before a decision.
    public enum BiasingPass: String, Sendable, Codable, CaseIterable {
        /// No contextual set was in force, or the base text was empty.
        case notAttempted = "not_attempted"
        /// The biasing recognizer was missing, unavailable, or not on-device.
        case recognizerUnavailable = "recognizer_unavailable"
        /// The biasing recognizer threw.
        case recognizerFailed = "recognizer_failed"
        case noBiasedHypothesis = "no_biased_hypothesis"
        case emptyBase = "empty_base"
        case biasedConfidenceBelowThreshold = "biased_confidence_below_threshold"
        case divergent = "divergent"
        case insertionOrDeletion = "insertion_or_deletion"
        case tokenNotContextual = "token_not_contextual"
        case replacedTokenInVocabulary = "replaced_token_in_vocabulary"
        case baseMoreConfident = "base_more_confident"
        case agreed = "agreed"

        public init(_ reason: BiasingReason) {
            switch reason {
            case .noBiasedHypothesis: self = .noBiasedHypothesis
            case .emptyBase: self = .emptyBase
            case .biasedConfidenceBelowThreshold: self = .biasedConfidenceBelowThreshold
            case .divergent: self = .divergent
            case .insertionOrDeletion: self = .insertionOrDeletion
            case .tokenNotContextual: self = .tokenNotContextual
            case .replacedTokenInVocabulary: self = .replacedTokenInVocabulary
            case .baseMoreConfident: self = .baseMoreConfident
            case .agreed: self = .agreed
            }
        }
    }

    /// What one push-to-talk press led to.
    public enum CaptureOutcome: String, Sendable, Codable, CaseIterable {
        case scored
        case clarify
        case manualEntry = "manual_entry"
        case tooShort = "too_short"
        case error
        case interrupted
    }

    /// One transcription, recorded by the engine.
    public struct TranscriptionRecord: Sendable, Equatable {
        public let engine: TranscriberEngine
        /// The base leg's native confidence in 0…1, exactly as reported (`nil` on iOS 26).
        public let baseConfidence: Float?
        /// The biased leg's measured confidence in 0…1, or `nil` when that leg produced nothing.
        public let biasedConfidence: Float?
        public let biasing: BiasingPass

        public init(engine: TranscriberEngine, baseConfidence: Float?, biasedConfidence: Float?, biasing: BiasingPass) {
            self.engine = engine
            self.baseConfidence = baseConfidence
            self.biasedConfidence = biasedConfidence
            self.biasing = biasing
        }
    }

    /// One push-to-talk press, recorded by the pipeline.
    public struct CaptureRecord: Sendable, Equatable {
        public let durationSeconds: Double
        /// Release to transcript, in milliseconds; `nil` when no transcript was produced.
        public let latencyMs: Int?
        public let outcome: CaptureOutcome

        public init(durationSeconds: Double, latencyMs: Int?, outcome: CaptureOutcome) {
            self.durationSeconds = durationSeconds
            self.latencyMs = latencyMs
            self.outcome = outcome
        }
    }

    /// Either kind, in the order recorded.
    public enum Record: Sendable, Equatable {
        case transcription(TranscriptionRecord)
        case capture(CaptureRecord)
    }

    // MARK: - Recording

    public func recordTranscription(_ record: TranscriptionRecord) {
        logger.notice("""
            transcription engine=\(record.engine.rawValue, privacy: .public) \
            base=\(Self.label(record.baseConfidence), privacy: .public) \
            biased=\(Self.label(record.biasedConfidence), privacy: .public) \
            biasing=\(record.biasing.rawValue, privacy: .public)
            """)
        retain(.transcription(record))
    }

    public func recordTranscription(
        engine: TranscriberEngine, baseConfidence: Float?, biasedConfidence: Float?, biasing: BiasingPass
    ) {
        recordTranscription(TranscriptionRecord(
            engine: engine, baseConfidence: baseConfidence, biasedConfidence: biasedConfidence, biasing: biasing))
    }

    public func recordCapture(durationSeconds: Double, latencyMs: Int?, outcome: CaptureOutcome) {
        let record = CaptureRecord(durationSeconds: durationSeconds, latencyMs: latencyMs, outcome: outcome)
        logger.notice("""
            capture seconds=\(Self.label(record.durationSeconds), privacy: .public) \
            latency_ms=\(record.latencyMs.map(String.init) ?? Self.unreported, privacy: .public) \
            outcome=\(record.outcome.rawValue, privacy: .public)
            """)
        retain(.capture(record))
    }

    // MARK: - Export (DEBUG ring)

    /// The retained records, oldest first. Always empty in a Release build.
    public func recentRecords() -> [Record] {
        #if DEBUG
        return ring
        #else
        return []
        #endif
    }

    /// The retained records as a JSON array of objects holding numbers and labels only.
    public func exportJSON() -> Data {
        let objects = recentRecords().map(Self.jsonObject)
        // Only numbers and strings go in, so serialization cannot fail.
        return (try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])) ?? Data("[]".utf8)
    }

    // MARK: - Private

    private func retain(_ record: Record) {
        #if DEBUG
        ring.append(record)
        if ring.count > Self.ringCapacity { ring.removeFirst(ring.count - Self.ringCapacity) }
        #endif
    }

    private static func jsonObject(_ record: Record) -> [String: Any] {
        switch record {
        case .transcription(let r):
            return [
                "kind": "transcription",
                "engine": r.engine.rawValue,
                "base_confidence": number(r.baseConfidence.map(Double.init)),
                "biased_confidence": number(r.biasedConfidence.map(Double.init)),
                "biasing": r.biasing.rawValue,
            ]
        case .capture(let r):
            return [
                "kind": "capture",
                "capture_seconds": number(r.durationSeconds),
                "latency_ms": r.latencyMs.map { $0 as Any } ?? unreported,
                "outcome": r.outcome.rawValue,
            ]
        }
    }

    /// Rounds to four places so a `Float` exports as `0.85`, not `0.8500000238418579`.
    private static func number(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return unreported }
        return (value * 10_000).rounded() / 10_000
    }

    private static func label(_ value: Float?) -> String {
        label(value.map(Double.init))
    }

    private static func label(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unreported }
        return String(format: "%.4f", value)
    }
}
