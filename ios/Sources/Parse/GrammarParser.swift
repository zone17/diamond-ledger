/// GrammarParser.swift — T049/T050 (Squad B, Story B3)
/// DL-151: grammar hardening — misplay routing, deterministic fielder order, full reduced-grammar coverage.
/// DL-157 U9: the parser never guesses a fielder (KTD-U9) — whole-word matching, no silent defaults.
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
/// KTD-U9 — the parser never guesses a fielder (Article VII / FR-008; DL-157 findings F1–F9):
///
///   Every production that NEEDS a fielder (groundout chain, flyout, sac fly, error / misplay
///   position, double-play chain) or a play variant (strikeout looking vs swinging) resolves it
///   ONLY from what the utterance explicitly says. When the utterance does not say it, the
///   production still matches (so the play TYPE is known) but marks itself `unresolved`, and
///   `parse` throws `ParseError.ambiguous(candidates: [thatPlay])` — a single-candidate clarify.
///   The Clarify sheet offers the play and the scorer confirms or fixes the fielder. There is no
///   hard-coded default chain / position anywhere in this file any more. Concretely:
///     - groundout: fewer than two explicit positions (one is enough only with "unassisted")
///       → clarify; "ground ball four three" / "ground ball to X, threw him out at first" with
///       X unrecognised → clarify (F1). The candidate carries the partial chain that WAS heard
///       (e.g. "3"), never an invented one.
///     - flyout / sac fly / error / misplay: no explicit position → clarify (F2, F3, F7).
///       The batter's DESTINATION ("safe at first", "reached first", "runner on third") is never
///       read as a fielder (F7).
///     - double play: fewer than two explicit positions → clarify (F6/F11).
///     - strikeout: "looking"/"called" → Kl, "swinging" → K; a BARE strikeout ("struck out",
///       "struck out, runner safe at third", "K") keeps the swinging default (the canonical
///       corpus and DL-154 treat a bare strikeout as K); a strikeout followed by an unknown
///       content word in the modifier slot ("strikeout cooking") is a mis-heard modifier →
///       clarify with BOTH variants as candidates (F4).
///
///   Whole-word matching (F5, the DL-151 loose-substring class —
///   docs/solutions/logic-errors/loose-substring-guard-silent-misclassification.md): the
///   transcript is tokenized into words (punctuation stripped, commas/periods kept as clause
///   markers) and every keyword / phrase matches whole tokens only. "alright" never matches
///   "right", "wright" never matches "right", "terror" never matches "error". A BARE direction /
///   ordinal word ("right", "left", "center", "first", "second", "third", "short") counts as a
///   position only in a fielding slot: after a fielding preposition ("to / at / by / in / from /
///   into / toward(s)", articles skipped) or as the head of a chain ("first to short"). Phrase
///   forms ("right field", "third baseman", "shortstop", "pitcher", "catcher") always count.
///   Numerals ("6-3", "four three", "F7", "E6") are NOT positions in v1: a number word is too
///   overloaded in play narration (counts, outs, runs, innings) to be read as a fielder without
///   guessing — those utterances surface as a clarify or out-of-grammar.
///
/// Roster-aware name masking (DL-157 / R22 / KTD7):
///   `parse(_:roster:)` accepts an optional roster of player names. Before any production runs,
///   every whole-word occurrence of a roster name (multi-word names matched as a phrase first) is
///   replaced with `namePlaceholder` on the SAME token list the productions inspect, so a
///   surname can no longer collide with a position keyword ("Wright" → "right" → RF; a player
///   named "Short" / "Center"). Masking is EXACT-token replacement — never fuzzy — because fuzzy
///   matching would re-introduce the loose-substring class of bug.
///
///   Invariant (Article VII / FR-008 — never a silent wrong play, F6): a masked name that sits
///   in a FIELDING SLOT ("to Wright", "by Jones", "Wright to second to first") almost certainly
///   WAS the fielder the production is missing, so every fielder-requiring production treats it
///   as unresolved → single-candidate clarify — even when the remaining explicit positions would
///   form a complete (wrong) chain. A masked name qualified by its position ("Wright at short",
///   "Jones in center") is not a lost fielder. A masked name outside a fielding slot ("Wright
///   threw him out at first", "Garcia grounds to short", "single to Wright") never forces a
///   clarify on its own.

import Foundation
import SpeechTypes

// MARK: - GrammarParser

public struct GrammarParser: Sendable {

    /// Confidence below this integer threshold triggers the ambiguity path (FR-008).
    /// Integer scale 0…100 (ADR-0007).
    public static let lowConfidenceThreshold: Int = 70

    public init() {}

    /// Placeholder substituted for every masked roster name. Deliberately contains NO grammar
    /// keyword (checked by `DL157RosterMaskingTests.test_placeholder_neverMatchesAProduction`):
    /// it is a single token that equals no keyword, position word, or exact-equality token
    /// ("k", "dp", "bb", "iw", "hr"), and whole-word matching means it can never be formed
    /// across token boundaries.
    static let namePlaceholder = "__name__"

    /// Parse a `Transcript` into a `NormalizedPlay`.
    ///
    /// - Parameters:
    ///   - transcript: ASR output from `Transcriber`.
    ///   - roster: Optional player names (any case / punctuation). Each whole-word occurrence is
    ///     masked before production matching (see file header). Empty = no masking.
    /// - Returns: `NormalizedPlay` fact map ready for `CoreClient.recordPlay`.
    /// - Throws:
    ///     `ParseError.outOfGrammar(transcript:)` — no production matched; route to manual entry.
    ///     `ParseError.ambiguous(candidates:)`     — multiple productions matched, low confidence,
    ///                                                OR the single matching production could not
    ///                                                resolve its fielder / variant from the
    ///                                                utterance (KTD-U9); route to clarifying Q.
    ///     `ParseError.emptyInput`                 — transcript text is empty.
    public func parse(_ transcript: Transcript, roster: [String] = []) throws -> NormalizedPlay {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.emptyInput }

        // Low-confidence threshold check (FR-008): if confidence is below threshold,
        // try to parse but treat any result as ambiguous (surface clarifying question).
        let isLowConfidence = transcript.confidence < Self.lowConfidenceThreshold

        // Tokenize (whole-word grammar, F5), then mask roster names on the same token list the
        // productions inspect (DL-157). Punctuation-only input matches no production.
        var tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { throw ParseError.outOfGrammar(transcript: transcript.text) }
        var maskedAny = false
        if !roster.isEmpty {
            let masked = Self.maskRosterNames(tokens: tokens, roster: roster)
            tokens = masked.tokens
            maskedAny = masked.maskedAny
        }
        let utterance = Utterance(tokens: tokens, maskedAny: maskedAny)

        var candidates: [NormalizedPlay] = []
        var anyUnresolved = false

        // Productions in precedence order (see file header). Each returns a Match on
        // match or nil on non-match. The order matters:
        //   - tryMisplay BEFORE tryGroundout (a "booted grounder, safe at first" must NOT become
        //     a groundout; misplay verbs on a reached batter are more specific than "grounder").
        //   - tryDoublePlay BEFORE tryDouble ("double play" contains "double").
        //   - trySacFly BEFORE trySacBunt (both contain "sac"; "fly" distinguishes them).
        let productions: [(Utterance) -> Match?] = [
            tryMisplay, tryDoublePlay, tryGroundout, tryFlyout, trySacFly, trySacBunt,
            tryStrikeout, tryWalk, tryHomeRun, trySingle, tryDouble, tryTriple,
            tryHitByPitch, tryError,
        ]
        for production in productions {
            if let match = production(utterance) {
                candidates.append(match.play)
                if match.unresolved {
                    anyUnresolved = true
                    candidates.append(contentsOf: match.alternates)
                }
            }
        }

        // No grammar production matched → manual entry path.
        guard !candidates.isEmpty else { throw ParseError.outOfGrammar(transcript: transcript.text) }

        // Multiple productions matched → ambiguous (FR-008).
        // Unique match but low-confidence → still ambiguous with one candidate so the scorer can
        // confirm (never a silent guess, FR-008).
        // Unique match whose fielder / variant the utterance did not state (KTD-U9) → a
        // single-candidate clarify: the play type is offered, the scorer supplies the fielder.
        if candidates.count > 1 || isLowConfidence || anyUnresolved {
            throw ParseError.ambiguous(candidates: candidates)
        }
        return candidates[0]
    }

    // MARK: - Tokenization (whole-word grammar, F5)

    /// Clause marker token: a comma / period / semicolon / colon / "!" / "?" in the transcript.
    /// Kept so productions can tell "struck out, runner safe at third" (a new clause after the
    /// strikeout) from "strikeout cooking" (an unknown modifier in the same clause). A phrase
    /// never matches across a clause marker.
    static let clauseMarker = ","

    /// Splits `text` into lowercase word tokens. Letters and digits form words; whitespace,
    /// hyphens and slashes separate words ("6-3" → "6","3"; "stand-up" → "stand","up";
    /// "strike-out" → "strike","out"); clause punctuation becomes a single `clauseMarker`
    /// token; every other character (apostrophes, quotes, underscores) is dropped so
    /// "O'Neil" and "oneil" tokenize identically (matches `normalizeForMasking`).
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if ch.isWhitespace || ch == "-" || ch == "/" || ch == "–" || ch == "—" {
                flush()
            } else if ",;.!?:".contains(ch) {
                flush()
                if tokens.last != clauseMarker { tokens.append(clauseMarker) }
            }
            // Anything else (apostrophes, quotes, underscores, …) is dropped.
        }
        flush()
        while tokens.first == clauseMarker { tokens.removeFirst() }
        while tokens.last == clauseMarker { tokens.removeLast() }
        return tokens
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
    ///     player, the production loses its position word, and the play surfaces as a clarify —
    ///     a safe miss rather than a silent guess.
    ///   - After the full phrases, each INDIVIDUAL token of a multi-word name is masked too
    ///     (U9, found by U7's wiring tests): a lineup entry "Dee Wright" must mask a spoken bare
    ///     "wright". Tokens of a multi-word name that are themselves position keywords or number
    ///     words ("center" / "fielder" in "Center Fielder Jones") are NOT masked on their own —
    ///     only the whole phrase is — otherwise every "to center" would vanish. A single-word
    ///     entry that IS a keyword ("Short") keeps the rule above.
    ///
    /// - Returns: the masked string and whether at least one replacement happened.
    static func maskRosterNames(in normalized: String, roster: [String]) -> (masked: String, maskedAny: Bool) {
        let tokens = normalized.split(separator: " ").map(String.init)
        let result = maskRosterNames(tokens: tokens, roster: roster)
        return (result.tokens.joined(separator: " "), result.maskedAny)
    }

    /// Token-level masking (the form `parse` uses). Same rules as the string form. A clause
    /// marker is never part of a name, so a multi-word name never spans a clause boundary.
    static func maskRosterNames(tokens input: [String], roster: [String]) -> (tokens: [String], maskedAny: Bool) {
        let names: [[String]] = roster
            .map { normalizeForMasking($0).split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        guard !names.isEmpty else { return (input, false) }

        var tokens = input
        var maskedAny = false
        for name in names {
            var i = 0
            while i + name.count <= tokens.count {
                if Array(tokens[i..<(i + name.count)]) == name {
                    tokens.replaceSubrange(i..<(i + name.count), with: [namePlaceholder])
                    maskedAny = true
                }
                i += 1
            }
        }
        // Individual tokens of multi-word names ("Dee Wright" → "dee", "wright"), minus any token
        // that is a position keyword or a number word (see the doc comment).
        let singles = Set(names.filter { $0.count > 1 }.flatMap { $0 })
            .subtracting(positionKeywordTokens)
            .subtracting(numberWords)
        if !singles.isEmpty {
            for i in tokens.indices where singles.contains(tokens[i]) {
                tokens[i] = namePlaceholder
                maskedAny = true
            }
        }
        return (tokens, maskedAny)
    }

    /// Every word that takes part in a position phrase or is a bare position word — never
    /// masked as a lone token of a multi-word roster name.
    static let positionKeywordTokens: Set<String> =
        Set(Utterance.positionPhrases.flatMap { $0.words }).union(Utterance.barePositionWords.keys)

    static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "1", "2", "3", "4", "5", "6", "7", "8", "9",
    ]

    // MARK: - Production match

    /// A production's result: the play, whether the production could NOT resolve its fielder /
    /// chain / variant from the utterance (KTD-U9 — `parse` then surfaces a clarify instead of
    /// returning the play), and any alternate readings to offer alongside it (the strikeout
    /// looking-vs-swinging case).
    struct Match {
        let play: NormalizedPlay
        let unresolved: Bool
        var alternates: [NormalizedPlay] = []
    }

    // MARK: - Utterance (tokens + whole-word matching + position mentions)

    /// The tokenized, roster-masked transcript plus the whole-word matching helpers every
    /// production uses. All matching is on whole tokens; nothing in this file matches a
    /// substring of a word (F5).
    struct Utterance {
        let tokens: [String]
        let maskedAny: Bool

        // MARK: whole-word phrase matching

        /// Index of the first whole-word occurrence of `phrase` (one or more space-separated
        /// words matched against consecutive tokens), or nil.
        func firstIndex(of phrase: String) -> Int? {
            let words = phrase.split(separator: " ").map(String.init)
            guard !words.isEmpty, words.count <= tokens.count else { return nil }
            for i in 0...(tokens.count - words.count) where Array(tokens[i..<(i + words.count)]) == words {
                return i
            }
            return nil
        }

        func contains(_ phrase: String) -> Bool { firstIndex(of: phrase) != nil }

        func containsAny(_ phrases: [String]) -> Bool { phrases.contains { contains($0) } }

        /// First-found phrase from `phrases` with its (index, wordCount); earliest index wins.
        func earliest(of phrases: [String]) -> (index: Int, length: Int)? {
            var best: (index: Int, length: Int)? = nil
            for phrase in phrases {
                guard let i = firstIndex(of: phrase) else { continue }
                let len = phrase.split(separator: " ").count
                if best == nil || i < best!.index { best = (i, len) }
            }
            return best
        }

        func isExactly(_ word: String) -> Bool { tokens == [word] }

        // MARK: position mentions

        struct Mention {
            let index: Int
            let pos: String
            let outfield: Bool
        }

        /// Position phrases that ALWAYS denote a fielder (longest first, tried at every index).
        static let positionPhrases: [(words: [String], pos: String)] = [
            (["behind", "the", "plate"], "2"),
            (["first", "baseman"], "3"), (["first", "base"], "3"),
            (["second", "baseman"], "4"), (["second", "base"], "4"),
            (["third", "baseman"], "5"), (["third", "base"], "5"),
            (["short", "stop"], "6"),
            (["left", "fielder"], "7"), (["left", "field"], "7"),
            (["center", "fielder"], "8"), (["center", "field"], "8"),
            (["centre", "fielder"], "8"), (["centre", "field"], "8"),
            (["right", "fielder"], "9"), (["right", "field"], "9"),
            (["pitcher"], "1"), (["mound"], "1"),
            (["catcher"], "2"),
            (["shortstop"], "6"),
        ]

        /// Bare direction / ordinal words: a fielder ONLY in a fielding slot (see `isFieldingSlot`).
        /// "centre" is the British spelling — the same word, not a mis-hearing.
        static let barePositionWords: [String: String] = [
            "first": "3", "second": "4", "third": "5", "short": "6",
            "left": "7", "center": "8", "centre": "8", "right": "9",
        ]

        static let outfieldPositions: Set<String> = ["7", "8", "9"]

        /// Prepositions that put the following word in a fielding slot ("to short", "at first",
        /// "by the pitcher", "in center", "from short"). "on" is deliberately absent for BARE
        /// words ("runner on third" is a runner, not a fielder); "error on the third baseman"
        /// still works because the phrase form always counts.
        static let fieldingPrepositions: Set<String> = ["to", "at", "by", "in", "from", "into", "toward", "towards"]

        static let articles: Set<String> = ["the", "a", "an"]

        /// Words that mark the following base as a DESTINATION (the batter's / a runner's), never
        /// a fielder: "safe at first", "reached first", "advanced to third", "runner on third".
        static let destinationWords: Set<String> = [
            "safe", "safely", "reached", "reaches", "reach", "advanced", "advances", "advance",
            "moved", "moves", "went", "goes", "scored", "scores", "holds", "held", "stays", "stayed",
            "runner", "runners", "man", "men",
        ]

        /// Every explicit position mention in transcript order (destinations excluded).
        var mentions: [Mention] {
            var found: [Mention] = []
            var i = 0
            while i < tokens.count {
                if let (pos, length) = mentionStarting(at: i) {
                    if !isDestination(i) { found.append(Mention(index: i, pos: pos, outfield: Self.outfieldPositions.contains(pos))) }
                    i += length
                } else {
                    i += 1
                }
            }
            return found
        }

        /// The fielder chain in spoken order, one digit per distinct position (earliest occurrence
        /// wins when the same position is named twice: "short" and "shortstop" both = 6).
        var chain: [String] {
            var seen = Set<String>()
            var out: [String] = []
            for m in mentions where !seen.contains(m.pos) {
                seen.insert(m.pos)
                out.append(m.pos)
            }
            return out
        }

        /// Earliest mention, preferring an outfield position (for fly balls and hits).
        var outfieldFirstPosition: String? {
            let all = mentions
            return all.first(where: { $0.outfield })?.pos ?? all.first?.pos
        }

        /// (position, token length) if a position mention starts at `i`: a phrase form, or a bare
        /// word in a fielding slot.
        func mentionStarting(at i: Int) -> (pos: String, length: Int)? {
            for (words, pos) in Self.positionPhrases where i + words.count <= tokens.count {
                if Array(tokens[i..<(i + words.count)]) == words { return (pos, words.count) }
            }
            if let pos = Self.barePositionWords[tokens[i]], isFieldingSlot(i) { return (pos, 1) }
            return nil
        }

        /// A bare word at `i` is in a fielding slot when a fielding preposition precedes it
        /// (articles skipped) or it heads a chain ("first to short").
        func isFieldingSlot(_ i: Int) -> Bool {
            var p = i - 1
            while p >= 0, Self.articles.contains(tokens[p]) { p -= 1 }
            if p >= 0, Self.fieldingPrepositions.contains(tokens[p]) { return true }
            return isChainHead(i)
        }

        /// "X to Y" where Y is a position mention: X is the head of a fielder chain.
        func isChainHead(_ i: Int) -> Bool {
            guard i + 2 < tokens.count, tokens[i + 1] == "to" else { return false }
            return mentionStarting(at: i + 2) != nil
        }

        /// The base named at `i` is where someone ENDED UP, not who fielded the ball.
        func isDestination(_ i: Int) -> Bool {
            var p = i - 1
            while p >= 0, Self.articles.contains(tokens[p]) { p -= 1 }
            guard p >= 0 else { return false }
            if Self.destinationWords.contains(tokens[p]) { return true }
            if ["at", "to", "on"].contains(tokens[p]), p - 1 >= 0, Self.destinationWords.contains(tokens[p - 1]) {
                return true
            }
            return false
        }

        // MARK: lost fielder (DL-157 / F6)

        /// True when a masked roster name occupies a fielding slot ("to Wright", "by Jones",
        /// "Wright to second to first") without being qualified by an explicit position right
        /// after it ("Wright at short", "Jones in center"). Such a name almost certainly WAS the
        /// fielder, so a fielder-requiring production must not resolve without it.
        var lostFielder: Bool {
            guard maskedAny else { return false }
            for (i, t) in tokens.enumerated() where t == GrammarParser.namePlaceholder {
                if i + 2 < tokens.count, ["at", "in"].contains(tokens[i + 1]), mentionStarting(at: i + 2) != nil {
                    continue  // "Wright at short" — the position is stated.
                }
                var p = i - 1
                while p >= 0, Self.articles.contains(tokens[p]) { p -= 1 }
                if p >= 0, Self.fieldingPrepositions.contains(tokens[p]) || tokens[p] == "on" { return true }
                if isChainHead(i) { return true }
            }
            return false
        }
    }

    // MARK: - Keyword tables (whole words / phrases)

    private static let misplayVerbs = ["misplayed", "booted", "bobbled", "muffed", "dropped"]
    private static let flyBallContext = ["fly ball", "flyball", "flyout", "fly out", "flied out", "flies out"]
    private static let batterReachedAnchors = [
        "batter safe", "batter reached", "batter reach", "batter reaches",
        "safe at first", "safe at second", "safe at third",
        "reached first", "reached second", "reached third", "reached base",
    ]
    private static let reachedWords = ["reached", "reaches", "reach", "safe", "safely", "on base"]
    private static let groundWords = ["ground", "grounder", "grounders", "grounds", "grounded", "groundout", "groundball"]
    private static let flyWords = [
        "fly ball", "flyball", "flyout", "fly out", "flied out", "flies out",
        "line drive", "line out", "lineout", "lined out", "lines out",
        "pop up", "popup", "pop out", "popped out", "pops out", "popped up", "pops up",
    ]
    private static let strikeoutPhrases = ["struck out", "strikeout", "strike out", "strikes out"]
    private static let lookingWords = ["looking", "called", "watching"]
    private static let swingingWords = ["swinging", "swings", "swung", "swing"]
    /// Words that may follow a strikeout without being a (mis-heard) modifier: function words,
    /// fillers, a new clause, or a masked name.
    private static let neutralAfterStrikeout: Set<String> = [
        clauseMarker, namePlaceholder,
        "to", "and", "for", "on", "with", "the", "a", "an", "in", "at", "as", "but", "then",
        "he", "she", "they", "that", "there", "of", "by", "yeah", "okay", "ok", "so", "um", "uh",
    ]
    private static let sacWords = ["sac", "sacrifice", "sack"]
    private static let buntWords = ["bunt", "bunts", "bunted"]

    // MARK: - Grammar productions

    // Each production returns a `Match` (play + unresolved) on match, or `nil` on non-match.
    // Keys mirror the MockCore/real core FFI schema (core/src/model.rs).
    // `unresolved` is true when the production could not take its fielder / chain / variant from
    // the utterance (KTD-U9) — `parse` then surfaces the play as a single-candidate clarify.

    // MARK: Misplay → reached_on_error (Card B)
    //
    // DL-151 fix: this production MUST appear before tryGroundout in the dispatch list.
    //
    // Misplay verbs that indicate the batter REACHED base (error, not out):
    //   "misplayed grounder to short, reached first"
    //   "booted by short, batter safe at first"
    //   "muffed the ball, batter safe"                → clarify (no fielder stated, F7)
    //   "dropped it, batter reaches first"            → clarify (no fielder stated, F7)
    //
    // Three-signal guard (P1a + P1b code-review fixes, DL-151):
    //
    //   (a) A misplay verb: misplayed / booted / bobbled / muffed / dropped
    //
    //   (b) The BATTER specifically reached — NOT a bare "safe" / "reached" anywhere in the
    //       transcript (that could refer to a runner, not the batter). Accepted batter-specific
    //       patterns:
    //         "batter safe", "batter reached", "batter reach(es)"
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
    //       dropping a fly ball where the batter reaches is a different scorer judgment path —
    //       leave it out-of-grammar so the scorer can use manual entry.
    //
    // Emits: ["batter_result": "reached_on_error", "error_position": "<pos>"]
    // FactBridge maps this to misplayedGrounder(at:) → real core classifies HitVsError (Card B).
    //
    // The error position is the EARLIEST explicit fielder mention; the batter's destination
    // ("safe at first") is never a fielder (F7). No mention → unresolved → clarify.
    private func tryMisplay(_ u: Utterance) -> Match? {
        guard u.containsAny(Self.misplayVerbs) else { return nil }
        if u.containsAny(["third strike", "strike three", "strike 3"]) { return nil }
        if u.containsAny(Self.flyBallContext) { return nil }
        guard u.containsAny(Self.batterReachedAnchors) else { return nil }
        return Self.errorMatch(u)
    }

    /// Shared by tryMisplay / tryError: reached_on_error at the earliest explicit fielder.
    private static func errorMatch(_ u: Utterance) -> Match {
        var play: NormalizedPlay = ["batter_result": "reached_on_error"]
        let pos = u.mentions.first?.pos
        if let pos { play["error_position"] = pos }
        return Match(play: play, unresolved: pos == nil || u.lostFielder)
    }

    // MARK: Groundout
    private func tryGroundout(_ u: Utterance) -> Match? {
        // "ground ball to short, threw him out at first" → batter_result=groundout, fielders="63"
        guard u.containsAny(Self.groundWords) else { return nil }
        // Guard: a double play that includes "ground ball" is handled by tryDoublePlay.
        if u.contains("double play") || u.contains("dp") { return nil }
        // Guard: if the batter REACHED, this is NOT a groundout — let tryMisplay handle it.
        if u.containsAny(Self.reachedWords) { return nil }

        // A groundout needs the full chain (two positions), or one position + "unassisted".
        // Anything less is a partial reading: offer it, never complete it (F1, F8).
        let chain = u.chain
        let complete = chain.count >= 2 || (chain.count == 1 && u.contains("unassisted"))
        var play: NormalizedPlay = ["batter_result": "groundout", "outs_recorded": "1"]
        if !chain.isEmpty { play["fielders"] = chain.joined() }
        return Match(play: play, unresolved: !complete || u.lostFielder)
    }

    // MARK: Flyout
    private func tryFlyout(_ u: Utterance) -> Match? {
        let caught = u.contains("caught")
            && !u.containsAny(["strike", "strikes", "steal", "stealing", "stole", "looking"])
        guard u.containsAny(Self.flyWords) || caught else { return nil }
        // Guard: "sac fly" / "sacrifice fly" belongs to trySacFly.
        if Self.isSacFly(u) { return nil }
        // Guard (F9): a dropped / muffed / misplayed fly ball is a scorer judgment (did the
        // batter reach? was a runner doubled off?) — never a confident batter-out. Out-of-grammar
        // → manual entry.
        if u.containsAny(Self.misplayVerbs) { return nil }
        let pos = u.outfieldFirstPosition
        var play: NormalizedPlay = ["batter_result": "flyout", "outs_recorded": "1"]
        if let pos { play["fielder"] = pos }
        return Match(play: play, unresolved: pos == nil || u.lostFielder)  // F2: no default CF
    }

    // MARK: Strikeout
    //
    // Variant rule (F4, decided from the canonical corpus + DL-154):
    //   - "looking" / "called" / "watching" anywhere → strikeout_looking (Kl).
    //   - "swinging" / "swings" / "swung" anywhere    → strikeout (K).
    //   - A BARE strikeout — nothing after the strikeout phrase, a new clause ("struck out,
    //     runner safe at third"), a masked name, or a function/filler word — keeps the
    //     conventional swinging reading. The canonical rows "struck out" → K and DL-154's
    //     "struck out" → strikeout pin this ONE default; it is a reading of an unqualified
    //     strikeout, not a lost fielder.
    //   - Any OTHER content word in the modifier slot ("strikeout cooking", "strikeout singing")
    //     is most likely a mis-heard "looking"/"swinging": the variant is unknown → clarify
    //     with BOTH variants offered as candidates.
    private func tryStrikeout(_ u: Utterance) -> Match? {
        guard let trigger = u.earliest(of: Self.strikeoutPhrases) ?? (u.isExactly("k") ? (0, 1) : nil) else {
            return nil
        }
        let swinging: NormalizedPlay = ["batter_result": "strikeout", "outs_recorded": "1"]
        let looking: NormalizedPlay = ["batter_result": "strikeout_looking", "outs_recorded": "1"]
        if u.containsAny(Self.lookingWords) { return Match(play: looking, unresolved: false) }
        if u.containsAny(Self.swingingWords) { return Match(play: swinging, unresolved: false) }
        let slot = trigger.index + trigger.length
        if slot < u.tokens.count, !Self.neutralAfterStrikeout.contains(u.tokens[slot]) {
            return Match(play: swinging, unresolved: true, alternates: [looking])
        }
        return Match(play: swinging, unresolved: false)
    }

    // MARK: Walk
    private func tryWalk(_ u: Utterance) -> Match? {
        guard u.containsAny(["walk", "walked", "walks", "base on balls"]) || u.isExactly("bb") || u.isExactly("iw") else {
            return nil
        }
        let intentional = u.containsAny(["intentional", "intentionally"]) || u.isExactly("iw")
        return Match(play: ["batter_result": intentional ? "intentional_walk" : "walk"], unresolved: false)
    }

    // MARK: Home run
    private func tryHomeRun(_ u: Utterance) -> Match? {
        guard u.containsAny(["home run", "homerun", "homer", "homers", "homered"]) || u.isExactly("hr") else { return nil }
        return Match(play: ["batter_result": "home_run", "runs_scored": "1"], unresolved: false)
    }

    // MARK: Single
    private func trySingle(_ u: Utterance) -> Match? {
        guard u.containsAny(["single", "singled", "singles"]) else { return nil }
        var play: NormalizedPlay = ["batter_result": "single"]
        if let pos = u.outfieldFirstPosition { play["fielder"] = pos }
        return Match(play: play, unresolved: false)  // the fielder is optional on a hit
    }

    // MARK: Double
    private func tryDouble(_ u: Utterance) -> Match? {
        // Guard: "double play" was handled by tryDoublePlay earlier.
        guard u.containsAny(["double", "doubled", "doubles"]), !u.contains("double play"), !u.contains("dp") else {
            return nil
        }
        var play: NormalizedPlay = ["batter_result": "double"]
        if let pos = u.outfieldFirstPosition { play["fielder"] = pos }
        return Match(play: play, unresolved: false)
    }

    // MARK: Triple
    private func tryTriple(_ u: Utterance) -> Match? {
        guard u.containsAny(["triple", "tripled", "triples"]) else { return nil }
        var play: NormalizedPlay = ["batter_result": "triple"]
        if let pos = u.outfieldFirstPosition { play["fielder"] = pos }
        return Match(play: play, unresolved: false)
    }

    // MARK: Hit by pitch
    private func tryHitByPitch(_ u: Utterance) -> Match? {
        guard u.containsAny(["hit by pitch", "hit by the pitch", "hit by a pitch", "hbp", "plunked"]) else { return nil }
        return Match(play: ["batter_result": "hit_by_pitch"], unresolved: false)
    }

    // MARK: Sac fly
    private static func isSacFly(_ u: Utterance) -> Bool {
        u.containsAny(sacWords) && u.containsAny(["fly", "flies"]) && !u.containsAny(buntWords)
    }

    private func trySacFly(_ u: Utterance) -> Match? {
        // "sac fly", "sacrifice fly" — a sac word and "fly" must both be present (whole words).
        guard Self.isSacFly(u) else { return nil }
        let pos = u.outfieldFirstPosition
        var play: NormalizedPlay = ["batter_result": "sac_fly", "outs_recorded": "1"]
        if let pos { play["fielder"] = pos }
        return Match(play: play, unresolved: pos == nil || u.lostFielder)  // F3: no default RF
    }

    // MARK: Sac bunt
    private func trySacBunt(_ u: Utterance) -> Match? {
        // Must contain "bunt" — a bare "sacrifice" must NOT match (else "sacrifice fly"
        // is ambiguous between sac_fly and sac_bunt).
        guard u.containsAny(Self.buntWords), u.containsAny(Self.sacWords) else { return nil }
        let chain = u.chain
        var play: NormalizedPlay = ["batter_result": "sac_bunt", "outs_recorded": "1"]
        if chain.count >= 2 { play["fielders"] = chain.joined() }
        return Match(play: play, unresolved: false)  // fielders are optional facts on a sac bunt
    }

    // MARK: Error (reached on error — generic path without a misplay verb)
    private func tryError(_ u: Utterance) -> Match? {
        // "reached on error", "error by short" → E6
        guard u.containsAny(["error", "errors"]) || (u.contains("reached on") && !u.containsAny(["strike", "strikes"])) else {
            return nil
        }
        // A fielder's choice is not an error — out-of-grammar in v1.
        if u.contains("choice") { return nil }
        return Self.errorMatch(u)  // F7: no default SS; destination never a fielder
    }

    // MARK: Double play
    private func tryDoublePlay(_ u: Utterance) -> Match? {
        // "double play" or the standalone token "dp".
        guard u.contains("double play") || u.contains("dp") else { return nil }
        let chain = u.chain
        var play: NormalizedPlay = ["batter_result": "double_play", "outs_recorded": "2"]
        if !chain.isEmpty { play["fielders"] = chain.joined() }
        return Match(play: play, unresolved: chain.count < 2 || u.lostFielder)  // F6/F11: no default 6-4-3
    }
}
