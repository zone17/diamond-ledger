/// DevAuth.swift — T081 partial (Squad B, Story B0)
///
/// Development-only auth convenience. Provides a stable `AuthSession` for iteration
/// against MockCore without requiring real sign-in infrastructure.
///
/// IMPORTANT: This file is gated `#if DEBUG` throughout. It MUST NOT be compiled into
/// production builds. Real sign-in (Apple Sign-In + email) is T081.
///
/// The `ownerId` produced here is a stable deterministic string derived from the display
/// name — NOT a real cryptographic identity. It satisfies MockCore's non-empty `ownerId`
/// guard (I5/FR-020) for demo purposes only.

import Foundation

#if DEBUG

public extension AuthStore {

    /// Create a development session without real credentials.
    ///
    /// - Parameter displayName: Human-readable name for the UI; used to derive a stable `ownerId`.
    /// - Returns: An `AuthSession` with a dev-stable `ownerId` and `.email` sign-in method.
    ///
    /// WARNING: This session's `ownerId` is NOT cryptographically tied to a real credential.
    /// It satisfies MockCore's authority check only. Never ship this to production.
    @discardableResult
    func devSignIn(displayName: String) async -> AuthSession {
        let slug = displayName
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: "-")
        let ownerId = "dev-owner-\(slug)"
        let session = AuthSession(ownerId: ownerId, displayName: displayName, signInMethod: .email)
        // AuthStore's `_session` is internal; callers hold the session in AppState.
        return session
    }
}

#endif
