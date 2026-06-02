/// RealPathRegressionTests.swift — DL-35 H1-completion (real-path verification gap)
///
/// These tests close the gap that let the live-on-sim bugs through: the earlier
/// `RealCoreIntegrationTests` drove **idealized** facts straight into `DiamondCoreClient`, so it
/// never exercised the ACTUAL UI path the app runs:
///
///     StubTranscriber(script) → GrammarParser().parse → FactBridge → real DiamondCore
///
/// nor the stateful-core reconciliations in `AppState` (Card-A dismiss, End Game). Each test here
/// fails on the pre-DL-35 behavior and passes on the new behavior.
///
/// Coverage:
///   1. groundOut63 transcript → real grammar parse → Card A → confirm → next play records.
///   2. reached-on-error transcript → real grammar parse → FACT-derived Card B (real core, NO
///      `"script"` marker) → resolve.
///   3. record → dismiss-without-confirm → NO orphaned-pending inconsistency (the reconciliation).
///   4. End Game on an incomplete game → graceful path (real reason surfaced, no crash/blind fail).
///   5. `FactBridge.parseFielders("63") == [6, 3]` (the bug class that caused `CoreError 4`).
///
/// - SeeAlso: `ios/Sources/Core/DiamondCoreClient.swift` (FactBridge — the H1 fact seam)
/// - SeeAlso: `ios/Sources/UI/App/AppState.swift` (the stateful-core reconciliation under test)

import XCTest
@testable import Core
@testable import UI
import Parse
import DiamondSpeech
import DiamondLedgerCoreBindings  // `Position` (UInt8 newtype) is the generated UniFFI type

final class RealPathRegressionTests: XCTestCase {

    private let owner = "dev-owner-demo-scorer"

    // MARK: - Real UI fact path helper

    /// Reproduce the EXACT facts the app produces for a WoZ script: stub transcript → grammar parse.
    /// Returns the `[String: String]` facts `AppState.recordPlay` would receive (NO script marker —
    /// the grammar parser never emits one). Throws if the transcript is out-of-grammar/ambiguous.
    private func realFacts(for script: WoZScript) async throws -> [String: String] {
        let transcriber = StubTranscriber(script: script)
        let buffer = AudioBuffer(rawBytes: Data(), durationSeconds: 1.0, capturedAt: Date())
        let transcript = try await transcriber.transcribe(buffer: consume buffer)
        return try GrammarParser().parse(transcript)
    }

    /// A "reached on error by short" transcript — the real grammar's `tryError` production, which
    /// emits `reached_on_error` facts (the fact-derived Card B path, no WoZ marker).
    private func reachedOnErrorFacts() throws -> [String: String] {
        let transcript = Transcript(
            text: "reached on error by short",
            confidence: 95,
            engine: .stub,
            finalizedAt: Date()
        )
        return try GrammarParser().parse(transcript)
    }

    private func newRealGame() async throws -> (DiamondCoreClient, String) {
        let core = DiamondCoreClient()
        let r = try await core.createGame(
            homeTeam: "Hawks", visitorTeam: "Owls", ownerId: owner, correlationId: "rp-create"
        )
        return (core, r.gameId)
    }

    // MARK: 5. The bug class — parseFielders on the concatenated grammar output

    func test_factBridge_parseFielders_concatenatedChain_isPerDigit() {
        // The grammar parser emits "63" (concatenated), NOT "6-3". Splitting on "-" produced
        // Position(63) — the out-of-range position the real core rejected (CoreError 4).
        XCTAssertEqual(FactBridge.parseFielders("63"), [Position(6), Position(3)])
        XCTAssertEqual(FactBridge.parseFielders("6-3"), [Position(6), Position(3)])   // WoZ format
        XCTAssertEqual(FactBridge.parseFielders("643"), [Position(6), Position(4), Position(3)])
        XCTAssertEqual(FactBridge.parseFielders("6-4-3"), [Position(6), Position(4), Position(3)])
        XCTAssertNil(FactBridge.parseFielders(""))
        XCTAssertNil(FactBridge.parseFielders(nil))
    }

    // MARK: 1. Real grammar path → Card A → confirm → next play records

    func test_realPath_groundOut_cardA_confirm_thenNextPlayRecords() async throws {
        let (core, gameId) = try await newRealGame()

        // The ACTUAL facts the app produces — concatenated fielders, no script marker.
        let facts = try await realFacts(for: .groundOut63)
        XCTAssertEqual(facts["batter_result"], "groundout")
        // Bug class: the real grammar emits a CONCATENATED single-digit chain (e.g. "63"/"36"), NOT
        // a dash-separated "6-3". Order is non-deterministic (the out-of-lane parser iterates a dict,
        // tracked separately), so assert the shape — concatenated digits, no dash — not the order.
        let fielders = try XCTUnwrap(facts["fielders"])
        XCTAssertFalse(fielders.contains("-"), "grammar emits concatenated digits, not dash-separated")
        XCTAssertEqual(Set(fielders), Set("63"), "the chain is SS(6) + 1B(3), concatenated")
        XCTAssertEqual(FactBridge.parseFielders(fielders)?.count, 2, "parses to two valid positions")

        // record_play must SUCCEED past position validation (the pre-fix CoreError-4 cause).
        let rec = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: facts, correlationId: "rp-rec-a"
        )
        XCTAssertEqual(rec.needs, .confirm, "clean ground out → Card A")
        XCTAssertNil(rec.judgment)

        let confirmed = try await core.confirmPlay(
            gameId: gameId, confirmsSeq: rec.recordedSeq, ownerId: owner, correlationId: "rp-conf-a"
        )
        XCTAssertEqual(confirmed.state.outs, 1)

        // After confirm, the next real-path play records cleanly (no FR-007 pending block).
        let rec2 = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: facts, correlationId: "rp-rec-a2"
        )
        XCTAssertEqual(rec2.needs, .confirm, "next play records once the prior is confirmed")
    }

    // MARK: 2. Real grammar path → FACT-derived Card B (no script marker) → resolve

    func test_realPath_reachedOnError_factDerivedCardB_resolve() async throws {
        let (core, gameId) = try await newRealGame()

        let facts = try reachedOnErrorFacts()
        XCTAssertEqual(facts["batter_result"], "reached_on_error",
                       "grammar derives reached_on_error from facts")
        XCTAssertNil(facts["script"], "NO WoZ script marker on the real grammar path")

        // The real core must derive a HitVsError JUDGMENT from these FACTS (Card B), not Card A.
        let rec = try await core.recordPlay(
            gameId: gameId, ownerId: owner, normalizedFacts: facts, correlationId: "rp-rec-b"
        )
        XCTAssertEqual(rec.needs, .judgment, "reached-on-error is a fact-derived judgment (Card B)")
        XCTAssertEqual(rec.classification, .judgment(.hitVsError))
        let decision = try XCTUnwrap(rec.judgment)
        XCTAssertEqual(decision.status, .open, "never auto-resolved (I2/SC-003)")

        // Confirm must be blocked while the judgment is open, then succeed once resolved.
        do {
            _ = try await core.confirmPlay(
                gameId: gameId, confirmsSeq: rec.recordedSeq, ownerId: owner, correlationId: "rp-conf-b-early"
            )
            XCTFail("confirm must be blocked while the judgment is open")
        } catch CoreError.judgmentRequired {
            // expected
        }

        let resolved = try await core.resolveJudgment(
            gameId: gameId, decisionId: decision.id, chosen: decision.recommendation.call,
            ownerId: owner, correlationId: "rp-resolve-b"
        )
        XCTAssertEqual(resolved.decision.status, .resolved)
        XCTAssertEqual(resolved.decision.decider?.id, owner)
    }

    // MARK: 2b. Card B via AppState — resolve must ALSO confirm → next play records (P1 fix)

    /// The P1 from PR #148 review: `resolve_judgment` only resolves the decision; it does NOT
    /// confirm the play, so the `PlayRecorded` row stays unconfirmed and `pending_play()` is still
    /// `Some`. The old `AppState.resolveJudgment` cleared `pendingResult` anyway, so the NEXT mic
    /// press hit the core's `PendingConfirmation` guard with no recovery. The fix: resolve THEN
    /// confirm. This drives the real path through `AppState` and asserts the next play records.
    @MainActor
    func test_appState_resolveJudgment_alsoConfirms_thenNextPlayRecords() async throws {
        let appState = AppState(core: DiamondCoreClient())
        appState.devSignIn()
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")

        // reached-on-error → fact-derived Card B (real core, no script marker).
        let facts = try reachedOnErrorFacts()
        await appState.recordPlay(facts: facts)
        guard case .cardB = appState.presentedSheet else {
            return XCTFail("reached-on-error must surface Card B")
        }
        let decision = try XCTUnwrap(appState.activeGame?.pendingResult?.judgment)

        // Resolve via AppState (resolve + confirm). On success the pending clears and the sheet drops.
        await appState.resolveJudgment(decisionId: decision.id, chosen: decision.recommendation.call)
        XCTAssertNil(appState.activeGame?.pendingResult,
                     "after resolve+confirm the play is no longer pending")
        XCTAssertNil(appState.presentedSheet, "Card B dismissed on success")
        XCTAssertNil(appState.presentedError, "no error on the happy path")

        // The crux: the NEXT play must RECORD (not hit PendingConfirmation). Old code orphaned the
        // play here, so this recorded a Card A → the previous behaviour would fail this assertion
        // (record blocked → reopen Card B, or an error banner — never a fresh Card A).
        await appState.recordPlay(facts: ["batter_result": "groundout", "fielders": "63"])
        guard case .cardA = appState.presentedSheet else {
            return XCTFail("next play after resolve+confirm must record a NEW play (Card A), not be blocked")
        }
        XCTAssertNil(appState.presentedError, "next play records cleanly — no PendingConfirmation error")
    }

    // MARK: 2c. Leave PENDING must not orphan the open judgment (P2 fix)

    @MainActor
    func test_appState_deferJudgment_doesNotOrphan_andExplains() async throws {
        let appState = AppState(core: DiamondCoreClient())
        appState.devSignIn()
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")
        await appState.recordPlay(facts: try reachedOnErrorFacts())
        XCTAssertNotNil(appState.activeGame?.pendingResult, "Card B pending")

        // "Leave PENDING" has no core path (resolve requires a chosen call). It must NOT orphan the
        // play (the old MockCore behaviour) — it keeps the pending and explains.
        appState.deferJudgment()
        XCTAssertNotNil(appState.activeGame?.pendingResult, "defer must NOT orphan the open judgment")
        XCTAssertNotNil(appState.presentedError, "defer explains it isn't available")
    }

    // MARK: 3. Record → dismiss-without-confirm → NO orphaned-pending inconsistency

    @MainActor
    func test_appState_dismissWithoutConfirm_doesNotOrphanPendingPlay() async {
        let appState = AppState(core: DiamondCoreClient())
        appState.devSignIn()
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")
        XCTAssertNotNil(appState.activeGame)

        // Record a real-path ground out → Card A.
        await appState.recordPlay(facts: ["batter_result": "groundout", "fielders": "63", "outs_recorded": "1"])
        XCTAssertNotNil(appState.activeGame?.pendingResult, "a play is pending after record")
        if case .cardA = appState.presentedSheet {} else { XCTFail("expected Card A presented") }

        // Simulate the user swiping the sheet away (the old orphan path): sheet onDismiss runs.
        appState.presentedSheet = nil
        appState.handleSheetDismiss()

        // RECONCILIATION: the pending play must NOT be silently dropped — the real core still holds
        // it. The old behavior set pendingResult = nil here (orphaning the core's row).
        XCTAssertNotNil(appState.activeGame?.pendingResult,
                        "dismiss must NOT orphan the pending play (core still holds it)")

        // The user can recover: a mic press reopens the pending card (not a dead-end error, and
        // not a rejected new record_play).
        await appState.recordPlay(facts: ["batter_result": "groundout", "fielders": "63"])
        if case .cardA = appState.presentedSheet {} else {
            XCTFail("mic press with a pending play must REOPEN the card, not record a new play")
        }
        XCTAssertNotNil(appState.activeGame?.pendingResult, "still the same pending play")

        // And confirming it clears it cleanly against the real core.
        await appState.confirmPlay()
        XCTAssertNil(appState.activeGame?.pendingResult, "confirm clears the pending play")
        XCTAssertEqual(appState.activeGame?.state.outs, 1)
    }

    @MainActor
    func test_appState_correctPendingEntry_keepsPendingAndExplains() async {
        let appState = AppState(core: DiamondCoreClient())
        appState.devSignIn()
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")
        await appState.recordPlay(facts: ["batter_result": "groundout", "fielders": "63"])
        XCTAssertNotNil(appState.activeGame?.pendingResult)

        // "Correct" must NOT orphan the play (real core has no pre-confirm replace). It keeps the
        // pending intact and surfaces an explanation.
        let changed = appState.correctPendingEntry()
        XCTAssertFalse(changed, "Correct makes no core state change pre-confirm")
        XCTAssertNotNil(appState.activeGame?.pendingResult, "Correct keeps the pending play")
        XCTAssertNotNil(appState.presentedError, "Correct explains why it can't replace facts yet")
    }

    // MARK: 4. End Game on an incomplete game → graceful, real-reason path

    @MainActor
    func test_appState_endGame_withPendingPlay_doesNotFinalize_reopensCard() async {
        let appState = AppState(core: DiamondCoreClient())
        appState.devSignIn()
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")
        await appState.recordPlay(facts: ["batter_result": "groundout", "fielders": "63"])
        XCTAssertTrue(appState.hasPendingPlay)

        // End Game must NOT drop into export/finalize while a play is pending — it surfaces a clear
        // message and reopens the pending card (graceful, no blind finalize that the core rejects).
        appState.endGame()
        XCTAssertNotNil(appState.presentedError, "End Game explains the incomplete-game blocker")
        if case .export = appState.presentedSheet { XCTFail("must NOT open export with a pending play") }
        if case .cardA = appState.presentedSheet {} else { XCTFail("End Game reopens the pending card") }
    }

    /// End Game on a finalizable (completed/empty) game opens Export and the real core finalizes.
    func test_realCore_finalize_emptyGame_succeeds() async throws {
        let (core, gameId) = try await newRealGame()
        let book = try await core.finalizeScorecard(
            gameId: gameId, ownerId: owner, correlationId: "rp-fin"
        )
        XCTAssertFalse(book.reisnerBook.isEmpty)
    }

    /// The ExportView error mapper turns each real-core finalize reason into a clear, actionable
    /// string — never a generic "something went wrong" (the live ExportView bug).
    func test_exportView_failureMessages_areActionable_notGeneric() {
        let proof = ExportView.finalizeFailureMessage(for: .proofBoxImbalance("inning 1 Top SC-011"))
        XCTAssertTrue(proof.lowercased().contains("half-inning"), "proof-box reason is actionable")
        XCTAssertFalse(proof.lowercased().contains("something went wrong"))

        let pending = ExportView.finalizeFailureMessage(for: .invalidState("FR-007 pending"))
        XCTAssertTrue(pending.lowercased().contains("confirm"), "pending reason tells user to confirm")

        let judgment = ExportView.finalizeFailureMessage(for: .judgmentRequired("open decision"))
        XCTAssertTrue(judgment.lowercased().contains("resolve"), "judgment reason tells user to resolve")
    }
}
