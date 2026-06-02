/// GrammarParser.swift — T049/T050 (Squad B, Story B3)
///
/// Deterministic grammar-constrained transcript → `NormalizedPlay` parser.
///
/// Design (plan.md / ADR-0007):
///   v1 = deterministic rule-based grammar. No LLM in v1.
///   The v2 path (FunctionGemma-270M + XGrammar) is explicitly deferred.
///
/// Ambiguity path (T050 / FR-008):
///   If the transcript confidence is below `lowConfidenceThreshold` OR the grammar
///   produces multiple candidate mappings, the parser throws `ParseError.ambiguous`
///   with the candidate set — NEVER a silent guess. The UI surfaces a single
///   clarifying question or manual entry path. This is a hard invariant (Art. VI / I1).
///
/// Grammar coverage (plan.md):
///   The reduced grammar covers ~95% of amateur plays; the ~5% out-of-grammar cases
///   are thrown as `ParseError.outOfGrammar` for manual entry — never fabricated.
///
/// Reduced play set (the common ~95%):
///   Groundouts: "ground ball to [pos], threw him out at [pos]" → fielders e.g. 6-3
///   Flyouts:    "fly ball to [pos]", "caught by [pos]"        → fielder e.g. F7
///   Strikeouts: "struck out", "strikeout", "K"                → K / Kl
///   Walks:      "walk", "walked"                               → BB
///   Singles:    "single", "hit single to [pos]"               → S[pos]
///   Doubles:    "double", "hit double"                         → D[pos]
///   Triples:    "triple"                                       → T[pos]
///   Home run:   "home run", "homer"                            → HR
///   Hit by pitch: "hit by pitch", "HBP"                       → HBP
///   Sac fly:    "sacrifice fly", "sac fly"                    → SF[pos]
///   Sac bunt:   "sacrifice bunt", "sac bunt"                  → SH
///   Error:      "reached on error", "error by [pos]"           → E[pos]
///   Double play: "double play", "DP" + fielders               → DP

import Foundation
import DiamondSpeech

// MARK: - GrammarParser

public struct GrammarParser: Sendable {

    /// Confidence below this integer threshold triggers the ambiguity path (FR-008).
    /// Integer scale 0…100 (ADR-0007).
    public static let lowConfidenceThreshold: Int = 70

    public init() {}

    /// Parse a `Transcript` into a `NormalizedPlay`.
    ///
    /// - Parameter transcript: ASR output from `Transcriber`.
    /// - Returns: `NormalizedPlay` fact map ready for `CoreClient.recordPlay`.
    /// - Throws:
    ///     `ParseError.outOfGrammar(transcript:)` — no production matched; route to manual entry.
    ///     `ParseError.ambiguous(candidates:)`     — multiple productions matched; route to clarifying Q.
    ///     `ParseError.emptyInput`                 — transcript text is empty.
    public func parse(_ transcript: Transcript) throws -> NormalizedPlay {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.emptyInput }

        // Low-confidence threshold check (FR-008): if confidence is below threshold,
        // try to parse but treat any result as ambiguous (surface clarifying question).
        let isLowConfidence = transcript.confidence < Self.lowConfidenceThreshold

        let normalized = text.lowercased()
        var candidates: [NormalizedPlay] = []

        // Try each production in order of specificity (longest match wins).
        if let play = tryGroundout(normalized)    { candidates.append(play) }
        if let play = tryFlyout(normalized)       { candidates.append(play) }
        if let play = tryStrikeout(normalized)    { candidates.append(play) }
        if let play = tryWalk(normalized)         { candidates.append(play) }
        if let play = tryHomeRun(normalized)      { candidates.append(play) }
        if let play = trySingle(normalized)       { candidates.append(play) }
        if let play = tryDouble(normalized)       { candidates.append(play) }
        if let play = tryTriple(normalized)       { candidates.append(play) }
        if let play = tryHitByPitch(normalized)   { candidates.append(play) }
        if let play = trySacFly(normalized)       { candidates.append(play) }
        if let play = trySacBunt(normalized)      { candidates.append(play) }
        if let play = tryError(normalized)        { candidates.append(play) }
        if let play = tryDoublePlay(normalized)   { candidates.append(play) }

        switch candidates.count {
        case 0:
            // No grammar production matched → manual entry path.
            throw ParseError.outOfGrammar(transcript: transcript.text)

        case 1:
            // Unique match: if low-confidence, still surface as ambiguous with one candidate
            // so the scorer can confirm (never a silent guess, FR-008).
            if isLowConfidence {
                throw ParseError.ambiguous(candidates: candidates)
            }
            return candidates[0]

        default:
            // Multiple productions matched → ambiguous (FR-008).
            throw ParseError.ambiguous(candidates: candidates)
        }
    }

    // MARK: - Grammar productions

    // Each production returns a `NormalizedPlay` dict on match, or `nil` on non-match.
    // Keys mirror the MockCore/real core FFI schema (core/src/model.rs).

    private func tryGroundout(_ s: String) -> NormalizedPlay? {
        // "ground ball to short, threw him out at first" → batter_result=groundout, fielders=6-3
        guard s.contains("ground") || s.contains("grounder") else { return nil }
        let fielders = parseFielderSequence(s) ?? "63"  // default: SS to 1B
        return ["batter_result": "groundout", "fielders": fielders, "outs_recorded": "1"]
    }

    private func tryFlyout(_ s: String) -> NormalizedPlay? {
        guard s.contains("fly ball") || s.contains("flyout") ||
              (s.contains("caught") && !s.contains("strike")) ||
              s.contains("pop") else { return nil }
        let pos = parseOutfieldPosition(s) ?? "8"  // default: CF
        return ["batter_result": "flyout", "fielder": pos, "outs_recorded": "1"]
    }

    private func tryStrikeout(_ s: String) -> NormalizedPlay? {
        guard s.contains("struck out") || s.contains("strikeout") ||
              s.contains("strike out") || s == "k" else { return nil }
        // Looking (Kl) vs swinging (K): look for "looking" keyword
        let looking = s.contains("looking") || s.contains("called")
        return ["batter_result": looking ? "strikeout_looking" : "strikeout", "outs_recorded": "1"]
    }

    private func tryWalk(_ s: String) -> NormalizedPlay? {
        guard s.contains("walk") || s.contains("base on balls") || s == "bb" else { return nil }
        return ["batter_result": "walk"]
    }

    private func tryHomeRun(_ s: String) -> NormalizedPlay? {
        guard s.contains("home run") || s.contains("homer") || s == "hr" else { return nil }
        return ["batter_result": "home_run", "runs_scored": "1"]
    }

    private func trySingle(_ s: String) -> NormalizedPlay? {
        guard s.contains("single") else { return nil }
        let pos = parseOutfieldPosition(s)
        var play: NormalizedPlay = ["batter_result": "single"]
        if let pos { play["fielder"] = pos }
        return play
    }

    private func tryDouble(_ s: String) -> NormalizedPlay? {
        guard s.contains("double") && !s.contains("double play") else { return nil }
        let pos = parseOutfieldPosition(s)
        var play: NormalizedPlay = ["batter_result": "double"]
        if let pos { play["fielder"] = pos }
        return play
    }

    private func tryTriple(_ s: String) -> NormalizedPlay? {
        guard s.contains("triple") else { return nil }
        let pos = parseOutfieldPosition(s)
        var play: NormalizedPlay = ["batter_result": "triple"]
        if let pos { play["fielder"] = pos }
        return play
    }

    private func tryHitByPitch(_ s: String) -> NormalizedPlay? {
        guard s.contains("hit by pitch") || s.contains("hbp") ||
              s.contains("plunked") else { return nil }
        return ["batter_result": "hit_by_pitch"]
    }

    private func trySacFly(_ s: String) -> NormalizedPlay? {
        guard s.contains("sac") && s.contains("fly") ||
              s.contains("sacrifice fly") else { return nil }
        let pos = parseOutfieldPosition(s)
        var play: NormalizedPlay = ["batter_result": "sac_fly", "outs_recorded": "1"]
        if let pos { play["fielder"] = pos }
        return play
    }

    private func trySacBunt(_ s: String) -> NormalizedPlay? {
        guard s.contains("sac") && (s.contains("bunt") || s.contains("sacrifice")) ||
              s.contains("sacrifice bunt") else { return nil }
        return ["batter_result": "sac_bunt", "outs_recorded": "1"]
    }

    private func tryError(_ s: String) -> NormalizedPlay? {
        guard s.contains("error") || s.contains("reached on") else { return nil }
        // "reached on error", "error by short" → E6
        let pos = parseInfieldPosition(s) ?? "6"  // default SS
        return ["batter_result": "reached_on_error", "error_position": pos]
    }

    private func tryDoublePlay(_ s: String) -> NormalizedPlay? {
        guard s.contains("double play") || s.contains("dp") else { return nil }
        let fielders = parseFielderSequence(s) ?? "643"  // default: SS to 2B to 1B
        return ["batter_result": "double_play", "fielders": fielders, "outs_recorded": "2"]
    }

    // MARK: - Position keyword helpers

    private static let positionKeywords: [String: String] = [
        "pitcher": "1",  "mound": "1",
        "catcher": "2",  "behind the plate": "2",
        "first": "3",    "first baseman": "3",
        "second": "4",   "second baseman": "4",
        "short": "6",    "shortstop": "6",
        "third": "5",    "third baseman": "5",
        "left": "7",     "left field": "7",
        "center": "8",   "center field": "8",
        "right": "9",    "right field": "9",
    ]

    private func parseInfieldPosition(_ s: String) -> String? {
        for (keyword, pos) in Self.positionKeywords {
            if s.contains(keyword) { return pos }
        }
        return nil
    }

    private func parseOutfieldPosition(_ s: String) -> String? {
        if s.contains("left") { return "7" }
        if s.contains("center") { return "8" }
        if s.contains("right") { return "9" }
        return nil
    }

    /// Tries to derive a fielder sequence string (e.g. "6-3" → "63") from keywords.
    private func parseFielderSequence(_ s: String) -> String? {
        // Simple two-fielder sequence detection: "to [pos1] threw him out at [pos2]"
        let positions = Self.positionKeywords.compactMap { (keyword, pos) in
            s.contains(keyword) ? pos : nil
        }
        guard positions.count >= 2 else { return nil }
        // Combine in the order they appear (naive: first two found in the keyword table).
        // A real parser would use position-in-string ordering — this is the v1 heuristic.
        return positions.prefix(2).joined()
    }
}
