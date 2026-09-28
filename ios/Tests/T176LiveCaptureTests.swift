/// T176LiveCaptureTests.swift — DL-176 U2: `LiveAudioCapture` driven entirely through fakes.
///
/// CI safety (plan KTD1): the test host has no microphone usage string, so nothing here touches
/// `AVAudioEngine.inputNode`, an `AVAudioSession`, or a real permission API. `LiveAudioCapture`
/// is built with a `FakeAudioEngine` (records every call, hands the installed tap handler back to
/// the test), a scripted `MicrophonePermissionProviding` (U3's seam), and a `FakeInterruptionSource`. Every await that
/// could hang is bounded by an `XCTestExpectation` of at most 5 s.
///
/// Coverage (plan U2 test scenarios):
///   - Mic permission denied or unanswered → `permissionDenied`, no prompt, no session, no tap.
///   - Unconvertible input format (0 channels / 0 Hz / none) → `engineUnavailable`, no tap.
///   - Happy path: synthetic 48 kHz buffers through the installed tap → a buffer of the expected
///     duration; teardown order is tap removed → engine stopped → session deactivated.
///   - Chunks delivered just before and during the release tail are in the buffer.
///   - Interruption → `events` emits `.interrupted(.phoneCall)`, same teardown order, `stop()` nil.
///   - Cap (0.2 s injected) → `events` emits `.capReached` exactly once; `stop()` still returns audio.
///   - A second `start()` while capturing is ignored: the capture continues untouched.
///   - Engine start failure → `engineUnavailable`, tap removed, session deactivated.

import XCTest
import Foundation
import AVFoundation
import Synchronization
@testable import DiamondSpeech

// MARK: - Fakes

/// Records engine/session calls and exposes the installed tap so the test can "speak".
final class FakeAudioEngine: AudioEngineDriving {
    enum Call: Equatable { case activate, installTap, startEngine, removeTap, stopEngine, deactivate }

    private struct State {
        var calls: [Call] = []
        var handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    }

    private let state = Mutex(State())
    private let format: AVAudioFormat?
    private let startFails: Bool

    init(format: AVAudioFormat? = LiveSynth.format48kMono, startFails: Bool = false) {
        self.format = format
        self.startFails = startFails
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var hasTap: Bool { state.withLock { $0.handler != nil } }

    func activateSession() throws { record(.activate) }
    func inputFormat() -> AVAudioFormat? { format }
    func installTap(format: AVAudioFormat,
                    handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        state.withLock {
            $0.calls.append(.installTap)
            $0.handler = handler
        }
    }
    func removeTap() {
        state.withLock {
            $0.calls.append(.removeTap)
            $0.handler = nil
        }
    }
    func startEngine() throws {
        record(.startEngine)
        if startFails { throw NSError(domain: "FakeAudioEngine", code: 1) }
    }
    func stopEngine() { record(.stopEngine) }
    func deactivateSession() { record(.deactivate) }

    /// Delivers one synthetic tap buffer the way the engine would; a no-op once the tap is removed.
    func deliver(seconds: Double) {
        guard let handler = state.withLock({ $0.handler }) else { return }
        let chunk = LiveSynth.sine(seconds: seconds)
        handler(chunk, AVAudioTime(sampleTime: 0, atRate: 48_000))
    }

    private func record(_ call: Call) { state.withLock { $0.calls.append(call) } }
}

/// A notification source the test drives: each subscription gets a fresh stream.
final class FakeInterruptionSource: Sendable {
    private let sinks = Mutex<[AsyncStream<CaptureEvent.InterruptionReason>.Continuation]>([])

    var subscriptions: Int { sinks.withLock { $0.count } }

    func subscribe() -> AsyncStream<CaptureEvent.InterruptionReason> {
        let (stream, sink) = AsyncStream<CaptureEvent.InterruptionReason>.makeStream()
        sinks.withLock { $0.append(sink) }
        return stream
    }

    func post(_ reason: CaptureEvent.InterruptionReason) {
        sinks.withLock { $0.last }?.yield(reason)
    }
}

/// U3's microphone seam with a scripted status; counts status reads and any prompt attempt.
final class FakePermission: MicrophonePermissionProviding {
    private let answer: VoicePermissionStatus
    private let counts = Mutex((checks: 0, requests: 0))
    init(_ answer: VoicePermissionStatus) { self.answer = answer }
    var checks: Int { counts.withLock { $0.checks } }
    var requests: Int { counts.withLock { $0.requests } }
    func status() async -> VoicePermissionStatus {
        counts.withLock { $0.checks += 1 }
        return answer
    }
    func request() async -> VoicePermissionStatus {
        counts.withLock { $0.requests += 1 }
        return answer
    }
}

enum LiveSynth {
    static let format48kMono = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    )

    static func sine(seconds: Double) -> AVAudioPCMBuffer {
        let format = format48kMono!
        let frames = AVAudioFrameCount((48_000 * seconds).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / 48_000))
        }
        return buffer
    }
}

private final class ResultBox<T: Sendable>: Sendable {
    private let value = Mutex<T?>(nil)
    func set(_ newValue: T) { value.withLock { $0 = newValue } }
    func get() -> T? { value.withLock { $0 } }
}

// MARK: - Tests

final class T176LiveCaptureTests: XCTestCase {

    private func makeCapture(
        engine: FakeAudioEngine = FakeAudioEngine(),
        permission status: VoicePermissionStatus = .granted,
        source: FakeInterruptionSource = FakeInterruptionSource(),
        cap: Duration = .seconds(15),
        releaseTail: Duration = .zero
    ) -> (LiveAudioCapture, FakeAudioEngine, FakePermission, FakeInterruptionSource) {
        let permission = FakePermission(status)
        let capture = LiveAudioCapture(
            engine: engine,
            microphone: permission,
            interruptions: { source.subscribe() },
            cap: cap,
            releaseTail: releaseTail
        )
        return (capture, engine, permission, source)
    }

    /// Runs `operation` in its own task and waits at most `timeout` seconds for it. Returns `nil`
    /// (and fails the expectation) if it does not finish, so a regression never hangs the suite.
    private func bounded<T: Sendable>(
        _ label: String,
        timeout: TimeInterval = 5,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let box = ResultBox<T>()
        let done = expectation(description: label)
        Task {
            box.set(await operation())
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
        return box.get()
    }

    /// Stops the capture within the bound and reports the returned buffer's duration
    /// (`.some(nil)` means `stop()` returned `nil`).
    private func stopDuration(_ capture: LiveAudioCapture) async -> Double?? {
        await bounded("stop returns") { () -> Double? in
            guard let buffer = await capture.stop() else { return nil }
            return buffer.durationSeconds
        }
    }

    private func collect(_ events: AsyncStream<CaptureEvent>) async -> [CaptureEvent]? {
        await bounded("events stream finishes") {
            var received: [CaptureEvent] = []
            for await event in events { received.append(event) }
            return received
        }
    }

    // MARK: Start failures

    func testPermissionDeniedOrUnanswered_throws_neverPrompts_andTouchesNoSessionOrTap() async {
        for status: VoicePermissionStatus in [.denied, .notDetermined] {
            let (capture, engine, permission, source) = makeCapture(permission: status)
            do {
                try await capture.start()
                XCTFail("start must throw when the microphone is \(status)")
            } catch TranscriberError.permissionDenied {
                // expected
            } catch {
                XCTFail("expected permissionDenied, got \(error)")
            }
            XCTAssertEqual(permission.checks, 1)
            XCTAssertEqual(permission.requests, 0, "a press never shows the permission prompt")
            XCTAssertEqual(engine.calls, [], "no session configured, no tap installed")
            XCTAssertEqual(source.subscriptions, 0)
            let stopped = await stopDuration(capture)
            XCTAssertEqual(stopped, .some(nil), "stop after a failed start returns nil")
        }
    }

    func testUnconvertibleInputFormat_throwsEngineUnavailable_withNoTap() async throws {
        // A route with no input reports 0 channels or 0 Hz; installing a tap on it would raise an
        // uncatchable exception. Try each shape AVAudioFormat lets us build, plus "no format".
        var formats: [AVAudioFormat?] = [nil]
        if let zeroHz = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0,
                                      channels: 1, interleaved: false) {
            formats.append(zeroHz)
        }
        var zeroChannels = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 0, mBitsPerChannel: 32, mReserved: 0
        )
        if let zeroCh = AVAudioFormat(streamDescription: &zeroChannels) {
            formats.append(zeroCh)
        }

        for format in formats {
            let (capture, engine, _, _) = makeCapture(engine: FakeAudioEngine(format: format))
            do {
                try await capture.start()
                XCTFail("start must throw for format \(String(describing: format))")
            } catch TranscriberError.engineUnavailable(let engineKind) {
                XCTAssertEqual(engineKind, .apple)
            } catch {
                XCTFail("expected engineUnavailable, got \(error)")
            }
            XCTAssertFalse(engine.calls.contains(.installTap), "no tap on an unconvertible format")
            XCTAssertFalse(engine.calls.contains(.startEngine))
            XCTAssertEqual(engine.calls.last, .deactivate, "the activated session is released")
        }
    }

    func testEngineStartFailure_throwsEngineUnavailable_andReleasesTapAndSession() async {
        let (capture, engine, _, _) = makeCapture(engine: FakeAudioEngine(startFails: true))
        do {
            try await capture.start()
            XCTFail("start must throw when the engine does not start")
        } catch TranscriberError.engineUnavailable {
            // expected
        } catch {
            XCTFail("expected engineUnavailable, got \(error)")
        }
        XCTAssertEqual(engine.calls, [.activate, .installTap, .startEngine, .removeTap, .deactivate])
        XCTAssertFalse(engine.hasTap)
    }

    // MARK: Happy path

    func testHappyPath_tapBuffersBecomeOneBuffer_andTeardownIsOrdered() async throws {
        let (capture, engine, _, source) = makeCapture()
        try await capture.start()
        XCTAssertEqual(engine.calls, [.activate, .installTap, .startEngine])
        XCTAssertEqual(source.subscriptions, 1)
        let events = capture.events

        // Ten 100 ms chunks at 48 kHz, delivered from the engine's (background) thread.
        let delivered = expectation(description: "tap delivered on a background queue")
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<10 { engine.deliver(seconds: 0.1) }
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 5)

        let duration = await stopDuration(capture)
        let seconds = try XCTUnwrap(try XCTUnwrap(duration), "stop returned nil")
        XCTAssertEqual(seconds, 1.0, accuracy: 2.0 / 16_000, "duration comes from the frame count")
        XCTAssertEqual(engine.calls,
                       [.activate, .installTap, .startEngine, .removeTap, .stopEngine, .deactivate],
                       "tap removed, then engine stopped, then session deactivated")
        let received = await collect(events)
        XCTAssertEqual(received, [], "a clean release emits no events and finishes the stream")
    }

    func testChunksDeliveredJustBeforeStop_areInTheBuffer() async throws {
        let (capture, engine, _, _) = makeCapture()
        try await capture.start()
        engine.deliver(seconds: 0.5)
        engine.deliver(seconds: 0.25)   // the last chunk, immediately before release
        let duration = await stopDuration(capture)
        let seconds = try XCTUnwrap(try XCTUnwrap(duration))
        XCTAssertEqual(seconds, 0.75, accuracy: 2.0 / 16_000, "the resampler tail is drained, nothing lost")
    }

    func testChunksDuringTheReleaseTail_areInTheBuffer() async throws {
        let (capture, engine, _, _) = makeCapture(releaseTail: .milliseconds(500))
        try await capture.start()
        engine.deliver(seconds: 0.5)
        let clock = ContinuousClock()
        let released = clock.now
        let stopping = Task { () -> Double? in
            guard let buffer = await capture.stop() else { return nil }
            return buffer.durationSeconds
        }
        // The finger is up; the tap keeps running for the tail and catches the last word.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(engine.hasTap, "the tap stays installed during the release tail")
        engine.deliver(seconds: 0.25)

        let done = expectation(description: "stop finishes")
        let box = ResultBox<Double?>()
        Task {
            box.set(await stopping.value)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertGreaterThanOrEqual(clock.now - released, .milliseconds(450), "stop waited the tail")
        let seconds = try XCTUnwrap(try XCTUnwrap(box.get()))
        XCTAssertEqual(seconds, 0.75, accuracy: 2.0 / 16_000)
    }

    func testStopWithoutStart_returnsNil_andTouchesNothing() async {
        let (capture, engine, _, _) = makeCapture()
        let stopped = await stopDuration(capture)
        XCTAssertEqual(stopped, .some(nil))
        XCTAssertEqual(engine.calls, [])
    }

    // MARK: Interruption (R3)

    func testInterruption_emitsReason_tearsDownInOrder_andStopReturnsNil() async throws {
        let (capture, engine, _, source) = makeCapture()
        try await capture.start()
        let events = capture.events
        engine.deliver(seconds: 0.5)

        source.post(.phoneCall)
        let received = await collect(events)
        XCTAssertEqual(received, [.interrupted(.phoneCall)])
        XCTAssertEqual(engine.calls,
                       [.activate, .installTap, .startEngine, .removeTap, .stopEngine, .deactivate])
        XCTAssertFalse(engine.hasTap)

        // Audio after the interruption never reaches a buffer, and stop() reports nothing.
        engine.deliver(seconds: 0.5)
        let stopped = await stopDuration(capture)
        XCTAssertEqual(stopped, .some(nil), "interrupted audio is discarded, never transcribed")
        XCTAssertEqual(engine.calls.filter { $0 == .deactivate }.count, 1, "teardown runs once")
    }

    func testEveryNotificationReason_isForwarded() async throws {
        for reason: CaptureEvent.InterruptionReason in [.otherInterruption, .routeChange, .mediaServicesReset] {
            let (capture, _, _, source) = makeCapture()
            try await capture.start()
            let events = capture.events
            source.post(reason)
            let received = await collect(events)
            XCTAssertEqual(received, [.interrupted(reason)])
        }
    }

    func testAfterInterruption_aFreshStartCapturesAgain() async throws {
        let (capture, engine, _, source) = makeCapture()
        try await capture.start()
        let first = capture.events
        source.post(.routeChange)
        _ = await collect(first)

        try await capture.start()
        XCTAssertEqual(source.subscriptions, 2, "each capture subscribes afresh")
        engine.deliver(seconds: 0.5)
        let duration = await stopDuration(capture)
        let seconds = try XCTUnwrap(try XCTUnwrap(duration))
        XCTAssertEqual(seconds, 0.5, accuracy: 2.0 / 16_000, "no audio from the interrupted capture leaks in")
    }

    // MARK: Cap (R2)

    func testCap_emitsCapReachedExactlyOnce_andStopStillReturnsAudio() async throws {
        let (capture, engine, _, _) = makeCapture(cap: .milliseconds(200))
        try await capture.start()
        let events = capture.events
        engine.deliver(seconds: 0.3)

        // Wait well past two cap periods so a repeating timer would have fired twice.
        try await Task.sleep(for: .milliseconds(600))
        let duration = await stopDuration(capture)
        let seconds = try XCTUnwrap(try XCTUnwrap(duration), "a cap is a release, not a discard")
        XCTAssertEqual(seconds, 0.3, accuracy: 2.0 / 16_000)

        let received = await collect(events)
        XCTAssertEqual(received, [.capReached])
    }

    func testCap_isNotEmittedAfterAnEarlyRelease() async throws {
        let (capture, _, _, _) = makeCapture(cap: .milliseconds(200))
        try await capture.start()
        let events = capture.events
        _ = await stopDuration(capture)
        try await Task.sleep(for: .milliseconds(400))
        let received = await collect(events)
        XCTAssertEqual(received, [])
    }

    // MARK: Duplicate press

    func testSecondStartWhileCapturing_isIgnored() async throws {
        let (capture, engine, permission, source) = makeCapture()
        try await capture.start()
        let events = capture.events
        engine.deliver(seconds: 0.25)

        try await capture.start()   // a duplicate touch-down: no error, no new session
        XCTAssertEqual(engine.calls, [.activate, .installTap, .startEngine])
        XCTAssertEqual(permission.checks, 1)
        XCTAssertEqual(permission.requests, 0)
        XCTAssertEqual(source.subscriptions, 1)

        engine.deliver(seconds: 0.25)
        let duration = await stopDuration(capture)
        let seconds = try XCTUnwrap(try XCTUnwrap(duration))
        XCTAssertEqual(seconds, 0.5, accuracy: 2.0 / 16_000, "the original capture kept every chunk")
        let received = await collect(events)
        XCTAssertEqual(received, [], "the original capture's stream is the one that finishes")
    }

    // MARK: Events stream shape

    func testEventsBeforeAnyStart_isAlreadyFinished() async {
        let (capture, _, _, _) = makeCapture()
        let received = await collect(capture.events)
        XCTAssertEqual(received, [])
    }
}
