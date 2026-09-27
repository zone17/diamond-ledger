/// DL151GrammarHardeningTests.swift — DL-151 (Squad B, Story B3)
///
/// Real-path tests for the DL-151 grammar hardening pass. Every test drives the ACTUAL
/// transcript → GrammarParser().parse(...) → FactBridge.normalizedPlay(from:) pipeline,
/// not an idealized fact dict (lesson from mock-to-real-stateful-core-swap.md).
///
/// Coverage areas:
///   1. Misplay routing → Card B.  Transcripts with misplay verbs (misplayed / booted / bobbled /
///      muffed / dropped) on a batter who REACHED must emit `reached_on_error` facts, and those
///      facts must build the misplayedGrounder NormalizedPlay the real core classifies HitVsError.
///      Adversarial cases (P1a/P1b code-review fixes, DL-151):
///        - P1a: "dropped third strike, batter reached first" → NOT reached_on_error (K+WP is OOG).
///        - P1b: "dropped fly ball in center, runner scored safely" → NOT reached_on_error (batter out).
///        - P2a: "dropped in left field, batter safe at first" → error_position "7" not "6".
///   2. Deterministic fielder order.  "ground ball to short, threw him out at first" must ALWAYS
///      produce fielders "63" (short=6 precedes first=3 in the transcript), never "36".
///   3. Reduced-grammar coverage.  Groundout, flyout, strikeout(looking), walk, single, double,
///      triple, HR, HBP, sac fly, sac bunt, error, double play — all parse to correct facts.
///   4. Ambiguity / out-of-grammar throw (never a silent guess, FR-008).
///   5. FactBridge misplay shape.  The `reached_on_error` fact dict builds a NormalizedPlay whose
///      `touchedOrMisplayedBy` is non-empty (the invariant the real core keys on for Card B).
///   6. Roster-aware name masking (DL-157 / R22 / KTD7).  Exact-token masking of roster names
///      before production matching; a masked name in a fielding slot must surface as a
///      single-candidate clarify (ParseError.ambiguous), never a silent guess.
///   7. The parser never guesses a fielder (DL-157 U9 / KTD-U9, findings F1–F11 in
///      evals/voice-accuracy/README.md).  No production resolves a fielder, chain, or strikeout
///      variant from a hard-coded default; an utterance that does not state it surfaces as a
///      single-candidate clarify. Position keywords match whole words only, and a bare
///      direction/ordinal word is a fielder only in a fielding slot.
///
/// Updated by U9 (each change is a former silent guess the corpus exposed):
///   - 1c / 1d / 1e: "bobbled the grounder, safe at first", "muffed the ball, batter safe" and
///     "dropped it, batter reaches first" name NO fielder; the old E3 came from the batter's
///     destination ("safe at first") and the old E6 from the SS default (F7). They now assert
///     the clarify shape.
///   - 3 unassisted: "first baseman made the play unassisted" is fielders "3", not the 6-3 default (F8).
///   - 6e: with NO roster, "fly ball to wright, caught" is no longer right field — "wright" is
///     not a position word under whole-word matching (F5); it surfaces as a clarify.

import XCTest
@testable import Parse
@testable import Core
import DiamondSpeech
import DiamondLedgerCoreBindings  // Position

// MARK: - Helpers

private func transcript(_ text: String, confidence: Int = 90) -> Transcript {
    Transcript(text: text, confidence: confidence, engine: .apple, finalizedAt: Date())
}

private func parse(_ text: String, confidence: Int = 90) throws -> [String: String] {
    try GrammarParser().parse(transcript(text, confidence: confidence))
}

/// Roster-aware variant (DL-157): masks `roster` names before production matching.
private func parse(_ text: String, roster: [String], confidence: Int = 90) throws -> [String: String] {
    try GrammarParser().parse(transcript(text, confidence: confidence), roster: roster)
}

/// Asserts the parse throws `ParseError.ambiguous` with exactly ONE candidate whose
/// `batter_result` is `expectedResult` — the DL-157 "safe miss" shape (clarify, not a guess).
/// Returns the candidate for further assertions.
@discardableResult
private func assertSingleCandidateClarify(
    _ text: String, roster: [String], expectedResult: String,
    file: StaticString = #filePath, line: UInt = #line
) -> [String: String]? {
    do {
        let facts = try parse(text, roster: roster)
        XCTFail("DL-157: '\(text)' with roster \(roster) must surface a clarify, but silently returned \(facts)",
                file: file, line: line)
        return nil
    } catch ParseError.ambiguous(let candidates) {
        XCTAssertEqual(candidates.count, 1,
                       "clarify must carry exactly one candidate, got \(candidates)", file: file, line: line)
        XCTAssertEqual(candidates.first?["batter_result"], expectedResult, file: file, line: line)
        return candidates.first
    } catch {
        XCTFail("DL-157: expected ParseError.ambiguous for '\(text)', got \(error)", file: file, line: line)
        return nil
    }
}

// MARK: - 1. Misplay routing → reached_on_error (Card B path)

final class DL151MisplayRoutingTests: XCTestCase {

    // 1a. "misplayed" verb + "reached" → reached_on_error, NOT groundout
    func test_misplayed_grounder_reached_first_emitsReachedOnError() throws {
        let facts = try parse("misplayed grounder to short, reached first")
        XCTAssertEqual(facts["batter_result"], "reached_on_error",
                       "misplayed grounder + reached must NOT produce a groundout")
        XCTAssertNotNil(facts["error_position"])
    }

    // 1b. "booted" variant
    func test_booted_by_short_emitsReachedOnError() throws {
        let facts = try parse("booted by short, batter safe at first")
        XCTAssertEqual(facts["batter_result"], "reached_on_error",
                       "booted must route to reached_on_error (Card B)")
        XCTAssertEqual(facts["error_position"], "6",
                       "error_position must be '6' (shortstop) for 'short'")
    }

    // 1c. "bobbled" variant — routes to reached_on_error, but NO fielder is named ("safe at
    //     first" is the batter's destination, not the fielder — F7), so the play surfaces as a
    //     single-candidate clarify carrying reached_on_error with no error_position.
    func test_bobbled_grounder_safe_at_first_clarifiesReachedOnError_noGuessedFielder() {
        let c = assertSingleCandidateClarify("bobbled the grounder, safe at first", roster: [],
                                             expectedResult: "reached_on_error")
        XCTAssertNil(c?["error_position"], "F7: 'safe at first' must not become error_position 3")
    }

    // 1d. "muffed" variant — no fielder named → clarify, never the SS default (F7).
    func test_muffed_the_ball_batter_safe_clarifiesReachedOnError_noGuessedFielder() {
        let c = assertSingleCandidateClarify("muffed the ball, batter safe", roster: [],
                                             expectedResult: "reached_on_error")
        XCTAssertNil(c?["error_position"], "F7: no fielder stated → no error_position")
    }

    // 1e. "dropped" variant — "batter reaches first" is the destination → clarify (F7).
    func test_dropped_batter_reaches_first_clarifiesReachedOnError_noGuessedFielder() {
        let c = assertSingleCandidateClarify("dropped it, batter reaches first", roster: [],
                                             expectedResult: "reached_on_error")
        XCTAssertNil(c?["error_position"], "F7: 'reaches first' must not become error_position 3")
    }

    // 1f. Misplay verb WITHOUT a reached keyword is still a groundout (the batter was out).
    //     "dropped the throw to first, batter out" — no "safe" / "reached".
    //     This asserts tryMisplay guard (b) works: batter must have reached.
    func test_misplayVerbWithoutReached_doesNotRouteToError() throws {
        // "dropped" alone without "safe"/"reached" should NOT match tryMisplay.
        // The most likely result is outOfGrammar (no other production handles this transcript),
        // but what matters is it must NOT emit reached_on_error.
        let result = Result { try parse("dropped the throw, out at first") }
        switch result {
        case .success(let facts):
            // If something matched, it must not be reached_on_error.
            XCTAssertNotEqual(facts["batter_result"], "reached_on_error",
                              "misplay verb without a reached keyword must NOT produce reached_on_error")
        case .failure:
            // outOfGrammar or ambiguous is acceptable here.
            break
        }
    }

    // 1g. FactBridge: reached_on_error facts → NormalizedPlay has non-empty touchedOrMisplayedBy.
    //     This is the FACT the real core keys on for Card B (HitVsError judgment).
    func test_factBridge_reachedOnError_buildsMisplayShape() throws {
        let facts = try parse("booted by short, batter safe at first")
        XCTAssertEqual(facts["batter_result"], "reached_on_error")
        let play = FactBridge.normalizedPlay(from: facts)
        // The real card-B invariant: touchedOrMisplayedBy must be non-empty.
        // FactBridge.misplayedGrounder sets catalyst.touchedOrMisplayedBy = [fielder].
        XCTAssertFalse(play.catalyst.touchedOrMisplayedBy.isEmpty,
                       "misplayedGrounder fact pattern must set touchedOrMisplayedBy (real core's Card B signal)")
        // Batter reaches first base (not out). AdvanceOutcome is .base(.first) or .out — no bare .home.
        let batterAdvance = play.catalyst.advances.first { $0.runner == RunnerId(1) }
        if let adv = batterAdvance {
            switch adv.to {
            case .base(let base):
                XCTAssertEqual(base, .first, "batter advance must be to first base on error")
            case .out:
                XCTFail("reached_on_error must NOT advance batter to .out")
            }
        } else {
            XCTFail("misplayedGrounder must include a batter advance")
        }
    }

    // -------------------------------------------------------------------------
    // ADVERSARIAL CASES — P1a / P1b code-review bugs (DL-151 follow-up)
    // -------------------------------------------------------------------------

    // P1a — dropped third strike: "dropped third strike, batter reached first"
    // MUST NOT produce reached_on_error (false Card B).
    // K+WP/K+PB is out-of-grammar in v1 → must throw outOfGrammar (or at minimum NOT card B).
    // The misplay verb ("dropped") + bare-reached signal ("reached first") previously fired
    // tryMisplay before the third-strike guard was added. FR-008/Article VII: no silent judgment.
    func test_P1a_droppedThirdStrike_batterReachedFirst_isNotCardB() {
        XCTAssertThrowsError(try parse("dropped third strike, batter reached first")) { e in
            // Must NOT silently emit reached_on_error — either outOfGrammar or ambiguous is fine.
            if case ParseError.outOfGrammar = e { return }
            if case ParseError.ambiguous = e { return }
            // If it somehow succeeded (should never happen after fix), fail explicitly.
            XCTFail("P1a: dropped-third-strike must NOT succeed — got \(e)")
        }
        // Belt-and-suspenders: parse as Result and assert the fact map never carries reached_on_error.
        let result = Result { try parse("dropped third strike, batter reached first") }
        if case .success(let facts) = result {
            XCTAssertNotEqual(facts["batter_result"], "reached_on_error",
                              "P1a: dropped third strike must NEVER emit reached_on_error (false Card B)")
        }
    }

    // P1b — runner safe, batter out: "dropped fly ball in center, runner scored safely"
    // The batter was OUT (the fielder dropped the fly ball after catch, runner tagged and scored).
    // Bare "safely" ≈ "safe" but refers to the RUNNER, not the batter.
    // MUST NOT produce reached_on_error → must be outOfGrammar (batter was out, no Card B).
    func test_P1b_droppedFlyBall_runnerScored_batterWasOut_isNotCardB() {
        let result = Result { try parse("dropped fly ball in center, runner scored safely") }
        switch result {
        case .success(let facts):
            XCTAssertNotEqual(facts["batter_result"], "reached_on_error",
                              "P1b: runner-safe transcript must NOT produce reached_on_error (batter was out)")
        case .failure:
            // outOfGrammar or ambiguous — both acceptable (batter was out, no v1 production).
            break
        }
    }

    // P1b variant — "struck out, runner safe at third" (bare "safe" refers to runner, not batter).
    // Another case where bare-"safe" would have triggered the old tryMisplay but must not now.
    // No misplay verb here so tryMisplay wouldn't fire anyway, but tests the invariant stays clean.
    func test_P1b_noMisplayVerb_runnerSafe_doesNotRouteToMisplay() throws {
        // "struck out, runner safe at third" → strikeout, not reached_on_error.
        let facts = try parse("struck out, runner safe at third")
        XCTAssertEqual(facts["batter_result"], "strikeout",
                       "P1b: no misplay verb → must not produce reached_on_error even with 'safe at third'")
        XCTAssertNotEqual(facts["batter_result"], "reached_on_error")
    }

    // P2a — outfield misplay: "dropped in left field, batter safe at first"
    // error_position must be "7" (left field), not "6" (shortstop default).
    // The old tryMisplay called parseInfieldPosition only → defaulted to "6" for any outfield drop.
    func test_P2a_droppedInLeftField_batterSafe_errorPositionIsLeftField() throws {
        let facts = try parse("dropped in left field, batter safe at first")
        XCTAssertEqual(facts["batter_result"], "reached_on_error",
                       "P2a: dropped in left field + batter safe must be reached_on_error")
        XCTAssertEqual(facts["error_position"], "7",
                       "P2a: outfield drop in left field must record error_position '7', not '6' (SS default)")
    }
}

// MARK: - 2. Deterministic fielder order

final class DL151DeterministicFielderOrderTests: XCTestCase {

    // 2a. THE critical assertion: "ground ball to short, threw him out at first"
    //     must ALWAYS produce "63" — short (6) spoken first, then first (3). Repeat 100 times
    //     to surface any dict-iteration non-determinism that might lurk.
    func test_groundBallShortToFirst_fielderOrder_isAlwaysSixThree() throws {
        let expectedFielders = "63"
        for i in 0..<100 {
            let facts = try parse("ground ball to short, threw him out at first")
            XCTAssertEqual(facts["fielders"], expectedFielders,
                           "Run \(i): fielder chain must be '63' (short spoken first), got '\(facts["fielders"] ?? "nil")'")
        }
    }

    // 2b. Reversed spoken order: "threw it from first back to short" → first(3) before short(6) → "36"
    //     (Contrived but verifies the ordering mechanism works both ways.)
    func test_groundBallFirstToShort_fielderOrder_isAlwaysThreeSix() throws {
        let expectedFielders = "36"
        for i in 0..<20 {
            let facts = try parse("ground ball, first to short")
            XCTAssertEqual(facts["fielders"], expectedFielders,
                           "Run \(i): first(3) spoken before short(6) → '36', got '\(facts["fielders"] ?? "nil")'")
        }
    }

    // 2c. Third to second to first (DP): "ground ball third to second to first" → "543"
    func test_doublePlay_thirdToSecondToFirst_fielderOrder_isFiveFourThree() throws {
        let facts = try parse("ground ball, double play third to second to first")
        XCTAssertEqual(facts["fielders"], "543",
                       "double play third→second→first must produce '543'")
    }

    // 2d. Classic 6-4-3 double play: "double play short to second to first" → "643"
    func test_doublePlay_shortToSecondToFirst_fielderOrder_isSixFourThree() throws {
        let facts = try parse("double play short to second to first")
        XCTAssertEqual(facts["fielders"], "643")
    }

    // 2e. Pitcher to first: "ground ball to the pitcher, threw him out at first" → "13"
    func test_groundBallPitcherToFirst_fielderOrder_isOneThree() throws {
        let facts = try parse("ground ball to the pitcher, threw him out at first")
        XCTAssertEqual(facts["batter_result"], "groundout")
        XCTAssertEqual(facts["fielders"], "13",
                       "pitcher(1) then first(3) → '13'")
    }
}

// MARK: - 3. Reduced grammar coverage (all play types)

final class DL151ReducedGrammarCoverageTests: XCTestCase {

    // Groundout
    func test_groundout_shortToFirst() throws {
        let f = try parse("ground ball to short, threw him out at first")
        XCTAssertEqual(f["batter_result"], "groundout")
        XCTAssertEqual(f["fielders"], "63")
        XCTAssertEqual(f["outs_recorded"], "1")
    }

    func test_groundout_secondToFirst() throws {
        let f = try parse("ground ball to second, over to first")
        XCTAssertEqual(f["batter_result"], "groundout")
        XCTAssertEqual(f["fielders"], "43")
    }

    func test_groundout_thirdToFirst() throws {
        let f = try parse("ground ball to third, threw him out at first")
        XCTAssertEqual(f["batter_result"], "groundout")
        XCTAssertEqual(f["fielders"], "53")
    }

    func test_groundout_unassistedFirst() throws {
        let f = try parse("ground ball, first baseman made the play unassisted")
        XCTAssertEqual(f["batter_result"], "groundout")
        // U9 / F8: one position ("first baseman" = 3) plus "unassisted" is a complete chain.
        // The pre-U9 parser silently scored this as the 6-3 default — a wrong play.
        XCTAssertEqual(f["fielders"], "3", "unassisted play by the first baseman is fielders '3'")
        XCTAssertEqual(f["outs_recorded"], "1")
    }

    // Flyout
    func test_flyout_centerField() throws {
        let f = try parse("fly ball to center field")
        XCTAssertEqual(f["batter_result"], "flyout")
        XCTAssertEqual(f["fielder"], "8")
        XCTAssertEqual(f["outs_recorded"], "1")
    }

    func test_flyout_leftField() throws {
        let f = try parse("fly ball to left field")
        XCTAssertEqual(f["batter_result"], "flyout")
        XCTAssertEqual(f["fielder"], "7")
    }

    func test_flyout_rightField() throws {
        let f = try parse("fly ball to right field")
        XCTAssertEqual(f["batter_result"], "flyout")
        XCTAssertEqual(f["fielder"], "9")
    }

    func test_flyout_lineDrive() throws {
        let f = try parse("line drive to center, caught")
        XCTAssertEqual(f["batter_result"], "flyout")
        XCTAssertEqual(f["fielder"], "8")
    }

    func test_flyout_popUp() throws {
        let f = try parse("pop up to the catcher")
        XCTAssertEqual(f["batter_result"], "flyout")
    }

    // Strikeout swinging
    func test_strikeout_swinging() throws {
        let f = try parse("struck out")
        XCTAssertEqual(f["batter_result"], "strikeout")
        XCTAssertEqual(f["outs_recorded"], "1")
    }

    // Strikeout looking
    func test_strikeout_looking() throws {
        let f = try parse("struck out looking")
        XCTAssertEqual(f["batter_result"], "strikeout_looking")
        XCTAssertEqual(f["outs_recorded"], "1")
    }

    func test_strikeout_called() throws {
        let f = try parse("struck out on a called third strike")
        XCTAssertEqual(f["batter_result"], "strikeout_looking")
    }

    // Walk
    func test_walk() throws {
        let f = try parse("walked")
        XCTAssertEqual(f["batter_result"], "walk")
    }

    func test_baseOnBalls() throws {
        let f = try parse("base on balls")
        XCTAssertEqual(f["batter_result"], "walk")
    }

    func test_intentionalWalk() throws {
        let f = try parse("intentional walk")
        XCTAssertEqual(f["batter_result"], "intentional_walk")
    }

    // Home run
    func test_homeRun() throws {
        let f = try parse("home run")
        XCTAssertEqual(f["batter_result"], "home_run")
        XCTAssertEqual(f["runs_scored"], "1")
    }

    func test_homer() throws {
        let f = try parse("homer to left field")
        XCTAssertEqual(f["batter_result"], "home_run")
    }

    // Single
    func test_single_toLeft() throws {
        let f = try parse("single to left")
        XCTAssertEqual(f["batter_result"], "single")
        XCTAssertEqual(f["fielder"], "7")
    }

    func test_single_toRight() throws {
        let f = try parse("single to right field")
        XCTAssertEqual(f["batter_result"], "single")
        XCTAssertEqual(f["fielder"], "9")
    }

    func test_single_noDirection() throws {
        let f = try parse("hit a single")
        XCTAssertEqual(f["batter_result"], "single")
    }

    // Double
    func test_double_toRight() throws {
        let f = try parse("hit double to right")
        XCTAssertEqual(f["batter_result"], "double")
        XCTAssertEqual(f["fielder"], "9")
    }

    func test_double_toCenter() throws {
        let f = try parse("double to center field")
        XCTAssertEqual(f["batter_result"], "double")
        XCTAssertEqual(f["fielder"], "8")
    }

    // Triple
    func test_triple_toCenter() throws {
        let f = try parse("triple to center")
        XCTAssertEqual(f["batter_result"], "triple")
        XCTAssertEqual(f["fielder"], "8")
    }

    // Hit by pitch
    func test_hitByPitch() throws {
        let f = try parse("hit by pitch")
        XCTAssertEqual(f["batter_result"], "hit_by_pitch")
    }

    func test_plunked() throws {
        let f = try parse("plunked")
        XCTAssertEqual(f["batter_result"], "hit_by_pitch")
    }

    // Sac fly
    func test_sacFly_toRight() throws {
        let f = try parse("sacrifice fly to right")
        XCTAssertEqual(f["batter_result"], "sac_fly")
        XCTAssertEqual(f["fielder"], "9")
        XCTAssertEqual(f["outs_recorded"], "1")
    }

    func test_sacFly_shortForm() throws {
        let f = try parse("sac fly to left field")
        XCTAssertEqual(f["batter_result"], "sac_fly")
        XCTAssertEqual(f["fielder"], "7")
    }

    // Sac bunt
    func test_sacBunt() throws {
        let f = try parse("sacrifice bunt")
        XCTAssertEqual(f["batter_result"], "sac_bunt")
        XCTAssertEqual(f["outs_recorded"], "1")
    }

    func test_sacBunt_shortForm() throws {
        let f = try parse("sac bunt to the pitcher")
        XCTAssertEqual(f["batter_result"], "sac_bunt")
        XCTAssertEqual(f["outs_recorded"], "1")
    }

    // Error / reached on error (generic path — no misplay verb)
    func test_reachedOnError_byShort() throws {
        let f = try parse("reached on error by short")
        XCTAssertEqual(f["batter_result"], "reached_on_error")
        XCTAssertEqual(f["error_position"], "6")
    }

    func test_reachedOnError_byThird() throws {
        let f = try parse("error by third baseman")
        XCTAssertEqual(f["batter_result"], "reached_on_error")
        XCTAssertEqual(f["error_position"], "5")
    }

    // Double play — fielder chain
    func test_doublePlay_643() throws {
        let f = try parse("double play short to second to first")
        XCTAssertEqual(f["batter_result"], "double_play")
        XCTAssertEqual(f["fielders"], "643")
        XCTAssertEqual(f["outs_recorded"], "2")
    }

    func test_doublePlay_463() throws {
        let f = try parse("double play second to short to first")
        XCTAssertEqual(f["batter_result"], "double_play")
        XCTAssertEqual(f["fielders"], "463")
    }

    // "double" alone must NOT match double play
    func test_double_doesNotMatchDoublePlay() throws {
        let f = try parse("hit a double to center")
        XCTAssertEqual(f["batter_result"], "double")
        XCTAssertNotEqual(f["batter_result"], "double_play")
    }

    // Outfield positions in flyout
    func test_flyout_caughtByCenter() throws {
        let f = try parse("caught by center fielder")
        XCTAssertEqual(f["batter_result"], "flyout")
        XCTAssertEqual(f["fielder"], "8")
    }
}

// MARK: - 4. Ambiguity / out-of-grammar — never a silent guess (FR-008)

final class DL151AmbiguityOutOfGrammarTests: XCTestCase {

    // 4a. Low confidence → ambiguous even with a single candidate match.
    func test_lowConfidence_throws_ambiguous() {
        let below = GrammarParser.lowConfidenceThreshold - 1
        XCTAssertThrowsError(try parse("ground ball to short, threw him out at first", confidence: below)) { e in
            guard case ParseError.ambiguous = e else {
                XCTFail("FR-008: low-confidence must throw .ambiguous, got \(e)"); return
            }
        }
    }

    // 4b. Unintelligible transcript → outOfGrammar (manual entry path, not a fabricated play).
    func test_outOfGrammar_nonsense_throws() {
        XCTAssertThrowsError(try parse("the runner was safe on a spectacular diving catch followed by a pickle")) { e in
            guard case ParseError.outOfGrammar = e else {
                XCTFail("FR-017: no production should match; expected .outOfGrammar, got \(e)"); return
            }
        }
    }

    // 4c. Empty input → emptyInput.
    func test_emptyInput_throws_emptyInput() {
        XCTAssertThrowsError(try parse("")) { e in
            guard case ParseError.emptyInput = e else {
                XCTFail("expected .emptyInput, got \(e)"); return
            }
        }
    }

    // 4d. Whitespace-only input → emptyInput.
    func test_whitespaceOnly_throws_emptyInput() {
        XCTAssertThrowsError(try GrammarParser().parse(transcript("   "))) { e in
            guard case ParseError.emptyInput = e else {
                XCTFail("whitespace only must throw .emptyInput, got \(e)"); return
            }
        }
    }

    // 4e. A transcript that matches two productions → ambiguous (never silently picks one).
    //     "walk to first single" contains both "walk" and "single" — two matches.
    func test_multipleMatches_throws_ambiguous() {
        XCTAssertThrowsError(try parse("walk to first then hit a single")) { e in
            guard case ParseError.ambiguous(let candidates) = e else {
                XCTFail("multi-match must throw .ambiguous, got \(e)"); return
            }
            XCTAssertGreaterThan(candidates.count, 1,
                                 "ambiguous error must carry the candidate set")
        }
    }
}

// MARK: - 5. FactBridge misplay shape (invariant the real core keys on)

final class DL151FactBridgeMisplayShapeTests: XCTestCase {

    // 5a. parseFielders with concatenated grammar output (regression guard for DL-35 CoreError 4).
    func test_parseFielders_concatenated_isPerDigit() {
        XCTAssertEqual(FactBridge.parseFielders("63"),    [Position(6), Position(3)])
        XCTAssertEqual(FactBridge.parseFielders("6-3"),   [Position(6), Position(3)])
        XCTAssertEqual(FactBridge.parseFielders("643"),   [Position(6), Position(4), Position(3)])
        XCTAssertEqual(FactBridge.parseFielders("6-4-3"), [Position(6), Position(4), Position(3)])
        XCTAssertNil(FactBridge.parseFielders(""))
        XCTAssertNil(FactBridge.parseFielders(nil))
    }

    // 5b. reached_on_error with explicit error_position bridges to the correct fielder.
    func test_factBridge_reachedOnError_position5_buildsThirdBasemanMisplay() throws {
        let facts = try parse("muffed by the third baseman, batter safe at first")
        XCTAssertEqual(facts["batter_result"], "reached_on_error")
        XCTAssertEqual(facts["error_position"], "5")
        let play = FactBridge.normalizedPlay(from: facts)
        XCTAssertFalse(play.catalyst.touchedOrMisplayedBy.isEmpty,
                       "touchedOrMisplayedBy must be non-empty for Card B")
        XCTAssertEqual(play.catalyst.touchedOrMisplayedBy.first, Position(5),
                       "error_position '5' must map to Position(5) in touchedOrMisplayedBy")
    }

    // 5c. Deterministic 63 groundout bridges to a clean fielded-out with empty touchedOrMisplayedBy.
    func test_factBridge_groundout63_clearsToochedOrMisplayedBy() throws {
        let facts = try parse("ground ball to short, threw him out at first")
        XCTAssertEqual(facts["batter_result"], "groundout")
        let play = FactBridge.normalizedPlay(from: facts)
        XCTAssertTrue(play.catalyst.touchedOrMisplayedBy.isEmpty,
                      "clean groundout must have empty touchedOrMisplayedBy (Card A, no judgment)")
        // Batter is out. AdvanceOutcome is .base(Base) or .out.
        let batterOut = play.catalyst.advances.first { $0.runner == RunnerId(1) }
        if let adv = batterOut {
            switch adv.to {
            case .out:
                break  // correct — batter retired
            case .base(let b):
                XCTFail("clean groundout batter advance must be .out, got .base(\(b))")
            }
        } else {
            XCTFail("groundout must include a batter advance")
        }
    }
}

// MARK: - 6. Roster-aware name masking (DL-157 / R22 / KTD7) — never a silent wrong play

final class DL157RosterMaskingTests: XCTestCase {

    // 6a. THE motivating case: a surname containing "right" must NOT become right field, and the
    //     flyout's center-field default must NOT be returned silently either. The only acceptable
    //     outcome is a single-candidate clarify carrying the flyout.
    func test_wright_flyBall_surfacesClarify_neverRightField_neverSilentDefault() {
        let candidate = assertSingleCandidateClarify("fly ball to wright, caught", roster: ["Wright"],
                                                     expectedResult: "flyout")
        XCTAssertNotEqual(candidate?["fielder"], "9",
                          "masked 'wright' must never be read as right field (9)")
    }

    // 6b. A position word that survives masking still resolves the fielder — no clarify needed.
    func test_wright_inCenter_parsesFlyoutToCenter() throws {
        let f = try parse("fly ball to wright in center, caught", roster: ["Wright"])
        XCTAssertEqual(f["batter_result"], "flyout")
        XCTAssertEqual(f["fielder"], "8")
        XCTAssertEqual(f["outs_recorded"], "1")
    }

    // 6c. Chosen rule: a roster name IDENTICAL to a grammar keyword ("Short") is still masked.
    //     The roster is the more specific signal, so "short" is treated as the player, the
    //     groundout production has no fielder chain, and the play surfaces as a clarify — a safe
    //     miss rather than a guessed 6-3. (Documented on `GrammarParser.maskRosterNames`.)
    func test_rosterNameIdenticalToKeyword_short_isMasked_surfacesClarify() {
        assertSingleCandidateClarify("ground ball to short", roster: ["Short"],
                                     expectedResult: "groundout")
        // Even with a second explicit position, the masked "short" removed the first fielder,
        // so the chain would be a default — still a clarify, never a silent "63".
        assertSingleCandidateClarify("ground ball to short, threw him out at first", roster: ["Short"],
                                     expectedResult: "groundout")
    }

    // 6d. Multi-word roster name is masked as ONE phrase; no position keyword leaks out of it.
    func test_multiWordName_maskedAsPhrase_noPositionLeaks() {
        let masked = GrammarParser.maskRosterNames(
            in: GrammarParser.normalizeForMasking("fly ball to center fielder jones, caught"),
            roster: ["Center Fielder Jones"])
        XCTAssertTrue(masked.maskedAny)
        XCTAssertEqual(masked.masked, "fly ball to \(GrammarParser.namePlaceholder) caught")
        assertSingleCandidateClarify("fly ball to center fielder jones, caught",
                                     roster: ["Center Fielder Jones"], expectedResult: "flyout")
    }

    // 6e. Empty roster ⇒ identical to the no-roster path (representative DL-151 sample).
    func test_emptyRoster_isIdenticalToLegacyBehavior() throws {
        let cases: [(String, [String: String])] = [
            ("ground ball to short, threw him out at first",
             ["batter_result": "groundout", "fielders": "63", "outs_recorded": "1"]),
            ("ground ball to second, threw him out at first",
             ["batter_result": "groundout", "fielders": "43", "outs_recorded": "1"]),
            ("fly ball to center caught for the out",
             ["batter_result": "flyout", "fielder": "8", "outs_recorded": "1"]),
            ("sacrifice fly to center",
             ["batter_result": "sac_fly", "fielder": "8", "outs_recorded": "1"]),
            ("reached on error by the shortstop",
             ["batter_result": "reached_on_error", "error_position": "6"]),
            ("double play short to second to first",
             ["batter_result": "double_play", "fielders": "643", "outs_recorded": "2"]),
            ("struck out looking", ["batter_result": "strikeout_looking", "outs_recorded": "1"]),
            ("walk", ["batter_result": "walk"]),
            ("home run", ["batter_result": "home_run", "runs_scored": "1"]),
            ("single", ["batter_result": "single"]),
            ("hit by pitch", ["batter_result": "hit_by_pitch"]),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try parse(text), expected, "legacy: \(text)")
            XCTAssertEqual(try parse(text, roster: []), expected, "empty roster: \(text)")
        }
        // U9 / F5: with no roster "wright" is simply not a position word (whole-word matching —
        // it no longer reads as right field by substring), and no CF default fires either: the
        // flyout surfaces as a single-candidate clarify with no fielder.
        let c = assertSingleCandidateClarify("fly ball to wright, caught", roster: [], expectedResult: "flyout")
        XCTAssertNil(c?["fielder"], "no roster: 'wright' is neither right field nor a defaulted CF")
        // Existing throw paths unchanged.
        XCTAssertThrowsError(try parse("dropped third strike, batter reached first", roster: [])) { e in
            guard case ParseError.outOfGrammar = e else { XCTFail("expected outOfGrammar, got \(e)"); return }
        }
        XCTAssertThrowsError(try parse("the quick brown fox jumps", roster: [])) { e in
            guard case ParseError.outOfGrammar = e else { XCTFail("expected outOfGrammar, got \(e)"); return }
        }
    }

    // 6e'. A roster whose names never occur in the transcript must not change the result either
    //      (exercises the roster-path normalization on the same representative sample).
    func test_nonOccurringRoster_isIdenticalToLegacyBehavior() throws {
        let decoy = ["Zzyzx", "Quentin Blake"]
        for text in ["ground ball to short, threw him out at first", "fly ball to center caught for the out",
                     "sacrifice fly to center", "reached on error by the shortstop",
                     "double play short to second to first", "strikeout looking", "triple to right"] {
            XCTAssertEqual(try parse(text, roster: decoy), try parse(text), "decoy roster: \(text)")
        }
    }

    // 6f. A name that appears twice is masked twice.
    func test_nameAppearingTwice_isMaskedTwice() {
        let masked = GrammarParser.maskRosterNames(
            in: GrammarParser.normalizeForMasking("ground ball wright to wright"), roster: ["Wright"])
        let ph = GrammarParser.namePlaceholder
        XCTAssertEqual(masked.masked, "ground ball \(ph) to \(ph)")
        XCTAssertTrue(masked.maskedAny)
        assertSingleCandidateClarify("ground ball wright to wright", roster: ["Wright"],
                                     expectedResult: "groundout")
    }

    // 6g. Punctuation / case in the roster name: "O'Neil" masks o'neil / oneil / O’Neil alike.
    func test_rosterNameWithPunctuation_masksAllNormalizedForms() {
        let ph = GrammarParser.namePlaceholder
        for form in ["single to o'neil", "single to oneil", "single to O’Neil", "single to O'NEIL,"] {
            let masked = GrammarParser.maskRosterNames(
                in: GrammarParser.normalizeForMasking(form), roster: ["O'Neil"])
            XCTAssertEqual(masked.masked, "single to \(ph)", "form: \(form)")
            XCTAssertTrue(masked.maskedAny, "form: \(form)")
        }
        assertSingleCandidateClarify("fly ball to o'neil, caught", roster: ["O'Neil"],
                                     expectedResult: "flyout")
    }

    // 6h. Exact-token only (KTD7): "wright" must NOT mask "wrights" or any longer word.
    func test_masking_isWholeWordOnly_neverSubstring() {
        let masked = GrammarParser.maskRosterNames(
            in: GrammarParser.normalizeForMasking("fly ball to wrights"), roster: ["Wright"])
        XCTAssertFalse(masked.maskedAny)
        XCTAssertEqual(masked.masked, "fly ball to wrights")
    }

    // 6h'. A multi-word lineup entry masks each of its tokens on its own (U9): "Dee Wright" must
    //      mask a spoken bare "wright". Position-keyword tokens of a multi-word name are NOT
    //      masked alone (only the whole phrase is), so "Center Fielder Jones" never eats "center".
    func test_multiWordName_masksEachTokenIndividually() throws {
        let ph = GrammarParser.namePlaceholder
        let masked = GrammarParser.maskRosterNames(
            in: GrammarParser.normalizeForMasking("fly ball to wright, caught"), roster: ["Dee Wright"])
        XCTAssertEqual(masked.masked, "fly ball to \(ph) caught")
        XCTAssertTrue(masked.maskedAny)
        let c = assertSingleCandidateClarify("fly ball to wright, caught", roster: ["Dee Wright"],
                                             expectedResult: "flyout")
        XCTAssertNil(c?["fielder"], "bare 'wright' from 'Dee Wright' is a lost fielder, never RF and never a default")
        let f = try parse("fly ball to wright in center, caught", roster: ["Dee Wright"])
        XCTAssertEqual(f["batter_result"], "flyout")
        XCTAssertEqual(f["fielder"], "8")
        // Keyword tokens of a multi-word name stay usable as positions on their own.
        let keep = GrammarParser.maskRosterNames(
            in: GrammarParser.normalizeForMasking("fly ball to center, caught"), roster: ["Center Fielder Jones"])
        XCTAssertEqual(keep.masked, "fly ball to center caught")
        XCTAssertFalse(keep.maskedAny)
        XCTAssertEqual(try parse("fly ball to center, caught", roster: ["Center Fielder Jones"])["fielder"], "8")
        // Still whole-token: "wrights" is not masked by "Dee Wright".
        XCTAssertFalse(GrammarParser.maskRosterNames(
            in: GrammarParser.normalizeForMasking("fly ball to wrights"), roster: ["Dee Wright"]).maskedAny)
    }

    // 6i. The placeholder itself can never satisfy a production (no keyword substring, no
    //     exact-equality token). Parsing the bare placeholder must be out-of-grammar.
    func test_placeholder_neverMatchesAProduction() {
        XCTAssertThrowsError(try parse(GrammarParser.namePlaceholder, roster: ["anyone"])) { e in
            guard case ParseError.outOfGrammar = e else {
                XCTFail("placeholder must never match a production, got \(e)"); return
            }
        }
    }

    // 6j. Masking + defaults across the other defaulting productions: sac fly, error, misplay,
    //     double play — all must clarify, none may return the default silently.
    func test_maskedName_withDefaultedFielder_clarifies_acrossProductions() {
        assertSingleCandidateClarify("sacrifice fly to wright", roster: ["Wright"], expectedResult: "sac_fly")
        assertSingleCandidateClarify("reached on error by wright", roster: ["Wright"], expectedResult: "reached_on_error")
        // NOTE: "batter reached base" (not "safe at first") — the misplay production reads any
        // position word, so "first" in "safe at first" would become the error position (a
        // pre-existing DL-151 behavior, independent of masking; see U3 report).
        assertSingleCandidateClarify("booted by wright, batter reached base", roster: ["Wright"],
                                     expectedResult: "reached_on_error")
        assertSingleCandidateClarify("double play jones to smith to wright", roster: ["Jones", "Smith", "Wright"],
                                     expectedResult: "double_play")
    }

    // 6k. Masked name but NO default involved ⇒ a normal successful parse (masking alone is
    //     not a reason to clarify). "single to wright" carries no fielder default.
    func test_maskedName_withoutDefault_parsesNormally() throws {
        let f = try parse("single to wright", roster: ["Wright"])
        XCTAssertEqual(f["batter_result"], "single")
        XCTAssertNil(f["fielder"], "masked name yields no fielder — and no guessed one either")
        let k = try parse("wright struck out", roster: ["Wright"])
        XCTAssertEqual(k["batter_result"], "strikeout")
    }
}

// MARK: - 7. The parser never guesses a fielder (DL-157 U9 / KTD-U9) — findings F1–F11

/// One test per finding in evals/voice-accuracy/README.md "Pipeline findings". Every case is a
/// transcript the voice-accuracy corpus exposed as a confident wrong play (or a pass-by-
/// coincidence) under the pre-U9 defaults. Rule: a production resolves a fielder / chain /
/// variant ONLY from what the utterance says; otherwise it surfaces a single-candidate clarify.
final class DL157NeverGuessAFielderTests: XCTestCase {

    /// Asserts `ParseError.ambiguous` with exactly the given `batter_result`s (order-insensitive).
    private func assertClarify(_ text: String, roster: [String] = [], results: Set<String>,
                               file: StaticString = #filePath, line: UInt = #line) -> [[String: String]] {
        do {
            let facts = try parse(text, roster: roster)
            XCTFail("'\(text)' must clarify, but silently returned \(facts)", file: file, line: line)
        } catch ParseError.ambiguous(let candidates) {
            XCTAssertEqual(Set(candidates.compactMap { $0["batter_result"] }), results,
                           "candidates for '\(text)': \(candidates)", file: file, line: line)
            XCTAssertEqual(candidates.count, results.count, file: file, line: line)
            return candidates
        } catch {
            XCTFail("expected ParseError.ambiguous for '\(text)', got \(error)", file: file, line: line)
        }
        return []
    }

    // F1 — groundout: the 6-3 default never fires. An incomplete chain is offered as heard.
    func test_F1_groundout_incompleteChain_clarifies_neverSixThree() {
        // Zero explicit positions ("four three" — numerals are not positions in v1).
        let none = assertClarify("ground ball four three", results: ["groundout"])
        XCTAssertNil(none.first?["fielders"], "no position heard → no chain invented")
        // One explicit position: the candidate carries what WAS heard ("at first" → 3), never 63.
        let one = assertClarify("ground ball to sickened, threw him out at first", results: ["groundout"])
        XCTAssertEqual(one.first?["fielders"], "3")
        let four = assertClarify("ground ball to second, threw him out at thirst", results: ["groundout"])
        XCTAssertEqual(four.first?["fielders"], "4")
        assertClarify("ground ball to thud, threw him out at first", results: ["groundout"])
        assertClarify("6-3 groundout", results: ["groundout"])
        // Complete explicit chains still score.
        XCTAssertEqual(try parse("ground ball to short, threw him out at first")["fielders"], "63")
        XCTAssertEqual(try parse("ground ball to second, threw him out at first")["fielders"], "43")
        XCTAssertEqual(try parse("ground ball, first to short")["fielders"], "36")
    }

    // F2 — flyout: the CF default never fires.
    func test_F2_flyout_noPosition_clarifies_neverCenter() {
        for text in ["fly ball, seven", "fly ball to 7", "fly ball to loft field", "fly ball to lift field",
                     "fly ball to write field", "fly ball to rite field", "fly out to 8"] {
            let c = assertClarify(text, results: ["flyout"])
            XCTAssertNil(c.first?["fielder"], "\(text): no fielder guessed")
        }
        XCTAssertEqual(try parse("fly ball to left field")["fielder"], "7")
    }

    // F3 — sac fly: the RF default never fires; "centre" is the same word as "center".
    func test_F3_sacFly_noPosition_clarifies_centreIsCenter() throws {
        let c = assertClarify("sacrifice fly to enter", results: ["sac_fly"])
        XCTAssertNil(c.first?["fielder"])
        XCTAssertEqual(try parse("sacrifice fly to centre")["fielder"], "8", "British spelling is a synonym")
        XCTAssertEqual(try parse("fly ball to centre caught for the out")["fielder"], "8")
    }

    // F4 — strikeout: bare strikeout keeps the ONE documented default (K); an unknown word in
    //      the modifier slot is a mis-heard modifier → clarify with both variants.
    func test_F4_strikeout_unknownModifier_clarifiesBothVariants_bareStaysK() throws {
        assertClarify("strikeout cooking", results: ["strikeout", "strikeout_looking"])
        assertClarify("strikeout booking", results: ["strikeout", "strikeout_looking"])
        assertClarify("strikeout singing", results: ["strikeout", "strikeout_looking"])
        XCTAssertEqual(try parse("struck out")["batter_result"], "strikeout")
        XCTAssertEqual(try parse("struck out, runner safe at third")["batter_result"], "strikeout")
        XCTAssertEqual(try parse("strikeout swinging, yeah")["batter_result"], "strikeout")
        XCTAssertEqual(try parse("strikeout called")["batter_result"], "strikeout_looking")
        XCTAssertEqual(try parse("wright struck out", roster: ["Wright"])["batter_result"], "strikeout")
        XCTAssertEqual(try parse("K")["batter_result"], "strikeout")
    }

    // F5 — whole-word keywords: fillers and look-alike words are never absorbed as positions.
    func test_F5_wholeWordMatching_fillersNeverBecomeFielders() throws {
        XCTAssertEqual(try parse("alright, ground ball to short, threw him out at first")["fielders"], "63")
        XCTAssertEqual(try parse("right, ground ball to short, threw him out at first")["fielders"], "63")
        XCTAssertEqual(try parse("first of all, ground ball to short, threw him out at first")["fielders"], "63")
        XCTAssertEqual(try parse("right, ground ball to second, threw him out at first")["fielders"], "43")
        XCTAssertEqual(try parse("first of all, error on the third baseman, batter reached first")["error_position"], "5")
        XCTAssertEqual(try parse("reached on terror by the shortstop")["error_position"], "6",
                       "'terror' is not 'error'; 'reached on' + 'shortstop' still scores E6")
        XCTAssertEqual(try parse("reached on error by the short stop")["error_position"], "6")
        // "wright" is not "right" — with or without a roster.
        let c = assertClarify("fly ball to wright field", results: ["flyout"])
        XCTAssertNil(c.first?["fielder"])
        // A bare direction word is a fielder only in a fielding slot.
        XCTAssertEqual(try parse("hit double to right")["fielder"], "9")
        XCTAssertEqual(try parse("single to left")["fielder"], "7")
        // A destination is never a fielder.
        XCTAssertEqual(try parse("ground ball to short, threw him out at first, runner on third")["fielders"], "63")
        XCTAssertEqual(try parse("fly ball to center, runner advanced to third")["fielder"], "8")
    }

    // F6 — a masked roster name in a fielding slot is a lost fielder: never a silent chain.
    func test_F6_maskedNameInChain_clarifies_evenWhenRemainingChainIsComplete() throws {
        assertClarify("double play short to second to first", roster: ["Short"], results: ["double_play"])
        assertClarify("double play Wright to second to first", roster: ["Wright"], results: ["double_play"])
        assertClarify("ground ball, Wright to second to first", roster: ["Wright"], results: ["groundout"])
        assertClarify("ground ball to Short, Wright threw him out at first", roster: ["Short", "Wright"],
                      results: ["groundout"])
        // A masked name OUTSIDE a fielding slot, or qualified by its position, does not clarify.
        XCTAssertEqual(try parse("ground ball to short, Wright threw him out at first", roster: ["Wright"])["fielders"], "63")
        XCTAssertEqual(try parse("ground ball to Wright at short, threw him out at first", roster: ["Wright"])["fielders"], "63")
        XCTAssertEqual(try parse("Garcia grounds to short, threw him out at first", roster: ["Garcia"])["fielders"], "63")
        XCTAssertEqual(try parse("fly ball to wright in center, caught", roster: ["Wright"])["fielder"], "8")
        XCTAssertEqual(try parse("reached on error by Wright at shortstop", roster: ["Wright"])["error_position"], "6")
    }

    // F7 — error position is never inferred from the batter's destination.
    func test_F7_errorPosition_neverFromDestination() throws {
        for text in ["error on the turd baseman, batter reached first", "error five, batter reached first",
                     "error on 5", "bobbled the grounder, safe at first", "dropped it, batter reaches first"] {
            let c = assertClarify(text, results: ["reached_on_error"])
            XCTAssertNil(c.first?["error_position"], "\(text): destination must not become the fielder")
        }
        assertClarify("error on Garcia, batter reached first", roster: ["Garcia"], results: ["reached_on_error"])
        XCTAssertEqual(try parse("error on the third baseman, batter reached first")["error_position"], "5")
        XCTAssertEqual(try parse("booted by short, batter safe at first")["error_position"], "6")
    }

    // F8 — an unassisted play is the one stated fielder, not 6-3.
    func test_F8_unassisted_isSingleFielder() throws {
        let f = try parse("ground ball, first baseman made the play unassisted")
        XCTAssertEqual(f["batter_result"], "groundout")
        XCTAssertEqual(f["fielders"], "3")
    }

    // F9 — a dropped fly ball is a scorer judgment: out-of-grammar, never a confident F8.
    func test_F9_droppedFlyBall_isOutOfGrammar_neverConfidentFlyout() {
        XCTAssertThrowsError(try parse("dropped fly ball in center, runner scored safely")) { e in
            guard case ParseError.outOfGrammar = e else { XCTFail("expected outOfGrammar, got \(e)"); return }
        }
    }

    // F10 — unambiguous synonyms parse; shorthand notation and numerals stay out of grammar.
    func test_F10_synonyms_parse_notationStaysOutOfGrammar() throws {
        XCTAssertEqual(try parse("flied out to center")["fielder"], "8")
        XCTAssertEqual(try parse("flyball to left field")["fielder"], "7")
        XCTAssertEqual(try parse("Martinez flies out to center")["fielder"], "8")
        XCTAssertEqual(try parse("strike-out swinging")["batter_result"], "strikeout")
        XCTAssertEqual(try parse("sack fly to center")["batter_result"], "sac_fly")
        XCTAssertEqual(try parse("Garcia homers to center")["batter_result"], "home_run")
        XCTAssertEqual(try parse("Jones walks")["batter_result"], "walk")
        for text in ["F7", "E6", "six three", "6 3"] {
            XCTAssertThrowsError(try parse(text), text) { e in
                guard case ParseError.outOfGrammar = e else { XCTFail("\(text): expected outOfGrammar, got \(e)"); return }
            }
        }
    }

    // F11 — double play: the 6-4-3 default never fires.
    func test_F11_doublePlay_noChain_clarifies_neverSixFourThree() throws {
        for text in ["six four three double play", "6-4-3 double play", "4-6-3 double play", "dp"] {
            let c = assertClarify(text, results: ["double_play"])
            XCTAssertNil(c.first?["fielders"], "\(text): no chain invented")
        }
        XCTAssertEqual(try parse("double play second to short to first")["fielders"], "463")
    }
}
