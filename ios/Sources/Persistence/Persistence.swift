/// Persistence.swift — T003 placeholder (Squad B, Story B7)
///
/// SQLite / GRDB append-only event log + replayed projections (T055).
/// CloudKit private-DB sync stub (T058, post-MVP).
///
/// **Storage model (plan.md / data-model.md):**
///   - Single append-only `events` table; state is derived by replaying events (never mutated).
///   - Supports a full 80–300-play game with no connectivity (SC-006 / FR-021).
///   - Crash-safe: every write is an atomic SQLite transaction.
///   - Private by default: data stays on-device; CloudKit sync is an explicit owner action (FR-023).
///   - No raw audio is written to any persistent store (FR-022 / COPPA).
///
/// **GRDB integration note:** The `GRDB` dependency is declared (commented) in `Package.swift`.
/// Uncomment when integrating at T055.
///
/// - TODO: T055 — implement `EventStore` with GRDB append-only `events` table.
/// - TODO: T056 — offline integrity test (80–300 plays, crash-safe, SC-006).
/// - TODO: T058 — `CloudKitSync` (post-MVP, LWW, no CRDTs — Art. XXXVII).

import Foundation

// MARK: - Placeholder types (T055)

/// A durable, ordered event appended to the event log.
/// Full schema defined in `core/src/eventlog/` (T013) and the FFI surface (T007).
/// TODO: T055 — replace with the generated UniFFI event type at H1 (T071).
public struct StoredEvent: Sendable, Codable {
    public let sequenceNumber: Int64
    public let gameId: String
    public let payload: Data  // JSON-encoded FFI event from the Rust core
    public let recordedAt: Date
}

/// Manages the append-only SQLite event log for a single game.
/// TODO: T055 — implement with GRDB; this is a compile-time placeholder only.
public actor EventStore {
    // TODO: T055 — inject a GRDB `DatabaseQueue` here.
    public init() {}

    /// Append a new event to the log (atomic, idempotent on duplicate sequence numbers).
    /// TODO: T055 — implement.
    public func append(_ event: StoredEvent) async throws {
        // Placeholder — no-op until T055.
    }

    /// Replay all events for `gameId` in sequence order.
    /// TODO: T055 — implement.
    public func replay(gameId: String) async throws -> [StoredEvent] {
        return []
    }
}
