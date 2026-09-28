/// T176PushToTalkDiagnosticsTests.swift — DL-176 U5 (R8): one numeric diagnostics record per
/// push-to-talk utterance, recorded by `PushToTalkPipeline`.
///
/// Each test injects a fresh `VoiceDiagnostics` into `AppState`, so records from other tests never
/// leak in. The ring only retains records in DEBUG builds, which is how the suite runs.
///
/// Coverage:
///   - A 1.2 s capture that scores → one capture record: 1.2 s, a latency, outcome `scored`.
///   - A real-engine out-of-grammar transcript → outcome `manual_entry`.
///   - An interruption with the finger down → outcome `interrupted`, 0 s, no latency.
///   - The DEBUG facilitator's canned play → no record (demo plays never pollute device evidence).
///   - The exported JSON never contains the transcript text.

import XCTest
import SwiftUI
@testable import Core
@testable import UI
@testable import DiamondSpeech
import Auth

#if DEBUG
@MainActor
final class T176PushToTalkDiagnosticsTests: XCTestCase {

    private func makeAppState(
        capture: ControlledCapture,
        transcriber: any Transcriber
    ) async throws -> (AppState, VoiceDiagnostics) {
        let readiness = await readySpeechReadiness()
        let appState = AppState(core: MockCore(),
                                consentDefaults: UserDefaults(suiteName: "test.t176u5.\(UUID().uuidString)")!,
                                authStore: AuthStore(store: InMemorySessionStore()),
                                transcriberFactory: { @Sendable _ in transcriber },
                                speechReadiness: readiness,
                                captureFactory: CaptureFactoryProbe(capture).factory)
        let diagnostics = VoiceDiagnostics()
        appState.voiceDiagnostics = diagnostics
        try appState.completeAppleSignIn(appleUserID: "adult-176-u5", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls",
                                  homeLineup: ["Ben Ortiz"], visitorLineup: ["Ana Ruiz"])
        return (appState, diagnostics)
    }

    private func captureRecords(_ diagnostics: VoiceDiagnostics) async -> [VoiceDiagnostics.CaptureRecord] {
        await diagnostics.recentRecords().compactMap {
            if case .capture(let record) = $0 { return record }
            return nil
        }
    }

    func test_scoredCapture_recordsDurationLatencyAndOutcome() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.2))
        let (appState, diagnostics) = try await makeAppState(capture: capture, transcriber: RecordingTranscriber())

        await speak(appState)

        let records = await captureRecords(diagnostics)
        XCTAssertEqual(records.count, 1)
        guard let record = records.first else { return }
        XCTAssertEqual(record.outcome, .scored)
        XCTAssertEqual(record.durationSeconds, 1.2, accuracy: 1e-9)
        let latency = try XCTUnwrap(record.latencyMs, "a transcript arrived, so latency is measured")
        XCTAssertGreaterThanOrEqual(latency, 0)
    }

    func test_outOfGrammarRealEngine_recordsManualEntry() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber(text: "the quick brown fox")
        let (appState, diagnostics) = try await makeAppState(capture: capture, transcriber: transcriber)

        await speak(appState)

        let records = await captureRecords(diagnostics)
        XCTAssertEqual(records.map(\.outcome), [.manualEntry])
    }

    func test_interruption_recordsInterruptedWithoutDurationOrLatency() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let (appState, diagnostics) = try await makeAppState(capture: capture, transcriber: RecordingTranscriber())

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        capture.interrupt(.phoneCall)
        await waitUntil("an interrupted record") { await self.captureRecords(diagnostics).count == 1 }
        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))

        let records = await captureRecords(diagnostics)
        XCTAssertEqual(records, [.init(durationSeconds: 0, latencyMs: nil, outcome: .interrupted)])
    }

    func test_facilitatorPlay_recordsNothing() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let (appState, diagnostics) = try await makeAppState(capture: capture, transcriber: RecordingTranscriber())

        await PushToTalkPipeline.scoreFacilitatorScript(.groundOut63, appState: appState)

        let records = await captureRecords(diagnostics)
        XCTAssertEqual(records, [], "demo plays never reach the device evidence")
    }

    func test_exportedJSON_neverContainsTranscriptText() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber(text: "the quick brown fox")
        let (appState, diagnostics) = try await makeAppState(capture: capture, transcriber: transcriber)

        await speak(appState)

        let json = String(decoding: await diagnostics.exportJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains("manual_entry"), json)
        XCTAssertFalse(json.contains("quick"), "transcript text must never reach diagnostics: \(json)")
        XCTAssertFalse(json.contains("fox"), json)
    }
}
#endif
