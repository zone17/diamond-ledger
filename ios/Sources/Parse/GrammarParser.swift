/// GrammarParser.swift — T049/T050 (Squad B, Story B3)
/// DL-151: grammar hardening — misplay routing, deterministic fielder order, full reduced-grammar coverage.
///
/// Design (plan.md / ADR-0007):
///   v1 = deterministic rule-based grammar. No LLM in v1.
///   The v2 path (FunctionGemma-270M + XGrammar) is explicitly deferred.
///
/// Ambiguity path (T050 / FR-008):
///   If the transcript confidence is below `lowConfidenceThreshold` OR the grammar
///   produces multiple candidate mappings, the parser throws `ParseError.ambiguous`
///   with the candidate set — NEVER a silent guess. This is a hard invariant (Art. VI / I1).
///
/// Grammar coverage (plan.md / contracts/retrosheet-reduced-grammar.md v1.1):
///   The reduced grammar covers ~95% of amateur plays; the ~5% out-of-grammar cases
///   are thrown as `ParseError.outOfGrammar` for manual entry — never fabricated.
///
/// Reduced play set (the common ~95%):
///   Misplay/error: "misplayed/booted/bobbled/muffed/dropped + batter-specific reached" → reached_on_error (Card B)
///   Groundouts:  "ground ball to [pos], threw him out at [pos]"     → fielders e.g. "63"
///   Flyouts:     "fly ball to [pos]", "caught by [pos]"             → fielder e.g. "8"
///   Strikeouts:  "struck out", "strikeout", "K"                     → K / Kl
///   Walks:       "walk", "walked", "base on balls"                  → BB
///   Singles:     "single", "hit single to [pos]"                    → S[pos]
///   Doubles:     "double", "hit double"                             → D[pos]
///   Triples:     "triple"                                           → T[pos]
///   Home run:    "home run", "homer"                               → HR
///   Hit by pitch:"hit by pitch", "HBP", "plunked"                  → HBP
///   Sac fly:     "sacrifice fly", "sac fly"                        → SF[pos]
///   Sac bunt:    "sacrifice bunt", "sac bunt"                      → SH
///   Error:       "reached on error", "error by [pos]"              → E[pos]
///   Double play: "double play", "DP" + fielders                    → DP
///
/// Production precedence (most specific first — prevents shorter matches swallowing longer ones):
///   1. tryMisplay     — misplay verbs + "reached/safe" → MUST precede tryGroundout
///   2. tryDoublePlay  — "double play" → MUST precede tryDouble
///   3. tryGroundout
///   4. tryFlyout
///   5. trySacFly      — "sac"+"fly" → MUST precede trySacBunt and tryFlyout
///   6. trySacBunt     — "bunt"+"sac" → MUST precede tryWalk etc.
///   7. tryStrikeout
///   8. tryWalk
///   9. tryHomeRun
///  10. trySingle
///  11. tryDouble
///  12. tryTriple
///  13. tryHitByPitch
///  14. tryError
///
/// Roster-aware name masking (DL-157 / R22 / KTD7):
///   `parse(_:roster:)` accepts an optional roster of player names. Before any production runs,
///   every whole-word occurrence of a roster name (multi-word names matched as a phrase first) is
///   replaced with `namePlaceholder` on the SAME normalized string the productions inspect, so a
///   surname can no longer collide with a position keyword ("Wright" → "right" → RF; a player
///   named "Short" / "Center"). Masking is EXACT-token replacement — never fuzzy — because fuzzy
///   matching would re-introduce the loose-substring class of bug
///   (docs/solutions/logic-errors/loose-substring-guard-silent-misclassification.md).
///
///   Invariant (Article VII / FR-008 — never a silent wrong play): when at least one name was
///   masked AND the single matching production resolved its fielder via its hard-coded default,
///   the parser throws `ParseError.ambiguous(candidates: [thatPlay])` so the play surfaces as a
///   clarify. Defaults may fire silently only when no name was masked. With an empty roster the
///   parser's behavior is byte-for-byte identical to the pre-DL-157 parser.

import Foundation
import SpeechTypes

// MARK: - GrammarParser

public struct GrammarParser: Sendable {

    /// Confidence below this integer threshold triggers the ambiguity path (FR-008).
    /// Integer scale 0…100 (ADR-0007).
    public static let lowConfidenceThreshold: Int = 70

    public init() {}

    /// Placeholder substituted for every masked roster name. Deliberately contains NO grammar
    /// keyword as a substring (checked by `DL157RosterMaskingTests.test_placeholder_neverMatchesAProduction`):
    /// no production's `contains(...)` check, position keyword, or exact-equality token ("k",
    /// "dp", "bb", "iw", "hr") can ever match it or be formed across its boundaries.
    static let namePlaceholder = "__name__"

    /// Parse a `Transcript` into a `NormalizedPlay`.
    ///
    /// - Parameters:
    ///   - transcript: ASR output from `Transcriber`.
    ///   - roster: Optional player names (any case / punctuation). Each whole-word occurrence is
    ///     masked before production matching (see file header). Empty = legacy behavior.
    /// - Returns: `NormalizedPlay` fact map ready for `CoreClient.recordPlay`.
    /// - Throws:
    ///     `ParseError.outOfGrammar(transcript:)` — no production matched; route to manual entry.
    ///     `ParseError.ambiguous(candidates:)`     — multiple productions matched, low confidence,
    ///                                                OR a roster name was masked and the matched
    ///                                                production fell back to a default fielder;
    ///                                                route to clarifying Q.
    ///     `ParseError.emptyInput`                 — transcript text is empty.
    public func parse(_ transcript: Transcript, roster: [String] = []) throws -> NormalizedPlay {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.emptyInput }

        // Low-confidence threshold check (FR-008): if confidence is below threshold,
        // try to parse but treat any result as ambiguous (surface clarifying question).
        let isLowConfidence = transcript.confidence < Self.lowConfidenceThreshold

        // Roster masking (DL-157). Only the roster path applies the stronger normalization
        // (strip punctuation, collapse whitespace) so that the no-roster path stays identical to
        // the pre-DL-157 parser. Masking operates on the exact string the productions inspect.
        let normalized: String
        let maskedAny: Bool
        if roster.isEmpty {
            normalized = text.lowercased()
            maskedAny = false
        } else {
            let masked = Self.maskRosterNames(in: Self.normalizeForMasking(text), roster: roster)
            normalized = masked.masked
            maskedAny = masked.maskedAny
        }
        var candidates: [NormalizedPlay] = []
        var anyUsedDefault = false

        // Productions in precedence order (see file header). Each returns a Match on
        // match or nil on non-match. The order matters:
        //   - tryMisplay BEFORE tryGroundout (a "booted grounder, safe at first" must NOT become
        //     a groundout; misplay verbs on a reached batter are more specific than "grounder").
        //   - tryDoublePlay BEFORE tryDouble ("double play" contains "double").
        //   - trySacFly BEFORE trySacBunt (both contain "sac"; "fly" distinguishes them).
        let productions: [(String) -> Match?] = [
            tryMisplay, tryDoublePlay, tryGroundout, tryFlyout, trySacFly, trySacBunt,
            tryStrikeout, tryWalk, tryHomeRun, trySingle, tryDouble, tryTriple,
            tryHitByPitch, tryError,
        ]
        for production in productions {
            if let match = production(normalized) {
                candidates.append(match.play)
                if match.usedDefault { anyUsedDefault = true }
            }
        }

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
            // DL-157 invariant: a masked roster name plus a defaulted fielder means the fielder
            // information was in the name we just masked — the default is a guess, not a fact.
            // Surface as a single-candidate clarify; never return it silently.
            if maskedAny && anyUsedDefault {
                throw ParseError.ambiguous(candidates: candidates)
            }
            return candidates[0]

        default:
            // Multiple productions matched → ambiguous (FR-008).
            throw ParseError.ambiguous(candidates: candidates)
        }
    }

    // MARK: - Roster masking (DL-157 / R22 / KTD7)

    /// Normalizes text for roster masking: lowercase, strip every character that is not a letter,
    /// digit, or whitespace (so "O'Neil" / "O’Neil" / "oneil" all become "oneil"), then collapse
    /// runs of whitespace to a single space. Applied identically to the transcript and to each
    /// roster name so both sides compare token-for-token.
    static func normalizeForMasking(_ text: String) -> String {
        let lowered = text.lowercased()
        var scrubbed = ""
        scrubbed.reserveCapacity(lowered.count)
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch.isWhitespace { scrubbed.append(ch) }
        }
        return scrubbed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Replaces every whole-word occurrence of each roster name in `normalized` (already passed
    /// through `normalizeForMasking`) with `namePlaceholder`.
    ///
    /// Rules (KTD7 — exact token replacement, never fuzzy):
    ///   - Comparison is token-by-token on the whitespace-split string, so "wright" never masks
    ///     "wrights" and a name never matches inside another word.
    ///   - Multi-word names ("center fielder jones") are matched as a contiguous phrase and
    ///     replaced by ONE placeholder; longer names are tried first so a multi-word name is
    ///     never partially eaten by a shorter one.
    ///   - Every occurrence is masked ("wright to wright" → two placeholders).
    ///   - A roster name identical to a grammar keyword ("Short", "Center") IS masked. The
    ///     chosen rule: the roster is the more specific signal, so the token is treated as the
    ///     player, the production loses its position word, and (if it would default) the play
    ///     surfaces as a clarify — a safe miss rather than a silent guess.
    ///
    /// - Returns: the masked string and whether at least one replacement happened.
    static func maskRosterNames(in normalized: String, roster: [String]) -> (masked: String, maskedAny: Bool) {
        let names: [[Substring]] = roster
            .map { normalizeForMasking($0).split(separator: " ") }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        guard !names.isEmpty else { return (normalized, false) }

        var tokens: [Substring] = normalized.split(separator: " ")
        var maskedAny = false
        let placeholder = Substring(namePlaceholder)

        for name in names {
            var i = 0
            while i + name.count <= tokens.count {
                if Array(tokens[i..<(i + name.count)]) == name {
                    tokens.replaceSubrange(i..<(i + name.count), with: [placeholder])
                    maskedAny = true
                }
                i += 1
            }
        }
        return (tokens.joined(separator: " "), maskedAny)
    }

    // MARK: - Production match

    /// A production's result: the play plus whether its fielder came from a hard-coded default
    /// rather than a position keyword found in the transcript (DL-157 clarify invariant).
    struct Match {
        let play: NormalizedPlay
        let usedDefault: Bool
    }

    // MARK: - Grammar productions

    // Each production returns a `Match` (play + usedDefault) on match, or `nil` on non-match.
    // Keys mirror the MockCore/real core FFI schema (core/src/model.rs).
    // `usedDefault` is true only when the production filled its fielder/chain from a hard-coded
    // default because no position keyword was found — the signal the roster-masking clarify
    // invariant keys on.

    // MARK: Misplay → reached_on_error (Card B)
    //
    // DL-151 fix: this production MUST appear before tryGroundout in the dispatch list.
    //
    // Misplay verbs that indicate the batter REACHED base (error, not out):
    //   "misplayed grounder to short, reached first"
    //   "booted by short, batter safe at first"
    //   "bobbled the grounder, batter safe at first"
    //   "muffed the ball, batter safe"
    //   "dropped it, batter reaches first"
    //
    // Three-signal guard (P1a + P1b code-review fixes, DL-151):
    //
    //   (a) A misplay verb: misplayed / booted / bobbled / muffed / dropped
    //
    //   (b) The BATTER specifically reached — NOT a bare "safe" / "reached" anywhere in the
    //       transcript (that could refer to a runner, not the batter). Accepted batter-specific
    //       patterns:
    //         "batter safe", "batter reached", "batter reach"
    //         "safe at first", "safe at second", "safe at third"
    //         "reached first", "reached second", "reached third", "reached base"
    //       A bare "reached"/"safe"/"on base" without a batter-specific anchor is rejected.
    //       Rationale: "dropped fly ball in center, runner scored safely" → "safely" ≈ "safe"
    //       but the batter was out — the bare-safe guard was the P1b false-Card-B root cause.
    //
    //   (c) NOT a dropped-third-strike context: "third strike" / "strike three" / "strike 3"
    //       in the same transcript → return nil (K+WP/K+PB is out-of-grammar in v1; routing it
    //       to reached_on_error was the P1a false-Card-B root cause).
    //
    //   (d) NOT a fly-ball context: "fly ball" / "flyout" / "fly out" → return nil. A fielder
    //       dropping a fly ball where the batter reaches would be described differently (e.g.
    //       "dropped in left, batter safe at first"); a "dropped fly ball" transcript almost
    //       always means the batter reached on the catch attempt, which is a different scorer
    //       judgment path — leave it out-of-grammar so the scorer can use manual entry.
    //
    // Emits: ["batter_result": "reached_on_error", "error_position": "<pos>"]
    // FactBridge maps this to misplayedGrounder(at:) → real core classifies HitVsError (Card B).
    //
    // P2a fix: use parseInfieldPosition ?? parseOutfieldPosition so an outfield drop (e.g.
    // "dropped in left field, batter safe at first") records position 7 not 6 (SS default).
    private func tryMisplay(_ s: String) -> Match? {
        // (a) Require a misplay verb.
        let hasMisplayVerb = s.contains("misplayed") || s.contains("booted")
                          || s.contains("bobbled")   || s.contains("muffed")
                          || s.contains("dropped")
        guard hasMisplayVerb else { return nil }

        // (c) P1a guard: dropped-third-strike context → out-of-grammar in v1, not Card B.
        // "dropped third strike, batter reached first" is K+WP/K+PB — no v1 production.
        if s.contains("third strike") || s.contains("strike three") || s.contains("strike 3") {
            return nil
        }

        // (d) Fly-ball context guard: a "dropped fly ball" where the batter reached is a
        // distinct scorer judgment; leave it for manual entry (outOfGrammar) rather than
        // silently mis-classifying it as a reached-on-grounder-error (FR-008 / Article VII).
        if s.contains("fly ball") || s.contains("flyout") || s.contains("fly out") {
            return nil
        }

        // (b) P1b guard: the BATTER must specifically have reached, not just any runner.
        // Anchored patterns only — bare "safe" / "reached" anywhere in the string is
        // insufficient and was the root cause of the runner-safe false-Card-B.
        let batterReachedAnchors: [String] = [
            "batter safe", "batter reached", "batter reach",
            "safe at first", "safe at second", "safe at third",
            "reached first", "reached second", "reached third", "reached base",
        ]
        let batterReached = batterReachedAnchors.contains { s.contains($0) }
        guard batterReached else { return nil }

        // P2a: try infield position first, then outfield (a drop in left field → pos "7").
        let explicit = parseInfieldPosition(s) ?? parseOutfieldPosition(s)
        let pos = explicit ?? "6"
        return Match(play: ["batter_result": "reached_on_error", "error_position": pos],
                     usedDefault: explicit == nil)
    }

    // MARK: Groundout
    private func tryGroundout(_ s: String) -> Match? {
        // "ground ball to short, threw him out at first" → batter_result=groundout, fielders="63"
        guard s.contains("ground") || s.contains("grounder") else { return nil }
        // Guard: a double play that includes "ground ball" is handled by tryDoublePlay.
        if s.contains("double play") || s.contains(" dp") || s == "dp" { return nil }
        // Guard: if the batter REACHED, this is NOT a groundout — let tryMisplay handle it.
        // (tryMisplay runs first, but if tryGroundout is ever reached after a misplay keyword
        // appears alone without a reached keyword, we still don't want a groundout.)
        let batterReached = s.contains("reached") || s.contains("safe")
                         || s.contains("on base")  || s.contains("reach")
        if batterReached { return nil }

        let explicit = parseFielderSequence(s)
        let fielders = explicit ?? "63"  // default: SS to 1B
        return Match(play: ["batter_result": "groundout", "fielders": fielders, "outs_recorded": "1"],
                     usedDefault: explicit == nil)
    }

    // MARK: Flyout
    private func tryFlyout(_ s: String) -> Match? {
        guard s.contains("fly ball") || s.contains("flyout") || s.contains("line drive") ||
              (s.contains("caught") && !s.contains("strike") && !s.contains("steal")) ||
              s.contains("pop up") || s.contains("pop-up") || s.contains("popup") ||
              s.contains("line out") || s.contains("lineout") else { return nil }
        // Guard: "sac fly" or "sacrifice fly" matches "fly" but belongs to trySacFly.
        if s.contains("sac") && (s.contains("fly") || s.contains("sacrifice")) { return nil }
        let explicit = parseOutfieldPosition(s) ?? parseInfieldPosition(s)
        let pos = explicit ?? "8"  // default: CF
        return Match(play: ["batter_result": "flyout", "fielder": pos, "outs_recorded": "1"],
                     usedDefault: explicit == nil)
    }

    // MARK: Strikeout
    private func tryStrikeout(_ s: String) -> Match? {
        guard s.contains("struck out") || s.contains("strikeout") ||
              s.contains("strike out") || s == "k" else { return nil }
        // Looking (Kl) vs swinging (K): look for "looking" or "called" keyword.
        let looking = s.contains("looking") || s.contains("called")
        return Match(play: ["batter_result": looking ? "strikeout_looking" : "strikeout", "outs_recorded": "1"],
                     usedDefault: false)
    }

    // MARK: Walk
    private func tryWalk(_ s: String) -> Match? {
        guard s.contains("walk") || s.contains("base on balls") || s == "bb" ||
              s.contains("intentional walk") || s == "iw" else { return nil }
        let intentional = s.contains("intentional") || s == "iw"
        return Match(play: ["batter_result": intentional ? "intentional_walk" : "walk"], usedDefault: false)
    }

    // MARK: Home run
    private func tryHomeRun(_ s: String) -> Match? {
        guard s.contains("home run") || s.contains("homer") || s == "hr" else { return nil }
        return Match(play: ["batter_result": "home_run", "runs_scored": "1"], usedDefault: false)
    }

    // MARK: Single
    private func trySingle(_ s: String) -> Match? {
        guard s.contains("single") else { return nil }
        let pos = parseOutfieldPosition(s) ?? parseInfieldPosition(s)
        var play: NormalizedPlay = ["batter_result": "single"]
        if let pos { play["fielder"] = pos }
        return Match(play: play, usedDefault: false)
    }

    // MARK: Double
    private func tryDouble(_ s: String) -> Match? {
        // Guard: "double play" was handled by tryDoublePlay earlier.
        guard s.contains("double") && !s.contains("double play") && !s.contains("dp") else { return nil }
        let pos = parseOutfieldPosition(s) ?? parseInfieldPosition(s)
        var play: NormalizedPlay = ["batter_result": "double"]
        if let pos { play["fielder"] = pos }
        return Match(play: play, usedDefault: false)
    }

    // MARK: Triple
    private func tryTriple(_ s: String) -> Match? {
        guard s.contains("triple") else { return nil }
        let pos = parseOutfieldPosition(s) ?? parseInfieldPosition(s)
        var play: NormalizedPlay = ["batter_result": "triple"]
        if let pos { play["fielder"] = pos }
        return Match(play: play, usedDefault: false)
    }

    // MARK: Hit by pitch
    private func tryHitByPitch(_ s: String) -> Match? {
        guard s.contains("hit by pitch") || s.contains("hbp") ||
              s.contains("plunked") || s.contains("hit by the pitch") else { return nil }
        return Match(play: ["batter_result": "hit_by_pitch"], usedDefault: false)
    }

    // MARK: Sac fly
    private func trySacFly(_ s: String) -> Match? {
        // "sac fly", "sacrifice fly" — both "sac" and "fly" must be present.
        guard (s.contains("sac") || s.contains("sacrifice")) && s.contains("fly") else { return nil }
        // Guard: "sac bunt" does not contain "fly" but "bunt" — no conflict, but be safe.
        guard !s.contains("bunt") else { return nil }
        let explicit = parseOutfieldPosition(s)
        let pos = explicit ?? "9"  // default: RF
        var play: NormalizedPlay = ["batter_result": "sac_fly", "outs_recorded": "1"]
        play["fielder"] = pos
        return Match(play: play, usedDefault: explicit == nil)
    }

    // MARK: Sac bunt
    private func trySacBunt(_ s: String) -> Match? {
        // Must contain "bunt" — a bare "sacrifice" must NOT match (else "sacrifice fly"
        // is ambiguous between sac_fly and sac_bunt). "sacrifice" already contains "sac".
        guard s.contains("bunt") && (s.contains("sac") || s.contains("sacrifice")) else { return nil }
        let fielders = parseFielderSequence(s)
        var play: NormalizedPlay = ["batter_result": "sac_bunt", "outs_recorded": "1"]
        if let fielders { play["fielders"] = fielders }
        return Match(play: play, usedDefault: false)
    }

    // MARK: Error (reached on error — generic path without a misplay verb)
    private func tryError(_ s: String) -> Match? {
        // "reached on error", "error by short" → E6
        guard s.contains("error") || (s.contains("reached on") && !s.contains("strike")) else { return nil }
        let explicit = parseInfieldPosition(s) ?? parseOutfieldPosition(s)
        let pos = explicit ?? "6"  // default SS
        return Match(play: ["batter_result": "reached_on_error", "error_position": pos],
                     usedDefault: explicit == nil)
    }

    // MARK: Double play
    private func tryDoublePlay(_ s: String) -> Match? {
        // "double play" or standalone "dp" (case-normalized to lowercase already).
        guard s.contains("double play") || s == "dp" || s.hasPrefix("dp ") || s.hasSuffix(" dp") else { return nil }
        let explicit = parseFielderSequence(s)
        let fielders = explicit ?? "643"  // default: SS to 2B to 1B
        return Match(play: ["batter_result": "double_play", "fielders": fielders, "outs_recorded": "2"],
                     usedDefault: explicit == nil)
    }

    // MARK: - Position keyword helpers

    /// All recognized position keywords mapped to their Retrosheet position digit.
    /// Order within this array is irrelevant — `parseFielderSequence` uses position-in-string
    /// ordering (the TRANSCRIPT order), not the order of this array.
    private static let positionKeywords: [(keyword: String, pos: String)] = [
        // Pitcher
        ("pitcher", "1"), ("mound", "1"),
        // Catcher
        ("catcher", "2"), ("behind the plate", "2"),
        // First base — must come before "second" to avoid "first" matching inside "first baseman"
        // ambiguously. The matching is exact substring, so "first baseman" also matches "first".
        ("first baseman", "3"), ("first base", "3"), ("first", "3"),
        // Second base
        ("second baseman", "4"), ("second base", "4"), ("second", "4"),
        // Third base
        ("third baseman", "5"), ("third base", "5"), ("third", "5"),
        // Shortstop
        ("shortstop", "6"), ("short", "6"),
        // Left field
        ("left fielder", "7"), ("left field", "7"), ("left", "7"),
        // Center field
        ("center fielder", "8"), ("center field", "8"), ("center", "8"),
        // Right field
        ("right fielder", "9"), ("right field", "9"), ("right", "9"),
    ]

    /// Return the position digit for the position keyword that appears EARLIEST in `s`, or nil.
    ///
    /// Using string-position ordering (not keyword-array order) ensures that "booted by short,
    /// batter safe at first" returns "6" (short appears earlier in the string than first), and
    /// "muffed by the third baseman, batter safe at first" returns "5" (third baseman is earlier).
    private func parseInfieldPosition(_ s: String) -> String? {
        var earliest: (index: String.Index, pos: String)? = nil
        for (keyword, pos) in Self.positionKeywords {
            guard let range = s.range(of: keyword) else { continue }
            if let current = earliest {
                if range.lowerBound < current.index {
                    earliest = (range.lowerBound, pos)
                }
            } else {
                earliest = (range.lowerBound, pos)
            }
        }
        return earliest?.pos
    }

    /// Return the outfield position for the first outfield keyword found in `s`, or nil.
    private func parseOutfieldPosition(_ s: String) -> String? {
        // Prioritize "left field" / "right field" / "center field" over bare "left" / "right" /
        // "center" to avoid matching "left" in "left the base" or "right" in "right away".
        if s.contains("left field")   || s.contains("left fielder")   { return "7" }
        if s.contains("center field") || s.contains("center fielder") { return "8" }
        if s.contains("right field")  || s.contains("right fielder")  { return "9" }
        if s.contains("left")   { return "7" }
        if s.contains("center") { return "8" }
        if s.contains("right")  { return "9" }
        return nil
    }

    /// Derives a fielder-chain string (e.g. "63") from the spoken position keywords, ordered by
    /// their POSITION IN THE TRANSCRIPT STRING (the order the speaker said them).
    ///
    /// DL-151 fix: the previous implementation iterated `positionKeywords` as a Dictionary,
    /// which has undefined iteration order — "short to first" could produce "36" or "63"
    /// non-deterministically across runs. We now find each keyword's first occurrence index in
    /// the string, then sort by that index so the output chain always reflects spoken order:
    ///   "short to first" → SS found at offset N < 1B found at offset M → "63"
    ///   "third to second to first" → 5 then 4 then 3 → "543"
    ///
    /// Returns nil when fewer than two position keywords are found (no chain to form).
    private func parseFielderSequence(_ s: String) -> String? {
        // Collect (firstOccurrenceIndex, positionDigit) for every keyword found in the string.
        // When multiple keywords map to the same position (e.g. "short" and "shortstop" both = "6"),
        // keep only the earliest occurrence so we don't double-count the same fielder.
        var seen: [String: String.Index] = [:]   // pos digit → earliest occurrence in s
        for (keyword, pos) in Self.positionKeywords {
            guard let range = s.range(of: keyword) else { continue }
            if let existing = seen[pos] {
                // Keep whichever occurrence is earlier in the string.
                if range.lowerBound < existing {
                    seen[pos] = range.lowerBound
                }
            } else {
                seen[pos] = range.lowerBound
            }
        }

        guard seen.count >= 2 else { return nil }

        // Sort by the index in the transcript string (ascending = spoken order).
        let ordered = seen.sorted { $0.value < $1.value }
        return ordered.map { $0.key }.joined()
    }
}
