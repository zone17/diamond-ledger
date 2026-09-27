/// T176DiagnosticsTests.swift — DL-176 U5 (R8, KTD7): numeric-only voice diagnostics.
///
/// Every test uses a fresh `VoiceDiagnostics()` (never `.shared`) and synthetic values. Nothing here
/// touches an audio engine, a speech recognizer, or a permission API.
///
/// Coverage (plan U5 test scenarios):
///   - A transcription record holds only numbers and the reason enum; no transcript text fed through
///     the biasing decision reaches the export.
///   - A nil base confidence is recorded as `unreported`, never as the 0.60 fallback.
///   - The DEBUG ring keeps the last 50 records, in order, and exports valid JSON.

import XCTest
import Foundation
@testable import DiamondSpeech

@available(iOS 26, *)
final class T176DiagnosticsTests: XCTestCase {

    /// The contextual set a live transcription carries with an empty roster: the lexicon.
    private let vocabulary = RosterContextBuilder.build(roster: [])

    /// Decodes an export into its record objects; fails the test when it is not a JSON array.
    private func decode(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [[String: Any]], "export must be a JSON array of objects")
    }

    // MARK: - Numbers and reasons only

    func testTranscriptionRecord_holdsOnlyNumbersAndReason_noTranscriptText() async throws {
        let diagnostics = VoiceDiagnostics()
        let base = "ground out to sean"
        let biasedText = "ground out to short"
        let decision = BiasingStrategy.decide(
            baseText: base, baseConfidence: nil, biased: (biasedText, 0.85),
            contextualStrings: vocabulary)
        XCTAssertEqual(decision.reason, .agreed, "precondition: the correction is accepted")

        await diagnostics.recordTranscription(
            engine: .apple, baseConfidence: nil, biasedConfidence: 0.85,
            biasing: VoiceDiagnostics.BiasingPass(decision.reason))

        let data = await diagnostics.exportJSON()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for word in ["ground", "sean", "short"] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(word),
                           "export must not contain transcript text (\(word)): \(json)")
        }

        let records = try decode(data)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record["kind"] as? String, "transcription")
        XCTAssertEqual(record["engine"] as? String, "apple")
        XCTAssertEqual(record["biasing"] as? String, "agreed")
        XCTAssertEqual(try XCTUnwrap(record["biased_confidence"] as? Double), 0.85, accuracy: 0.0001)

        // Every value is a number or one of the closed enum labels.
        let labels = Set(VoiceDiagnostics.BiasingPass.allCases.map(\.rawValue))
            .union(VoiceDiagnostics.CaptureOutcome.allCases.map(\.rawValue))
            .union(["transcription", "capture", "apple", "sherpa", "stub", VoiceDiagnostics.unreported])
        for (key, value) in record {
            if value is NSNumber { continue }
            let text = try XCTUnwrap(value as? String, "\(key) is neither a number nor a label")
            XCTAssertTrue(labels.contains(text), "\(key)=\(text) is not a closed label")
        }
    }

    /// Structural guarantee: neither record type has a stored `String` field, so no caller can
    /// route transcript text into a record however it is built.
    func testRecordTypes_haveNoStringFields() {
        let transcription = VoiceDiagnostics.TranscriptionRecord(
            engine: .apple, baseConfidence: 0.5, biasedConfidence: 0.9, biasing: .agreed)
        let capture = VoiceDiagnostics.CaptureRecord(durationSeconds: 1.2, latencyMs: 800, outcome: .clarify)
        for subject in [Mirror(reflecting: transcription), Mirror(reflecting: capture)] {
            for child in subject.children {
                XCTAssertFalse(child.value is String, "\(child.label ?? "?") must not be a String")
                XCTAssertFalse(child.value is String?, "\(child.label ?? "?") must not be a String?")
            }
        }
    }

    /// Every decision reason has a diagnostics label with the same spelling as the `dl-bias` harness.
    func testBiasingPass_mirrorsEveryDecisionReason() {
        for reason in BiasingReason.allCases {
            XCTAssertEqual(VoiceDiagnostics.BiasingPass(reason).rawValue, reason.rawValue)
        }
    }

    // MARK: - nil base confidence is `unreported`, never 0.60

    func testNilBaseConfidence_isRecordedUnreported_neverTheFallback() async throws {
        let diagnostics = VoiceDiagnostics()
        await diagnostics.recordTranscription(
            engine: .apple, baseConfidence: nil, biasedConfidence: nil, biasing: .notAttempted)

        let records = try decode(await diagnostics.exportJSON())
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record["base_confidence"] as? String, "unreported")
        XCTAssertEqual(record["biased_confidence"] as? String, "unreported")
        XCTAssertEqual(record["biasing"] as? String, "not_attempted")
        for (key, value) in record {
            if let number = value as? NSNumber {
                XCTAssertNotEqual(number.doubleValue,
                                  Double(AppleTranscriber.defaultConfidenceWhenUnreported),
                                  accuracy: 0.0001, "\(key) must not carry the 0.60 fallback")
            }
        }
    }

    func testReportedBaseConfidence_isRecordedAsTheNumber() async throws {
        let diagnostics = VoiceDiagnostics()
        await diagnostics.recordTranscription(
            engine: .apple, baseConfidence: 0.42, biasedConfidence: 0.91, biasing: .baseMoreConfident)
        let records = try decode(await diagnostics.exportJSON())
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(try XCTUnwrap(record["base_confidence"] as? Double), 0.42, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(record["biased_confidence"] as? Double), 0.91, accuracy: 0.0001)
    }

    // MARK: - Capture records

    func testCaptureRecord_exportsDurationLatencyAndOutcome() async throws {
        let diagnostics = VoiceDiagnostics()
        await diagnostics.recordCapture(durationSeconds: 2.25, latencyMs: 1_340, outcome: .clarify)
        await diagnostics.recordCapture(durationSeconds: 0.4, latencyMs: nil, outcome: .interrupted)

        let records = try decode(await diagnostics.exportJSON())
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["kind"] as? String, "capture")
        XCTAssertEqual(try XCTUnwrap(records[0]["capture_seconds"] as? Double), 2.25, accuracy: 0.0001)
        XCTAssertEqual(records[0]["latency_ms"] as? Int, 1_340)
        XCTAssertEqual(records[0]["outcome"] as? String, "clarify")
        XCTAssertEqual(records[1]["latency_ms"] as? String, "unreported")
        XCTAssertEqual(records[1]["outcome"] as? String, "interrupted")
    }

    // MARK: - The DEBUG ring

    #if DEBUG
    func testRing_keepsTheLast50InOrder_andExportsValidJSON() async throws {
        let diagnostics = VoiceDiagnostics()
        for i in 1...60 {
            if i.isMultiple(of: 2) {
                await diagnostics.recordCapture(durationSeconds: Double(i), latencyMs: i, outcome: .scored)
            } else {
                await diagnostics.recordTranscription(
                    engine: .apple, baseConfidence: nil, biasedConfidence: Float(i) / 100,
                    biasing: .noBiasedHypothesis)
            }
        }
        let count = await diagnostics.recentRecords().count
        XCTAssertEqual(count, VoiceDiagnostics.ringCapacity)
        XCTAssertEqual(VoiceDiagnostics.ringCapacity, 50)

        let records = try decode(await diagnostics.exportJSON())
        XCTAssertEqual(records.count, 50)
        // Records 1…10 were dropped; 11 (a transcription) is now first and 60 (a capture) last.
        XCTAssertEqual(records.first?["kind"] as? String, "transcription")
        XCTAssertEqual(try XCTUnwrap(records.first?["biased_confidence"] as? Double), 0.11, accuracy: 0.0001)
        XCTAssertEqual(records.last?["kind"] as? String, "capture")
        XCTAssertEqual(records.last?["latency_ms"] as? Int, 60)
    }
    #endif

    func testEmptyDiagnostics_exportsAnEmptyJSONArray() async throws {
        let records = try decode(await VoiceDiagnostics().exportJSON())
        XCTAssertTrue(records.isEmpty)
    }
}
