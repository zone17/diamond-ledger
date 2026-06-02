/// DL102Tests.swift — DL-102 (Squad B, feat/ios/DL-102-voice-client-shell)
///
/// Invariant tests for the V3 glance voice-client shell built in this increment.
///
/// Test coverage:
///   1. Card B invariant (I2) — judgment is surfaced open; NEVER auto-resolved.
///   2. Empty ownerId invariant (I5) — every mutating primitive throws `.unauthorized`.
///   3. New Game → record → confirm → judgment → resolve smoke test (the demoable loop).
///   4. GrammarParser — common play set parses to expected facts.
///   5. GrammarParser — ambiguity path throws `ParseError.ambiguous` (never silent guess).
///   6. EventLog — append/replay round-trip (InMemoryEventLog).
///
/// These tests run against MockCore (no real Rust core required; T071 swaps it at H1).
///
/// Note: compile-untested locally (no Xcode/Swift toolchain in this environment).
/// The CI `ios-build` job is advisory (ADR-0002).

import XCTest
import Foundation
@testable import Core
@testable import Auth
@testable import Persistence
@testable import Parse
@testable import DiamondSpeech

// MARK: - 1. Card B invariant: judgment is never auto-resolved (I2)

final class CardBNeverAutoResolvesTests: XCTestCase {

    private let core = MockCore()
    private let ownerId = "test-owner-dl102"

    // MARK: I2 — open judgment has nil chosen and nil decider

    func testJudgmentPlay_isOpen_chosenAndDeciderNil() async throws {
        let result = try await core.recordPlay(
            gameId: "game-dl102",
            ownerId: ownerId,
            normalizedFacts: ["script": "misplayed-grounder"],
            correlationId: "corr-i2-\(UUID())"
        )

        XCTAssertEqual(result.needs, .judgment,
            "I2: needs must be .judgment for a judgment play (Card B path required)")

        guard let j = result.judgment else {
            XCTFail("I2: judgment must be non-nil when needs == .judgment")
            return
        }

        XCTAssertEqual(j.status, .open,
            "I2: judgment.status must be .open — the core never auto-resolves")
        XCTAssertNil(j.chosen,
            "I2: judgment.chosen must be nil while open (core never picks a call)")
        XCTAssertNil(j.decider,
            "I2: judgment.decider must be nil while open (FR-011: decider set only on resolution)")
    }

    // MARK: I2 — Card B resolution: resolveJudgment records chosen + decider

    func testResolveJudgment_setsChosenAndDecider() async throws {
        // Record the judgment play.
        let recordResult = try await core.recordPlay(
            gameId: "game-dl102-resolve",
            ownerId: ownerId,
            normalizedFacts: ["script": "misplayed-grounder"],
            correlationId: "corr-resolve-rec-\(UUID())"
        )
        guard let j = recordResult.judgment else {
            XCTFail("Expected judgment on misplayed-grounder script"); return
        }

        // Resolve it (simulates the scorer tapping a call on Card B).
        let chosen = ScoringCall(token: "hit", label: "Hit")
        let resolveResult = try await core.resolveJudgment(
            gameId: "game-dl102-resolve",
            decisionId: j.id,
            chosen: chosen,
            ownerId: ownerId,
            correlationId: "corr-resolve-\(UUID())"
        )

        XCTAssertEqual(resolveResult.decision.status, .resolved,
            "FR-011: judgment must be .resolved after resolveJudgment")
        XCTAssertEqual(resolveResult.decision.chosen?.token, "hit",
            "FR-011: chosen must equal the tapped call")
        XCTAssertNotNil(resolveResult.decision.decider,
            "FR-011: decider must be set after resolution (the scorer's identity is recorded)")
        XCTAssertEqual(resolveResult.decision.decider?.id, ownerId,
            "FR-011: decider.id must match the authenticated ownerId")
    }

    // MARK: I2 — classification is .judgment for misplayed-grounder (never .deterministic)

    func testJudgmentPlay_classificationIsJudgment() async throws {
        let result = try await core.recordPlay(
            gameId: "game-dl102-class",
            ownerId: ownerId,
            normalizedFacts: ["script": "misplayed-grounder"],
            correlationId: "corr-class-\(UUID())"
        )

        if case .judgment(let kind) = result.classification {
            XCTAssertEqual(kind, .hitVsError,
                "I2/FR-010: classification must be .judgment(.hitVsError) for misplayed-grounder")
        } else {
            XCTFail("I2: classification must be .judgment(...); got \(result.classification)")
        }
    }
}

// MARK: - 2. Empty ownerId is unauthorized on all mutating primitives (I5)

final class EmptyOwnerIdUnauthorizedTests: XCTestCase {

    private let core = MockCore()

    func testCreateGame_emptyOwnerId_throwsUnauthorized() async {
        await assertUnauthorized("createGame") {
            try await self.core.createGame(
                homeTeam: "Home", visitorTeam: "Visitor",
                ownerId: "",
                correlationId: "corr-\(UUID())"
            )
        }
    }

    func testRecordPlay_emptyOwnerId_throwsUnauthorized() async {
        await assertUnauthorized("recordPlay") {
            try await self.core.recordPlay(
                gameId: "game-empty",
                ownerId: "",
                normalizedFacts: [:],
                correlationId: "corr-\(UUID())"
            )
        }
    }

    func testConfirmPlay_emptyOwnerId_throwsUnauthorized() async {
        await assertUnauthorized("confirmPlay") {
            try await self.core.confirmPlay(
                gameId: "game-empty",
                confirmsSeq: 1,
                ownerId: "",
                correlationId: "corr-\(UUID())"
            )
        }
    }

    func testResolveJudgment_emptyOwnerId_throwsUnauthorized() async {
        await assertUnauthorized("resolveJudgment") {
            try await self.core.resolveJudgment(
                gameId: "game-empty",
                decisionId: 1,
                chosen: ScoringCall(token: "hit", label: "Hit"),
                ownerId: "",
                correlationId: "corr-\(UUID())"
            )
        }
    }

    private func assertUnauthorized(_ label: String, body: () async throws -> some Any) async {
        do {
            _ = try await body()
            XCTFail("\(label): expected CoreError.unauthorized for empty ownerId, call succeeded")
        } catch CoreError.unauthorized {
            // I5 satisfied.
        } catch {
            XCTFail("\(label): expected CoreError.unauthorized, got \(error)")
        }
    }
}

// MARK: - 3. New Game → record → confirm → judgment → resolve smoke test

final class FullLoopSmokeTest: XCTestCase {

    private let core = MockCore()
    private let ownerId = "smoke-owner-dl102"

    func testNewGame_recordConfirm_thenJudgmentResolve_completesLoop() async throws {
        // Step 1: Create game.
        let createResult = try await core.createGame(
            homeTeam: "Eagles",
            visitorTeam: "Hawks",
            ownerId: ownerId,
            correlationId: "smoke-create"
        )
        XCTAssertFalse(createResult.gameId.isEmpty, "gameId must be non-empty after createGame")

        let gameId = createResult.gameId

        // Step 2: Record a deterministic play (Card A path).
        let recordCardA = try await core.recordPlay(
            gameId: gameId,
            ownerId: ownerId,
            normalizedFacts: ["batter_result": "groundout", "fielders": "6-3"],
            correlationId: "smoke-record-a"
        )
        XCTAssertEqual(recordCardA.needs, .confirm,
            "Card A: needs must be .confirm for a deterministic groundout")
        XCTAssertNil(recordCardA.judgment,
            "Card A: judgment must be nil for a deterministic play")

        // Step 3: Confirm the Card A play.
        let confirmResult = try await core.confirmPlay(
            gameId: gameId,
            confirmsSeq: recordCardA.recordedSeq,
            ownerId: ownerId,
            correlationId: "smoke-confirm"
        )
        XCTAssertEqual(confirmResult.confirmedSeq, recordCardA.recordedSeq,
            "Confirm: confirmedSeq must echo the recorded seq")

        // Step 4: Record a judgment play (Card B path).
        let recordCardB = try await core.recordPlay(
            gameId: gameId,
            ownerId: ownerId,
            normalizedFacts: ["script": "misplayed-grounder"],
            correlationId: "smoke-record-b"
        )
        XCTAssertEqual(recordCardB.needs, .judgment,
            "Card B: needs must be .judgment for misplayed-grounder")
        guard let judgment = recordCardB.judgment else {
            XCTFail("Card B: judgment must be non-nil"); return
        }
        XCTAssertEqual(judgment.status, .open, "I2: judgment must be .open")

        // Step 5: Resolve the judgment (scorer tap).
        let chosen = ScoringCall(token: "hit", label: "Hit")
        let resolveResult = try await core.resolveJudgment(
            gameId: gameId,
            decisionId: judgment.id,
            chosen: chosen,
            ownerId: ownerId,
            correlationId: "smoke-resolve"
        )
        XCTAssertEqual(resolveResult.decision.status, .resolved,
            "Resolve: decision must be .resolved")
        XCTAssertEqual(resolveResult.decision.chosen?.token, chosen.token,
            "Resolve: chosen must match the tapped call")
        XCTAssertNotNil(resolveResult.decision.decider,
            "FR-011: decider must be set after resolution")
    }
}

// MARK: - 4. GrammarParser — common play set

final class GrammarParserCommonPlaysTests: XCTestCase {

    private let parser = GrammarParser()

    private func makeTranscript(_ text: String, confidence: Int = 90) -> Transcript {
        Transcript(text: text, confidence: confidence, engine: .apple, finalizedAt: Date())
    }

    func testGroundout_63_parses() throws {
        let facts = try parser.parse(makeTranscript("ground ball to short, threw him out at first"))
        XCTAssertEqual(facts["batter_result"], "groundout")
    }

    func testStrikeout_parses() throws {
        let facts = try parser.parse(makeTranscript("struck out"))
        XCTAssertEqual(facts["batter_result"], "strikeout")
        XCTAssertEqual(facts["outs_recorded"], "1")
    }

    func testStrikeoutLooking_parses() throws {
        let facts = try parser.parse(makeTranscript("struck out looking"))
        XCTAssertEqual(facts["batter_result"], "strikeout_looking")
    }

    func testWalk_parses() throws {
        let facts = try parser.parse(makeTranscript("walk"))
        XCTAssertEqual(facts["batter_result"], "walk")
    }

    func testHomeRun_parses() throws {
        let facts = try parser.parse(makeTranscript("home run"))
        XCTAssertEqual(facts["batter_result"], "home_run")
    }

    func testSingle_parses() throws {
        let facts = try parser.parse(makeTranscript("single to left"))
        XCTAssertEqual(facts["batter_result"], "single")
    }

    func testDouble_parses() throws {
        let facts = try parser.parse(makeTranscript("hit double to right"))
        XCTAssertEqual(facts["batter_result"], "double")
    }

    func testTriple_parses() throws {
        let facts = try parser.parse(makeTranscript("triple to center"))
        XCTAssertEqual(facts["batter_result"], "triple")
    }

    func testHitByPitch_parses() throws {
        let facts = try parser.parse(makeTranscript("hit by pitch"))
        XCTAssertEqual(facts["batter_result"], "hit_by_pitch")
    }

    func testSacFly_parses() throws {
        let facts = try parser.parse(makeTranscript("sacrifice fly to right"))
        XCTAssertEqual(facts["batter_result"], "sac_fly")
    }

    func testError_parses() throws {
        let facts = try parser.parse(makeTranscript("reached on error by short"))
        XCTAssertEqual(facts["batter_result"], "reached_on_error")
    }

    func testEmptyInput_throwsEmptyInput() throws {
        XCTAssertThrowsError(try parser.parse(makeTranscript(""))) { error in
            guard case ParseError.emptyInput = error else {
                XCTFail("Expected ParseError.emptyInput, got \(error)")
                return
            }
        }
    }
}

// MARK: - 5. GrammarParser ambiguity path: low confidence → ParseError.ambiguous

final class GrammarParserAmbiguityTests: XCTestCase {

    private let parser = GrammarParser()

    /// A transcript with confidence below the threshold must never produce a silent result —
    /// it must throw `ParseError.ambiguous` even when the grammar matches exactly one production.
    /// This is the core FR-008 / Art. VI / I1 invariant: NEVER a silent guess.
    func testLowConfidence_singleMatch_throwsAmbiguous() {
        let lowConfidenceTranscript = Transcript(
            text: "ground ball to short",
            confidence: GrammarParser.lowConfidenceThreshold - 1,  // just below threshold
            engine: .apple,
            finalizedAt: Date()
        )
        XCTAssertThrowsError(try parser.parse(lowConfidenceTranscript)) { error in
            guard case ParseError.ambiguous = error else {
                XCTFail("FR-008: low-confidence single-match must throw .ambiguous, got \(error)")
                return
            }
        }
    }

    /// Out-of-grammar input must throw `ParseError.outOfGrammar` — never fabricated (FR-017).
    func testOutOfGrammar_throwsOutOfGrammar() {
        let transcript = Transcript(
            text: "the runner was safe on a spectacular diving catch followed by a pickle",
            confidence: 95,
            engine: .apple,
            finalizedAt: Date()
        )
        XCTAssertThrowsError(try parser.parse(transcript)) { error in
            guard case ParseError.outOfGrammar = error else {
                XCTFail("FR-017: out-of-grammar must throw .outOfGrammar, got \(error)")
                return
            }
        }
    }
}

// MARK: - 6. EventLog — append/replay round-trip

final class InMemoryEventLogTests: XCTestCase {

    func testAppendAndReplay_roundTrips() async throws {
        let log = InMemoryEventLog()
        let payload = try JSONEncoder().encode(["event": "test"])

        let e1 = GameEvent(seq: 1, gameId: "game-log", eventType: "PlayRecorded", payload: payload)
        let e2 = GameEvent(seq: 2, gameId: "game-log", eventType: "PlayConfirmed", payload: payload)

        try await log.append(e1)
        try await log.append(e2)

        let events = try await log.replay(gameId: "game-log")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].seq, 1)
        XCTAssertEqual(events[1].seq, 2)
        XCTAssertEqual(events[0].eventType, "PlayRecorded")
    }

    func testAppend_idempotentOnDuplicateSeq() async throws {
        let log = InMemoryEventLog()
        let payload = Data()
        let e = GameEvent(seq: 1, gameId: "game-idem", eventType: "Test", payload: payload)

        try await log.append(e)
        try await log.append(e)  // duplicate — must be ignored

        let events = try await log.replay(gameId: "game-idem")
        XCTAssertEqual(events.count, 1, "Idempotent append: duplicate seq must not double-insert")
    }

    func testLatestSeq_returnsHighest() async throws {
        let log = InMemoryEventLog()
        let payload = Data()

        try await log.append(GameEvent(seq: 3, gameId: "game-seq", eventType: "A", payload: payload))
        try await log.append(GameEvent(seq: 1, gameId: "game-seq", eventType: "B", payload: payload))
        try await log.append(GameEvent(seq: 2, gameId: "game-seq", eventType: "C", payload: payload))

        let latest = await log.latestSeq(gameId: "game-seq")
        XCTAssertEqual(latest, 3, "latestSeq must return the highest seq regardless of insertion order")
    }

    func testReplay_emptyForUnknownGameId() async throws {
        let log = InMemoryEventLog()
        let events = try await log.replay(gameId: "unknown-game")
        XCTAssertTrue(events.isEmpty)
    }
}
