/// DiamondLedgerTests.swift — T003 placeholder (Squad B)
///
/// XCTest target for the iOS app-logic library (T056 offline test, T044 core-wrapper tests, etc.).
///
/// **Test tasks in this target (tasks.md):**
///   - T056 — Offline integrity test: score a full 80–300-play game with no connectivity;
///     assert no data loss (SC-006). Implemented in `OfflineTests.swift`.
///   - Additional integration tests wired at T044 / T071 (MockCore → real core swap).
///
/// **Note on min iOS 26 (SpeechAnalyzer):**
///   Tests that exercise `AppleTranscriber` (T047) require an iOS 26 simulator or device.
///   Run the `ios-build` CI job on an iOS 26 sim (`.github/workflows/ci.yml`, T004).
///
/// - TODO: T056 — add `OfflineTests.swift` (SQLite crash-safe 300-play game, SC-006).
/// - TODO: T071 — add H1 integration tests (MockCore → real UniFFI core swap).

import XCTest
@testable import Core
@testable import Auth
@testable import Persistence

/// Placeholder test case — ensures the test target compiles and the module graph is sound.
/// Replace with real tests at T056 / T071.
final class DiamondLedgerPlaceholderTests: XCTestCase {

    /// Verifies that `AuthStore` is reachable and restores no session from an empty store
    /// (module linkage smoke test). Full owner-identity coverage lives in `T081OwnerIdentityTests`.
    @MainActor
    func testAuthStoreRestoresNilWhenEmpty() async {
        let store = AuthStore(store: InMemorySessionStore())
        let restored = await store.restoreSession()
        XCTAssertNil(restored, "Expected no session when nothing is persisted.")
    }

    /// Verifies that `EventStore` can be instantiated (Persistence module smoke test).
    func testEventStoreInstantiates() async throws {
        let store = EventStore()
        let events = try await store.replay(gameId: "placeholder-game-id")
        XCTAssertTrue(events.isEmpty, "Expected empty replay from placeholder EventStore.")
    }
}

// MARK: - MockCore invariant tests (I2 / I5 — contract documentation)
//
// These tests assert the behavioral invariants that MockCore must uphold and that the real
// UniFFI core will be verified against at H1 (T071). They act as living documentation of:
//   I2 — The core never auto-resolves a judgment; chosen/decider stay nil until the UI taps.
//   I5 — Every mutating primitive rejects an empty ownerId with CoreError.unauthorized.
//
// Marked as stub tests with `XCTExpectFailure` barriers only where the implementation does
// not yet provide the full path — but MockCore IS implemented, so these should pass today.

final class MockCoreInvariantTests: XCTestCase {

    // MARK: I2 — Judgment is surfaced open; never auto-resolved

    /// recordPlay with the misplayed-grounder script marker must return:
    ///   - `needs == .judgment`   (UI must surface Card B)
    ///   - `judgment.status == .open`
    ///   - `judgment.chosen == nil`    (the core never picks a call, I2)
    ///   - `judgment.decider == nil`   (no decider while unresolved, FR-011)
    ///
    /// This verifies the P0 fix: `recordPlay` now returns `RecordPlayResult` (not bare `GameState`),
    /// so `needs` and `judgment` are reachable by the caller without data loss.
    func testRecordPlay_misplayedGrounder_needsJudgmentAndIsOpen() async throws {
        let core = MockCore()
        let result = try await core.recordPlay(
            gameId: "test-game-001",
            ownerId: "owner-123",
            normalizedFacts: ["script": "misplayed-grounder"],
            correlationId: "corr-001"
        )

        // The loop-control must demand judgment (Card B path).
        XCTAssertEqual(result.needs, .judgment,
            "needs must be .judgment for the misplayed-grounder script (FR-010 / Card B)")

        // Classification must be .judgment(.hitVsError).
        if case .judgment(let kind) = result.classification {
            XCTAssertEqual(kind, .hitVsError,
                "classification must be .judgment(.hitVsError) for a misplayed grounder")
        } else {
            XCTFail("classification must be .judgment(...); got \(result.classification)")
        }

        // The judgment must be present and open.
        guard let judgment = result.judgment else {
            XCTFail("judgment must be non-nil when needs == .judgment (I2)")
            return
        }

        XCTAssertEqual(judgment.status, .open,
            "judgment.status must be .open — the core never auto-resolves (I2)")

        // chosen and decider must be nil while open (I2 — UI resolves, never the core).
        XCTAssertNil(judgment.chosen,
            "judgment.chosen must be nil while status is .open (I2: core never picks a call)")
        XCTAssertNil(judgment.decider,
            "judgment.decider must be nil while status is .open (FR-011: decider only present iff resolved)")
    }

    // MARK: I5 — Empty ownerId is unauthorized on all mutating primitives

    /// Every mutating primitive must throw `CoreError.unauthorized` when `ownerId` is empty.
    /// This test covers `createGame`, `recordPlay`, `confirmPlay`, and `resolveJudgment`.
    /// The real core enforces this deterministically (FR-020 / I5); MockCore mirrors it exactly.
    func testMutatingPrimitives_emptyOwnerId_throwsUnauthorized() async {
        let core = MockCore()

        // createGame — Primitive 0
        await assertThrowsUnauthorized(label: "createGame") {
            try await core.createGame(
                homeTeam: "Home", visitorTeam: "Visitor",
                ownerId: "",   // empty — must be rejected
                correlationId: "corr-create"
            )
        }

        // recordPlay — Primitive 1
        await assertThrowsUnauthorized(label: "recordPlay") {
            try await core.recordPlay(
                gameId: "test-game-001",
                ownerId: "",   // empty — must be rejected
                normalizedFacts: ["script": "6-3"],
                correlationId: "corr-record"
            )
        }

        // confirmPlay — Primitive 3b
        await assertThrowsUnauthorized(label: "confirmPlay") {
            try await core.confirmPlay(
                gameId: "test-game-001",
                confirmsSeq: 1,
                ownerId: "",   // empty — must be rejected
                correlationId: "corr-confirm"
            )
        }

        // resolveJudgment — Primitive 3c
        await assertThrowsUnauthorized(label: "resolveJudgment") {
            try await core.resolveJudgment(
                gameId: "test-game-001",
                decisionId: 1,
                chosen: ScoringCall(token: "hit", label: "Hit"),
                ownerId: "",   // empty — must be rejected
                correlationId: "corr-resolve"
            )
        }
    }

    // MARK: - Helpers

    /// Asserts that the async throwing closure throws `CoreError.unauthorized`.
    private func assertThrowsUnauthorized(
        label: String,
        _ body: () async throws -> some Any
    ) async {
        do {
            _ = try await body()
            XCTFail("\(label): expected CoreError.unauthorized for empty ownerId, but call succeeded")
        } catch CoreError.unauthorized {
            // Expected — I5 satisfied.
        } catch {
            XCTFail("\(label): expected CoreError.unauthorized, got \(error)")
        }
    }
}
