/// EngineSelector.swift — T047-B / T048-B (Squad B, Story B2)
///
/// Runtime seam for selecting the active ASR engine.
///
/// Priority order:
///   1. **Apple** (`AppleTranscriber`) — primary, on-device, iOS 26+ only.
///   2. **Sherpa** (`SherpaTranscriber`) — fallback, portable, iOS 16+.
///   3. **Stub** (`StubTranscriber`) — debug / Wizard-of-Oz fallback behind a runtime toggle.
///
/// The default at runtime is:
///   - Simulator + debug: **Stub** (WoZ-compatible; no microphone required).
///   - Device, iOS 26+, `SpeechAnalyzer` authorized: **Apple**.
///   - Device, sherpa model present: **Sherpa**.
///   - Fallback: **Stub** with a warning log.
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
    /// Resolution priority:
    ///   1. `forceStub == true` → `StubTranscriber` (WoZ / debug).
    ///   2. iOS 26+ AND Apple engine available → `AppleTranscriber`.
    ///   3. Sherpa model present → `SherpaTranscriber`.
    ///   4. Fallback → `StubTranscriber` with a warning.
    public static func resolve(wozScript: WoZScript = .groundOut63) async -> any Transcriber {
        // 1. Debug / WoZ override.
        if forceStub {
            return StubTranscriber(script: wozScript)
        }

        // 2. Apple on-device (iOS 26+, primary).
        if #available(iOS 26, *) {
            let apple = AppleTranscriber()
            if await apple.isAvailable {
                return apple
            }
        }

        // 3. Sherpa fallback (portable, iOS 16+).
        let sherpa = SherpaTranscriber()
        if await sherpa.isAvailable {
            return sherpa
        }

        // 4. Last resort: stub with a warning.
        // This path should not be reached in production; it indicates either:
        //   - No microphone permission granted (handled by the individual engine's `isAvailable`).
        //   - Pre-iOS-26 device with no sherpa model bundle present.
        // Log a warning and surface the stub so the UI degrades gracefully.
        engineWarningLog("No real ASR engine available — falling back to StubTranscriber. " +
            "On-device speech recognition will not function.")
        return StubTranscriber(script: wozScript)
    }

    // MARK: - Engine identification (for observability / audit)

    /// Returns the `TranscriberEngine` that `resolve()` would select (without constructing
    /// the full transcriber). Useful for logging and diagnostics.
    public static func resolvedEngineKind() async -> TranscriberEngine {
        if forceStub { return .stub }   // WoZ / debug stub — reported distinctly (ADR-0010)

        if #available(iOS 26, *) {
            let apple = AppleTranscriber()
            if await apple.isAvailable { return .apple }
        }

        let sherpa = SherpaTranscriber()
        if await sherpa.isAvailable { return .sherpa }

        return .stub  // last-resort fallback is the stub — never a lie about real ASR
    }

    // MARK: - Private

    private static func engineWarningLog(_ message: String) {
        // In production, route to the observability pipeline (T023 / Art. XXIII).
        // For now, use os_log or a simple print that can be replaced at T023.
        print("[EngineSelector WARNING] \(message)")
    }
}
