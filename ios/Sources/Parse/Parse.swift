/// Parse.swift — T003 placeholder (Squad B, Story B3)
///
/// Deterministic grammar-constrained transcript → `NormalizedPlay` parser (T049 / T050).
///
/// **Design (plan.md / ADR-0007):**
///   v1 = a deterministic grammar-constrained parser. No LLM in v1.
///   The v2 path (FunctionGemma-270M + XGrammar) is explicitly deferred.
///
/// **Input**: `Transcript` from `ios/Sources/Speech/Transcriber.swift`
///   e.g. "ground ball to short, threw him out at first"
///
/// **Output**: A `NormalizedPlay` (a key/value fact map, matching `core/src/model.rs` T012)
///   e.g. { "batter_result": "groundout", "fielders": "6-3", "outs_recorded": "1" }
///
/// **Ambiguity path (T050 / FR-008):**
///   If the transcript confidence is below threshold OR the grammar produces multiple candidate
///   mappings, the parser surfaces a single clarifying question to the scorer — NEVER a silent
///   guess. This is a hard invariant (Art. VI / I1).
///
/// **Grammar coverage (plan.md):**
///   The reduced grammar covers ~95% of amateur plays; the ~5% out-of-grammar cases are flagged
///   for manual entry (T030 / FR-017) — never fabricated.
///
/// - TODO: T049 — implement the grammar parser ("to short" → SS, "threw him out at first" → 6-3).
/// - TODO: T050 — implement the ambiguity path (low-confidence / multi-mapping → clarifying Q).

import Foundation
import DiamondSpeech

// MARK: - NormalizedPlay (Swift-side representation)

/// A fact-based representation of a single play, ready for the Rust core's `record_play`.
///
/// Keys and value semantics are defined in `core/src/model.rs` (T012 / `SituationDiamond` +
/// `Catalyst`) and the FFI boundary (T007). This is a loosely-typed Swift mirror;
/// the generated UniFFI type replaces it at H1 (T044 / T071).
///
/// **Important**: the core's fact-derived classifier (T021) reads these facts directly —
/// the caller label (if any) is ignored. Do NOT embed a pre-classification in the facts dict.
///
/// TODO: T049 — replace `[String: String]` with a typed value object.
public typealias NormalizedPlay = [String: String]

// MARK: - Parse errors

/// Errors from the grammar parser.
public enum ParseError: Error, Sendable {
    /// The transcript does not match any grammar production. Returns the raw transcript for
    /// display to the scorer (manual-entry path, FR-017).
    case outOfGrammar(transcript: String)
    /// The transcript is ambiguous (multiple candidate mappings). Returns the candidates
    /// so the UI can surface a clarifying question (T050 / FR-008).
    case ambiguous(candidates: [NormalizedPlay])
    /// The input transcript is empty or too short to parse.
    case emptyInput
}

// MARK: - Parser placeholder

/// Converts a `Transcript` into a `NormalizedPlay` using a deterministic grammar.
///
/// TODO: T049 — implement the reduced grammar parser.
///   Example reductions:
///     "ground ball to short" → { "trajectory": "ground_ball", "fielder_primary": "SS" }
///     "threw him out at first" → { "putout_fielder": "1B", "outs_recorded": "1" }
///     "ground ball to short, threw him out at first" → { "batter_result": "groundout",
///       "fielders": "6-3", "outs_recorded": "1" }
public struct GrammarParser: Sendable {
    public init() {}

    /// Parse a `Transcript` into a `NormalizedPlay`.
    ///
    /// - Parameter transcript: ASR output from `Transcriber` (T046).
    /// - Returns: `NormalizedPlay` fact map ready for `CoreClient.recordPlay`.
    /// - Throws: `ParseError.outOfGrammar` if no production matches;
    ///           `ParseError.ambiguous` if multiple candidates exist (→ clarifying Q, T050).
    ///
    /// TODO: T049 — implement grammar productions.
    public func parse(_ transcript: Transcript) throws -> NormalizedPlay {
        // Placeholder — T049.
        throw ParseError.outOfGrammar(transcript: transcript.text)
    }
}
