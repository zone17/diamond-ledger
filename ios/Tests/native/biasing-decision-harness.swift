/// biasing-decision-harness.swift — native (macOS `swiftc`) harness for the DL-157 biasing
/// decision. NOT part of the SwiftPM test target (`Tests/native` is excluded in Package.swift):
/// the XCTest target needs an iOS-26 destination this host cannot run, so this file re-states
/// every scenario of `Tests/BiasingDecisionTests.swift` as plain assertions that compile and
/// run headlessly against the `SpeechTypes` sources alone.
///
/// Build + run (from `ios/`):
///
///     swiftc -O -module-name BiasingHarness Sources/SpeechTypes/*.swift \
///         Tests/native/biasing-decision-harness.swift -o /tmp/biasing-harness && /tmp/biasing-harness
///
/// Exit status is non-zero on any failure; one line is printed per scenario.

import Foundation

// MARK: - Tiny assertion runner

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if condition() {
        passes += 1
        print("PASS  \(name)")
    } else {
        failures += 1
        let d = detail()
        print("FAIL  \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

func approx(_ a: Float?, _ b: Float?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return abs(x - y) < 1e-6
    default: return false
    }
}

let threshold = 70
let policyOff = BiasingPolicy.default(parserThreshold: threshold)
let policyOn = BiasingPolicy(parserThreshold: threshold, agreementThreshold: 0.30, silentScoringEnabled: true)
let roster = ContextualVocabulary(phrases: ["short", "Wright", "single", "double", "third base"])

func decide(
    _ base: String, _ baseConf: Float? = nil,
    _ biasedText: String?, _ biasedConf: Float = 0.85,
    vocabulary: ContextualVocabulary = roster,
    policy: BiasingPolicy = policyOff
) -> BiasingOutcome {
    let biased = biasedText.map { BiasedHypothesis(text: $0, confidence: biasedConf) }
    return BiasingDecision.decide(
        base: base, baseConfidence: baseConf, biased: biased, vocabulary: vocabulary, policy: policy)
}

// MARK: - Scenarios (mirror Tests/BiasingDecisionTests.swift one-for-one)

@main
struct BiasingDecisionHarness {
static func main() {

// 1. Override: OOV "sean" -> in-set "short" at 0.85; cap applies when silent scoring is off.
do {
    let off = decide("ground out to sean", nil, "ground out to short", 0.85)
    check("override-cap-off: text", off.text == "ground out to short", "got \(off.text)")
    check("override-cap-off: conf 0.69", approx(off.confidence, 0.69), "got \(String(describing: off.confidence))")
    check("override-cap-off: reason agreed", off.reason == .agreed, "got \(off.reason)")
    let on = decide("ground out to sean", nil, "ground out to short", 0.85, policy: policyOn)
    check("override-cap-on: conf 0.85", approx(on.confidence, 0.85), "got \(String(describing: on.confidence))")
    check("override-cap-on: reason agreed", on.reason == .agreed)
}

// 2. Biased confidence below the parser threshold: keep base, nil confidence.
do {
    let o = decide("ground out to sean", nil, "ground out to short", 0.65)
    check("below-threshold: keeps base", o.text == "ground out to sean")
    check("below-threshold: nil conf", o.confidence == nil, "got \(String(describing: o.confidence))")
    check("below-threshold: reason", o.reason == .biasedConfidenceBelowThreshold, "got \(o.reason)")
}

// 3. Divergent: "home run" vs "homer" (distance 1.0).
do {
    check("distance home run/homer == 1.0",
          TokenEditDistance.normalized("home run", "homer") == 1.0)
    let o = decide("home run", nil, "homer", 0.90)
    check("divergent: keeps base", o.text == "home run")
    check("divergent: reason", o.reason == .divergent, "got \(o.reason)")
}

// 4. Differing token not in the contextual set ("third" absent): keep base.
do {
    let base = "ground ball to short, threw him out at first"
    let biased = "ground ball to short, threw him out at third"
    let d = TokenEditDistance.normalized(base, biased)
    check("distance first/third == 1/9", abs(d - 1.0 / 9.0) < 1e-12, "got \(d)")
    let o = decide(base, nil, biased, 0.90, vocabulary: ContextualVocabulary(phrases: ["short"]))
    check("not-contextual: keeps base", o.text == base)
    check("not-contextual: reason", o.reason == .tokenNotContextual, "got \(o.reason)")
}

// 5. In-vocabulary swap refused; OOV correction still allowed with the same set.
do {
    let o = decide("line drive single to right", nil, "line drive double to right", 0.90)
    check("in-vocab-swap: keeps base", o.text == "line drive single to right")
    check("in-vocab-swap: reason", o.reason == .replacedTokenInVocabulary, "got \(o.reason)")
    let p = decide("ground out to sean", nil, "ground out to short", 0.90)
    check("oov-correction-same-set: overrides", p.text == "ground out to short" && p.reason == .agreed)
}

// 6. Casing-only difference: distance 0, biased (roster-cased) text returned verbatim.
do {
    check("distance wright/Wright == 0", TokenEditDistance.normalized("fly ball to wright", "fly ball to Wright") == 0)
    let o = decide("fly ball to wright", nil, "fly ball to Wright", 0.90)
    check("case-only: returns biased verbatim", o.text == "fly ball to Wright", "got \(o.text)")
    check("case-only: reason agreed", o.reason == .agreed, "got \(o.reason)")
}

// 7. R19: known base confidence higher than biased -> keep base with base confidence.
do {
    let o = decide("ground out to sean", 0.95, "ground out to short", 0.80)
    check("base-more-confident: keeps base", o.text == "ground out to sean")
    check("base-more-confident: conf 0.95", approx(o.confidence, 0.95), "got \(String(describing: o.confidence))")
    check("base-more-confident: reason", o.reason == .baseMoreConfident, "got \(o.reason)")
}

// 8. Known base confidence lower than biased -> override (0.80 on, 0.69 capped off).
do {
    let off = decide("ground out to sean", 0.60, "ground out to short", 0.80)
    check("base-less-confident-off: text", off.text == "ground out to short")
    check("base-less-confident-off: conf 0.69", approx(off.confidence, 0.69), "got \(String(describing: off.confidence))")
    let on = decide("ground out to sean", 0.60, "ground out to short", 0.80, policy: policyOn)
    check("base-less-confident-on: conf 0.80", approx(on.confidence, 0.80), "got \(String(describing: on.confidence))")
}

// 9. Biased nil or whitespace: keep base.
do {
    let a = decide("ground out to sean", nil, nil)
    check("nil-biased: keeps base", a.text == "ground out to sean" && a.confidence == nil)
    check("nil-biased: reason", a.reason == .noBiasedHypothesis, "got \(a.reason)")
    let b = decide("ground out to sean", nil, "   \n ")
    check("blank-biased: keeps base", b.text == "ground out to sean" && b.confidence == nil)
    check("blank-biased: reason", b.reason == .noBiasedHypothesis, "got \(b.reason)")
    // A known base confidence is carried through untouched (R19).
    let c = decide("ground out to sean", 0.9, nil)
    check("nil-biased: keeps base conf", approx(c.confidence, 0.9))
}

// 10. Agreement boundary: 3/10 passes, 4/10 fails.
do {
    let set = ContextualVocabulary(phrases: ["alpha beta", "gamma delta"])
    let base = "one two three four five six seven eight nine ten"
    let three = "one two alpha four five beta seven eight gamma ten"
    let four = "one two alpha four delta beta seven eight gamma ten"
    check("distance 3/10 == 0.30", TokenEditDistance.normalized(base, three) == 0.30)
    let ok = decide(base, nil, three, 0.90, vocabulary: set)
    check("boundary 0.30: overrides", ok.text == three && ok.reason == .agreed, "got \(ok.reason)")
    let bad = decide(base, nil, four, 0.90, vocabulary: set)
    check("boundary 0.40: divergent", bad.text == base && bad.reason == .divergent, "got \(bad.reason)")
}

// 11. Empty base with non-empty biased: keep (empty) base, nil confidence.
do {
    let o = decide("", nil, "ground out to short", 0.95)
    check("empty-base: keeps empty base", o.text == "" && o.confidence == nil, "got \(o.text)/\(String(describing: o.confidence))")
    check("empty-base: reason", o.reason == .emptyBase, "got \(o.reason)")
}

// 12. Normalization.
do {
    let t = TextNormalization.tokens("Ground ball, to SHORT!!")
    check("normalize tokens", t == ["ground", "ball", "to", "short"], "got \(t)")
    check("normalize collapses whitespace", TextNormalization.tokens("  a \t b\n\nc ") == ["a", "b", "c"])
    check("vocabulary membership is normalized", roster.contains("WRIGHT!") && roster.contains("third") && !roster.contains("sean"))
}

// 13. Token edit distance.
do {
    check("distance identical == 0", TokenEditDistance.normalized("a b c", "a b c") == 0)
    check("distance empty/empty == 0", TokenEditDistance.normalized("", "") == 0)
    check("distance a b c / a x c == 1/3", abs(TokenEditDistance.normalized("a b c", "a x c") - 1.0 / 3.0) < 1e-12)
    check("distance insertion == 1/4", abs(TokenEditDistance.normalized("a b c", "a b x c") - 0.25) < 1e-12)
}

// 14. Alignment-derived guards on insertions/deletions.
do {
    // Insertion of an in-set token with nothing replaced: allowed.
    let ins = decide("ground ball to", nil, "ground ball to short", 0.90)
    check("insert in-set token: overrides", ins.text == "ground ball to short" && ins.reason == .agreed, "got \(ins.reason)")
    // Deletion of an in-vocabulary base token: refused.
    let del = decide("ground ball to short", nil, "ground ball to", 0.90)
    check("delete in-vocab token: refused", del.text == "ground ball to short" && del.reason == .replacedTokenInVocabulary, "got \(del.reason)")
    // Deletion of an OOV base token: allowed.
    let delOOV = decide("ground ball to um short", nil, "ground ball to short", 0.90)
    check("delete OOV token: overrides", delOOV.text == "ground ball to short" && delOOV.reason == .agreed, "got \(delOOV.reason)")
}

print("")
print("biasing-decision-harness: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
}
}
