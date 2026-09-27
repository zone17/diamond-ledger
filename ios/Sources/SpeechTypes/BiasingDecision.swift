/// BiasingDecision.swift — the pure roster-biasing override decision (DL-157, R16–R20).
///
/// Issue #157 adds a second, contextually-biased ASR leg (roster names, positions, play words)
/// beside the base transcription. This type decides, from the two hypotheses alone, whether the
/// biased text may replace the base — and with what confidence. It is the single place that
/// rule lives; `DiamondSpeech`'s `BiasingStrategy` delegates here (KTD2) and the `dl-bias`
/// harness calls it directly to label an adversarial corpus.
///
/// ## The settled decision this encodes
///
/// "The biased engine may correct *words*, never *confidence*." The base leg's confidence is
/// generally unreachable (Apple `SpeechAnalyzer` reports none), so the override rule is built
/// on the biased leg's *measured* confidence plus text agreement — never on a base confidence
/// we do not have. Consequences:
///   - No override without a positive measurement (R18 / P0b): every guard failure keeps the
///     base exactly as it was (its text and its own confidence, `nil` when unknown).
///   - Biasing never lowers a known confidence (R19): a known base confidence is always carried
///     through when the base is kept, and beats a lower biased confidence outright.
///   - By default a correction is *capped below the parser threshold* (R20): it improves the
///     Clarify candidates but cannot open hands-free scoring until the silent-scoring policy
///     switch is turned on deliberately. Article VII / FR-008: never a silent wrong play.
///
/// ## Guard order (R17) — the first failing guard names the `reason`
///
/// 1. `noBiasedHypothesis`              biased is `nil` or blank
/// 2. `emptyBase`                       base is blank but biased is not (never fabricate)
/// 3. `biasedConfidenceBelowThreshold`  biased confidence (mapped to 0…100) < parser threshold
/// 4. `divergent`                       token edit distance > `agreementThreshold` (0.30)
/// 5. `insertionOrDeletion`             the alignment inserts or deletes a token — biasing may
///                                      only substitute words, never add or drop them (a biased
///                                      leg that inserts "double play" is adding a play, not
///                                      correcting a word)
/// 6. `tokenNotContextual`              a substituted biased token is not in the contextual set
/// 7. `replacedTokenInVocabulary`       a replaced base token IS in the set (known→known swap)
/// 7. `baseMoreConfident`               base confidence known and higher than biased
/// 8. `agreed`                          override: biased text verbatim, confidence per R20
///
/// "Differing" and "replaced" tokens come from the word-level Levenshtein alignment
/// (`TokenEditDistance.alignment`): only substitutions are eligible; any insertion or deletion
/// refuses the override outright (guard 5). A distance of 0 (e.g. a casing-only
/// difference, `wright` → `Wright`) has no differing tokens, so guards 5–6 pass vacuously and the
/// biased spelling is returned verbatim.
///
/// Confidences are native `Float`s in 0…1 (the same scale `ConfidenceMapping.toInt` consumes);
/// the parser threshold is the integer 0…100 the `Parse` layer compares against.

import Foundation

// MARK: - Inputs

/// The biased ASR leg's hypothesis: its text and its *measured* confidence.
public struct BiasedHypothesis: Sendable, Equatable {
    /// Best-hypothesis text from the biased leg (returned verbatim on override — not normalized).
    public let text: String
    /// Native confidence in 0.0…1.0. Non-finite values are treated as "no measurement".
    public let confidence: Float

    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }
}

/// Policy knobs for the decision. The parser threshold is *passed in* (SpeechTypes must not
/// import `Parse`); callers hand over the same integer the `GrammarParser` ambiguity gate uses.
public struct BiasingPolicy: Sendable, Equatable {
    /// The `Parse` layer's ambiguity threshold on the 0…100 scale (e.g. 70). Must be 1…100.
    public let parserThreshold: Int
    /// Maximum normalized token edit distance for the two hypotheses to count as agreeing (R17-2).
    public let agreementThreshold: Double
    /// R20 switch. `false` (default) caps an override's confidence at `parserThreshold - 1` so a
    /// correction can never score hands-free; `true` passes the biased confidence through.
    public let silentScoringEnabled: Bool

    public init(parserThreshold: Int, agreementThreshold: Double = 0.30, silentScoringEnabled: Bool = false) {
        precondition((1...100).contains(parserThreshold), "BiasingPolicy.parserThreshold must be 1...100; got \(parserThreshold)")
        precondition(agreementThreshold >= 0, "BiasingPolicy.agreementThreshold must be >= 0")
        self.parserThreshold = parserThreshold
        self.agreementThreshold = agreementThreshold
        self.silentScoringEnabled = silentScoringEnabled
    }

    /// The default policy: 0.30 agreement threshold, silent scoring OFF.
    public static func `default`(parserThreshold: Int) -> BiasingPolicy {
        BiasingPolicy(parserThreshold: parserThreshold)
    }

    /// The largest confidence an override may carry with silent scoring off: `(threshold - 1) / 100`.
    public var cappedConfidence: Float {
        Float(parserThreshold - 1) / 100
    }
}

// MARK: - Outcome

/// Which guard decided the outcome. `rawValue` is the snake_case label the `dl-bias` harness
/// reports (evals/INTERFACE.md).
public enum BiasingReason: String, Sendable, Codable, CaseIterable {
    case noBiasedHypothesis = "no_biased_hypothesis"
    case emptyBase = "empty_base"
    case biasedConfidenceBelowThreshold = "biased_confidence_below_threshold"
    case divergent = "divergent"
    case insertionOrDeletion = "insertion_or_deletion"
    case tokenNotContextual = "token_not_contextual"
    case replacedTokenInVocabulary = "replaced_token_in_vocabulary"
    case baseMoreConfident = "base_more_confident"
    case agreed = "agreed"

    /// `true` only for `.agreed` — the single reason under which the biased text is used.
    public var isOverride: Bool { self == .agreed }
}

/// The decision: the text to parse, the confidence to attach (`nil` = unknown → Clarify), and why.
public struct BiasingOutcome: Sendable, Equatable {
    public let text: String
    public let confidence: Float?
    public let reason: BiasingReason

    public init(text: String, confidence: Float?, reason: BiasingReason) {
        self.text = text
        self.confidence = confidence
        self.reason = reason
    }
}

// MARK: - Decision

public enum BiasingDecision {
    /// Decide whether `biased` may replace `base`. Pure; see the file doc for the guard order.
    ///
    /// - Parameters:
    ///   - base: the base leg's text (kept verbatim whenever it is kept).
    ///   - baseConfidence: the base leg's native confidence if it has one (usually `nil`).
    ///   - biased: the biased leg's hypothesis, or `nil` if that leg produced nothing.
    ///   - vocabulary: the contextual set in force for this utterance.
    ///   - policy: threshold + switches (`BiasingPolicy.default(parserThreshold:)`).
    public static func decide(
        base: String,
        baseConfidence: Float?,
        biased: BiasedHypothesis?,
        vocabulary: ContextualVocabulary,
        policy: BiasingPolicy
    ) -> BiasingOutcome {
        func keepBase(_ reason: BiasingReason) -> BiasingOutcome {
            BiasingOutcome(text: base, confidence: baseConfidence, reason: reason)
        }

        // 1. Nothing to consider.
        guard let biased, !biased.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return keepBase(.noBiasedHypothesis)
        }

        let baseTokens = TextNormalization.tokens(base)
        let biasedTokens = TextNormalization.tokens(biased.text)

        // 2. Never fabricate a play from an empty base.
        guard !baseTokens.isEmpty else {
            return keepBase(.emptyBase)
        }

        // 3. The biased leg must carry a real confidence at or above the parser threshold.
        guard biased.confidence.isFinite,
              ConfidenceMapping.toInt(biased.confidence) >= policy.parserThreshold
        else {
            return keepBase(.biasedConfidenceBelowThreshold)
        }

        // 4. The two hypotheses must agree closely at the token level. One alignment serves
        //    guards 4–7: the number of non-`.equal` ops IS the Levenshtein distance (see
        //    `TokenEditDistance.alignment`), so the DP table is built once, not twice.
        let ops = TokenEditDistance.alignment(base: baseTokens, biased: biasedTokens)
        guard TokenEditDistance.normalized(alignment: ops, base: baseTokens, biased: biasedTokens)
                <= policy.agreementThreshold
        else {
            return keepBase(.divergent)
        }

        // 5. Substitution only: an insertion or deletion is a changed play, not a corrected word.
        for op in ops {
            switch op {
            case .insert, .delete: return keepBase(.insertionOrDeletion)
            case .equal, .substitute: break
            }
        }

        // 6 + 7. Every substituted token must be contextual; every replaced token must be OOV.
        for op in ops {
            switch op {
            case .substitute(_, let differing), .insert(let differing):
                if !vocabulary.containsNormalized(differing) { return keepBase(.tokenNotContextual) }
            case .equal, .delete:
                break
            }
        }
        for op in ops {
            switch op {
            case .substitute(let replaced, _), .delete(let replaced):
                if vocabulary.containsNormalized(replaced) { return keepBase(.replacedTokenInVocabulary) }
            case .equal, .insert:
                break
            }
        }

        // 8. A known, higher base confidence wins (R19).
        if let baseConfidence, baseConfidence > biased.confidence {
            return keepBase(.baseMoreConfident)
        }

        // 9. Override — words corrected, confidence capped unless silent scoring is on (R20).
        let confidence = policy.silentScoringEnabled
            ? biased.confidence
            : min(biased.confidence, policy.cappedConfidence)
        return BiasingOutcome(text: biased.text, confidence: confidence, reason: .agreed)
    }
}
