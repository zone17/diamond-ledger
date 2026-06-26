/// Auth.swift — T003 / T081 placeholder (Squad B, Story B0)
///
/// Email + social sign-in; private-by-default account/owner identity (T081 / FR-028 / FR-020 / I5).
///
/// **Why this must be real at MVP (remediation G1/G2, tasks.md Story B0):**
///   The owner-as-decider authority assertion in the Rust core (T036 / FR-020 / I5) binds to an
///   authenticated owner identity supplied by this module. An anonymous stub does NOT satisfy the
///   authority or privacy claims. A minimal real sign-in (email or social) is the MVP requirement;
///   a placeholder token is acceptable only during development against `MockCore` (T008).
///
/// **Sign-in methods (FR-028):**
///   - Email + password (primary — no third-party dependency required for MVP)
///   - Social (Apple Sign-In mandatory for App Store; Google/other optional fast-follow)
///
/// **Private-by-default (FR-023):**
///   A scorebook is private to the authenticated owner until an explicit share action (T082).
///   The `ownerId` returned by `AuthSession` is the identity passed to every `CoreClient` primitive.
///
/// **COPPA (FR-029 / Art. XXVI):**
///   Age-gating + consent flow required before any data is recorded. No under-13 PII stored.
///
/// - SeeAlso: `ios/Sources/Core/CoreClient.swift` — `ownerId` used in every primitive call.
/// - SeeAlso: `ios/Sources/UI/Share/` (T082, post-MVP) — explicit share action.
/// - SeeAlso: `specs/001-voice-scorebook-core/contracts/owner_identity.md` — the contract.
/// - Decision: ADR-0016 — v1 is on-device Sign in with Apple; email/Google deferred to the
///   backend (an offline app has nothing to verify a password against).

import Foundation
import AuthenticationServices

// MARK: - Auth session

/// An authenticated session for a signed-in owner.
///
/// `ownerId` is the stable identity that the Rust core's authority assertion validates against
/// (FR-020 / T036). It MUST be cryptographically tied to the sign-in credential —
/// a bare UUID generated client-side is NOT acceptable for the authority claim.
///
/// Persisted in the Keychain by `KeychainSessionStore` (Codable); restored on launch (ADR-0016).
public struct AuthSession: Sendable, Codable, Equatable {
    /// Stable owner identity, passed to every `CoreClient` primitive call.
    public let ownerId: String
    /// Display name for UI (not used for authority decisions).
    public let displayName: String
    /// Sign-in method used to establish this session.
    public let signInMethod: SignInMethod

    public init(ownerId: String, displayName: String, signInMethod: SignInMethod) {
        self.ownerId = ownerId
        self.displayName = displayName
        self.signInMethod = signInMethod
    }
}

/// The authentication method used to establish an `AuthSession`.
public enum SignInMethod: String, Sendable, Codable {
    /// Email + password (primary MVP path).
    case email
    /// Apple Sign-In (required for App Store distribution).
    case apple
    /// Google Sign-In (optional fast-follow).
    case google
}

// MARK: - Auth errors

public enum AuthError: Error, Sendable {
    /// The user is not signed in; a `CoreClient` primitive call cannot proceed.
    case notAuthenticated
    /// Sign-in credentials were rejected.
    case invalidCredentials(String)
    /// COPPA consent has not been completed (FR-029).
    case coppaConsentRequired
    /// The sign-in method is not available on this device.
    case methodUnavailable(SignInMethod)
    /// The user dismissed the sign-in flow (not an error to surface loudly).
    case cancelled
    /// The session could not be persisted to / cleared from the Keychain.
    case persistenceFailed(String)
}

// MARK: - AuthStore

/// Establishes and persists the authenticated owner session (T081 / ADR-0016).
///
/// v1 authentication is **on-device Sign in with Apple**: the stable, app+team-scoped
/// `ASAuthorizationAppleIDCredential.user` becomes `ownerId = "apple:<user>"`, persisted in the
/// Keychain so the owner survives launches. The Rust core *validates* this `ownerId` for authority
/// (FR-020/I5) but never *authenticates* it — that is this type's job. Email/Google are deferred
/// to the sync/backend milestone (ADR-0016 §3); an offline app has no backend to verify a password.
///
/// `@MainActor`: sign-in is a UI flow and the session is consumed by the `@MainActor` `AppState`.
@MainActor
public final class AuthStore {
    public static let shared = AuthStore()

    private let store: SessionStore

    /// - Parameter store: session persistence (defaults to the Keychain-backed store; tests inject
    ///   `InMemorySessionStore`).
    public init(store: SessionStore = KeychainSessionStore()) {
        self.store = store
    }

    /// The Apple-credential namespace prefix for a v1 `ownerId`.
    public static let appleOwnerPrefix = "apple:"

    /// Derive the stable owner identity from an Apple credential user id (ADR-0016). Namespaced by
    /// method so provenance is auditable and method namespaces can never collide.
    public static func ownerId(forAppleUserID userID: String) -> String {
        "\(appleOwnerPrefix)\(userID)"
    }

    /// Establish (and persist) a session from a completed Sign-in-with-Apple authorization.
    ///
    /// - Parameters:
    ///   - appleUserID: `ASAuthorizationAppleIDCredential.user` — stable, app+team-scoped, opaque.
    ///   - fullName: optional name from the first authorization (Apple sends it only once).
    /// - Returns: the persisted `AuthSession`.
    /// - Throws: `.invalidCredentials` (empty user id) or `.persistenceFailed` (Keychain).
    @discardableResult
    public func establishAppleSession(appleUserID: String,
                                      fullName: PersonNameComponents?) throws -> AuthSession {
        let trimmed = appleUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AuthError.invalidCredentials("empty Apple user id") }

        let session = AuthSession(ownerId: Self.ownerId(forAppleUserID: trimmed),
                                  displayName: Self.displayName(from: fullName),
                                  signInMethod: .apple)
        try store.save(session)
        return session
    }

    /// Restore a persisted session on launch. For an Apple session, verify the credential is still
    /// valid; a revoked/absent credential signs the user out (clears storage, returns `nil`).
    public func restoreSession() async -> AuthSession? {
        guard let session = store.load() else { return nil }
        switch session.signInMethod {
        case .apple:
            guard session.ownerId.hasPrefix(Self.appleOwnerPrefix) else {
                store.clear()
                return nil
            }
            let userID = String(session.ownerId.dropFirst(Self.appleOwnerPrefix.count))
            let state = await Self.appleCredentialState(forUserID: userID)
            if state == .authorized { return session }
            store.clear()
            return nil
        case .email, .google:
            // Reserved (ADR-0016 follow-up a) — no local credential to re-verify yet.
            return session
        }
    }

    /// Sign out: clear the persisted session.
    public func signOut() {
        store.clear()
    }

    // MARK: - Helpers

    private static func displayName(from name: PersonNameComponents?) -> String {
        guard let name else { return "Scorer" }
        let formatted = PersonNameComponentsFormatter().string(from: name)
        return formatted.isEmpty ? "Scorer" : formatted
    }

    private static func appleCredentialState(
        forUserID userID: String
    ) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }
}
