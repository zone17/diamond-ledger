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

    /// An `.apple` session whose `ownerId` lost its `apple:` namespace is corrupt — restore must
    /// clear it rather than hand back an identity whose provenance can no longer be proven
    /// (ADR-0016: "namespaced by method so provenance is auditable"). This branch runs entirely
    /// before the device-gated credential-state call, so it is verifiable off-device.
    func testRestoreClearsMalformedAppleSession() async throws {
        let store = InMemorySessionStore()
        try store.save(AuthSession(ownerId: "not-apple-namespaced",
                                   displayName: "Pat",
                                   signInMethod: .apple))
        let auth = AuthStore(store: store)
        let restored = await auth.restoreSession()
        XCTAssertNil(restored, "a malformed .apple session must not restore")
        XCTAssertNil(store.load(), "the corrupt item must be cleared, not left to retry forever")
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

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.consent.\(UUID().uuidString)")!
    }

    private func freshGate(owner: String = "apple:owner") -> ConsentGate {
        ConsentGate(ownerId: owner, defaults: freshDefaults())
    }

    func testConsentGateStartsUnknownAndBlocksRecording() {
        let gate = freshGate()
        XCTAssertEqual(gate.status, .unknown)
        XCTAssertFalse(gate.recordingAllowed)
    }

    func testConsentGateAdultAllowsRecordingAndPersists() {
        let defaults = freshDefaults()
        ConsentGate(ownerId: "apple:u1", defaults: defaults).record(isUnder13: false)
        let reloaded = ConsentGate(ownerId: "apple:u1", defaults: defaults)  // new instance, same store
        XCTAssertEqual(reloaded.status, .allowed)
        XCTAssertTrue(reloaded.recordingAllowed)
    }

    func testConsentGateUnder13BlocksRecording() {
        let gate = freshGate()
        gate.record(isUnder13: true)
        XCTAssertEqual(gate.status, .blockedUnder13)
        XCTAssertFalse(gate.recordingAllowed)
    }

    /// The answer binds to the owner, not the device (FR-029). On a shared family device, one
    /// adult's "13 or older" must never pre-answer the gate for a child who signs in afterwards.
    func testConsentAnswerDoesNotLeakBetweenOwners() {
        let defaults = freshDefaults()   // one device
        ConsentGate(ownerId: "apple:adult", defaults: defaults).record(isUnder13: false)

        let child = ConsentGate(ownerId: "apple:child", defaults: defaults)
        XCTAssertEqual(child.status, .unknown, "a second owner must be asked their own age")
        XCTAssertFalse(child.recordingAllowed)
    }

    /// The reverse leak: a child's answer must block only that child — a later adult on the same
    /// device is asked normally — while still blocking the child on every later sign-in.
    func testUnder13BlockIsScopedToItsOwnerAndSurvivesReSignIn() {
        let defaults = freshDefaults()
        ConsentGate(ownerId: "apple:child", defaults: defaults).record(isUnder13: true)

        XCTAssertEqual(ConsentGate(ownerId: "apple:child", defaults: defaults).status, .blockedUnder13,
                       "the block must survive the child signing in again")
        XCTAssertEqual(ConsentGate(ownerId: "apple:adult", defaults: defaults).status, .unknown,
                       "a different owner must not inherit the block")
    }
}
