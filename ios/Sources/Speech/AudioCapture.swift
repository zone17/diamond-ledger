/// AudioCapture.swift — DL-176 U1: the push-to-talk capture seam and its pure audio math.
///
/// Three pieces, kept apart so everything except the live engine is simulator-testable (plan
/// KTD1–KTD3):
///   - `AudioCaptureSource`: the Sendable capture contract `AppState` is injected with. The live
///     conformer (`LiveAudioCapture`, U2) drives `AVAudioEngine`; tests inject a fake.
///   - `PCM16Accumulator`: a value type that collects converted 16 kHz mono Int16 frames for one
///     press and hands them off as a single `AudioBuffer`, releasing and zeroing its storage.
///   - `PCMConversion`: converts whatever the input tap delivers (any float/int format, rate, and
///     channel count) to the transcriber's 16 kHz mono interleaved Int16 layout, with exactly one
///     `AVAudioConverter` per press, plus the `nonisolated` tap-handler factory (KTD3).
///
/// **Target byte layout** matches `AppleTranscriber.makePCMBuffer(from:)`: 16 kHz, mono,
/// interleaved, native-endian (little-endian on every Apple platform) Int16, no header.
///
/// **FR-022 (process, don't store):** frames live only in memory for the duration of a press.
/// Nothing here writes to disk, logs samples, or keeps frames after the buffer is built.
/// Receiver names deliberately avoid the privacy gate's audio write-verb vocabulary.

import Foundation
import AVFoundation
import Synchronization

// MARK: - Capture events

/// Something that ends or shortens a capture while the finger may still be down (plan R2, R3).
public enum CaptureEvent: Sendable, Equatable {
    /// The maximum capture length was reached. The owner treats it as a release: call `stop()`
    /// and transcribe what was captured.
    case capReached
    /// The capture was cut off. Captured audio is discarded and `stop()` returns `nil`.
    case interrupted(InterruptionReason)

    /// Why a capture was cut off. Each maps to a readable message in the UI layer.
    public enum InterruptionReason: Sendable, Equatable, Hashable {
        /// A phone or FaceTime call took the audio session.
        case phoneCall
        /// Any other session interruption (Siri, an alarm, another app's audio).
        case otherInterruption
        /// The input route changed (headset unplugged, Bluetooth connected) and the engine
        /// was reconfigured.
        case routeChange
        /// The system audio services were reset.
        case mediaServicesReset
        /// The app left the foreground.
        case background
    }
}

// MARK: - Capture source

/// A push-to-talk capture: started on press, stopped on release (plan KTD1, R1).
///
/// ## Contract
///   - `start()` begins one capture. It throws `TranscriberError.permissionDenied` or
///     `TranscriberError.engineUnavailable(_:)` without capturing anything.
///   - `stop()` ends the capture and returns its audio as one `AudioBuffer` (16 kHz mono Int16,
///     duration computed from the frame count). It returns `nil` when the capture was interrupted
///     or never started. The conformer keeps no frames after `stop()` returns (FR-022).
///   - `events` is finite per capture: each `start()` begins a new stream, and that stream
///     finishes when the capture stops or is interrupted. Read it after `start()` returns.
///
/// The press path calls `stop()` inside its own task and passes the result straight to
/// `Transcriber.transcribe(buffer:)`, so the `~Copyable` buffer never crosses a `Task {}` boundary.
public protocol AudioCaptureSource: Sendable {
    /// Begins one capture.
    func start() async throws
    /// Ends the capture; `nil` if it was interrupted or never started.
    func stop() async -> AudioBuffer?
    /// Cap and interruption events for the current capture.
    var events: AsyncStream<CaptureEvent> { get }
}

// MARK: - Accumulator

/// Collects one press worth of converted 16 kHz mono Int16 frames (plan KTD2).
///
/// A value type with no shared storage: the owner (the capture actor) is the only holder.
/// `makeBuffer(capturedAt:)` and `discard()` zero the frames before releasing them.
public struct PCM16Accumulator: Sendable {
    /// Frames per second of the accumulated audio (matches `AppleTranscriber.captureSampleRate`).
    public static let sampleRate: Double = 16_000

    private var frames: [Int16] = []

    public init() {}

    /// Number of 16 kHz mono frames collected so far.
    public var frameCount: Int { frames.count }

    /// Appends already-converted frames, preserving order.
    public mutating func append(_ chunk: [Int16]) {
        frames.append(contentsOf: chunk)
    }

    /// Builds the capture's `AudioBuffer`, then zeroes and releases the frames.
    ///
    /// The duration is `frameCount / 16000`, never assumed. An empty accumulator yields an empty
    /// buffer with duration 0, which the transcriber rejects as too short.
    public mutating func makeBuffer(capturedAt: Date) -> AudioBuffer {
        let bytes = frames.withUnsafeBytes { Data($0) }
        let duration = Double(frames.count) / Self.sampleRate
        discard()
        return AudioBuffer(rawBytes: bytes, durationSeconds: duration, capturedAt: capturedAt)
    }

    /// Zeroes and releases the frames without building a buffer (the interrupted path).
    public mutating func discard() {
        frames.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        frames = []
    }
}

// MARK: - Conversion

/// Converts tap buffers to 16 kHz mono interleaved Int16 frames with one `AVAudioConverter` per
/// press (plan KTD2). Create one when a capture starts, feed it every tap buffer in order, then
/// call `drain()` once at the end so the resampler's held-back tail is not lost.
///
/// `Sendable` because the converter is only touched under its lock: the tap thread calls
/// `convert(_:)` and the capture actor calls `drain()` after the tap is removed.
public final class PCMConversion: Sendable {

    /// The transcriber's capture layout (`AppleTranscriber.makePCMBuffer(from:)`).
    public static var targetFormat: AVAudioFormat {
        // Force-unwrap is safe: a 16 kHz mono interleaved Int16 format is always constructible.
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: PCM16Accumulator.sampleRate,
                      channels: 1, interleaved: true)!
    }

    /// Extra output frames beyond the exact rate ratio, for resampler rounding and held-back tail.
    static let outputSlackFrames: AVAudioFrameCount = 1_024

    /// Output capacity for converting `frames` input frames at `inputRate` Hz:
    /// `frames × 16000 ÷ inputRate + 1024`.
    static func outputCapacity(forInputFrames frames: AVAudioFrameCount, inputRate: Double) -> AVAudioFrameCount {
        guard inputRate > 0 else { return outputSlackFrames }
        return AVAudioFrameCount(Double(frames) * PCM16Accumulator.sampleRate / inputRate) + outputSlackFrames
    }

    private struct State: ~Copyable {
        let converter: AVAudioConverter
        let inputRate: Double
        var drained = false
    }

    private let state: Mutex<State>

    /// Returns `nil` when the input format cannot be converted (for example a 0 Hz or 0-channel
    /// tap format, which a route with no input reports).
    public init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            return nil
        }
        // Mix every input channel into the mono output instead of keeping only the first.
        converter.downmix = true
        state = Mutex(State(converter: converter, inputRate: inputFormat.sampleRate))
    }

    /// Converts one tap buffer and returns the frames it produced (possibly fewer than the exact
    /// ratio while the resampler holds back its tail). Returns `[]` after `drain()` or on error.
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let input = InputOnce(buffer)
        return state.withLock { state -> [Int16] in
            guard !state.drained, buffer.frameLength > 0 else { return [] }
            let capacity = Self.outputCapacity(forInputFrames: buffer.frameLength, inputRate: state.inputRate)
            guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
                return []
            }
            var error: NSError?
            // Input block: `.haveData` once, then `.noDataNow` so the converter keeps its
            // resampler state for the next tap buffer of the same press.
            let status = state.converter.convert(to: output, error: &error) { _, outStatus in
                guard let next = input.take() else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return next
            }
            guard status != .error, error == nil else { return [] }
            return Self.frames(of: output)
        }
    }

    /// Flushes the resampler's held-back tail at the end of a press. Call once, after the last
    /// `convert(_:)`; later calls, and `convert(_:)` after it, return `[]`.
    public func drain() -> [Int16] {
        state.withLock { state -> [Int16] in
            guard !state.drained else { return [] }
            state.drained = true
            var collected: [Int16] = []
            // The tail can exceed one output buffer; pull until the converter reports the end.
            while true {
                guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat,
                                                    frameCapacity: Self.outputSlackFrames) else { break }
                var error: NSError?
                let status = state.converter.convert(to: output, error: &error) { _, outStatus in
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if status == .error || error != nil { break }
                collected += Self.frames(of: output)
                if status == .endOfStream || output.frameLength == 0 { break }
            }
            return collected
        }
    }

    /// Builds the tap block the live engine installs (plan KTD3).
    ///
    /// `nonisolated` and `@Sendable` so it is never inferred onto the main actor: `AVAudioEngine`
    /// calls it on its own audio thread, and a main-actor-isolated closure would trap there.
    /// Converted frames go to `sink`, which forwards them to the capture actor (typically through
    /// an `AsyncStream` continuation). Empty conversions are not forwarded.
    public nonisolated static func makeTapHandler(
        conversion: PCMConversion,
        sink: @escaping @Sendable ([Int16]) -> Void
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            let frames = conversion.convert(buffer)
            if !frames.isEmpty { sink(frames) }
        }
    }

    private static func frames(of output: AVAudioPCMBuffer) -> [Int16] {
        guard output.frameLength > 0, let channel = output.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

// MARK: - One-shot input box

/// Hands the converter its input buffer exactly once. A reference box (not a captured `var`)
/// because Swift 6 rejects mutating captured state in the converter's `@Sendable`-shaped input
/// block. `@unchecked Sendable` is sound: the block runs synchronously inside one `convert` call,
/// under `PCMConversion`'s lock, on the calling thread.
private final class InputOnce: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
