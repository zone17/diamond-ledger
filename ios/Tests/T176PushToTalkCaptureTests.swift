/// T176PushToTalkCaptureTests.swift — DL-176 U4 (R1, R2, R3, R5, R7): push-to-talk capture wiring.
///
/// Drives `PushToTalkPipeline` (touch-down → capture start, touch-up → stop → transcribe → parse)
/// and its stuck-state guards against a `ControlledCapture` fake and fake readiness providers.
/// Nothing here touches the microphone, an audio session, or a real permission API.
///
/// Coverage (plan U4 test scenarios):
///   - 1.2 s capture → the transcriber gets a 1.2 s buffer, after `setContextualStrings(roster)`.
///   - `stop()` returns nil → idle, "interrupted" message, transcriber never called.
///   - Background mid-hold → capture stopped, idle; scene activation re-reads readiness.
///   - Press while not ready → readiness message, no `start()`.
///   - Release before `start()` finishes → the capture is still stopped exactly once.
///   - `capReached` with the finger down → the release pipeline runs once; drags never restart.
///   - `interrupted` with the finger down → idle + message, no transcribe, no restart until touch-up.
///   - The press handler fired twice before `start()` resumes → `start()` called once.
///   - The factory builds a fresh capture for every press.

import XCTest
import SwiftUI
@testable import Core
@testable import UI
@testable import DiamondSpeech
import Auth

@MainActor
final class T176PushToTalkCaptureTests: XCTestCase {

    private let roster = ["Ana Ruiz", "Ben Ortiz"]

    /// A signed-in AppState with a game on, the given capture fake, and a ready (or given) readiness.
    private func makeAppState(
        capture: ControlledCapture,
        transcriber: any Transcriber = RecordingTranscriber(),
        readiness: SpeechReadiness? = nil
    ) async throws -> (AppState, CaptureFactoryProbe) {
        let probe = CaptureFactoryProbe(capture)
        let resolvedReadiness: SpeechReadiness
        if let readiness {
            resolvedReadiness = readiness
        } else {
            resolvedReadiness = await readySpeechReadiness()
        }
        let appState = AppState(core: MockCore(),
                                consentDefaults: UserDefaults(suiteName: "test.t176u4.\(UUID().uuidString)")!,
                                authStore: AuthStore(store: InMemorySessionStore()),
                                transcriberFactory: { @Sendable _ in transcriber },
                                speechReadiness: resolvedReadiness,
                                captureFactory: probe.factory)
        try appState.completeAppleSignIn(appleUserID: "adult-176-u4", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls",
                                  homeLineup: ["Ben Ortiz"], visitorLineup: ["Ana Ruiz"])
        XCTAssertEqual(appState.activeRoster, roster, "precondition: game on with a roster")
        return (appState, probe)
    }

    // MARK: R1 — the captured buffer reaches the transcriber

    func test_capture1_2s_transcriberReceives1_2sBuffer_afterContextualStrings() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.2))
        let transcriber = RecordingTranscriber()
        let (appState, _) = try await makeAppState(capture: capture, transcriber: transcriber)

        await speak(appState)

        let events = await transcriber.events
        XCTAssertEqual(events, [.setContextualStrings(roster), .transcribe])
        let durations = await transcriber.durations
        XCTAssertEqual(durations.count, 1)
        XCTAssertEqual(durations.first ?? 0, 1.2, accuracy: 1e-9, "duration comes from the frame count")
        XCTAssertEqual(capture.startCalls, 1)
        XCTAssertEqual(capture.stopCalls, 1)
        guard case .cardA = appState.presentedSheet else {
            return XCTFail("groundout transcript must reach Card A, got \(String(describing: appState.presentedSheet))")
        }
    }

    func test_factoryBuildsAFreshCapturePerPress() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber(text: "the quick brown fox")   // → manual entry, idle
        let (appState, probe) = try await makeAppState(capture: capture, transcriber: transcriber)

        await speak(appState)
        appState.presentedSheet = nil
        await speak(appState)

        XCTAssertEqual(probe.buildCount, 2, "every press builds its own capture (media-services reset)")
        XCTAssertEqual(capture.startCalls, 2)
        XCTAssertEqual(capture.stopCalls, 2)
    }

    // MARK: R3 — nil buffer (interrupted) never transcribes

    func test_stopReturnsNil_goesIdleWithInterruptedMessage_neverTranscribes() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber()
        let (appState, _) = try await makeAppState(capture: capture, transcriber: transcriber)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        // Interrupted during the release tail: the source discards, so stop() returns nil. Emit
        // nothing on the event stream so only the release path sees it.
        capture.markInterruptedSilently()
        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))

        XCTAssertEqual(appState.pttState, .idle)
        let message = try XCTUnwrap(appState.presentedError?.message)
        XCTAssertTrue(message.lowercased().contains("interrupted"), message)
        let events = await transcriber.events
        XCTAssertEqual(events, [], "a discarded capture never reaches the transcriber")
        XCTAssertNil(appState.activeGame?.pendingResult)
    }

    func test_backgroundMidHold_stopsCapture_goesIdle_andReleaseDoesNothing() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber()
        let (appState, _) = try await makeAppState(capture: capture, transcriber: transcriber)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        XCTAssertEqual(appState.pttState, .listening)

        await awaitBounded(PushToTalkPipeline.scenePhaseChanged(.background, appState: appState))

        XCTAssertEqual(appState.pttState, .idle)
        XCTAssertEqual(capture.stopCalls, 1, "backgrounding stops (and discards) the capture")
        let message = try XCTUnwrap(appState.presentedError?.message)
        XCTAssertEqual(message, AppState.interruptionMessage(for: .background))

        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))
        XCTAssertEqual(capture.stopCalls, 1, "the later touch-up does not stop again")
        let events = await transcriber.events
        XCTAssertEqual(events, [], "nothing was transcribed")
    }

    func test_sceneBecomesActive_rereadsReadiness() async throws {
        let mic = FakeVoicePermission(.denied)
        let readiness = SpeechReadiness(microphone: mic, speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.succeed]))
        _ = await readiness.evaluate()
        await awaitPreload(readiness)
        let (appState, _) = try await makeAppState(capture: ControlledCapture(frames: []),
                                                   readiness: readiness)
        await appState.refreshVoiceReadiness()
        XCTAssertEqual(appState.voiceReadiness, .micDenied)

        await mic.set(.granted)   // the scorer flips the switch in Settings and comes back
        await awaitBounded(PushToTalkPipeline.scenePhaseChanged(.active, appState: appState))

        XCTAssertEqual(appState.voiceReadiness, .ready)
    }

    // MARK: R5 — not ready never starts a capture

    func test_pressWhileMicDenied_showsReadinessMessage_neverStarts() async throws {
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.denied),
                                        speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.succeed]))
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let (appState, probe) = try await makeAppState(capture: capture, readiness: readiness)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))

        XCTAssertEqual(capture.startCalls, 0, "no capture while the mic is denied")
        XCTAssertEqual(probe.buildCount, 0)
        XCTAssertEqual(appState.pttState, .idle)
        XCTAssertEqual(appState.presentedError?.message, AppState.readinessMessage(for: .micDenied))

        // Drags in the same touch do not re-prompt the message loop or start anything.
        appState.presentedError = nil
        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        XCTAssertNil(appState.presentedError, "the same touch is consumed")
        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))
        XCTAssertEqual(capture.startCalls, 0)
    }

    func test_pressWhileModelPreparing_showsModelMessage_neverStarts() async throws {
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.granted),
                                        speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.fail, .fail, .fail, .fail]))
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let (appState, _) = try await makeAppState(capture: capture, readiness: readiness)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))

        XCTAssertEqual(capture.startCalls, 0)
        XCTAssertEqual(appState.pttState, .idle)
        XCTAssertEqual(appState.presentedError?.message, AppState.readinessMessage(for: .modelPreparing))
    }

    func test_startThrowsPermissionDenied_showsMicMessage_goesIdle() async throws {
        let capture = ControlledCapture(frames: [], startError: .permissionDenied)
        let transcriber = RecordingTranscriber()
        let (appState, _) = try await makeAppState(capture: capture, transcriber: transcriber)

        await speak(appState)

        XCTAssertEqual(appState.pttState, .idle)
        XCTAssertEqual(appState.presentedError?.message, AppState.readinessMessage(for: .micDenied))
        let events = await transcriber.events
        XCTAssertEqual(events, [])
    }

    // MARK: Press/release races

    func test_releaseBeforeStartFinishes_stopsTheCaptureExactlyOnce() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0), holdStart: true)
        let transcriber = RecordingTranscriber()
        let (appState, _) = try await makeAppState(capture: capture, transcriber: transcriber)

        let started = PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState)
        await waitUntil("start() is in flight") { capture.startCalls == 1 }
        let released = PushToTalkPipeline.touchUp(appState: appState)
        XCTAssertEqual(appState.pttState, .processing, "release shows processing at once")
        XCTAssertEqual(capture.stopCalls, 0, "stop waits for start")

        capture.releaseStart()
        await awaitBounded(started)
        await awaitBounded(released)

        XCTAssertEqual(capture.startCalls, 1)
        XCTAssertEqual(capture.stopCalls, 1, "stopped exactly once, after start finished")
        let events = await transcriber.events
        XCTAssertEqual(events, [.setContextualStrings(roster), .transcribe])
    }

    func test_pressHandlerFiredTwiceBeforeStartResumes_startsOnce() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0), holdStart: true)
        let (appState, probe) = try await makeAppState(capture: capture)

        let first = PushToTalkPipeline.press(script: .groundOut63, appState: appState)
        XCTAssertEqual(appState.pttState, .listening, "the press leaves idle synchronously")
        let second = PushToTalkPipeline.press(script: .groundOut63, appState: appState)
        XCTAssertNil(second, "a second press while one is in flight is ignored")
        await waitUntil("start() is in flight") { capture.startCalls == 1 }

        capture.releaseStart()
        await awaitBounded(first)

        XCTAssertEqual(capture.startCalls, 1)
        XCTAssertEqual(probe.buildCount, 1)
        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))
        XCTAssertEqual(capture.stopCalls, 1)
    }

    // MARK: R2 — cap reached while the finger is down

    func test_capReachedWithFingerDown_runsReleaseOnce_dragsNeverRestart() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber(text: "the quick brown fox")   // → manual entry, idle
        let (appState, _) = try await makeAppState(capture: capture, transcriber: transcriber)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        capture.reachCap()
        await waitUntil("the release pipeline ran") {
            if case .manualEntry = appState.presentedSheet { return true }
            return false
        }
        XCTAssertEqual(appState.pttState, .idle)

        // The finger is still down: further drag changes in the same touch start nothing.
        for _ in 0..<3 {
            await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        }
        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))

        XCTAssertEqual(capture.startCalls, 1, "no restart within the same touch")
        XCTAssertEqual(capture.stopCalls, 1, "the cap release stopped once; touch-up adds nothing")
        let events = await transcriber.events
        XCTAssertEqual(events, [.setContextualStrings(roster), .transcribe], "transcribed once")
    }

    // MARK: R3 — interruption while the finger is down

    func test_interruptedWithFingerDown_goesIdleWithMessage_noTranscribe_noRestartUntilTouchUp() async throws {
        let capture = ControlledCapture(frames: syntheticPCM(seconds: 1.0))
        let transcriber = RecordingTranscriber(text: "the quick brown fox")
        let (appState, _) = try await makeAppState(capture: capture, transcriber: transcriber)

        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        capture.interrupt(.phoneCall)
        await waitUntil("the interruption returned PTT to idle") { appState.pttState == .idle }

        XCTAssertEqual(appState.presentedError?.message, AppState.interruptionMessage(for: .phoneCall))
        await awaitBounded(PushToTalkPipeline.touchDown(script: .groundOut63, appState: appState))
        XCTAssertEqual(capture.startCalls, 1, "no restart until a fresh touch-down")
        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))
        var events = await transcriber.events
        XCTAssertEqual(events, [], "an interrupted capture is never transcribed")
        XCTAssertEqual(appState.pttState, .idle)

        // A fresh touch works again.
        appState.presentedError = nil
        await speak(appState)
        XCTAssertEqual(capture.startCalls, 2)
        events = await transcriber.events
        XCTAssertEqual(events, [.setContextualStrings(roster), .transcribe])
    }

    // MARK: Messages

    func test_interruptionMessages_areReadableAndDistinct() {
        let reasons: [CaptureEvent.InterruptionReason] = [
            .phoneCall, .otherInterruption, .routeChange, .mediaServicesReset, .background,
        ]
        var seen = Set<String>()
        for reason in reasons {
            let message = AppState.interruptionMessage(for: reason)
            XCTAssertTrue(message.lowercased().contains("nothing was scored"), "\(reason): \(message)")
            XCTAssertTrue(seen.insert(message).inserted, "duplicate message for \(reason)")
        }
        XCTAssertFalse(seen.contains(AppState.captureInterruptedMessage))
    }
}
