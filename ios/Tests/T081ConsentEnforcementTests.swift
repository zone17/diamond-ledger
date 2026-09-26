/// T081ConsentEnforcementTests.swift — T081 review follow-up (FR-029 / ADR-0016 §4)
///
/// Device-independent coverage for the COPPA enforcement seam in `AppState` — the half of the age
/// gate that lives above `ConsentGate` and was previously untested: the `createGame` /
/// `recordPlay` guards, the under-13 PII purge, and the DEBUG dev-sign-in shortcut's blast radius.
///
/// These use `MockCore` and injected stores (`InMemorySessionStore`, a throwaway `UserDefaults`
/// suite), so nothing here touches the real Keychain, the real user defaults, or the Apple sheet.
///
/// - SeeAlso: `ios/Sources/UI/App/AppState.swift`, `ios/Sources/Auth/ConsentGate.swift`
/// - SeeAlso: `specs/001-voice-scorebook-core/contracts/owner_identity.md`

import XCTest
@testable import Core
@testable import UI
import Auth

@MainActor
final class T081ConsentEnforcementTests: XCTestCase {

    /// A fully isolated AppState: mock core, in-memory Keychain stand-in, throwaway defaults suite.
    private func makeAppState() -> (AppState, InMemorySessionStore) {
        let store = InMemorySessionStore()
        let defaults = UserDefaults(suiteName: "test.consent.\(UUID().uuidString)")!
        let appState = AppState(core: MockCore(),
                                consentDefaults: defaults,
                                authStore: AuthStore(store: store))
        return (appState, store)
    }

    private func childName() -> PersonNameComponents {
        var name = PersonNameComponents()
        name.givenName = "Sam"
        name.familyName = "Rivera"
        return name
    }

    // MARK: - The createGame age gate (FR-029 defense-in-depth)

    /// Routing hides the UI, but the guard is the real invariant: a signed-in owner who has not
    /// answered the gate must not be able to start recording a game.
    func test_createGame_refusedWhileAgeGateUnanswered() async throws {
        let (appState, _) = makeAppState()
        try appState.completeAppleSignIn(appleUserID: "adult-1", fullName: nil)
        XCTAssertEqual(appState.consentStatus, .unknown)

        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")

        XCTAssertNil(appState.activeGame, "no game may start before the age gate is answered")
        XCTAssertNotNil(appState.presentedError, "the refusal must be explained, not silent")
    }

    func test_createGame_refusedForUnder13Owner() async throws {
        let (appState, _) = makeAppState()
        try appState.completeAppleSignIn(appleUserID: "child-1", fullName: nil)
        appState.recordAgeResponse(isUnder13: true)

        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")

        XCTAssertNil(appState.activeGame, "an under-13 owner must not be able to record")
        XCTAssertNotNil(appState.presentedError)
    }

    func test_createGame_allowedAfterAdultAnswer() async throws {
        let (appState, _) = makeAppState()
        try appState.completeAppleSignIn(appleUserID: "adult-1", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)

        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")

        XCTAssertNotNil(appState.activeGame, "a 13+ owner records normally")
        XCTAssertNil(appState.presentedError)
    }

    /// The contract names `recordPlay` explicitly, not just game creation. Reaching it without a
    /// satisfied gate must record nothing even if an active game somehow exists.
    func test_recordPlay_refusedWhenGateNotSatisfied() async throws {
        let (appState, _) = makeAppState()
        try appState.completeAppleSignIn(appleUserID: "adult-1", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")
        XCTAssertNotNil(appState.activeGame)

        // The owner's answer is revoked out from under the active game (the shape a future
        // persisted/restored game could produce).
        appState.recordAgeResponse(isUnder13: true)
        await appState.recordPlay(facts: ["play_type": "single"])

        XCTAssertNil(appState.activeGame?.pendingResult, "no play may be recorded through a closed gate")
    }

    // MARK: - Under-13 PII purge (the "No under-13 PII stored" claim)

    /// Sign-in necessarily persists `{ownerId, displayName}` before the gate can be shown. The
    /// moment the user says they are under 13, that persisted record — a child's real name plus a
    /// persistent identifier — must be purged, not left for them to clear voluntarily.
    func test_under13Answer_purgesPersistedSession() async throws {
        let (appState, store) = makeAppState()
        try appState.completeAppleSignIn(appleUserID: "child-1", fullName: childName())
        XCTAssertNotNil(store.load(), "precondition: sign-in persists before the gate is shown")

        appState.recordAgeResponse(isUnder13: true)

        XCTAssertNil(store.load(), "a known under-13 owner must leave no persisted identity")
        XCTAssertEqual(appState.consentStatus, .blockedUnder13)
        XCTAssertNotNil(appState.session, "the in-memory session still drives Under13BlockedView")
    }

    /// The purge must hold on every later sign-in by that same child, not only the first answer.
    func test_under13Owner_signingInAgain_doesNotLeavePersistedSession() async throws {
        let (appState, store) = makeAppState()
        try appState.completeAppleSignIn(appleUserID: "child-1", fullName: childName())
        appState.recordAgeResponse(isUnder13: true)
        appState.signOut()

        try appState.completeAppleSignIn(appleUserID: "child-1", fullName: childName())

        XCTAssertEqual(appState.consentStatus, .blockedUnder13, "the block is remembered for this owner")
        XCTAssertNil(store.load(), "re-signing in must not re-persist a known child's identity")
    }

    func test_adultAnswer_keepsPersistedSession() async throws {
        let (appState, store) = makeAppState()
        try appState.completeAppleSignIn(appleUserID: "adult-1", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)

        XCTAssertNotNil(store.load(), "a 13+ owner stays signed in across launches")
        XCTAssertTrue(appState.recordingAllowed)
    }

    // MARK: - Sign-out and the DEBUG shortcut

    func test_signOut_clearsConsentStatusSoTheNextOwnerIsAsked() async throws {
        let (appState, _) = makeAppState()
        try appState.completeAppleSignIn(appleUserID: "adult-1", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)
        XCTAssertEqual(appState.consentStatus, .allowed)

        appState.signOut()
        XCTAssertEqual(appState.consentStatus, .unknown, "no signed-in owner, no standing answer")

        try appState.completeAppleSignIn(appleUserID: "other-1", fullName: nil)
        XCTAssertEqual(appState.consentStatus, .unknown, "a different owner is asked their own age")
        XCTAssertFalse(appState.recordingAllowed)
    }

    #if DEBUG
    /// The dev shortcut may bypass the gate for its own stub owner, but that bypass must not
    /// survive into a real Apple sign-in in the same launch.
    func test_devSignIn_consentDoesNotLeakToARealOwner() async throws {
        let (appState, _) = makeAppState()
        appState.devSignIn()
        XCTAssertTrue(appState.recordingAllowed, "the dev shortcut still skips the gate for itself")

        appState.signOut()
        try appState.completeAppleSignIn(appleUserID: "adult-1", fullName: nil)

        XCTAssertEqual(appState.consentStatus, .unknown, "the real owner must still be asked")
        XCTAssertFalse(appState.recordingAllowed)
    }
    #endif
}
