/// EngineSelector.swift — T047-B / T048-B (Squad B, Story B2)
///
/// Runtime seam for selecting the active ASR engine.
///
/// Priority order:
///   1. **Apple** (`AppleTranscriber`) — primary, on-device, iOS 26+ only.
///   2. **Sherpa** (`SherpaTranscriber`) — fallback, portable, iOS 16+.
///   3. **Stub** (`StubTranscriber`) — DEBUG-only Wizard-of-Oz seam (`forceStub`); never a fallback.
///
/// The default at runtime is:
///   - Simulator + debug: **Stub** (WoZ-compatible; no microphone required).
///   - Device, iOS 26+, speech authorization not denied: **Apple**.
///   - Speech denied, or no real engine: **`UnavailableTranscriber`** — throws, never a canned
///     transcript (DL-176 KTD6).
///
/// ## Integration point
///
/// `PushToTalkView` (T052) currently constructs a `StubTranscriber` directly.
/// At T047 integration, replace that construction with:
///
/// ```swift
/// let transcriber = await TranscriberEngineSelector.resolve()
/// ```
///
/// All callers use the same `Transcriber` protocol; no view code changes.
///
/// ## Debug toggle (WoZ fallback)
///
/// Setting `TranscriberEngineSelector.forceStub = true` at runtime forces the selector to
/// return the `StubTranscriber`, enabling the Wizard-of-Oz facilitator mode even on a device
/// with real ASR available. This toggle is intended for demo/debug builds only.
///
/// - SeeAlso: `ios/Sources/Speech/AppleTranscriber.swift` — primary engine (T047)
/// - SeeAlso: `ios/Sources/Speech/SherpaTranscriber.swift` — fallback / portable (T048)
/// - SeeAlso: `ios/Sources/Speech/StubTranscriber.swift` — WoZ debug stub
/// - SeeAlso: `ios/Sources/UI/PushToTalk/PushToTalkView.swift` — call site

import Foundation
import SpeechTypes

// MARK: - TranscriberEngineSelector

/// Resolves the best available `Transcriber` conformer for the current device/OS/config.
public enum TranscriberEngineSelector {

    // MARK: - Debug toggle (test/demo seam — excluded from release builds)

#if DEBUG
    /// Force the selector to return `StubTranscriber` regardless of device capabilities.
    ///
    /// Intended for Wizard-of-Oz demo builds and simulator testing. This is a **DEBUG-only seam**
    /// — it is compiled out of release builds entirely, so a production build can never be stuck
    /// on the stub via this flag.
    ///
    /// Swift 6 note: `nonisolated(unsafe)` is used here because this flag is written only
    /// from tests / debug code in a non-concurrent setup phase, making the data race safe
    /// in practice. Production code should treat this as read-only.
    public nonisolated(unsafe) static var forceStub: Bool = {
        // Default to `true` in simulator/debug builds.
#if targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }()
#else
    /// Release builds: the stub-force seam does not exist. `resolve()` always evaluates the real
    /// engine chain. Kept as a compile-time constant `false` so call sites need no `#if` fences.
    public static let forceStub: Bool = false
#endif

    // MARK: - Resolve

    /// Returns the best available `any Transcriber` for the current runtime context.
    ///
    /// Resolution priority (DL-176 KTD6 — **no Stub on a device**):
    ///   1. `forceStub == true` → `StubTranscriber` (DEBUG-only seam: simulator default + WoZ demo).
    ///   2. Speech authorization denied → `UnavailableTranscriber(.permissionDenied)`.
    ///   3. iOS 26+ → `AppleTranscriber` (a not-yet-downloaded model is a readiness concern,
    ///      handled by `SpeechReadiness`, not a reason to pick another engine).
    ///   4. Sherpa model present → `SherpaTranscriber`.
    ///   5. Otherwise → `UnavailableTranscriber(.engineUnavailable(.apple))`.
    ///
    /// Outside the DEBUG seam this can never return the Stub: a canned transcript on a device would
    /// be a fabricated play (Article VII / FR-008).
    ///
    /// - Parameter speechAuthorization: live speech-authorization status. Injected so tests never
    ///   call `SFSpeechRecognizer.authorizationStatus()` (the test host has no usage strings).
    public static func resolve(
        wozScript: WoZScript = .groundOut63,
        speechAuthorization: any SpeechAuthorizationProviding = LiveSpeechAuthorization()
    ) async -> any Transcriber {
        // 1. Debug / WoZ override. The Stub construction is compiled into DEBUG builds only, so a
        //    release binary has no path that returns a canned transcript (DL-176 KTD6).
#if DEBUG
        if forceStub {
            return StubTranscriber(script: wozScript)
        }
#endif

        // 2. A denied speech permission can never produce a play.
        if await speechAuthorization.status() == .denied {
            engineWarningLog("Speech recognition permission denied — voice capture unavailable.")
            return UnavailableTranscriber(reason: .permissionDenied)
        }

        // 3. Apple on-device (iOS 26+, primary).
        if #available(iOS 26, *) {
            return AppleTranscriber()
        }

        // 4. Sherpa fallback (portable, pre-26 OS).
        let sherpa = SherpaTranscriber()
        if await sherpa.isAvailable {
            return sherpa
        }

        // 5. No real engine: fail visibly, never fall back to the Stub.
        engineWarningLog("No real ASR engine available — voice capture unavailable.")
        return UnavailableTranscriber(reason: .engineUnavailable(.apple))
    }

    // MARK: - Engine identification (for observability / audit)

    /// Returns the `TranscriberEngine` that `resolve()` would select. `.stub` only under the DEBUG
    /// `forceStub` seam; an `UnavailableTranscriber` reports the engine it stands in for (it never
    /// produces a transcript, so no transcript can be mislabeled — ADR-0010).
    public static func resolvedEngineKind(
        speechAuthorization: any SpeechAuthorizationProviding = LiveSpeechAuthorization()
    ) async -> TranscriberEngine {
        await resolve(speechAuthorization: speechAuthorization).engine
    }

    // MARK: - Private

    private static func engineWarningLog(_ message: String) {
        // In production, route to the observability pipeline (T023 / Art. XXIII).
        // For now, use os_log or a simple print that can be replaced at T023.
        print("[EngineSelector WARNING] \(message)")
    }
}

// MARK: - UnavailableTranscriber

/// Stands in for a real engine that cannot run (speech permission denied, no model/engine). Every
/// call throws its reason, so the push-to-talk pipeline surfaces a readable message instead of a
/// play (DL-176 KTD6). This replaces the old silent `StubTranscriber` fallback on devices.
public struct UnavailableTranscriber: Transcriber {
    /// Why the engine cannot run. Only `.permissionDenied` or `.engineUnavailable` are meaningful.
    public let reason: TranscriberError
    /// The engine this stands in for (it never produces a transcript under that label).
    public let engine: TranscriberEngine

    public init(reason: TranscriberError, engine: TranscriberEngine = .apple) {
        self.reason = reason
        self.engine = engine
    }

    public var isAvailable: Bool {
        get async { false }
    }

    public func transcribe(buffer: consuming AudioBuffer) async throws -> Transcript {
        _ = consume buffer   // FR-022: nothing retained
        throw reason
    }

    public func preloadAssets() async throws {
        throw reason
    }

    public func setContextualStrings(_ phrases: [String]) async {}
}
