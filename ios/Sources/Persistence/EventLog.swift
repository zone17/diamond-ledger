/// EventLog.swift — T055 (Squad B, Story B7)
///
/// Event-log store protocol + in-memory implementation for offline play.
///
/// Design (plan.md / data-model.md):
///   - Single append-only `events` table; state is derived by replaying events (never mutated).
///   - Supports a full 80–300-play game with no connectivity (SC-006 / FR-021).
///   - Crash-safe: every write is an atomic SQLite transaction (real GRDB impl, later increment).
///   - Private by default: data stays on-device; CloudKit sync is a later increment (T058).
///   - No raw audio is written to any persistent store (FR-022 / COPPA).
///
/// This increment:
///   - `EventLogStore` protocol (the seam) — defines the interface both the in-memory impl
///     and the future GRDB impl must satisfy.
///   - `InMemoryEventLog` — a working offline store that satisfies the protocol and lets the
///     demo loop work without a real SQLite database. Survives the session; not persisted to disk.
///   - `FileEventLog` — a minimal JSON-file-backed store for minimal offline durability.
///     Not crash-safe; replaced by the GRDB implementation at T055 full.
///
/// Full GRDB / CloudKit implementation is a later increment (T055/T058). The seam is defined
/// here so all callers code to `EventLogStore` and the swap is a one-line injection change.

import Foundation

// MARK: - Event log entry

/// A logged event in the game's append-only event log.
///
/// `payload` is the JSON-encoded result from a `CoreClient` primitive call.
/// At H1 this will be the generated UniFFI event type; for now it is raw JSON data.
public struct GameEvent: Sendable, Codable, Identifiable {
    public let id: UUID
    /// Monotonic per-game sequence number (mirrors `ffi::Seq`).
    public let seq: UInt64
    public let gameId: String
    /// Event type keyword: "GameStarted", "PlayRecorded", "PlayConfirmed", "JudgmentResolved".
    public let eventType: String
    /// JSON-encoded event payload (CoreClient result type).
    public let payload: Data
    public let recordedAt: Date

    public init(seq: UInt64, gameId: String, eventType: String, payload: Data) {
        self.id = UUID()
        self.seq = seq
        self.gameId = gameId
        self.eventType = eventType
        self.payload = payload
        self.recordedAt = Date()
    }
}

// MARK: - EventLogStore protocol

/// The append-only event log seam.
///
/// Conformers: `InMemoryEventLog` (this increment), `GRDBEventLog` (T055 full increment).
/// All callers code to this protocol — swapping the backing store is a one-line injection change.
public protocol EventLogStore: Sendable {
    /// Append a new event atomically (idempotent on duplicate `seq` for the same `gameId`).
    func append(_ event: GameEvent) async throws

    /// Replay all events for `gameId` in ascending `seq` order.
    func replay(gameId: String) async throws -> [GameEvent]

    /// The highest `seq` currently recorded for `gameId` (nil if no events yet).
    func latestSeq(gameId: String) async -> UInt64?
}

// MARK: - InMemoryEventLog

/// A working in-memory event log for the demo and offline play against MockCore.
///
/// Not persisted to disk — survives the current process only. Replaced by `GRDBEventLog`
/// at the T055 full increment for crash-safe offline durability (SC-006).
public actor InMemoryEventLog: EventLogStore {

    private var events: [String: [GameEvent]] = [:]  // keyed by gameId

    public init() {}

    public func append(_ event: GameEvent) async throws {
        var log = events[event.gameId, default: []]
        // Idempotent: skip if already present (same seq + gameId).
        guard !log.contains(where: { $0.seq == event.seq }) else { return }
        log.append(event)
        log.sort { $0.seq < $1.seq }
        events[event.gameId] = log
    }

    public func replay(gameId: String) async throws -> [GameEvent] {
        events[gameId, default: []]
    }

    public func latestSeq(gameId: String) async -> UInt64? {
        events[gameId]?.last?.seq
    }
}

// MARK: - FileEventLog

/// Minimal JSON-file-backed event log for lightweight offline durability.
///
/// Writes are NOT atomic (not crash-safe). This is a step up from in-memory for development;
/// it is NOT the SC-006 offline-safe store. Use `GRDBEventLog` (T055 full) for production.
///
/// File layout: one JSON array per game, at `{documentsDirectory}/{gameId}.json`.
public actor FileEventLog: EventLogStore {

    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diamond-ledger-events", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(gameId: String) -> URL {
        directory.appendingPathComponent("\(gameId).json")
    }

    public func append(_ event: GameEvent) async throws {
        try ensureDirectory()
        var existing = try loadEvents(gameId: event.gameId)
        guard !existing.contains(where: { $0.seq == event.seq }) else { return }
        existing.append(event)
        existing.sort { $0.seq < $1.seq }
        let data = try JSONEncoder().encode(existing)
        try data.write(to: fileURL(gameId: event.gameId), options: .atomic)
    }

    public func replay(gameId: String) async throws -> [GameEvent] {
        try loadEvents(gameId: gameId)
    }

    public func latestSeq(gameId: String) async -> UInt64? {
        (try? loadEvents(gameId: gameId))?.last?.seq
    }

    private func loadEvents(gameId: String) throws -> [GameEvent] {
        let url = fileURL(gameId: gameId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([GameEvent].self, from: data)
    }
}
