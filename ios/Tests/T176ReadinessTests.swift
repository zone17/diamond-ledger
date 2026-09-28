/// T176ReadinessTests.swift — DL-176 U3 (R4, R5, KTD5)
///
/// `SpeechReadiness` computes `ready | micDenied | speechDenied | modelPreparing` from injected
/// live-status providers. Every provider here is a fake: the test host has no usage strings, so a
/// real `AVAudioApplication` / `SFSpeechRecognizer` / `AssetInventory` call would crash or prompt.

import XCTest
@testable import Core
@testable import UI
@testable import DiamondSpeech
import Auth

// MARK: - Fakes

/// Mic or speech permission whose status the test can flip (a user toggling it in Settings).
actor FakeVoicePermission: MicrophonePermissionProviding, SpeechAuthorizationProviding {
    private var current: VoicePermissionStatus
    /// What `request()` resolves the prompt to when the status is still `.notDetermined`.
    private let answer: VoicePermissionStatus
    private(set) var requestCount = 0
    private(set) var statusReads = 0

    init(_ current: VoicePermissionStatus, answer: VoicePermissionStatus = .granted) {
        self.current = current
        self.answer = answer
    }

    func set(_ status: VoicePermissionStatus) { current = status }

    func status() async -> VoicePermissionStatus {
        statusReads += 1
        return current
    }

    func request() async -> VoicePermissionStatus {
        requestCount += 1
        if current == .notDetermined { current = answer }
        return current
    }
}

/// Model preloader whose outcome is scripted per call; can also hold a call open until released.
actor FakePreloader: SpeechModelPreloading {
    enum Outcome { case succeed, fail, hold }

    private var outcomes: [Outcome]
    private(set) var callCount = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Sticky: a preload that reaches its hold after `releaseHeld()` does not wait (the detached
    /// preload may not have started yet when the test releases it).
    private var released = false

    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

    func preload() async throws {
        callCount += 1
        let outcome = outcomes.isEmpty ? .succeed : outcomes.removeFirst()
        switch outcome {
        case .succeed: return
        case .fail: throw TranscriberError.transcriptionFailed("fake download failed")
        case .hold:
            if released { return }
            await withCheckedContinuation { held.append($0) }
        }
    }

    /// Lets any held preload finish successfully.
    func releaseHeld() {
        released = true
        let pending = held
        held = []
        pending.forEach { $0.resume() }
    }
}

// MARK: - Bounded waiting

extension XCTestCase {
    /// Awaits the readiness preload with a hard bound: a fake that is never resumed fails the test
    /// after `timeout` instead of hanging the suite (the stuck task is abandoned, not awaited).
    @MainActor
    func awaitPreload(_ readiness: SpeechReadiness, timeout: TimeInterval = 2) async {
        let done = expectation(description: "preload settles")
        Task {
            await readiness.waitForPreload()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
    }
}

// MARK: - SpeechReadiness

@MainActor
final class T176SpeechReadinessTests: XCTestCase {

    func test_bothGranted_modelReady_isReady() async {
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.granted),
                                        speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.succeed]))
        _ = await readiness.evaluate()
        await awaitPreload(readiness)
        let state = await readiness.evaluate()
        XCTAssertEqual(state, .ready)
    }

    func test_micDenied_isMicDenied() async {
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.denied),
                                        speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.succeed]))
        let state = await readiness.evaluate()
        XCTAssertEqual(state, .micDenied)
    }

    func test_speechDenied_isSpeechDenied() async {
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.granted),
                                        speech: FakeVoicePermission(.denied),
                                        model: FakePreloader([.succeed]))
        let state = await readiness.evaluate()
        XCTAssertEqual(state, .speechDenied)
    }

    func test_preloadFails_isModelPreparing_thenRetrySucceeds_isReady() async {
        let model = FakePreloader([.fail, .succeed])
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.granted),
                                        speech: FakeVoicePermission(.granted),
                                        model: model)
        _ = await readiness.evaluate()          // starts the first (failing) preload
        await awaitPreload(readiness)
        let afterFailure = await readiness.evaluate()   // not ready → retries the preload
        XCTAssertEqual(afterFailure, .modelPreparing)
        await awaitPreload(readiness)
        let afterRetry = await readiness.evaluate()
        XCTAssertEqual(afterRetry, .ready)
        let calls = await model.callCount
        XCTAssertEqual(calls, 2, "a failed preload is retried exactly once per re-evaluation")
    }

    func test_preloadInFlight_isNotDuplicated() async {
        let model = FakePreloader([.hold])
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.granted),
                                        speech: FakeVoicePermission(.granted),
                                        model: model)
        let first = await readiness.evaluate()
        let second = await readiness.evaluate()
        XCTAssertEqual(first, .modelPreparing)
        XCTAssertEqual(second, .modelPreparing)
        await model.releaseHeld()
        await awaitPreload(readiness)
        let calls = await model.callCount
        XCTAssertEqual(calls, 1, "a preload already in flight is not started again")
        let state = await readiness.evaluate()
        XCTAssertEqual(state, .ready)
    }

    func test_micFlipsToGranted_isSeenOnNextEvaluation() async {
        let mic = FakeVoicePermission(.denied)
        let readiness = SpeechReadiness(microphone: mic,
                                        speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.succeed]))
        let before = await readiness.evaluate()
        XCTAssertEqual(before, .micDenied)
        await awaitPreload(readiness)
        await mic.set(.granted)                  // the scorer allowed it in Settings
        let after = await readiness.evaluate()
        XCTAssertEqual(after, .ready, "live status is re-read on every evaluation — no cached answer")
    }

    func test_prepareForNewGame_requestsBothPermissions_andDoesNotWaitForModel() async {
        let mic = FakeVoicePermission(.notDetermined)
        let speech = FakeVoicePermission(.notDetermined)
        let model = FakePreloader([.hold])
        let readiness = SpeechReadiness(microphone: mic, speech: speech, model: model)

        let state = await readiness.prepareForNewGame()   // returns while the preload is held

        XCTAssertEqual(state, .modelPreparing)
        let micRequests = await mic.requestCount
        let speechRequests = await speech.requestCount
        XCTAssertEqual(micRequests, 1)
        XCTAssertEqual(speechRequests, 1)
        await model.releaseHeld()
        await awaitPreload(readiness)
    }

    func test_notDeterminedMic_isNotReady() async {
        // A press never prompts (R4); an unanswered prompt cannot capture.
        let mic = FakeVoicePermission(.notDetermined)
        let readiness = SpeechReadiness(microphone: mic,
                                        speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.succeed]))
        let state = await readiness.evaluate()
        XCTAssertEqual(state, .micDenied)
        let requests = await mic.requestCount
        XCTAssertEqual(requests, 0, "evaluate() never shows a permission prompt")
    }
}

// MARK: - AppState readiness hook

@MainActor
final class T176AppStateReadinessTests: XCTestCase {

    private func makeAppState(readiness: SpeechReadiness) throws -> AppState {
        let defaults = UserDefaults(suiteName: "test.t176.\(UUID().uuidString)")!
        let appState = AppState(core: MockCore(),
                                consentDefaults: defaults,
                                authStore: AuthStore(store: InMemorySessionStore()),
                                speechReadiness: readiness)
        try appState.completeAppleSignIn(appleUserID: "adult-176", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)
        return appState
    }

    func test_startNewGame_completesWhilePreloadIsStillPending() async throws {
        let model = FakePreloader([.hold])
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.notDetermined),
                                        speech: FakeVoicePermission(.notDetermined),
                                        model: model)
        let appState = try makeAppState(readiness: readiness)

        await appState.startNewGame(homeTeam: "Hawks", visitorTeam: "Owls")

        XCTAssertNotNil(appState.activeGame, "New Game never waits for the model download")
        XCTAssertEqual(appState.voiceReadiness, .modelPreparing)
        await model.releaseHeld()
        await awaitPreload(readiness)
        let calls = await model.callCount
        XCTAssertEqual(calls, 1, "the preload was started (detached) by New Game")
        let refreshed = await appState.refreshVoiceReadiness()
        XCTAssertEqual(refreshed, .ready)
        XCTAssertEqual(appState.voiceReadiness, .ready)
    }

    func test_micDenied_surfacesSettingsMessage_andManualEntryStaysAvailable() async throws {
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.denied),
                                        speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.succeed]))
        let appState = try makeAppState(readiness: readiness)
        await appState.startNewGame(homeTeam: "Hawks", visitorTeam: "Owls")

        XCTAssertNotNil(appState.activeGame, "a denied mic never blocks the game (manual entry)")
        XCTAssertEqual(appState.voiceReadiness, .micDenied)
        let message = try XCTUnwrap(appState.voiceReadinessMessage)
        XCTAssertTrue(message.contains("Settings"), message)
        XCTAssertTrue(message.lowercased().contains("microphone"), message)
        XCTAssertTrue(message.lowercased().contains("manual"), message)
    }

    func test_micGrantedInSettings_isPickedUpWithoutANewGame() async throws {
        let mic = FakeVoicePermission(.denied)
        let readiness = SpeechReadiness(microphone: mic,
                                        speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.succeed]))
        let appState = try makeAppState(readiness: readiness)
        await appState.startNewGame(homeTeam: "Hawks", visitorTeam: "Owls")
        XCTAssertEqual(appState.voiceReadiness, .micDenied)
        let gameId = appState.activeGame?.gameId

        await awaitPreload(readiness)
        await mic.set(.granted)
        let state = await appState.refreshVoiceReadiness()

        XCTAssertEqual(state, .ready)
        XCTAssertNil(appState.voiceReadinessMessage)
        XCTAssertEqual(appState.activeGame?.gameId, gameId, "same game — no New Game needed")
    }

    func test_readinessMessages_areReadableAndDistinct() {
        XCTAssertNil(AppState.readinessMessage(for: .ready))
        let mic = AppState.readinessMessage(for: .micDenied) ?? ""
        let speech = AppState.readinessMessage(for: .speechDenied) ?? ""
        let model = AppState.readinessMessage(for: .modelPreparing) ?? ""
        XCTAssertTrue(mic.contains("Settings"))
        XCTAssertTrue(speech.contains("Settings"))
        XCTAssertTrue(speech.lowercased().contains("speech"))
        XCTAssertTrue(model.lowercased().contains("voice model still downloading"), model)
        XCTAssertTrue(model.contains("Wi-Fi"), model)
        XCTAssertEqual(Set([mic, speech, model]).count, 3)
        for message in [mic, speech, model] {
            XCTAssertTrue(message.lowercased().contains("manual"), "manual entry stays available: \(message)")
        }
    }

    func test_startNewGame_signedOut_neverPrompts() async throws {
        let mic = FakeVoicePermission(.notDetermined)
        let speech = FakeVoicePermission(.notDetermined)
        let readiness = SpeechReadiness(microphone: mic, speech: speech, model: FakePreloader([]))
        let defaults = UserDefaults(suiteName: "test.t176.\(UUID().uuidString)")!
        let appState = AppState(core: MockCore(), consentDefaults: defaults,
                                authStore: AuthStore(store: InMemorySessionStore()),
                                speechReadiness: readiness)

        await appState.startNewGame(homeTeam: "Hawks", visitorTeam: "Owls")

        XCTAssertNil(appState.activeGame)
        let micRequests = await mic.requestCount
        XCTAssertEqual(micRequests, 0, "no permission prompt before a game can actually start")
    }
}

// MARK: - Engine selection on device (KTD6)

final class T176EngineSelectorDeviceTests: XCTestCase {

    #if DEBUG
    func test_speechDenied_onDeviceBranch_resolvesUnavailable_neverStub() async {
        let previous = TranscriberEngineSelector.forceStub
        defer { TranscriberEngineSelector.forceStub = previous }
        TranscriberEngineSelector.forceStub = false      // the device branch

        let transcriber = await TranscriberEngineSelector.resolve(
            speechAuthorization: FakeVoicePermission(.denied))

        XCTAssertTrue(transcriber is UnavailableTranscriber,
                      "got \(type(of: transcriber)) — a device must never fall back to the Stub")
        XCTAssertFalse(transcriber is StubTranscriber)
        let available = await transcriber.isAvailable
        XCTAssertFalse(available)
        do {
            _ = try await transcriber.transcribe(
                buffer: AudioBuffer(rawBytes: Data([1, 2, 3, 4]), durationSeconds: 1, capturedAt: Date()))
            XCTFail("an unavailable engine must throw, never return a transcript")
        } catch TranscriberError.permissionDenied {
            // expected
        } catch {
            XCTFail("expected permissionDenied, got \(error)")
        }
    }

    func test_speechGranted_onDeviceBranch_resolvesApple_neverStub() async {
        let previous = TranscriberEngineSelector.forceStub
        defer { TranscriberEngineSelector.forceStub = previous }
        TranscriberEngineSelector.forceStub = false

        let transcriber = await TranscriberEngineSelector.resolve(
            speechAuthorization: FakeVoicePermission(.granted))

        XCTAssertEqual(transcriber.engine, .apple)
        XCTAssertFalse(transcriber is StubTranscriber)
    }

    func test_forceStub_stillResolvesStub_forTheDebugDemo() async {
        let previous = TranscriberEngineSelector.forceStub
        defer { TranscriberEngineSelector.forceStub = previous }
        TranscriberEngineSelector.forceStub = true

        let transcriber = await TranscriberEngineSelector.resolve(
            speechAuthorization: FakeVoicePermission(.denied))
        XCTAssertTrue(transcriber is StubTranscriber)
    }
    #endif

    func test_unavailableTranscriber_engineUnavailable_throwsThatReason() async {
        let transcriber = UnavailableTranscriber(reason: .engineUnavailable(.apple))
        do {
            _ = try await transcriber.transcribe(
                buffer: AudioBuffer(rawBytes: Data(), durationSeconds: 0, capturedAt: Date()))
            XCTFail("must throw")
        } catch TranscriberError.engineUnavailable(let engine) {
            XCTAssertEqual(engine, .apple)
        } catch {
            XCTFail("expected engineUnavailable, got \(error)")
        }
        do {
            try await transcriber.preloadAssets()
            XCTFail("preload must throw too")
        } catch {}
    }
}
