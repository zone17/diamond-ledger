/// PTTTestSupport.swift — shared push-to-talk test helpers (DL-176 U4).
///
/// Used by `T157PushToTalkWiringTests` and `T176PushToTalkCaptureTests`:
///   - `ControlledCapture`: an `AudioCaptureSource` fake that counts `start()`/`stop()` calls, can
///     hold `start()` open, and can emit `capReached` / `interrupted` mid-hold.
///   - `syntheticPCM(seconds:)`: 16 kHz mono Int16 sine frames (never a real microphone).
///   - `readySpeechReadiness()`: a `SpeechReadiness` over fake providers, primed to `.ready`.
///   - `speak`, `awaitBounded`, `waitUntil`: bounded drivers so no test can hang the suite.
///
/// Nothing here touches `AVAudioEngine`, an audio session, or a real permission API.

import XCTest
import Foundation
import Synchronization
@testable import Core
@testable import UI
@testable import DiamondSpeech

// MARK: - Synthetic PCM

/// `seconds` of a 440 Hz sine at 16 kHz mono Int16 — the transcriber's capture layout.
func syntheticPCM(seconds: Double) -> [Int16] {
    let count = Int((seconds * PCM16Accumulator.sampleRate).rounded())
    return (0..<count).map { index in
        Int16(8_000 * sin(2 * Double.pi * 440 * Double(index) / PCM16Accumulator.sampleRate))
    }
}

// MARK: - Controlled capture

/// An `AudioCaptureSource` whose every call is counted and whose timing the test controls.
///
/// Follows the live contract: `stop()` returns `nil` when the capture was interrupted or never
/// started; `events` is a finite per-capture stream created by `start()`.
final class ControlledCapture: AudioCaptureSource {
    private struct State: ~Copyable {
        var frames: [Int16]
        var startCalls = 0
        var stopCalls = 0
        var capturing = false
        var interrupted = false
        var holdStart: Bool
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var startError: TranscriberError?
        var continuation: AsyncStream<CaptureEvent>.Continuation?
        var stream: AsyncStream<CaptureEvent>
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - frames: what a clean `stop()` returns (16 kHz mono Int16).
    ///   - holdStart: `start()` suspends until `releaseStart()`.
    ///   - startError: `start()` throws this (after any hold).
    init(frames: [Int16], holdStart: Bool = false, startError: TranscriberError? = nil) {
        let (stream, continuation) = AsyncStream<CaptureEvent>.makeStream()
        continuation.finish()
        state = Mutex(State(frames: frames, holdStart: holdStart, startError: startError, stream: stream))
    }

    var startCalls: Int { state.withLock { $0.startCalls } }
    var stopCalls: Int { state.withLock { $0.stopCalls } }

    var events: AsyncStream<CaptureEvent> { state.withLock { $0.stream } }

    func start() async throws {
        let hold = state.withLock { state -> Bool in
            state.startCalls += 1
            return state.holdStart
        }
        if hold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    guard state.holdStart else { return true }
                    state.startWaiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let (stream, continuation) = AsyncStream<CaptureEvent>.makeStream()
        let error = state.withLock { state -> TranscriberError? in
            if let error = state.startError { return error }
            state.stream = stream
            state.continuation = continuation
            state.capturing = true
            state.interrupted = false
            return nil
        }
        if let error { throw error }
    }

    /// Lets every held `start()` continue (sticky: a start that has not reached its hold yet
    /// will not wait either).
    func releaseStart() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.holdStart = false
            let waiters = state.startWaiters
            state.startWaiters = []
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func stop() async -> DiamondSpeech.AudioBuffer? {
        let (continuation, frames) = state.withLock {
            state -> (AsyncStream<CaptureEvent>.Continuation?, [Int16]?) in
            state.stopCalls += 1
            let continuation = state.continuation
            state.continuation = nil
            let frames: [Int16]? = state.capturing && !state.interrupted ? state.frames : nil
            state.capturing = false
            return (continuation, frames)
        }
        continuation?.finish()
        guard let frames else { return nil }
        var accumulator = PCM16Accumulator()
        accumulator.append(frames)
        return accumulator.makeBuffer(capturedAt: Date())
    }

    /// The live source's interruption path: discard, emit the reason, end the stream.
    func interrupt(_ reason: CaptureEvent.InterruptionReason) {
        let continuation = state.withLock { state -> AsyncStream<CaptureEvent>.Continuation? in
            state.interrupted = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.yield(.interrupted(reason))
        continuation?.finish()
    }

    /// An interruption that only the release path sees (it lands during the release tail, after
    /// the owner stopped reading events): the next `stop()` returns `nil`.
    func markInterruptedSilently() {
        state.withLock { $0.interrupted = true }
    }

    /// The 15 s cap: emit `capReached`; the owner treats it as a release.
    func reachCap() {
        state.withLock { $0.continuation }?.yield(.capReached)
    }
}

/// Counts how many captures the factory built (one per press).
final class CaptureFactoryProbe: Sendable {
    private let built = Mutex(0)
    let capture: ControlledCapture

    init(_ capture: ControlledCapture) { self.capture = capture }

    var buildCount: Int { built.withLock { $0 } }

    var factory: @Sendable () -> any AudioCaptureSource {
        { [self] in
            built.withLock { $0 += 1 }
            return capture
        }
    }
}

// MARK: - Bounded drivers

extension XCTestCase {

    /// A `SpeechReadiness` whose fake providers are granted and whose model preload has finished,
    /// so the first `evaluate()` on a press returns `.ready`.
    @MainActor
    func readySpeechReadiness() async -> SpeechReadiness {
        let readiness = SpeechReadiness(microphone: FakeVoicePermission(.granted),
                                        speech: FakeVoicePermission(.granted),
                                        model: FakePreloader([.succeed]))
        _ = await readiness.evaluate()
        await awaitPreload(readiness)
        return readiness
    }

    /// Awaits `task` with a hard bound; a stuck task fails the test instead of hanging the suite.
    @MainActor
    func awaitBounded(_ task: Task<Void, Never>?, timeout: TimeInterval = 5) async {
        guard let task else { return }
        let done = expectation(description: "task settles")
        Task {
            await task.value
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
    }

    /// Polls `condition` on the main actor until it holds, failing after `timeout`.
    @MainActor
    func waitUntil(_ what: String, timeout: TimeInterval = 5,
                   file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// One whole push-to-talk utterance: touch-down, wait for the capture to start, touch-up,
    /// wait for the release pipeline to finish.
    @MainActor
    func speak(_ appState: AppState, script: WoZScript = .groundOut63) async {
        await awaitBounded(PushToTalkPipeline.touchDown(script: script, appState: appState))
        await awaitBounded(PushToTalkPipeline.touchUp(appState: appState))
    }
}
