/// StubTranscriber.swift — T052 stub (Squad B, Story B4)
///
/// A **stub** `Transcriber` conformer that returns canned transcripts instead of invoking a real
/// ASR engine. Used for the WoZ (Wizard-of-Oz) demo mode and for testing, where the facilitator
/// drives what the scorekeeper "said" by selecting a script.
///
/// **This is NOT a production conformer.** Real conformers:
///   - `AppleTranscriber` (T047) — `SpeechAnalyzer` / `DictationTranscriber` (iOS 26+)
///   - `SherpaTranscriber` (T048) — sherpa-onnx / Parakeet portable
///
/// **FR-022 / COPPA / process-don't-store compliance:**
///   `StubTranscriber.transcribe(buffer:)` consumes the `AudioBuffer` parameter but never reads
///   `rawBytes` (no real audio). The noncopyable `~Copyable` ownership on `AudioBuffer` ensures
///   the caller cannot retain a copy; the buffer is dropped when this method returns.
///
/// **Confidence mapping (ADR-0007 / integer scale):**
///   Returns integer confidence 95 (clear play) or 60 (ambiguous simulation). Real conformers
///   convert their native float confidence via `Int(clamp(native * 100, 0, 100).rounded())`.

import Foundation

// MARK: - WoZ script enum (public — consumed by UI/PushToTalk)

/// Wizard-of-Oz facilitator script selector (interaction-spec.md §WoZ control surface).
/// The facilitator taps the play the scorer just spoke → the subject's screen renders the card.
public enum WoZScript: String, CaseIterable, Sendable {
    case groundOut63
    case misplayedGrounder  // Card B

    public var displayName: String {
        switch self {
        case .groundOut63:        return "Card A — Ground out 6-3"
        case .misplayedGrounder:  return "Card B — Misplayed grounder (Hit vs Error)"
        }
    }
}

// NOTE: The WoZ → normalized-facts mapping (including the MockCore `"script"` routing marker)
// deliberately does NOT live here. The production Speech module must not depend on MockCore
// internals (ADR-0010). That translation lives in the WoZ/test-harness layer that drives the
// stub — see `WoZScript+Facts.swift` in the UI/PushToTalk target.

// MARK: - StubTranscriber

public actor StubTranscriber: Transcriber {

    public let engine: TranscriberEngine = .stub  // canned WoZ engine — not real ASR (ADR-0010)

    private let script: WoZScript

    public init(script: WoZScript = .groundOut63) {
        self.script = script
    }

    // Convenience init for callers that don't need WoZ (always produces Card A).
    public init() { self.script = .groundOut63 }

    public var isAvailable: Bool { true }  // stub is always available

    /// Returns a canned transcript matching the selected WoZ script.
    /// Consumes (and ignores) the `AudioBuffer` — no real audio is read or retained (FR-022).
    public func transcribe(buffer: consuming AudioBuffer) async throws -> Transcript {
        // The consuming parameter moves `buffer` into this scope; it is dropped here —
        // `rawBytes` is never accessed. This satisfies the FR-022 ownership contract trivially.
        _ = consume buffer

        return Transcript(
            text: script.cannedTranscript,
            confidence: script.cannedConfidence,
            engine: engine,
            finalizedAt: Date()
        )
    }

    public func preloadAssets() async throws {
        // No-op for stub.
    }

    public func setContextualStrings(_ phrases: [String]) async {
        // No-op for stub.
    }
}

// MARK: - WoZ canned transcripts

extension WoZScript {
    /// The canned text the stub transcriber returns for this script.
    var cannedTranscript: String {
        switch self {
        case .groundOut63:
            return "ground ball to short, threw him out at first"
        case .misplayedGrounder:
            return "misplayed grounder to short, runner reached first"
        }
    }

    /// Integer confidence 0…100 for the canned transcript.
    var cannedConfidence: Int {
        switch self {
        case .groundOut63:       return 95  // clear deterministic play
        case .misplayedGrounder: return 80  // clear enough, but judgment required
        }
    }
}
