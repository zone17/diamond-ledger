/// SpeechReadiness.swift — DL-176 U3 (R4, R5, KTD5)
///
/// Decides whether a push-to-talk capture can succeed *before* it starts:
/// `ready | micDenied | speechDenied | modelPreparing`.
///
/// ## Contract
///   - **New Game** (`prepareForNewGame`) awaits only the two permission prompts — microphone and
///     speech recognition — then starts the on-device model preload *detached*. The game never
///     waits for the model; manual entry always works.
///   - **Every press and every scene activation** (`evaluate`) re-reads the live permission status
///     (nothing is cached, so a toggle flipped in Settings takes effect without a new game) and,
///     when the model is not ready, retries the preload unless one is already in flight.
///   - `evaluate` never shows a permission prompt: a prompt mid-hold would strand the gesture
///     (R4). An unanswered prompt (`.notDetermined`) therefore counts as "cannot capture".
///
/// All three dependencies are injected protocols so tests never touch the real
/// `AVAudioApplication` / `SFSpeechRecognizer` / `AssetInventory` APIs (the test host carries no
/// usage strings; a real request there crashes).
///
/// - SeeAlso: `EngineSelector.swift` — consumes `SpeechAuthorizationProviding` (KTD6).
/// - SeeAlso: `ios/Sources/UI/App/AppState.swift` — `startNewGame`, `refreshVoiceReadiness`.

import Foundation
import AVFAudio
import Speech

// MARK: - Status values

/// A permission's live state, normalized across `AVAudioApplication` and `SFSpeechRecognizer`.
public enum VoicePermissionStatus: Sendable, Equatable {
    case notDetermined
    case granted
    /// Denied by the user or restricted by policy — only Settings can change it.
    case denied
}

/// Whether a push-to-talk capture can start right now.
public enum SpeechReadinessState: Sendable, Equatable {
    /// Microphone and speech access granted and the on-device model is installed.
    case ready
    /// Microphone access is denied (or was never answered).
    case micDenied
    /// Speech-recognition access is denied (or was never answered).
    case speechDenied
    /// Permissions are fine but the on-device model is still downloading (or its download failed
    /// and is being retried).
    case modelPreparing
}

// MARK: - Provider seams

/// Microphone permission — status read and the one-time prompt.
public protocol MicrophonePermissionProviding: Sendable {
    func status() async -> VoicePermissionStatus
    /// Shows the system prompt if unanswered; otherwise returns the current status immediately.
    func request() async -> VoicePermissionStatus
}

/// Speech-recognition authorization — status read and the one-time prompt.
public protocol SpeechAuthorizationProviding: Sendable {
    func status() async -> VoicePermissionStatus
    /// Shows the system prompt if unanswered; otherwise returns the current status immediately.
    func request() async -> VoicePermissionStatus
}

/// Downloads/installs the on-device speech model. Throws when the model cannot be made ready.
public protocol SpeechModelPreloading: Sendable {
    func preload() async throws
}

// MARK: - Live providers

/// `AVAudioApplication` (iOS 17+) microphone permission.
public struct LiveMicrophonePermission: MicrophonePermissionProviding {
    public init() {}

    public func status() async -> VoicePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:      return .granted
        case .denied:       return .denied
        case .undetermined: return .notDetermined
        @unknown default:   return .denied
        }
    }

    public func request() async -> VoicePermissionStatus {
        await AVAudioApplication.requestRecordPermission() ? .granted : .denied
    }
}

/// `SFSpeechRecognizer` authorization (shared by the SpeechAnalyzer and biasing paths).
public struct LiveSpeechAuthorization: SpeechAuthorizationProviding {
    public init() {}

    public func status() async -> VoicePermissionStatus {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    public func request() async -> VoicePermissionStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<VoicePermissionStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermissionStatus {
        switch status {
        case .authorized:          return .granted
        case .denied, .restricted: return .denied
        case .notDetermined:       return .notDetermined
        @unknown default:          return .denied
        }
    }
}

/// Preloads the Apple on-device model. When the DEBUG `forceStub` seam is on (the simulator
/// default and the WoZ demo) the Stub needs no model, so the preload is a no-op.
public struct LiveSpeechModelPreloader: SpeechModelPreloading {
    /// One transcriber for the preloader's lifetime so `AppleTranscriber.preloadAssets()` stays
    /// idempotent across retries.
    private let apple: AppleTranscriber

    public init() {
        apple = AppleTranscriber()
    }

    public func preload() async throws {
        if TranscriberEngineSelector.forceStub { return }
        try await apple.preloadAssets()
    }
}

// MARK: - SpeechReadiness

/// Orchestrates permission prompts, the detached model preload, and the readiness verdict.
public actor SpeechReadiness {

    private let microphone: any MicrophonePermissionProviding
    private let speech: any SpeechAuthorizationProviding
    private let model: any SpeechModelPreloading

    /// Set once a preload succeeds; a failed preload leaves it false so the next evaluation retries.
    private var modelReady = false
    /// The preload currently in flight, if any (never more than one).
    private var preloadTask: Task<Void, Never>?

    public init(microphone: any MicrophonePermissionProviding,
                speech: any SpeechAuthorizationProviding,
                model: any SpeechModelPreloading) {
        self.microphone = microphone
        self.speech = speech
        self.model = model
    }

    /// The production wiring: real permission APIs and the Apple model preload.
    public static func live() -> SpeechReadiness {
        SpeechReadiness(microphone: LiveMicrophonePermission(),
                        speech: LiveSpeechAuthorization(),
                        model: LiveSpeechModelPreloader())
    }

    /// New Game: shows the microphone and speech prompts (each only if still unanswered), starts
    /// the model preload without awaiting it, and returns the resulting verdict.
    public func prepareForNewGame() async -> SpeechReadinessState {
        _ = await microphone.request()
        _ = await speech.request()
        return await evaluate()
    }

    /// Re-reads the live status (every press, every scene activation). Never prompts. Starts a
    /// preload when the model is not ready and none is in flight.
    public func evaluate() async -> SpeechReadinessState {
        let mic = await microphone.status()
        let speechStatus = await speech.status()

        // The model can download as soon as speech access is not refused — even while the mic is
        // still denied — so granting the mic later finds the model already there.
        if speechStatus != .denied {
            startPreloadIfNeeded()
        }

        guard mic == .granted else { return .micDenied }
        guard speechStatus == .granted else { return .speechDenied }
        return modelReady ? .ready : .modelPreparing
    }

    /// Awaits the in-flight preload, if any. For diagnostics and tests; production never waits.
    public func waitForPreload() async {
        await preloadTask?.value
    }

    // MARK: Private

    private func startPreloadIfNeeded() {
        guard !modelReady, preloadTask == nil else { return }
        let model = self.model
        preloadTask = Task.detached { [weak self] in
            let succeeded: Bool
            do {
                try await model.preload()
                succeeded = true
            } catch {
                succeeded = false
            }
            await self?.preloadFinished(succeeded: succeeded)
        }
    }

    private func preloadFinished(succeeded: Bool) {
        if succeeded { modelReady = true }
        preloadTask = nil
    }
}
