/// TextAgreement.swift — normalization, token-level edit distance and word alignment (DL-157).
///
/// The pure text-comparison layer under the roster-biasing decision (`BiasingDecision.swift`).
/// Lives in `SpeechTypes` (Foundation-only, macOS-buildable) so the decision is testable
/// headlessly and reportable by the `dl-bias` harness without touching the iOS-26-only ASR
/// engines (plan DL-157, R16 / KTD2 / KTD3).
///
/// Everything here is deterministic and value-typed. Ratios are `Double`s — they exist only on
/// the Swift side and never cross the integer-only Rust core seam (ADR-0007 / I6).
///
/// - SeeAlso: `BiasingDecision.swift` (consumes the alignment to decide overrides)
/// - SeeAlso: `docs/plans/2026-09-26-0919-feat-voice-accuracy-harness-plan.md` (R16–R20)

import Foundation

// MARK: - Normalization

/// Canonical text normalization shared by the distance, the alignment and the contextual set,
/// so "membership" and "difference" are always judged on the same token shape.
///
/// Rule: lowercase → strip punctuation (every non-letter, non-number scalar becomes a space) →
/// collapse whitespace → split on whitespace. `"Ground ball, to SHORT!!"` → `[ground, ball, to, short]`.
/// Apostrophes are punctuation too (`"o'neil"` → `[o, neil]`); both sides of any comparison go
/// through the same rule, so this is consistent even if not linguistically ideal.
public enum TextNormalization {
    /// Normalized whitespace tokens of `text` (see the type doc for the rule). Empty for blank input.
    public static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var scrubbed = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scrubbed.append(scalar)
            } else {
                scrubbed.append(" ")
            }
        }
        return String(scrubbed)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Single normalized token for a one-word lookup (`"WRIGHT!"` → `"wright"`); `nil` if the
    /// input holds no alphanumerics or more than one word.
    public static func singleToken(_ word: String) -> String? {
        let t = tokens(word)
        return t.count == 1 ? t[0] : nil
    }
}

// MARK: - Contextual vocabulary

/// The set of words the biased ASR leg was told about (roster names, positions, play words) —
/// R17 (3)/(4) are judged against membership in this set.
///
/// Membership is over the normalized whitespace tokens of each phrase: `phrases: ["third base"]`
/// contains both `"third"` and `"base"`. Lookups normalize the queried word the same way, so
/// `contains("Wright")` and `contains("wright!")` agree.
public struct ContextualVocabulary: Sendable, Equatable {
    /// Normalized tokens in force.
    public let tokens: Set<String>

    public init(phrases: [String]) {
        var set = Set<String>()
        for phrase in phrases {
            for token in TextNormalization.tokens(phrase) { set.insert(token) }
        }
        self.tokens = set
    }

    /// Pre-normalized token set (used by the alignment guards; tokens are already canonical).
    public init(normalizedTokens: Set<String>) {
        self.tokens = normalizedTokens
    }

    public static let empty = ContextualVocabulary(normalizedTokens: [])

    /// `true` if `word`, after normalization, is one of the tokens in force.
    public func contains(_ word: String) -> Bool {
        guard let token = TextNormalization.singleToken(word) else { return false }
        return tokens.contains(token)
    }

    /// Membership test for an already-normalized token (no re-normalization).
    public func containsNormalized(_ token: String) -> Bool {
        tokens.contains(token)
    }
}

// MARK: - Token edit distance + alignment

/// One step of the word-level alignment between a base token list and a biased token list.
///
/// Produced by `TokenEditDistance.alignment(base:biased:)` via Levenshtein backtrace.
/// `BiasingDecision` reads it as:
///   - `.equal`      — no difference; contributes nothing to either guard.
///   - `.substitute` — `biased` is a *differing* token (must be contextual, R17-3) and `base` is
///                     a *replaced* token (must be out-of-vocabulary, R17-4).
///   - `.insert`     — `biased` is a differing token with no replaced base token.
///   - `.delete`     — `base` is a replaced token with no differing biased token: deleting an
///                     in-vocabulary base word is refused, deleting an OOV word is allowed.
public enum AlignmentOp: Sendable, Equatable {
    case equal(String)
    case substitute(base: String, biased: String)
    case insert(biased: String)
    case delete(base: String)
}

/// Word-level Levenshtein distance and the alignment it induces (KTD3).
///
/// `normalized` = `levenshtein / max(base.count, biased.count)`, with `0` for empty-vs-empty.
/// Operations are unit cost. Backtrace tie-break is fixed so the alignment (and thus the guard
/// verdict) is deterministic: at each cell prefer *equal*, then *substitute*, then *delete*
/// (consume a base token), then *insert* (consume a biased token).
public enum TokenEditDistance {
    /// Normalized token edit distance between two raw strings (both are normalized first).
    public static func normalized(_ base: String, _ biased: String) -> Double {
        normalized(TextNormalization.tokens(base), TextNormalization.tokens(biased))
    }

    /// Normalized token edit distance between two already-normalized token lists.
    public static func normalized(_ base: [String], _ biased: [String]) -> Double {
        let longest = max(base.count, biased.count)
        guard longest > 0 else { return 0 }
        return Double(levenshtein(base, biased)) / Double(longest)
    }

    /// Normalized distance derived from an alignment already computed for the same pair — the
    /// count of non-`.equal` ops equals `levenshtein(base, biased)`, so this avoids a second
    /// DP table when the caller also needs the ops.
    public static func normalized(alignment ops: [AlignmentOp], base: [String], biased: [String]) -> Double {
        let longest = max(base.count, biased.count)
        guard longest > 0 else { return 0 }
        let edits = ops.reduce(0) { count, op in
            if case .equal = op { return count }
            return count + 1
        }
        return Double(edits) / Double(longest)
    }

    /// Raw word-level Levenshtein distance (number of unit-cost edits).
    public static func levenshtein(_ base: [String], _ biased: [String]) -> Int {
        table(base, biased)[base.count][biased.count]
    }

    /// The alignment implied by the Levenshtein backtrace (see the type doc for tie-breaking).
    /// The number of non-`.equal` ops equals `levenshtein(base, biased)`.
    public static func alignment(base: [String], biased: [String]) -> [AlignmentOp] {
        let d = table(base, biased)
        var ops: [AlignmentOp] = []
        var i = base.count
        var j = biased.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, base[i - 1] == biased[j - 1], d[i][j] == d[i - 1][j - 1] {
                ops.append(.equal(base[i - 1]))
                i -= 1; j -= 1
            } else if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + 1 {
                ops.append(.substitute(base: base[i - 1], biased: biased[j - 1]))
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                ops.append(.delete(base: base[i - 1]))
                i -= 1
            } else {
                ops.append(.insert(biased: biased[j - 1]))
                j -= 1
            }
        }
        return ops.reversed()
    }

    /// Full DP table: `d[i][j]` = edits to turn `base[0..<i]` into `biased[0..<j]`.
    private static func table(_ base: [String], _ biased: [String]) -> [[Int]] {
        let n = base.count
        let m = biased.count
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        guard n > 0, m > 0 else { return d }
        for i in 1...n {
            for j in 1...m {
                let cost = base[i - 1] == biased[j - 1] ? 0 : 1
                d[i][j] = min(
                    d[i - 1][j] + 1,          // delete base[i-1]
                    d[i][j - 1] + 1,          // insert biased[j-1]
                    d[i - 1][j - 1] + cost    // equal / substitute
                )
            }
        }
        return d
    }
}
