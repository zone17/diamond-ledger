/// T081OwnerIdentityTests.swift — T081 (Squad B, Story B0 / ADR-0016)
///
/// Device-independent coverage for the owner-identity slice: `ownerId` derivation, Keychain-store
/// round-trip (via the in-memory store), the establish/restore plumbing, and the COPPA age gate.
/// The full Sign-in-with-Apple sheet and the live Apple credential-state check are device-gated
/// (real Apple ID + Xcode 26) and are verified on device, per the contract.
///
/// - SeeAlso: `ios/Sources/Auth/Auth.swift` (AuthStore), `KeychainSessionStore.swift`,
///   `ConsentGate.swift`; `specs/001-voice-scorebook-core/contracts/owner_identity.md`.

import XCTest
import Auth

@MainActor
final class T081OwnerIdentityTests: XCTestCase {

    // MARK: - ownerId derivation (ADR-0016)

    func testOwnerIdIsAppleNamespaced() {
        XCTAssertEqual(AuthStore.ownerId(forAppleUserID: "001234.abcd"), "apple:001234.abcd")
    }

    // MARK: - Session persistence

    func testSessionCodableRoundTrip() throws {
        let session = AuthSession(ownerId: "apple:u1", displayName: "Pat", signInMethod: .apple)
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(AuthSession.self, from: data)
        XCTAssertEqual(session, restored)
    }

    func testInMemoryStoreRoundTrip() throws {
        let store = InMemorySessionStore()
        XCTAssertNil(store.load())
        let session = AuthSession(ownerId: "apple:u1", displayName: "Pat", signInMethod: .apple)
        try store.save(session)
        XCTAssertEqual(store.load(), session)
        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: - AuthStore establish / restore

    func testEstablishAppleSessionTrimsAndPersistsOwner() throws {
        let store = InMemorySessionStore()
        let auth = AuthStore(store: store)
        let session = try auth.establishAppleSession(appleUserID: "  001.xyz  ", fullName: nil)
        XCTAssertEqual(session.ownerId, "apple:001.xyz")   // trimmed + namespaced
        XCTAssertEqual(session.signInMethod, .apple)
        XCTAssertEqual(session.displayName, "Scorer")       // no name → default
        XCTAssertEqual(store.load()?.ownerId, "apple:001.xyz")  // persisted
    }

    func testEstablishRejectsEmptyAppleUser() {
        let auth = AuthStore(store: InMemorySessionStore())
        XCTAssertThrowsError(try auth.establishAppleSession(appleUserID: "   ", fullName: nil)) { error in
            guard case AuthError.invalidCredentials = error else {
                return XCTFail("expected .invalidCredentials, got \(error)")
            }
        }
    }

    func testRestoreReturnsNilWhenNoSession() async {
        let auth = AuthStore(store: InMemorySessionStore())
        let restored = await auth.restoreSession()
        XCTAssertNil(restored)
    }

    /// A reserved-method (.email) session restores without an Apple credential-state check — this
    /// exercises the restore plumbing without the device-gated Apple call.
    func testRestoreReturnsReservedMethodSessionWithoutAppleCheck() async throws {
        let store = InMemorySessionStore()
        try store.save(AuthSession(ownerId: "email:u1", displayName: "Sam", signInMethod: .email))
        let auth = AuthStore(store: store)
        let restored = await auth.restoreSession()
        XCTAssertEqual(restored?.ownerId, "email:u1")
    }

    func testSignOutClearsStore() throws {
        let store = InMemorySessionStore()
        let auth = AuthStore(store: store)
        _ = try auth.establishAppleSession(appleUserID: "u1", fullName: nil)
        XCTAssertNotNil(store.load())
        auth.signOut()
        XCTAssertNil(store.load())
    }

    // MARK: - COPPA age gate (FR-029)

    private func freshGate() -> ConsentGate {
        let defaults = UserDefaults(suiteName: "test.consent.\(UUID().uuidString)")!
        return ConsentGate(defaults: defaults)
    }

    func testConsentGateStartsUnknownAndBlocksRecording() {
        let gate = freshGate()
        XCTAssertEqual(gate.status, .unknown)
        XCTAssertFalse(gate.recordingAllowed)
    }

    func testConsentGateAdultAllowsRecordingAndPersists() {
        let defaults = UserDefaults(suiteName: "test.consent.\(UUID().uuidString)")!
        ConsentGate(defaults: defaults).record(isUnder13: false)
        let reloaded = ConsentGate(defaults: defaults)   // new instance, same store
        XCTAssertEqual(reloaded.status, .allowed)
        XCTAssertTrue(reloaded.recordingAllowed)
    }

    func testConsentGateUnder13BlocksRecording() {
        let gate = freshGate()
        gate.record(isUnder13: true)
        XCTAssertEqual(gate.status, .blockedUnder13)
        XCTAssertFalse(gate.recordingAllowed)
    }
}
