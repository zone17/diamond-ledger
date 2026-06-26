/// KeychainSessionStore.swift — T081 (Squad B, Story B0 / ADR-0016)
///
/// Persistence for the authenticated `AuthSession` behind `AuthStore`. A protocol so tests and
/// previews can inject an in-memory store; the production store is Keychain-backed.
///
/// The Keychain item is **device-scoped** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`):
/// available offline after first unlock, never written to iCloud Keychain or device backups. No
/// password and no email are stored — only the opaque `ownerId`, display name, and method
/// (ADR-0016 threat model).

import Foundation
import Security

/// Where an `AuthSession` is persisted between launches.
public protocol SessionStore: Sendable {
    func save(_ session: AuthSession) throws
    func load() -> AuthSession?
    func clear()
}

/// Keychain-backed `SessionStore`. Stores a JSON-encoded `AuthSession` as a single generic-password
/// item keyed by `(service, account)`.
public struct KeychainSessionStore: SessionStore {
    private let service: String
    private let account: String

    public init(service: String = "app.diamondledger.session", account: String = "owner") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ session: AuthSession) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(session)
        } catch {
            throw AuthError.persistenceFailed("encode: \(error.localizedDescription)")
        }
        // Replace any existing item (idempotent re-sign-in).
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.persistenceFailed("keychain add failed (OSStatus \(status))")
        }
    }

    public func load() -> AuthSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let session = try? JSONDecoder().decode(AuthSession.self, from: data)
        else {
            return nil
        }
        return session
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// In-memory `SessionStore` for tests and previews. Not for production — no persistence across
/// launches. Thread-safe so it can be passed across isolation boundaries.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private var session: AuthSession?
    private let lock = NSLock()

    public init(session: AuthSession? = nil) { self.session = session }

    public func save(_ session: AuthSession) throws {
        lock.lock(); defer { lock.unlock() }
        self.session = session
    }

    public func load() -> AuthSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        session = nil
    }
}
