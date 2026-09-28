/// T176AudioCaptureTests.swift — DL-176 U1: capture seam, PCM16 accumulator, and conversion.
///
/// Every test uses synthetic `AVAudioPCMBuffer`s built in memory. Nothing here touches
/// `AVAudioEngine.inputNode`, an audio session, or a permission API: the test host has no
/// microphone usage string, and touching those crashes or hangs the suite (plan KTD1).
///
/// Coverage (plan U1 test scenarios):
///   - 48 kHz mono Float32 sine → 16 kHz mono Int16, frame count and duration from the count.
///   - 44.1 kHz stereo Float32 → 16 kHz mono with the expected frame count.
///   - Two appended chunks → one contiguous buffer, order preserved across the seam.
///   - Empty accumulator → duration 0, rejected by `AppleTranscriber` as too short.
///   - Retention: after `makeBuffer`, the accumulator holds no frames (FR-022).
///   - Round trip into `AppleTranscriber.makePCMBuffer(from:)` keeps the frame count.
///   - The tap handler runs on a background queue without a main-actor trap (KTD3).
///   - `FakeAudioCapture` exercises the `AudioCaptureSource` contract (R7).

import XCTest
import Foundation
import AVFoundation
import Synchronization
@testable import DiamondSpeech

// MARK: - Synthetic input

private enum Synth {
    /// A non-interleaved Float32 sine buffer (the shape `AVAudioEngine` taps usually deliver).
    static func sine(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        seconds: Double,
        frequency: Double = 440,
        amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let frames = AVAudioFrameCount((sampleRate * seconds).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                samples[i] = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
            }
        }
        return buffer
    }

    /// Runs one press worth of conversion: every chunk through one converter, then the drain.
    static func convertPress(_ chunks: [AVAudioPCMBuffer]) throws -> [Int16] {
        let conversion = try XCTUnwrap(PCMConversion(inputFormat: chunks[0].format))
        var frames: [Int16] = []
        for chunk in chunks { frames += conversion.convert(chunk) }
        frames += conversion.drain()
        return frames
    }
}

// MARK: - Conversion

final class T176PCMConversionTests: XCTestCase {

    func testTargetFormat_is16kMonoInterleavedInt16() {
        let format = PCMConversion.targetFormat
        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
        XCTAssertTrue(format.isInterleaved)
        XCTAssertEqual(format.sampleRate, AppleTranscriber.captureSampleRate)
        XCTAssertEqual(format.channelCount, AppleTranscriber.captureChannels)
    }

    func testOneSecondOf48kMonoFloatSine_becomes16000Frames_andOneSecond() throws {
        let frames = try Synth.convertPress([Synth.sine(sampleRate: 48_000, channels: 1, seconds: 1)])
        XCTAssertEqual(Double(frames.count), 16_000, accuracy: 1)

        var accumulator = PCM16Accumulator()
        accumulator.append(frames)
        let buffer = accumulator.makeBuffer(capturedAt: Date())
        XCTAssertEqual(buffer.durationSeconds, 1.0, accuracy: 1.0 / 16_000)
        XCTAssertEqual(buffer.rawBytes.count, frames.count * MemoryLayout<Int16>.size)
    }

    func testConvertedSine_isNotSilent() throws {
        // A 0.5-amplitude sine must survive conversion as audible Int16 samples, not zeros.
        let frames = try Synth.convertPress([Synth.sine(sampleRate: 48_000, channels: 1, seconds: 0.5)])
        let peak = frames.map { Int(abs(Int32($0))) }.max() ?? 0
        XCTAssertGreaterThan(peak, 8_000, "converted sine peak \(peak) is too quiet")
        XCTAssertLessThanOrEqual(peak, Int(Int16.max))
    }

    func testStereo44_1k_becomesMono16k_withExpectedFrameCount() throws {
        let input = Synth.sine(sampleRate: 44_100, channels: 2, seconds: 1)
        let frames = try Synth.convertPress([input])
        let expected = Double(input.frameLength) * 16_000 / 44_100
        XCTAssertEqual(Double(frames.count), expected, accuracy: 1)
    }

    func testStreamedChunks_matchTheWholeCaptureFrameCount() throws {
        // A tap delivers many small buffers; one converter per press keeps the resampler state,
        // so ten 100 ms chunks convert to the same count as one 1 s buffer.
        let chunks = (0..<10).map { _ in Synth.sine(sampleRate: 48_000, channels: 1, seconds: 0.1) }
        let frames = try Synth.convertPress(chunks)
        XCTAssertEqual(Double(frames.count), 16_000, accuracy: 1)
    }

    func testOutputCapacity_includesSlack() {
        XCTAssertEqual(PCMConversion.outputCapacity(forInputFrames: 48_000, inputRate: 48_000), 16_000 + 1_024)
        XCTAssertEqual(PCMConversion.outputCapacity(forInputFrames: 0, inputRate: 48_000), 1_024)
    }

    func testInvalidInputFormat_returnsNil() {
        // A 0 Hz tap format cannot be converted; the seam refuses it instead of trapping.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false)
        if let format {
            XCTAssertNil(PCMConversion(inputFormat: format))
        }
    }
}

// MARK: - Accumulator

final class T176PCM16AccumulatorTests: XCTestCase {

    func testTwoChunks_produceOneContiguousBuffer_orderPreserved() {
        var accumulator = PCM16Accumulator()
        accumulator.append([1, 2, 3])
        accumulator.append([-4, 5_000, Int16.min])
        XCTAssertEqual(accumulator.frameCount, 6)

        let buffer = accumulator.makeBuffer(capturedAt: Date())
        let samples = buffer.rawBytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(samples, [1, 2, 3, -4, 5_000, Int16.min])
        // The seam: last frame of chunk one, then first frame of chunk two.
        XCTAssertEqual(samples[2], 3)
        XCTAssertEqual(samples[3], -4)
    }

    func testBytesAreLittleEndianInt16_noHeader() {
        var accumulator = PCM16Accumulator()
        accumulator.append([0x0102])
        let buffer = accumulator.makeBuffer(capturedAt: Date())
        XCTAssertEqual(Array(buffer.rawBytes), [0x02, 0x01])
    }

    func testDurationIsComputedFromFrameCount() {
        var accumulator = PCM16Accumulator()
        accumulator.append([Int16](repeating: 7, count: 8_000))
        let buffer = accumulator.makeBuffer(capturedAt: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(buffer.durationSeconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(buffer.capturedAt, Date(timeIntervalSince1970: 42))
    }

    func testEmptyAccumulator_givesZeroDuration() {
        var accumulator = PCM16Accumulator()
        let buffer = accumulator.makeBuffer(capturedAt: Date())
        XCTAssertEqual(buffer.durationSeconds, 0)
        XCTAssertTrue(buffer.rawBytes.isEmpty)
    }

    func testEmptyAccumulatorBuffer_isRejectedAsTooShort() async {
        var accumulator = PCM16Accumulator()
        let buffer = accumulator.makeBuffer(capturedAt: Date())
        do {
            _ = try await AppleTranscriber().transcribe(buffer: buffer)
            XCTFail("an empty capture must never produce a transcript")
        } catch TranscriberError.audioTooShort {
            // expected: the duration guard runs before any permission or model access
        } catch {
            XCTFail("expected audioTooShort, got \(error)")
        }
    }

    func testAfterMakeBuffer_accumulatorIsEmpty() {
        var accumulator = PCM16Accumulator()
        accumulator.append([Int16](repeating: 1_234, count: 1_600))
        _ = accumulator.makeBuffer(capturedAt: Date())
        XCTAssertEqual(accumulator.frameCount, 0)

        // A second build does not resurrect the released frames.
        let again = accumulator.makeBuffer(capturedAt: Date())
        XCTAssertTrue(again.rawBytes.isEmpty)
        XCTAssertEqual(again.durationSeconds, 0)
    }

    func testDiscard_releasesFramesWithoutBuildingABuffer() {
        var accumulator = PCM16Accumulator()
        accumulator.append([Int16](repeating: 9, count: 320))
        accumulator.discard()
        XCTAssertEqual(accumulator.frameCount, 0)
    }

    func testRoundTrip_intoAppleTranscriberPCMBuffer_keepsFrameCount() throws {
        let frames = try Synth.convertPress([Synth.sine(sampleRate: 48_000, channels: 1, seconds: 0.75)])
        var accumulator = PCM16Accumulator()
        accumulator.append(frames)
        let expected = accumulator.frameCount
        let buffer = accumulator.makeBuffer(capturedAt: Date())

        let pcm = try AppleTranscriber.makePCMBuffer(from: buffer.rawBytes)
        XCTAssertEqual(Int(pcm.frameLength), expected)
        XCTAssertEqual(pcm.format, PCMConversion.targetFormat)
        // Spot-check sample fidelity through the round trip.
        XCTAssertEqual(pcm.int16ChannelData![0][expected / 2], frames[expected / 2])
    }
}

// MARK: - Tap handler isolation (KTD3)

private final class FrameCollector: Sendable {
    private let state = Mutex<[Int16]>([])
    func add(_ frames: [Int16]) { state.withLock { $0 += frames } }
    var count: Int { state.withLock { $0.count } }
}

final class T176TapHandlerTests: XCTestCase {

    func testTapHandler_onBackgroundQueue_deliversConvertedFrames() throws {
        let format = Synth.sine(sampleRate: 48_000, channels: 1, seconds: 0.01).format
        let conversion = try XCTUnwrap(PCMConversion(inputFormat: format))
        let collector = FrameCollector()
        let delivered = expectation(description: "sink received converted frames")
        delivered.assertForOverFulfill = false

        let handler = PCMConversion.makeTapHandler(conversion: conversion) { frames in
            collector.add(frames)
            delivered.fulfill()
        }

        // Invoke the handler the way AVAudioEngine does: off the main thread, on a queue the app
        // does not own. Built inside the closure so no non-Sendable buffer crosses threads.
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            let chunk = Synth.sine(sampleRate: 48_000, channels: 1, seconds: 0.1)
            handler(chunk, AVAudioTime(sampleTime: 0, atRate: 48_000))
        }

        wait(for: [delivered], timeout: 5)
        // 0.1 s at 16 kHz is 1600 frames; resampler latency may hold some back until the drain.
        XCTAssertGreaterThan(collector.count, 0)
        XCTAssertLessThanOrEqual(collector.count, 1_600 + 1)
    }
}

// MARK: - Capture seam (R7)

/// Test-only `AudioCaptureSource` that "captures" synthetic frames. One event stream per
/// capture, finished on stop or interruption, exactly like the live source.
final class FakeAudioCapture: AudioCaptureSource {
    private struct State: ~Copyable {
        var accumulator = PCM16Accumulator()
        var interrupted = false
        var continuation: AsyncStream<CaptureEvent>.Continuation?
        var stream: AsyncStream<CaptureEvent>
    }

    private let state: Mutex<State>
    private let scripted: [Int16]
    let startError: TranscriberError?

    init(frames: [Int16], startError: TranscriberError? = nil) {
        self.scripted = frames
        self.startError = startError
        let (stream, _) = AsyncStream<CaptureEvent>.makeStream()
        self.state = Mutex(State(stream: stream))
    }

    var events: AsyncStream<CaptureEvent> { state.withLock { $0.stream } }

    func start() async throws {
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream<CaptureEvent>.makeStream()
        let frames = scripted
        state.withLock {
            $0.continuation?.finish()
            $0.stream = stream
            $0.continuation = continuation
            $0.interrupted = false
            $0.accumulator.discard()
            $0.accumulator.append(frames)
        }
    }

    func stop() async -> DiamondSpeech.AudioBuffer? {
        let continuation: AsyncStream<CaptureEvent>.Continuation? = state.withLock {
            let continuation = $0.continuation
            $0.continuation = nil
            return continuation
        }
        continuation?.finish()
        return state.withLock { state -> DiamondSpeech.AudioBuffer? in
            if state.interrupted {
                state.accumulator.discard()
                return nil
            }
            return state.accumulator.makeBuffer(capturedAt: Date())
        }
    }

    /// Simulates the live source's interruption path: emit the reason, end the stream.
    func interrupt(_ reason: CaptureEvent.InterruptionReason) {
        let continuation: AsyncStream<CaptureEvent>.Continuation? = state.withLock {
            $0.interrupted = true
            $0.accumulator.discard()
            let continuation = $0.continuation
            $0.continuation = nil
            return continuation
        }
        continuation?.yield(.interrupted(reason))
        continuation?.finish()
    }

    /// Simulates the 15 s cap: emit `capReached`; the owner then calls `stop()` as a release.
    func reachCap() {
        state.withLock { $0.continuation }?.yield(.capReached)
    }
}

final class T176AudioCaptureSourceTests: XCTestCase {

    func testStartThenStop_returnsTheCapturedBuffer_andFinishesEvents() async throws {
        let capture = FakeAudioCapture(frames: [Int16](repeating: 100, count: 16_000))
        try await capture.start()
        let events = capture.events
        guard let buffer = await capture.stop() else { return XCTFail("stop returned nil") }
        XCTAssertEqual(buffer.durationSeconds, 1.0, accuracy: 1e-9)
        var received: [CaptureEvent] = []
        for await event in events { received.append(event) }
        XCTAssertEqual(received, [], "a clean release emits no events and ends the stream")
    }

    func testInterruption_emitsReason_andStopReturnsNil() async throws {
        let capture = FakeAudioCapture(frames: [Int16](repeating: 100, count: 16_000))
        try await capture.start()
        let events = capture.events
        capture.interrupt(.routeChange)
        var received: [CaptureEvent] = []
        for await event in events { received.append(event) }
        XCTAssertEqual(received, [.interrupted(.routeChange)])
        if let _ = await capture.stop() {
            XCTFail("interrupted audio is discarded, never transcribed")
        }
    }

    func testCapReached_isDelivered_thenStopStillReturnsAudio() async throws {
        let capture = FakeAudioCapture(frames: [Int16](repeating: 5, count: 4_800))
        try await capture.start()
        let events = capture.events
        capture.reachCap()
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .capReached)
        guard let buffer = await capture.stop() else { return XCTFail("stop returned nil") }
        XCTAssertEqual(buffer.durationSeconds, 0.3, accuracy: 1e-9)
        let end = await iterator.next()
        XCTAssertNil(end, "the stream is finite per capture")
    }

    func testStartFailure_surfacesTheError() async {
        let capture = FakeAudioCapture(frames: [], startError: .permissionDenied)
        do {
            try await capture.start()
            XCTFail("start must throw")
        } catch TranscriberError.permissionDenied {
            // expected
        } catch {
            XCTFail("expected permissionDenied, got \(error)")
        }
    }

    func testEveryInterruptionReason_isDistinct() {
        let reasons: [CaptureEvent.InterruptionReason] = [
            .phoneCall, .otherInterruption, .routeChange, .mediaServicesReset, .background,
        ]
        XCTAssertEqual(Set(reasons.map { "\($0)" }).count, reasons.count)
    }
}
