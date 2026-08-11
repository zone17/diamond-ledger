/// ConsentGate.swift — T081 (Squad B, Story B0 / FR-029 / ADR-0016 §4)
///
/// Minimal COPPA age gate. Asked once **per owner**, persisted in `UserDefaults`. v1 does NOT
/// collect data from under-13 scorers and blocks them from recording; **verified parental consent
/// is deferred** to the backend milestone (verifiable consent is an out-of-band/server process an
/// offline app cannot perform credibly). This keeps the T070 privacy marker honest, not decorative.
///
/// **The answer binds to the owner, not the device.** A device-global answer leaked one owner's
/// response to the next: on a shared family device an adult's "13 or older" would silently
/// pre-answer the gate for a child who signed in afterwards, and a child's answer would
/// permanently block every later adult. Keying by `ownerId` asks each owner exactly once and makes
/// an under-13 block survive that child signing in again.

import Foundation

/// The COPPA age-gate state machine for one owner (backed by `UserDefaults`). Used only on the main
/// actor (`AppState`); not `Sendable` because `UserDefaults` isn't, and it never crosses isolation.
public struct ConsentGate {

    public enum Status: String, Sendable {
        /// The age gate has not been answered yet — recording is blocked until it is.
        case unknown
        /// The user affirmed they are 13 or older — recording is allowed.
        case allowed
        /// The user is under 13 — recording is blocked pending the deferred consent flow.
        case blockedUnder13
    }

    private let defaults: UserDefaults
    private let ownerId: String

    /// Per-owner keys. Owners who answered under the earlier device-global keys are simply asked
    /// once more, which is the fail-safe direction — a stale answer can never auto-allow.
    private var respondedKey: String { "dl.consent.responded.\(ownerId)" }
    private var under13Key: String { "dl.consent.under13.\(ownerId)" }

    /// - Parameters:
    ///   - ownerId: the authenticated owner this answer belongs to (`AuthSession.ownerId`).
    ///   - defaults: backing store (tests inject a throwaway suite).
    public init(ownerId: String, defaults: UserDefaults = .standard) {
        self.ownerId = ownerId
        self.defaults = defaults
    }

    /// This owner's current gate status, derived from their persisted response.
    public var status: Status {
        guard defaults.bool(forKey: respondedKey) else { return .unknown }
        return defaults.bool(forKey: under13Key) ? .blockedUnder13 : .allowed
    }

    /// Recording is permitted only after an adult (13+) response (FR-029).
    public var recordingAllowed: Bool { status == .allowed }

    /// Record this owner's one-time age response.
    public func record(isUnder13: Bool) {
        defaults.set(true, forKey: respondedKey)
        defaults.set(isUnder13, forKey: under13Key)
    }

    #if DEBUG
    /// Reset this owner's gate (dev only — lets the demo re-exercise the flow).
    public func reset() {
        defaults.removeObject(forKey: respondedKey)
        defaults.removeObject(forKey: under13Key)
    }
    #endif
}
