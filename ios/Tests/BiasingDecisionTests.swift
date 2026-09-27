/// BiasingDecisionTests.swift — DL-157 roster-biasing decision (R16–R20).
///
/// Pins the pure `BiasingDecision` in `SpeechTypes`: the biased ASR leg may correct WORDS but
/// never manufacture CONFIDENCE (settled decision, plan DL-157 Key Decision 3). Every scenario
/// here is mirrored one-for-one in `Tests/native/biasing-decision-harness.swift`, which runs
/// headlessly on macOS via `swiftc` — this XCTest target needs an iOS-26 destination
/// (see memory: iOS tests cannot run on macOS), so the native harness is the red/green the host
/// can actually show.
///
/// Article VII / FR-008 framing: a guard failure must always keep the base untouched (text AND
/// its own confidence, `nil` when unknown), and an override is capped below the parser threshold
/// unless silent scoring is switched on deliberately.

import XCTest
import SpeechTypes

final class BiasingDecisionTests: XCTestCase {

    private let threshold = 70
    private var policyOff: BiasingPolicy { .default(parserThreshold: threshold) }
    private var policyOn: BiasingPolicy {
        BiasingPolicy(parserThreshold: threshold, agreementThreshold: 0.30, silentScoringEnabled: true)
    }
    private let roster = ContextualVocabulary(phrases: ["short", "Wright", "single", "double", "third base"])

    private func decide(
        _ base: String, _ baseConf: Float? = nil,
        _ biasedText: String?, _ biasedConf: Float = 0.85,
        vocabulary: ContextualVocabulary? = nil,
        policy: BiasingPolicy? = nil
    ) -> BiasingOutcome {
        let biased = biasedText.map { BiasedHypothesis(text: $0, confidence: biasedConf) }
        return BiasingDecision.decide(
            base: base, baseConfidence: baseConf, biased: biased,
            vocabulary: vocabulary ?? roster, policy: policy ?? policyOff)
    }

    // MARK: 1. Override with cap (R17 all pass, R20)

    func testOOVCorrectionOverridesAndIsCappedWhenSilentScoringOff() {
        let o = decide("ground out to sean", nil, "ground out to short", 0.85)
        XCTAssertEqual(o.text, "ground out to short")
        XCTAssertEqual(o.confidence, 0.69)
        XCTAssertEqual(o.reason, .agreed)
    }

    func testOOVCorrectionPassesBiasedConfidenceWhenSilentScoringOn() {
        let o = decide("ground out to sean", nil, "ground out to short", 0.85, policy: policyOn)
        XCTAssertEqual(o.text, "ground out to short")
        XCTAssertEqual(o.confidence, 0.85)
        XCTAssertEqual(o.reason, .agreed)
    }

    // MARK: 2. Biased confidence below threshold (R17-1, R18)

    func testBiasedConfidenceBelowThresholdKeepsBaseWithNilConfidence() {
        let o = decide("ground out to sean", nil, "ground out to short", 0.65)
        XCTAssertEqual(o.text, "ground out to sean")
        XCTAssertNil(o.confidence)
        XCTAssertEqual(o.reason, .biasedConfidenceBelowThreshold)
    }

    // MARK: 3. Divergent (R17-2)

    func testDivergentHypothesisKeepsBase() {
        XCTAssertEqual(TokenEditDistance.normalized("home run", "homer"), 1.0)
        let o = decide("home run", nil, "homer", 0.90)
        XCTAssertEqual(o.text, "home run")
        XCTAssertNil(o.confidence)
        XCTAssertEqual(o.reason, .divergent)
    }

    // MARK: 4. Differing token not contextual (R17-3)

    func testDifferingTokenOutsideContextualSetKeepsBase() {
        let base = "ground ball to short, threw him out at first"
        let biased = "ground ball to short, threw him out at third"
        XCTAssertEqual(TokenEditDistance.normalized(base, biased), 1.0 / 9.0, accuracy: 1e-12)
        let o = decide(base, nil, biased, 0.90, vocabulary: ContextualVocabulary(phrases: ["short"]))
        XCTAssertEqual(o.text, base)
        XCTAssertEqual(o.reason, .tokenNotContextual)
    }

    // MARK: 5. Replaced token in vocabulary (R17-4)

    func testKnownToKnownSwapIsRefusedButOOVCorrectionAllowed() {
        let swap = decide("line drive single to right", nil, "line drive double to right", 0.90)
        XCTAssertEqual(swap.text, "line drive single to right")
        XCTAssertEqual(swap.reason, .replacedTokenInVocabulary)

        let oov = decide("ground out to sean", nil, "ground out to short", 0.90)
        XCTAssertEqual(oov.text, "ground out to short")
        XCTAssertEqual(oov.reason, .agreed)
    }

    // MARK: 6. Casing-only difference returns the roster spelling

    func testCasingOnlyDifferenceReturnsBiasedTextVerbatim() {
        XCTAssertEqual(TokenEditDistance.normalized("fly ball to wright", "fly ball to Wright"), 0)
        let o = decide("fly ball to wright", nil, "fly ball to Wright", 0.90)
        XCTAssertEqual(o.text, "fly ball to Wright")
        XCTAssertEqual(o.reason, .agreed)
    }

    // MARK: 7 + 8. Known base confidence (R19)

    func testKnownHigherBaseConfidenceWins() {
        let o = decide("ground out to sean", 0.95, "ground out to short", 0.80)
        XCTAssertEqual(o.text, "ground out to sean")
        XCTAssertEqual(o.confidence, 0.95)
        XCTAssertEqual(o.reason, .baseMoreConfident)
    }

    func testKnownLowerBaseConfidenceIsOverridden() {
        let off = decide("ground out to sean", 0.60, "ground out to short", 0.80)
        XCTAssertEqual(off.text, "ground out to short")
        XCTAssertEqual(off.confidence, 0.69)
        XCTAssertEqual(off.reason, .agreed)

        let on = decide("ground out to sean", 0.60, "ground out to short", 0.80, policy: policyOn)
        XCTAssertEqual(on.confidence, 0.80)
    }

    // MARK: 9. No biased hypothesis

    func testNilOrBlankBiasedKeepsBase() {
        let a = decide("ground out to sean", nil, nil)
        XCTAssertEqual(a.text, "ground out to sean")
        XCTAssertNil(a.confidence)
        XCTAssertEqual(a.reason, .noBiasedHypothesis)

        let b = decide("ground out to sean", nil, "   \n ")
        XCTAssertEqual(b.text, "ground out to sean")
        XCTAssertNil(b.confidence)
        XCTAssertEqual(b.reason, .noBiasedHypothesis)

        let c = decide("ground out to sean", 0.9, nil)
        XCTAssertEqual(c.confidence, 0.9, "a known base confidence is carried through untouched (R19)")
    }

    // MARK: 10. Agreement boundary

    func testAgreementBoundaryThreeOfTenPassesFourOfTenFails() {
        let set = ContextualVocabulary(phrases: ["alpha beta", "gamma delta"])
        let base = "one two three four five six seven eight nine ten"
        let three = "one two alpha four five beta seven eight gamma ten"
        let four = "one two alpha four delta beta seven eight gamma ten"
        XCTAssertEqual(TokenEditDistance.normalized(base, three), 0.30)

        let ok = decide(base, nil, three, 0.90, vocabulary: set)
        XCTAssertEqual(ok.text, three)
        XCTAssertEqual(ok.reason, .agreed)

        let bad = decide(base, nil, four, 0.90, vocabulary: set)
        XCTAssertEqual(bad.text, base)
        XCTAssertEqual(bad.reason, .divergent)
    }

    // MARK: 11. Empty base

    func testEmptyBaseIsNeverFabricatedFrom() {
        let o = decide("", nil, "ground out to short", 0.95)
        XCTAssertEqual(o.text, "")
        XCTAssertNil(o.confidence)
        XCTAssertEqual(o.reason, .emptyBase)
    }

    // MARK: 12. Normalization

    func testNormalizationLowercasesStripsPunctuationAndCollapsesWhitespace() {
        XCTAssertEqual(TextNormalization.tokens("Ground ball, to SHORT!!"), ["ground", "ball", "to", "short"])
        XCTAssertEqual(TextNormalization.tokens("  a \t b\n\nc "), ["a", "b", "c"])
        XCTAssertTrue(roster.contains("WRIGHT!"))
        XCTAssertTrue(roster.contains("third"), "phrase membership is per whitespace token")
        XCTAssertFalse(roster.contains("sean"))
    }

    // MARK: 13. Token edit distance

    func testTokenEditDistance() {
        XCTAssertEqual(TokenEditDistance.normalized("a b c", "a b c"), 0)
        XCTAssertEqual(TokenEditDistance.normalized("", ""), 0)
        XCTAssertEqual(TokenEditDistance.normalized("a b c", "a x c"), 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(TokenEditDistance.normalized("a b c", "a b x c"), 0.25, accuracy: 1e-12)
    }

    // MARK: 14. Alignment-derived guards on insertions and deletions

    func testInsertionsAndDeletionsFollowTheAlignmentRule() {
        let ins = decide("ground ball to", nil, "ground ball to short", 0.90)
        XCTAssertEqual(ins.text, "ground ball to short")
        XCTAssertEqual(ins.reason, .agreed, "inserting an in-set token replaces nothing")

        let del = decide("ground ball to short", nil, "ground ball to", 0.90)
        XCTAssertEqual(del.text, "ground ball to short")
        XCTAssertEqual(del.reason, .replacedTokenInVocabulary, "deleting an in-vocabulary base token is refused")

        let delOOV = decide("ground ball to um short", nil, "ground ball to short", 0.90)
        XCTAssertEqual(delOOV.text, "ground ball to short")
        XCTAssertEqual(delOOV.reason, .agreed, "deleting an OOV base token is allowed")
    }
}
