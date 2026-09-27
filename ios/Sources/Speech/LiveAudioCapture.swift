/// LiveAudioCapture.swift — DL-176 U2: the device implementation of `AudioCaptureSource`.
///
/// `LiveAudioCapture` runs one push-to-talk capture on the audio engine: press → `start()`,
/// release → `stop()`, with a 15 s cap and a 250 ms release tail (plan R1, R2), and ends the
/// utterance on an interruption, an engine reconfiguration, or a media-services reset (R3).
///
/// Everything it touches in the OS sits behind an injected seam, so the capture logic runs in
/// the simulator against fakes and no CI test ever touches `AVAudioEngine.inputNode`, an audio
/// session, or a permission API (plan KTD1):
///   - `AudioEngineDriving` — session configure/activate/deactivate, input format, tap, engine.
///     `LiveAudioEngine` is the real one (KTD4).
///   - `microphone` — U3's `MicrophonePermissionProviding`, the one permission seam shared with
///     `SpeechReadiness`, so readiness and capture never disagree about the mic. Only `status()`
///     is read; capture never calls `request()`, so a press never prompts (plan R4). Anything but
///     `.granted` refuses before any session work.
///   - `interruptions` — a per-capture stream of interruption reasons.
///     `LiveAudioEngine.interruptionReasons()` is the real one.
///
/// **Isolation (KTD3):** the tap block comes from `PCMConversion.makeTapHandler` and its frame
/// sink from `makeFrameSink`, both `nonisolated static`, so no audio-thread callback is ever
/// inferred onto an actor. Converted chunks cross to a collector task through an `AsyncStream`.
///
/// **Teardown order (plan U2):** tap removed → engine stopped → frame stream finished and drained
/// (resampler tail included) → session deactivated. The same order runs on release and on
/// interruption.
///
/// **FR-022:** frames live only in memory for one press and are zeroed when the buffer is built
/// or the capture is discarded. Nothing here writes, logs, or retains audio.

import Foundation
import AVFoundation
import Synchronization
#if canImport(CallKit)
import CallKit
#endif

// MARK: - Engine seam

/// The audio engine and session operations one capture needs (plan KTD1, KTD4).
///
/// `LiveAudioCapture` calls these serially from its own actor, never concurrently.
public protocol AudioEngineDriving: Sendable {
    /// Configures the session for spoken input and activates it.
    func activateSession() throws
    /// The input's native format, read after activation. `nil` when there is no input.
    func inputFormat() -> AVAudioFormat?
    /// Installs the capture tap on the input in `format`.
    func installTap(format: AVAudioFormat,
                    handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)
    /// Removes the capture tap. Safe to call when none is installed.
    func removeTap()
    /// Starts the engine.
    func startEngine() throws
    /// Stops the engine. Safe to call when it is not running.
    func stopEngine()
    /// Deactivates the session so other apps' audio can resume. Never throws.
    func deactivateSession()
}

// MARK: - Live capture

/// Push-to-talk microphone capture on the audio engine (plan U2).
///
/// A second `start()` while a capture is starting or running is ignored: the current capture and
/// its `events` stream continue untouched. A `stop()` that arrives while `start()` is still
/// checking permission cancels that start, and the start then returns without capturing.
public actor LiveAudioCapture: AudioCaptureSource {

    /// Opens one capture's stream of interruption reasons; the stream is cancelled at teardown.
    public typealias InterruptionSource = @Sendable () -> AsyncStream<CaptureEvent.InterruptionReason>

    /// Maximum capture length (plan R2, matching the transcriber's results timeout).
    public static let defaultCap: Duration = .seconds(15)
    /// How long the tap keeps running after release so the last word is not clipped (plan R2).
    public static let defaultReleaseTail: Duration = .milliseconds(250)

    private let engine: any AudioEngineDriving
    private let microphone: any MicrophonePermissionProviding
    private let interruptions: InterruptionSource
    private let cap: Duration
    private let releaseTail: Duration

    /// The current capture's events, readable without hopping onto the actor.
    private let eventStream: Mutex<AsyncStream<CaptureEvent>>
    private var eventSink: AsyncStream<CaptureEvent>.Continuation?
    private var phase: Phase = .idle
    private var nextCaptureID: UInt64 = 0

    /// Builds a capture over injected seams (tests, and the live defaults below).
    public init(
        engine: any AudioEngineDriving,
        microphone: any MicrophonePermissionProviding = LiveMicrophonePermission(),
        interruptions: @escaping InterruptionSource,
        cap: Duration = LiveAudioCapture.defaultCap,
        releaseTail: Duration = LiveAudioCapture.defaultReleaseTail
    ) {
        self.engine = engine
        self.microphone = microphone
        self.interruptions = interruptions
        self.cap = cap
        self.releaseTail = releaseTail
        // Before any capture the stream is already finished, so a reader ends immediately.
        let (stream, sink) = AsyncStream<CaptureEvent>.makeStream()
        sink.finish()
        self.eventStream = Mutex(stream)
    }

    /// The device capture: a real `AVAudioEngine`, the live permission status, and live
    /// session and engine notifications.
    public init() {
        let live = LiveAudioEngine()
        self.init(engine: live, interruptions: { live.interruptionReasons() })
    }

    public nonisolated var events: AsyncStream<CaptureEvent> {
        eventStream.withLock { $0 }
    }

    // MARK: Start

    public func start() async throws {
        await settleTeardown()
        // A duplicate touch-down while a capture is starting or running changes nothing.
        guard case .idle = phase else { return }
        nextCaptureID &+= 1
        let id = nextCaptureID
        phase = .starting(id: id, cancelled: false)
        let (stream, sink) = AsyncStream<CaptureEvent>.makeStream()
        eventStream.withLock { $0 = stream }
        eventSink = sink

        // Permission first: a denied or unanswered microphone never touches the session (plan
        // KTD5). Status only: the prompt belongs to New Game, never to a press.
        guard await microphone.status() == .granted else {
            abandonStart()
            throw TranscriberError.permissionDenied
        }
        // Released while the permission check was in flight: nothing to capture.
        guard case .starting(id: id, cancelled: false) = phase else {
            abandonStart()
            return
        }

        do {
            try engine.activateSession()
        } catch {
            engine.deactivateSession()
            abandonStart()
            throw TranscriberError.engineUnavailable(.apple)
        }
        // A 0 Hz or 0-channel input (no usable route) cannot take a tap: installing one raises
        // an exception Swift cannot catch, so refuse before the tap.
        guard let format = engine.inputFormat(), let conversion = PCMConversion(inputFormat: format) else {
            engine.deactivateSession()
            abandonStart()
            throw TranscriberError.engineUnavailable(.apple)
        }

        let store = FrameStore()
        let (frames, frameSink) = AsyncStream<[Int16]>.makeStream()
        let collector = Task.detached {
            for await chunk in frames { store.add(chunk) }
        }
        engine.installTap(
            format: format,
            handler: PCMConversion.makeTapHandler(conversion: conversion, sink: Self.makeFrameSink(frameSink))
        )
        do {
            try engine.startEngine()
        } catch {
            engine.removeTap()
            frameSink.finish()
            await collector.value
            store.discard()
            engine.deactivateSession()
            abandonStart()
            throw TranscriberError.engineUnavailable(.apple)
        }

        let reasons = interruptions()
        let watcher = Task {
            for await reason in reasons {
                await self.interrupt(reason, captureID: id)
                return
            }
        }
        let timer = Task { [cap] in
            try? await Task.sleep(for: cap)
            guard !Task.isCancelled else { return }
            self.capElapsed(captureID: id)
        }
        phase = .capturing(Capture(
            id: id, startedAt: Date(), conversion: conversion, store: store,
            frameSink: frameSink, collector: collector, watcher: watcher, timer: timer
        ))
    }

    // MARK: Stop

    public func stop() async -> AudioBuffer? {
        switch phase {
        case .idle:
            return nil
        case .starting(let id, _):
            phase = .starting(id: id, cancelled: true)
            return nil
        case .tearingDown:
            await settleTeardown()
            return nil
        case .capturing(let capture):
            // The release tail: the tap keeps running so the last word is not clipped.
            if releaseTail > .zero {
                try? await Task.sleep(for: releaseTail)
            }
            // An interruption during the tail already tore the capture down and discarded it.
            guard case .capturing(let current) = phase, current.id == capture.id else {
                await settleTeardown()
                return nil
            }
            await tearDown(current, interruption: nil)
            return current.store.makeBuffer(capturedAt: current.startedAt)
        }
    }

    // MARK: Cap and interruption

    private func capElapsed(captureID: UInt64) {
        guard case .capturing(let capture) = phase, capture.id == captureID else { return }
        // Treated as a release by the owner, which then calls stop() (plan R2).
        eventSink?.yield(.capReached)
    }

    private func interrupt(_ reason: CaptureEvent.InterruptionReason, captureID: UInt64) async {
        guard case .capturing(let capture) = phase, capture.id == captureID else { return }
        await tearDown(capture, interruption: reason)
        capture.store.discard()
    }

    // MARK: Teardown

    /// Ends `capture` in the fixed order. The tap and engine stop synchronously, before any
    /// suspension, so no further audio arrives; the drain and deactivation run in a task that
    /// `start()` waits on, so a new press never activates a session this one is releasing.
    private func tearDown(_ capture: Capture, interruption: CaptureEvent.InterruptionReason?) async {
        capture.timer.cancel()
        capture.watcher.cancel()
        engine.removeTap()
        engine.stopEngine()
        capture.frameSink.finish()

        let sink = eventSink
        eventSink = nil
        if let interruption { sink?.yield(.interrupted(interruption)) }
        sink?.finish()

        let engine = self.engine
        let finishing = Task {
            await capture.collector.value
            capture.store.add(capture.conversion.drain())
            engine.deactivateSession()
        }
        phase = .tearingDown(finishing)
        await finishing.value
        if case .tearingDown = phase { phase = .idle }
    }

    /// Waits for an in-flight teardown so its deactivation lands before anything new starts.
    private func settleTeardown() async {
        while case .tearingDown(let finishing) = phase {
            await finishing.value
            if case .tearingDown = phase { phase = .idle }
        }
    }

    /// Returns to idle after a start that did not capture, finishing its event stream.
    private func abandonStart() {
        phase = .idle
        eventSink?.finish()
        eventSink = nil
    }

    /// The tap's frame sink, built outside actor isolation so it never runs on the actor (KTD3).
    private nonisolated static func makeFrameSink(
        _ continuation: AsyncStream<[Int16]>.Continuation
    ) -> @Sendable ([Int16]) -> Void {
        { chunk in continuation.yield(chunk) }
    }

    // MARK: State

    private enum Phase {
        case idle
        case starting(id: UInt64, cancelled: Bool)
        case capturing(Capture)
        case tearingDown(Task<Void, Never>)
    }

    private struct Capture {
        let id: UInt64
        let startedAt: Date
        let conversion: PCMConversion
        let store: FrameStore
        let frameSink: AsyncStream<[Int16]>.Continuation
        let collector: Task<Void, Never>
        let watcher: Task<Void, Never>
        let timer: Task<Void, Never>
    }
}

// MARK: - Frame store

/// One capture's accumulator behind a lock: the collector task adds chunks, the actor builds or
/// discards the buffer. Keeping the frames here (not in a task's return value) means the only
/// copy is the one `makeBuffer` and `discard` zero.
private final class FrameStore: Sendable {
    private let accumulator = Mutex(PCM16Accumulator())

    func add(_ chunk: [Int16]) {
        guard !chunk.isEmpty else { return }
        accumulator.withLock { $0.append(chunk) }
    }

    func makeBuffer(capturedAt: Date) -> AudioBuffer {
        accumulator.withLock { $0.makeBuffer(capturedAt: capturedAt) }
    }

    func discard() {
        accumulator.withLock { $0.discard() }
    }
}

// MARK: - Live engine

/// `AudioEngineDriving` over a real `AVAudioEngine` and the shared `AVAudioSession` (plan KTD4).
///
/// `@unchecked Sendable`: the engine is only touched through `AudioEngineDriving`, which
/// `LiveAudioCapture` calls serially from its actor. Never exercised in CI (no microphone usage
/// string in the test host); verified by the device checklist (plan U5).
public final class LiveAudioEngine: AudioEngineDriving, @unchecked Sendable {
    private let engine = AVAudioEngine()

    /// Tap buffer size in frames (about 85 ms at 48 kHz). The engine may deliver other sizes.
    static let tapBufferSize: AVAudioFrameCount = 4_096

    public init() {}

    public func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.allowBluetoothHFP, .duckOthers])
        try session.setActive(true)
    }

    public func inputFormat() -> AVAudioFormat? {
        engine.inputNode.outputFormat(forBus: 0)
    }

    public func installTap(format: AVAudioFormat,
                           handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        engine.inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format, block: handler)
    }

    public func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    public func startEngine() throws {
        engine.prepare()
        try engine.start()
    }

    public func stopEngine() {
        engine.stop()
    }

    public func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Live interruption reasons for one capture: a session interruption that begins (a phone
    /// or FaceTime call when CallKit reports one in progress, otherwise another interruption),
    /// this engine's configuration change (route change), and a media-services reset. Observers
    /// are removed when the stream terminates.
    public func interruptionReasons() -> AsyncStream<CaptureEvent.InterruptionReason> {
        let (stream, sink) = AsyncStream<CaptureEvent.InterruptionReason>.makeStream()
        let center = NotificationCenter.default
        let tokens = ObserverTokens()
        tokens.add(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                      object: nil, queue: nil) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            sink.yield(Self.callInProgress() ? .phoneCall : .otherInterruption)
        })
        tokens.add(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                      object: engine, queue: nil) { _ in
            sink.yield(.routeChange)
        })
        tokens.add(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                      object: nil, queue: nil) { _ in
            sink.yield(.mediaServicesReset)
        })
        sink.onTermination = { _ in tokens.removeAll(from: center) }
        return stream
    }

    /// Whether CallKit reports a call that has not ended (cellular, FaceTime, or a VoIP app).
    private static func callInProgress() -> Bool {
        #if canImport(CallKit)
        return CXCallObserver().calls.contains { !$0.hasEnded }
        #else
        return false
        #endif
    }
}

/// NotificationCenter observer tokens for one capture, removed once when its stream ends.
private final class ObserverTokens: Sendable {
    private struct Token: @unchecked Sendable { let value: any NSObjectProtocol }
    private let tokens = Mutex<[Token]>([])

    func add(_ token: any NSObjectProtocol) {
        tokens.withLock { $0.append(Token(value: token)) }
    }

    func removeAll(from center: NotificationCenter) {
        let taken = tokens.withLock { tokens -> [Token] in
            defer { tokens = [] }
            return tokens
        }
        for token in taken { center.removeObserver(token.value) }
    }
}
