/// T176ReviewFixTests.swift — regressions for the #176 code-review findings.
///
///   - Readiness never starts the model preload while speech access is unanswered: the Apple
///     preload requests speech authorization, so it would show a prompt on scene activation.
///   - A failed preload waits out its cooldown instead of restarting on every evaluation.
///   - Leaving a game (exit without saving) mid-hold or mid-release stops the capture and scores
///     nothing — no microphone left open behind a closed game.
///   - Losing the foreground discards the utterance whichever arrives first: the touch cancel
///     (which reads as a release) or the scene-phase change (R3).
///
/// Every test uses fakes only; nothing touches a real microphone or permission API.

import XCTest
import SwiftUI
@testable import Core
@testable import UI
@testable import DiamondSpeech
import Auth

// MARK: - Readiness

@MainActor
final class T176ReadinessReviewFixTests: XCTestCase {

    func test_speechNotDetermined_evaluateNeverStartsThePreload() async {
        let model = FakePreloader([.succeed])
        let speech = FakeVoicePermission(.notDetermined)
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.granted),
                                        speech: speech,
                                        model: model)

        let state = await readiness.evaluate()
        await awaitPreload(readiness)

        XCTAssertEqual(state, .speechDenied, "an unanswered speech prompt cannot capture")
        let calls = await model.callCount
        XCTAssertEqual(calls, 0, "the Apple preload requests speech auth, so it must not run unanswered")
        let requests = await speech.requestCount
        XCTAssertEqual(requests, 0)
    }

    func test_failedPreload_waitsOutTheCooldown_beforeRetrying() async {
        let model = FakePreloader([.fail, .succeed])
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.granted),
                                        speech: FakeVoicePermission(.granted),
                                        model: model,
                                        retryCooldown: .seconds(60))

        _ = await readiness.evaluate()          // first attempt fails
        await awaitPreload(readiness)
        let again = await readiness.evaluate()  // inside the cooldown: no new download
        await awaitPreload(readiness)

        XCTAssertEqual(again, .modelPreparing)
        let calls = await model.callCount
        XCTAssertEqual(calls, 1, "a failed download is not restarted on every press")
    }
}

// MARK: - Push-to-talk exits

@MainActor
final class T176PushToTalkReviewFixTests: XCTestCase {

    private func makeAppState(capture: ControlledCapture,
                              transcriber: RecordingTranscriber) async throws -> AppState {
        let readiness = await readySpeechReadiness()
        let appState = AppState(core: MockCore(),
                                consentDefaults: UserDefaults(suiteName: "test.t176fix.\(UUID().uuidString)")!,
                                authStore: AuthStore(store: InMemorySessionStore()),
                                transcriberFactory: { @Sendable _ in transcriber },
                                speechReadiness: readiness,
                                captureFactory: CaptureFactoryProbe(capture).factory)
        appState.voiceDiagnostics = VoiceDiagnostics()
        try appState.completeAppleSignIn(appleUserID: "adult-176-fix", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls",
                                  homeLineup: ["Ben Ortiz"], visitorLineup: ["Ana Ruiz"])
        return appState
    }

    func test_exitWithoutSaving_midHold_stopsTheCapture_andScoresNothing() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber()
        let appState = try await makeAppState(capture: capture, transcriber: transcriber)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        appState.exitGameWithoutFinalizing()
        await waitUntil("the live capture is stopped") { capture.stopCalls == 1 }
        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))

        let events = await transcriber.events
        XCTAssertEqual(events, [], "nothing is transcribed for a game that is gone")
        XCTAssertNil(appState.currentPress)
        XCTAssertEqual(appState.pttState, .idle)
        XCTAssertEqual(capture.stopCalls, 1)
    }

    func test_exitWithoutSaving_duringTheReleaseTail_scoresNothing() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber()
        let appState = try await makeAppState(capture: capture, transcriber: transcriber)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        let releasing = PushToTalkPipeline.touchUp(appState: appState)
        appState.exitGameWithoutFinalizing()
        await awaitBounded(releasing)

        let events = await transcriber.events
        XCTAssertEqual(events, [], "a release that lands after the exit is dropped")
        XCTAssertNil(appState.activeGame)
        XCTAssertEqual(appState.pttState, .idle)
    }

    func test_touchCancelBeforeBackground_discardsTheUtterance() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber()
        let appState = try await makeAppState(capture: capture, transcriber: transcriber)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        // iOS cancels the touch (reads as a release) first, then the scene goes inactive.
        let releasing = PushToTalkPipeline.touchUp(appState: appState)
        PushToTalkPipeline.scenePhaseChanged(.inactive, appState: appState)
        await awaitBounded(releasing)

        let events = await transcriber.events
        XCTAssertEqual(events, [], "the partial utterance is discarded, never scored (R3)")
        XCTAssertEqual(appState.pttState, .idle)
        XCTAssertEqual(appState.presentedError?.message, AppState.interruptionMessage(for: .background))
        XCTAssertNil(appState.presentedSheet)
    }

    func test_inactiveWhileHeld_cancelsTheCapture() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber()
        let appState = try await makeAppState(capture: capture, transcriber: transcriber)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        await awaitBounded(PushToTalkPipeline.scenePhaseChanged(.inactive, appState: appState))
        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))

        let events = await transcriber.events
        XCTAssertEqual(events, [])
        XCTAssertEqual(capture.stopCalls, 1)
        XCTAssertEqual(appState.pttState, .idle)
    }
}
