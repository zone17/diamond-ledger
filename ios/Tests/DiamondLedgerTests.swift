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

    /// Verifies that `AuthStore.shared` is reachable (module linkage smoke test).
    func testAuthStoreIsAccessible() async {
        let store = AuthStore.shared
        let session = await store.session
        // No session until T081 is implemented.
        XCTAssertNil(session, "Expected no session before T081 sign-in is implemented.")
    }

    /// Verifies that `EventStore` can be instantiated (Persistence module smoke test).
    func testEventStoreInstantiates() async throws {
        let store = EventStore()
        let events = try await store.replay(gameId: "placeholder-game-id")
        XCTAssertTrue(events.isEmpty, "Expected empty replay from placeholder EventStore.")
    }
}
