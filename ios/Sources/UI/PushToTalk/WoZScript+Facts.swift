/// WoZScript+Facts.swift — WoZ/test-harness fact mapping (Squad B, Story B4)
///
/// Maps a `WoZScript` (the Wizard-of-Oz facilitator selector defined in the `DiamondSpeech`
/// module) to the normalized-facts dictionary that drives `CoreClient.recordPlay` — *including*
/// the explicit `"script": "misplayed-grounder"` routing marker that `MockCore` keys on to surface
/// Card B.
///
/// ## Why this lives in the UI layer, not in `DiamondSpeech`
///
/// The production Speech module (`AppleTranscriber` / `SherpaTranscriber` / `Transcriber`) must
/// stay free of any dependency on `MockCore` internals (ADR-0010). The `"script"` marker is a
/// MockCore demo-routing convention; encoding it inside the Speech module would couple the real
/// ASR adapters to a test double. This extension lives in the UI/PushToTalk target — the WoZ
/// harness layer that already depends on both `DiamondSpeech` (for `WoZScript`) and `Core` (for
/// `MockCore`) — so the coupling is confined to where the stub is actually driven.
///
/// - SeeAlso: `ios/Sources/Speech/StubTranscriber.swift` — `WoZScript` definition (no facts)
/// - SeeAlso: `ios/Sources/Core/MockCore.swift` — consumes the `"script"` marker

import DiamondSpeech

extension WoZScript {
    /// Normalized facts passed to `CoreClient.recordPlay` when this WoZ script is dispatched.
    ///
    /// The `misplayedGrounder` case emits the explicit `"script"` routing marker that `MockCore`
    /// keys on to return a Card B (judgment) result. This is a WoZ/test-harness convention, not a
    /// production parse path — see the file header.
    var normalizedFacts: [String: String] {
        switch self {
        case .groundOut63:
            return ["batter_result": "groundout", "fielders": "6-3", "outs_recorded": "1"]
        case .misplayedGrounder:
            return ["script": "misplayed-grounder"]
        }
    }
}
