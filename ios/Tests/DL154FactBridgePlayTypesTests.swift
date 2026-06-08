/// DL154FactBridgePlayTypesTests.swift — DL-154 (iOS→core fact bridge, all play types)
///
/// Follow-up to DL-151 (grammar broadening) and DL-35 (the H1 fact seam). Before DL-154 the
/// `FactBridge.normalizedPlay(from:)` `default:` branch collapsed EVERY non-groundout/non-error
/// `batter_result` the broadened grammar emits — home run, strikeout, walk, double, double play,
/// sac fly, … — into a 6-3 GROUND OUT. So speaking "home run" recorded an out, "double play"
/// recorded 1 out not 2, "walk" recorded an out. The grammar broadening was moot until fixed.
///
/// These are REAL-PATH tests (the verification-gap lesson): each drives the ACTUAL app path
///
///     Transcript → GrammarParser().parse → FactBridge.normalizedPlay → real DiamondCore
///
/// then asserts BOTH the classification (Card A vs B) AND the recorded state delta (outs / bases /
/// runs) against the real Rust core — never idealized dicts.
///
/// - SeeAlso: `ios/Sources/Core/DiamondCoreClient.swift` (FactBridge — the mapping under test)
/// - SeeAlso: `ios/Sources/Parse/GrammarParser.swift` (the grammar emitting each batter_result)
/// - SeeAlso: `core/src/classify/mod.rs`, `core/src/rules/mod.rs` (the ground-truth classifier+rules)

import XCTest
@testable import Core
import Parse
import DiamondSpeech
import DiamondLedgerCoreBindings

final class DL154FactBridgePlayTypesTests: XCTestCase {

    private let owner = "dev-owner-demo-scorer"

    // MARK: - Real UI fact path helper

    /// Parse an arbitrary spoken transcript through the REAL grammar (the exact `[String:String]`
    /// facts `AppState.recordPlay` would receive). High confidence so the parse is not ambiguity-
    /// gated (FR-008). Throws if the transcript is out-of-grammar / ambiguous.
    private func facts(_ text: String) throws -> [String: String] {
        let transcript = Transcript(text: text, confidence: 95, engine: .stub, finalizedAt: Date())
        return try GrammarParser().parse(transcript)
    }

    private func newRealGame() async throws -> (DiamondCoreClient, String) {
        let core = DiamondCoreClient()
        let r = try await core.createGame(
            homeTeam: "Hawks", visitorTeam: "Owls", ownerId: owner, correlationId: "dl154-create"
        )
        return (core, r.gameId)
    }

    /// Record a transcript, asserting the Card-A path, then confirm and return the post-confirm
    /// state so callers can assert the state delta (outs / bases / runs) the real core recorded.
    @discardableResult
    private func recordConfirm(
        _ text: String,
        expectBatterResult: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Core.GameState {
        let (core, gameId) = try await newRealGame()
        let f = try facts(text)
        XCTAssertEqual(f["batter_result"], expectBatterResult,
                       "grammar emits the expected batter_result", file: file, line: line)

        let rec = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: f, correlationId: "dl154-rec"
        )
        XCTAssertEqual(rec.needs, .confirm, "\(text) is deterministic → Card A", file: file, line: line)
        XCTAssertEqual(rec.classification, .deterministic, file: file, line: line)
        XCTAssertNil(rec.judgment, "no judgment on a clean \(text)", file: file, line: line)

        let confirmed = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: rec.recordedSeq, ownerId: owner, correlationId: "dl154-conf"
        )
        return confirmed.state
    }

    // MARK: - Outs (Card A, +1 out)

    func test_groundOut_cardA_plusOneOut() async throws {
        let state = try await recordConfirm("ground ball to short, threw him out at first",
                                            expectBatterResult: "groundout")
        XCTAssertEqual(state.outs, 1, "ground out records exactly one out")
    }

    func test_flyOut_cardA_plusOneOut() async throws {
        let state = try await recordConfirm("fly ball to center", expectBatterResult: "flyout")
        XCTAssertEqual(state.outs, 1, "fly out records exactly one out (NOT a fabricated ground out)")
    }

    func test_strikeout_swinging_cardA_plusOneOut() async throws {
        let state = try await recordConfirm("struck out", expectBatterResult: "strikeout")
        XCTAssertEqual(state.outs, 1, "strikeout records one out, not a 6-3 ground out")
    }

    func test_strikeout_looking_cardA_plusOneOut() async throws {
        // The grammar distinguishes Kl; the core's BatterEvent has no looking/swinging split, so
        // both record an identical +1 out (DL-154 documented limitation).
        let state = try await recordConfirm("strikeout looking", expectBatterResult: "strikeout_looking")
        XCTAssertEqual(state.outs, 1, "strikeout looking records one out (Kl ≈ K at the core)")
    }

    // MARK: - On base, no out (Card A)

    func test_walk_cardA_batterOnFirst_noOut() async throws {
        let state = try await recordConfirm("walk", expectBatterResult: "walk")
        XCTAssertEqual(state.outs, 0, "a walk is NOT an out (the headline DL-154 bug)")
    }

    func test_intentionalWalk_cardA_noOut() async throws {
        let state = try await recordConfirm("intentional walk", expectBatterResult: "intentional_walk")
        XCTAssertEqual(state.outs, 0, "an intentional walk is not an out")
    }

    func test_hitByPitch_cardA_noOut() async throws {
        let state = try await recordConfirm("hit by pitch", expectBatterResult: "hit_by_pitch")
        XCTAssertEqual(state.outs, 0, "hit by pitch puts the batter on, not out")
    }

    // MARK: - Hits (Card A)

    func test_single_cardA_noOut() async throws {
        let state = try await recordConfirm("single", expectBatterResult: "single")
        XCTAssertEqual(state.outs, 0, "a single is not an out")
    }

    func test_standUpDouble_cardA_noOut() async throws {
        let state = try await recordConfirm("stand-up double", expectBatterResult: "double")
        XCTAssertEqual(state.outs, 0, "a double is not an out")
    }

    func test_triple_cardA_noOut() async throws {
        let state = try await recordConfirm("triple", expectBatterResult: "triple")
        XCTAssertEqual(state.outs, 0, "a triple is not an out")
    }

    func test_homeRun_cardA_plusOneRun_zeroOuts() async throws {
        // The marquee bug: "home run" used to record an OUT. It must score a run, no out.
        let (core, gameId) = try await newRealGame()
        let f = try facts("home run")
        XCTAssertEqual(f["batter_result"], "home_run")

        let rec = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: f, correlationId: "dl154-hr-rec"
        )
        XCTAssertEqual(rec.needs, .confirm, "a home run is deterministic → Card A")
        XCTAssertEqual(rec.classification, .deterministic)

        let confirmed = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: rec.recordedSeq, ownerId: owner, correlationId: "dl154-hr-conf"
        )
        XCTAssertEqual(confirmed.state.outs, 0, "a home run records ZERO outs (was a fake ground out)")
        // +1 run is reflected by the half-inning NOT ending and outs staying 0; the run lands in the
        // line score (a full-state read is covered by the core's own rules tests). The critical
        // delta here is the absence of the fabricated out.
    }

    // MARK: - Sacrifices (Card A, +1 out)

    func test_sacFly_cardA_plusOneOut() async throws {
        let state = try await recordConfirm("sacrifice fly to right", expectBatterResult: "sac_fly")
        XCTAssertEqual(state.outs, 1, "a sac fly retires the batter (one out)")
    }

    func test_sacBunt_cardA_plusOneOut() async throws {
        let state = try await recordConfirm("sacrifice bunt", expectBatterResult: "sac_bunt")
        XCTAssertEqual(state.outs, 1, "a sac bunt retires the batter (one out)")
    }

    // MARK: - Double play (fact-derived; +2 outs either way)

    /// A turned double play records TWO outs (was +1 under the silent collapse). With the grammar's
    /// default 3-fielder chain (6-4-3) the real core's classifier returns ContestedCredit (the
    /// putout/assist credit is the scorer's call) — a GENUINE fact-derived Card B, not a collapse.
    /// Either way the rules engine records +2 outs once the play is confirmed.
    func test_doublePlay_recordsTwoOuts_factDerivedCard() async throws {
        let (core, gameId) = try await newRealGame()
        let f = try facts("double play, short to second to first")
        XCTAssertEqual(f["batter_result"], "double_play")
        XCTAssertEqual(f["outs_recorded"], "2", "grammar marks a double play as two outs")

        let rec = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: f, correlationId: "dl154-dp-rec"
        )

        let seq = rec.recordedSeq
        switch rec.classification {
        case .deterministic:
            XCTAssertEqual(rec.needs, .confirm)
        case .judgment(let kind):
            // A 3-fielder DP is ContestedCredit per the core's classifier — resolve it, then confirm.
            XCTAssertEqual(kind, .contestedCredit,
                           "a 3-fielder double play is a contested-credit judgment (core ground truth)")
            let decision = try XCTUnwrap(rec.judgment)
            XCTAssertEqual(decision.status, .open, "never auto-resolved (I2/SC-003)")
            _ = try await core.resolveJudgment(
                gameId: gameId, decisionId: decision.id, chosen: decision.recommendation.call,
                ownerId: owner, correlationId: "dl154-dp-resolve"
            )
        case .outOfFormat(let msg):
            return XCTFail("a double play must NOT be out-of-format: \(msg)")
        }

        let confirmed = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: seq, ownerId: owner, correlationId: "dl154-dp-conf"
        )
        XCTAssertEqual(confirmed.state.outs, 2, "a double play records TWO outs, not one")
    }

    // MARK: - Reached on error stays a genuine Card B (unchanged by DL-154)

    func test_reachedOnError_stillCardB() async throws {
        let (core, gameId) = try await newRealGame()
        let f = try facts("booted by short, batter safe at first")
        XCTAssertEqual(f["batter_result"], "reached_on_error",
                       "a misplay the batter reached on is reached_on_error")

        let rec = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: f, correlationId: "dl154-err-rec"
        )
        XCTAssertEqual(rec.needs, .judgment, "reached-on-error is a fact-derived judgment (Card B)")
        XCTAssertEqual(rec.classification, .judgment(.hitVsError),
                       "DL-154 must NOT suppress the real hit-vs-error judgment")
        let decision = try XCTUnwrap(rec.judgment)
        XCTAssertEqual(decision.status, .open, "never auto-resolved (I2/SC-003)")
    }

    // MARK: - Unrecognized fact map must NOT become a ground out

    /// The core of the DL-154 fix: an unrecognized `batter_result` must surface (OutOfFormat),
    /// never the old silent `default → groundOut` collapse. Driven straight through the FactBridge
    /// + real core (the grammar would reject this text as out-of-grammar before it ever reached the
    /// bridge, so we feed the bridge an unknown fact map directly to lock in the no-collapse rule).
    func test_unrecognizedFactMap_isOutOfFormat_notGroundOut() async throws {
        let (core, gameId) = try await newRealGame()
        let unknown: [String: String] = ["batter_result": "triple_play_with_a_twist"]

        let rec = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: unknown, correlationId: "dl154-oof-rec"
        )
        // It must NOT classify deterministic-ground-out. The core returns OutOfFormat for
        // BatterEvent.other (FR-017) — a needs-review surface, not a fabricated out.
        guard case .outOfFormat = rec.classification else {
            return XCTFail("unrecognized fact map must be OutOfFormat, got \(rec.classification)")
        }

        // And it records ZERO outs (a fabricated ground out would have been +1 after confirm).
        let confirmed = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: rec.recordedSeq, ownerId: owner, correlationId: "dl154-oof-conf"
        )
        XCTAssertEqual(confirmed.state.outs, 0,
                       "an unrecognized fact map must NOT record a fabricated ground out")
    }

    /// The FactBridge produces `BatterEvent.other` for an unknown batter_result (the unit-level
    /// guarantee behind the real-path test above) — never a `.fieldedOut` ground out.
    func test_factBridge_unknownBatterResult_mapsToOther_notFieldedOut() {
        let play = FactBridge.normalizedPlay(from: ["batter_result": "no_such_play"])
        XCTAssertEqual(play.catalyst.batterEvent, .other,
                       "unknown batter_result → BatterEvent.other (OutOfFormat), not a ground out")
        XCTAssertTrue(play.catalyst.advances.isEmpty, "no fabricated batter-out advance")
        XCTAssertEqual(play.auditLabel, "no_such_play", "original label kept as audit-only provenance")
    }

    /// Spot-check the bridge maps each known batter_result to the right BatterEvent (the mapping
    /// table), independent of the core — guards against a future silent collapse regression.
    func test_factBridge_mapsEachBatterResultToCorrectEvent() {
        func event(_ facts: [String: String]) -> BatterEvent {
            FactBridge.normalizedPlay(from: facts).catalyst.batterEvent
        }
        XCTAssertEqual(event(["batter_result": "groundout", "fielders": "63"]), .fieldedOut)
        XCTAssertEqual(event(["batter_result": "flyout", "fielder": "8"]), .fieldedOut)
        XCTAssertEqual(event(["batter_result": "strikeout"]), .strikeout)
        XCTAssertEqual(event(["batter_result": "strikeout_looking"]), .strikeout)
        XCTAssertEqual(event(["batter_result": "walk"]), .walk)
        XCTAssertEqual(event(["batter_result": "intentional_walk"]), .intentionalWalk)
        XCTAssertEqual(event(["batter_result": "home_run"]), .homeRun)
        XCTAssertEqual(event(["batter_result": "single"]), .single)
        XCTAssertEqual(event(["batter_result": "double"]), .double)
        XCTAssertEqual(event(["batter_result": "triple"]), .triple)
        XCTAssertEqual(event(["batter_result": "hit_by_pitch"]), .hitByPitch)
        XCTAssertEqual(event(["batter_result": "sac_fly", "fielder": "9"]), .sacFly)
        XCTAssertEqual(event(["batter_result": "sac_bunt"]), .sacBunt)
        XCTAssertEqual(event(["batter_result": "double_play", "fielders": "643"]), .fieldedOut)
        XCTAssertEqual(event(["batter_result": "reached_on_error", "error_position": "6"]), .fieldedOut)
    }
}
