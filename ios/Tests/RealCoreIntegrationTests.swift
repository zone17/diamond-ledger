/// RealCoreIntegrationTests.swift — T071 / DL-35 (H1 real-core integration)
///
/// Drives the FULL judgment-loop against the **real** UniFFI core (`DiamondCoreClient`), not the
/// canned `MockCore`. Asserts the cardinal invariants hold identically against the real core:
///   - I2 / SC-003: the core NEVER auto-resolves a judgment (Card B stays open until an explicit
///     `resolveJudgment` call); and a judgment play cannot be confirmed while its decision is open.
///   - FR-007: state never advances on an unconfirmed entry; recording a new play while one is
///     pending is rejected.
///   - I5 / FR-020 (owner-as-decider): an empty/foreign owner id is rejected.
///   - The full loop runs end to end: createGame → record (ground out → Card A) → confirm →
///     record (misplayed grounder → Card B) → resolve → finalize/export.
///
/// This is the headless equivalent of the on-device WoZ walkthrough in MANUAL-TESTING.md. It runs
/// on the iOS simulator (the XCFramework ships iOS slices only), so the real Rust core executes.
///
/// - SeeAlso: `ios/Sources/Core/DiamondCoreClient.swift` (the adapter under test)
/// - SeeAlso: `core/src/primitives/mod.rs` (the real-core invariants these assertions mirror)

import XCTest
@testable import Core

final class RealCoreIntegrationTests: XCTestCase {

    private let owner = "dev-owner-demo-scorer"

    /// The misplayed-grounder WoZ marker the UI's PushToTalk harness emits for Card B.
    private let cardBFacts: [String: String] = ["script": "misplayed-grounder"]
    /// The clean 6-3 ground out facts the grammar parser emits for Card A.
    private let cardAFacts: [String: String] = [
        "batter_result": "groundout", "fielders": "6-3", "outs_recorded": "1"
    ]

    private func newGame() async throws -> (DiamondCoreClient, String) {
        let core = DiamondCoreClient()
        let r = try await core.createGame(
            homeTeam: "Hawks", visitorTeam: "Owls", ownerId: owner, correlationId: "c-create"
        )
        return (core, r.gameId)
    }

    // MARK: I5 / FR-020 — owner-as-decider

    func test_emptyOwner_isUnauthorized() async {
        let core = DiamondCoreClient()
        do {
            _ = try await core.createGame(
                homeTeam: "A", visitorTeam: "B", ownerId: "", correlationId: "c"
            )
            XCTFail("empty owner must be rejected by the real core (I5/FR-020)")
        } catch let CoreError.unauthorized(msg) {
            XCTAssertFalse(msg.isEmpty)
        } catch {
            XCTFail("expected .unauthorized, got \(error)")
        }
    }

    // MARK: Card A — deterministic ground out → confirm advances state (FR-007)

    func test_cardA_deterministicGroundOut_confirmAdvancesState() async throws {
        let (core, gameId) = try await newGame()

        let rec = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: cardAFacts, correlationId: "c-rec-a"
        )
        XCTAssertEqual(rec.needs, .confirm, "clean ground out is deterministic → Card A confirm")
        XCTAssertEqual(rec.classification, .deterministic)
        XCTAssertNil(rec.judgment, "no judgment on a deterministic play")

        // FR-007: a NEW play while this one is unconfirmed must be rejected by the real core.
        do {
            _ = try await core.recordPlay(
                gameId: gameId, ownerId: owner, normalizedFacts: cardAFacts, correlationId: "c-rec-a2"
            )
            XCTFail("real core must reject a new play while one is pending (FR-007)")
        } catch CoreError.invalidState {
            // expected — PendingConfirmation maps to .invalidState
        }

        let confirmed = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: rec.recordedSeq, ownerId: owner, correlationId: "c-conf-a"
        )
        XCTAssertEqual(confirmed.state.outs, 1, "state advances to 1 out after confirm (real core)")
    }

    // MARK: Card B — misplayed grounder → OPEN judgment, never auto-resolved (I2/SC-003)

    func test_cardB_misplayedGrounder_opensJudgment_neverAutoResolved() async throws {
        let (core, gameId) = try await newGame()

        let rec = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: cardBFacts, correlationId: "c-rec-b"
        )
        XCTAssertEqual(rec.needs, .judgment, "misplayed grounder surfaces Card B (I2)")
        XCTAssertEqual(rec.classification, .judgment(.hitVsError))
        let decision = try XCTUnwrap(rec.judgment, "Card B must carry an open decision")
        XCTAssertEqual(decision.status, .open, "the real core NEVER auto-resolves (I2/SC-003)")
        XCTAssertNil(decision.chosen, "open decision has no chosen call")
        XCTAssertNil(decision.decider, "open decision has no recorded decider yet")
        XCTAssertFalse(decision.alternatives.isEmpty, "Card B offers alternatives")

        // I2: the play that surfaced an OPEN judgment cannot be confirmed — JUDGMENT_REQUIRED.
        do {
            _ = try await core.confirmPlay(
                gameId: gameId, confirmsSeq: rec.recordedSeq, ownerId: owner, correlationId: "c-conf-b"
            )
            XCTFail("confirm must be blocked while the judgment is open (I2/SC-003)")
        } catch CoreError.judgmentRequired {
            // expected — the real core blocks the confirm.
        }

        // Resolve it explicitly (the human tap) — only NOW does it become resolved with a decider.
        let chosen = decision.recommendation.call
        let resolved = try await core.resolveJudgment(
            gameId: gameId, decisionId: decision.id, chosen: chosen,
            ownerId: owner, correlationId: "c-resolve-b"
        )
        XCTAssertEqual(resolved.decision.status, .resolved)
        XCTAssertEqual(resolved.decision.chosen?.token, chosen.token)
        XCTAssertEqual(resolved.decision.decider?.id, owner, "decider recorded as the owner (FR-011)")
    }

    // MARK: Full loop — create → A → confirm → B → resolve → confirm

    /// The full judgment loop the WoZ walkthrough drives, run against the REAL core: ground out →
    /// Card A → confirm → misplayed grounder → Card B → resolve → confirm. Every step succeeds and
    /// state threads through the real append-only event log.
    func test_fullLoop_createConfirmJudgeResolveConfirm() async throws {
        let (core, gameId) = try await newGame()

        // Card A: ground out → confirm (1 out).
        let a = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: cardAFacts, correlationId: "L-a"
        )
        XCTAssertEqual(a.needs, .confirm)
        let ca = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: a.recordedSeq, ownerId: owner, correlationId: "L-ca"
        )
        XCTAssertEqual(ca.state.outs, 1)

        // Card B: misplayed grounder → open judgment → resolve → confirm.
        let b = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: cardBFacts, correlationId: "L-b"
        )
        XCTAssertEqual(b.needs, .judgment)
        let dec = try XCTUnwrap(b.judgment)
        XCTAssertEqual(dec.status, .open)
        let resolved = try await core.resolveJudgment(
            gameId: gameId, decisionId: dec.id, chosen: dec.recommendation.call,
            ownerId: owner, correlationId: "L-rb"
        )
        XCTAssertEqual(resolved.decision.status, .resolved)

        // Once resolved, the play that surfaced the judgment can finally be confirmed (I2 cleared).
        let cb = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: b.recordedSeq, ownerId: owner, correlationId: "L-cb"
        )
        XCTAssertNotNil(cb.state, "loop completes end to end against the real core")
    }

    // MARK: Finalize / export

    /// Finalize + export plumbing against the real core, on a balanced (empty/just-created) game.
    /// Proves `DiamondCoreClient.finalizeScorecard` renders the human book + Retrosheet file from
    /// the generated `FinalizeResult` structs.
    func test_finalize_export_balancedGame() async throws {
        let (core, gameId) = try await newGame()
        let book = try await core.finalizeScorecard(
            gameId: gameId, ownerId: owner, correlationId: "F-fin"
        )
        XCTAssertFalse(book.reisnerBook.isEmpty, "finalize yields a human scorebook (US3)")
        XCTAssertTrue(
            book.reisnerBook.contains("balanced"),
            "an empty half-inning's proof box balances (SC-011)"
        )
    }

    /// REAL-CORE vs MockCore DISCREPANCY (documented finding, DL-35): the real core actually
    /// computes the half-inning proof box and ENFORCES SC-011 on finalize. Finalizing a half-inning
    /// that is still in progress (here: a confirmed out + a resolved-as-hit baserunner, half not
    /// over) legitimately fails to balance (AB+BB=2 ≠ R+PO+LOB=1) and is rejected with
    /// `proofBoxImbalance`. MockCore papered over this by always returning a canned balanced book.
    /// This asserts the real core's stricter, correct behavior — surfacing it rather than hiding it.
    func test_finalize_midHalfInning_surfacesProofBoxImbalance_realCoreStricterThanMock() async throws {
        let (core, gameId) = try await newGame()

        let a = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: cardAFacts, correlationId: "M-a"
        )
        _ = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: a.recordedSeq, ownerId: owner, correlationId: "M-ca"
        )
        let b = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: cardBFacts, correlationId: "M-b"
        )
        let dec = try XCTUnwrap(b.judgment)
        _ = try await core.resolveJudgment(
            gameId: gameId, decisionId: dec.id, chosen: dec.recommendation.call,
            ownerId: owner, correlationId: "M-rb"
        )
        _ = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: b.recordedSeq, ownerId: owner, correlationId: "M-cb"
        )

        do {
            _ = try await core.finalizeScorecard(
                gameId: gameId, ownerId: owner, correlationId: "M-fin"
            )
            XCTFail("real core must reject finalize of an unbalanced in-progress half-inning (SC-011)")
        } catch CoreError.proofBoxImbalance(let msg) {
            XCTAssertTrue(msg.contains("SC-011"), "imbalance carries the SC-011 signal: \(msg)")
        }
    }
}
