/// ConsentGate.swift — T081 (Squad B, Story B0 / FR-029 / ADR-0016 §4)
///
/// Minimal COPPA age gate. Asked once, persisted in `UserDefaults`. v1 does NOT collect data from
/// under-13 scorers and blocks them from recording; **verified parental consent is deferred** to
/// the backend milestone (verifiable consent is an out-of-band/server process that an offline app
/// cannot perform credibly). This keeps the T070 privacy marker honest rather than decorative.

import Foundation

/// The COPPA age-gate state machine (backed by `UserDefaults`). Used only on the main actor
/// (`AppState`); not `Sendable` because `UserDefaults` isn't, and it never crosses isolation.
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
    private static let respondedKey = "dl.consent.responded"
    private static let under13Key = "dl.consent.under13"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The current gate status, derived from the persisted response.
    public var status: Status {
        guard defaults.bool(forKey: Self.respondedKey) else { return .unknown }
        return defaults.bool(forKey: Self.under13Key) ? .blockedUnder13 : .allowed
    }

    /// Recording is permitted only after an adult (13+) response (FR-029).
    public var recordingAllowed: Bool { status == .allowed }

    /// Record the user's one-time age response.
    public func record(isUnder13: Bool) {
        defaults.set(true, forKey: Self.respondedKey)
        defaults.set(isUnder13, forKey: Self.under13Key)
    }

    #if DEBUG
    /// Reset the gate (dev only — lets the demo re-exercise the flow).
    public func reset() {
        defaults.removeObject(forKey: Self.respondedKey)
        defaults.removeObject(forKey: Self.under13Key)
    }
    #endif
}
