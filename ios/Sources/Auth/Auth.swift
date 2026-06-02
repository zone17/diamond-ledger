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
/// - TODO: T081 — implement email + Apple Sign-In; establish authenticated `ownerId`;
///   wire COPPA consent flow (FR-029); wire private-by-default posture (T055 / FR-023).

import Foundation

// MARK: - Auth session

/// An authenticated session for a signed-in owner.
///
/// `ownerId` is the stable identity that the Rust core's authority assertion validates against
/// (FR-020 / T036). It MUST be cryptographically tied to the sign-in credential —
/// a bare UUID generated client-side is NOT acceptable for the authority claim.
///
/// TODO: T081 — replace with a real signed-in session (Keychain-backed).
public struct AuthSession: Sendable {
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
}

// MARK: - AuthStore placeholder

/// Manages the current `AuthSession`.
///
/// TODO: T081 — implement with Keychain-backed credential storage + Apple Sign-In entitlement.
/// Until T081 lands, callers in development may use a development-only stub session
/// (never shipped to production — gated by a `#if DEBUG` or scheme flag).
public actor AuthStore {
    public static let shared = AuthStore()

    private var _session: AuthSession?

    private init() {}

    /// The currently authenticated session, or `nil` if not signed in.
    public var session: AuthSession? { _session }

    /// Sign in with email + password.
    /// TODO: T081 — implement.
    public func signIn(email: String, password: String) async throws -> AuthSession {
        throw AuthError.notAuthenticated  // Placeholder — T081.
    }

    /// Sign in with Apple Sign-In.
    /// TODO: T081 — implement (requires `com.apple.developer.applesignin` entitlement).
    public func signInWithApple() async throws -> AuthSession {
        throw AuthError.methodUnavailable(.apple)  // Placeholder — T081.
    }

    /// Sign out, clearing the stored session.
    /// TODO: T081 — implement (clear Keychain credential + notify UI).
    public func signOut() async {
        _session = nil
    }
}
