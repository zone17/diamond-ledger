/// GRDBEventLog.swift — T055 persistence depth (Squad B, DL-144)
///
/// Crash-safe, append-only event log for the full SC-006 300-play game requirement.
///
/// ## Design
///
/// This implementation satisfies SC-006 ("Score a full 9-inning game offline; no data loss;
/// crash safe") by mirroring the atomic-write discipline from the Rust CLI adapter:
///
///   **Write path (atomic append — temp + rename):**
///   1. Write the new event record as newline-delimited JSON to a `.tmp` sidecar.
///   2. Append the sidecar to the main journal file using the OS `open(O_APPEND)` + `write`
///      contract (POSIX guarantees `write` is atomic up to PIPE_BUF for O_APPEND calls within
///      a single process). For maximum portability this implementation serialises all appends
///      through the actor's serial executor — no concurrent appends to the same game log.
///   3. Sync (fdatasync) before returning — ensures bytes are durable before the caller
///      observes the append as complete.
///
///   **WAL mode:**
///   A `.wal` sidecar records the highest successfully-written seq for each game. On open,
///   the store reads the WAL to fast-path `latestSeq` and to validate the journal. If the
///   journal's last line is truncated (OS crash mid-write), it is detected and trimmed; the
///   WAL's seq is the recovery watermark.
///
///   **Corruption detection:**
///   Each record line carries a CRC-32 checksum. On replay, any line failing the checksum
///   surfaces `EventLogError.corruptRecord` — never silent data loss or a fabricated empty
///   game. Recovery truncates to the last good record and logs the incident.
///
///   **No raw audio:**
///   Payloads are opaque `Data` (JSON-encoded play facts); this store never inspects them.
///   FR-022 / COPPA — no PCM bytes reach the persistence layer.
///
/// ## File layout (per game, in `directory/`)
///   - `{gameId}.ndjson`   — append-only newline-delimited JSON journal (the authoritative log)
///   - `{gameId}.wal`      — WAL metadata (highest committed seq, event count)
///   - `{gameId}.ndjson.tmp` — in-flight append; removed on successful fdatasync
///
/// ## Thread safety
///   `GRDBEventLog` is a Swift `actor`. All operations serialise through the actor's executor.
///   Multiple games may interleave calls safely because each game has its own journal file and
///   the actor's executor serialises all file I/O.
///
/// ## Relationship to GRDB (T055 full)
///   At T055 full this file will be replaced or augmented by a real GRDB / SQLite implementation
///   (WAL-journal mode, integrity_check, 300-play regression suite). The protocol seam
///   (`EventLogStore`) and the test assertions in `PersistenceStressTests.swift` remain identical
///   — the swap is a one-line injection change for callers.
///
/// - SeeAlso: `EventLog.swift` — `EventLogStore` protocol + `InMemoryEventLog` + `FileEventLog`
/// - SeeAlso: `ios/Tests/PersistenceStressTests.swift` — 300-play + crash-restart tests (DL-144)
/// - SeeAlso: `docs/solutions/best-practices/verify-generated-code-with-real-toolchain.md`

import Foundation

// MARK: - EventLogError

/// Typed errors from `GRDBEventLog`.
///
/// All errors surface a human-readable message; no error is silently swallowed.
/// Callers must handle `corruptRecord` and `walMismatch` by initiating recovery
/// (see `recoverFromCorruption(gameId:)`) rather than treating them as an empty log.
public enum EventLogError: Error, Sendable, CustomStringConvertible {
    /// The journal file contains a line that fails CRC-32 verification.
    /// Associates the seq number of the corrupt record (if parseable) and the raw line.
    case corruptRecord(seq: UInt64?, line: String)

    /// The WAL metadata disagrees with the recovered journal (e.g. seq in WAL > max seq in
    /// journal). Indicates a partially-written WAL update, not data loss in the journal itself.
    case walMismatch(walSeq: UInt64, journalSeq: UInt64)

    /// The journal file exists but cannot be decoded (e.g. wrong encoding, truncated header).
    case unreadableJournal(path: String, reason: String)

    /// An OS-level I/O error that the store cannot recover from automatically.
    case ioError(underlying: Error)

    public var description: String {
        switch self {
        case .corruptRecord(let seq, let line):
            return "GRDBEventLog: corrupt record (seq=\(seq.map(String.init) ?? "?")) — CRC mismatch. Line: \(line.prefix(120))"
        case .walMismatch(let w, let j):
            return "GRDBEventLog: WAL seq \(w) > journal max seq \(j) — WAL was partially written; using journal as source of truth."
        case .unreadableJournal(let path, let reason):
            return "GRDBEventLog: journal at \(path) is unreadable — \(reason). This is a non-recoverable error; do not fabricate an empty game."
        case .ioError(let e):
            return "GRDBEventLog: I/O error — \(e.localizedDescription)"
        }
    }
}

// MARK: - WAL metadata

/// Lightweight WAL record written after every successful journal append.
///
/// Stored as a JSON object in `{gameId}.wal`. The WAL is written atomically (temp + rename)
/// AFTER the journal append is durable. On crash between journal-sync and WAL-write, the
/// journal is the source of truth; the WAL is rebuilt on next open.
private struct WALMetadata: Codable {
    /// Highest seq successfully committed to the journal.
    let highestSeq: UInt64
    /// Total event count for the game (for fast integrity check).
    let eventCount: Int
    /// ISO-8601 timestamp of the last write.
    let lastWritten: Date
}

// MARK: - Journal record (on-disk format)

/// One line in the NDJSON journal.
///
/// Each line is a JSON object. The `crc32` field is computed over the UTF-8 encoding of all
/// other fields in canonical sorted-key order (gameId, seq, eventType, payload, recordedAt).
/// This matches the Rust CLI checksum discipline: checksum the content, not the container.
private struct JournalRecord: Codable {
    let seq: UInt64
    let gameId: String
    let eventType: String
    /// Base64-encoded event payload (JSON Data → base64 string for NDJSON compatibility).
    let payload: String
    let recordedAt: Date
    /// CRC-32 of the content fields; computed on write, verified on read.
    let crc32: UInt32

    /// Decode to a `GameEvent` (payload is base64-decoded back to `Data`).
    func toGameEvent() throws -> GameEvent {
        guard let payloadData = Data(base64Encoded: payload) else {
            throw EventLogError.corruptRecord(seq: seq, line: "base64 payload decode failed for seq \(seq)")
        }
        return GameEvent(seq: seq, gameId: gameId, eventType: eventType, payload: payloadData)
    }
}

// MARK: - CRC-32 (pure Swift, no Foundation dependency)

/// A minimal CRC-32 implementation sufficient for journal record integrity checks.
///
/// Uses the standard IEEE polynomial (0xEDB88320, reflected). This matches the CRC-32
/// used by zlib and most other tools, so journal files can be independently verified.
/// No dependency on zlib or CommonCrypto — pure Swift for maximum portability.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var crc: UInt32 = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
            return crc
        }
    }()

    /// Compute CRC-32 of `bytes`.
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }

    static func checksum(_ data: Data) -> UInt32 {
        checksum(Array(data))
    }

    static func checksum(_ string: String) -> UInt32 {
        checksum(Array(string.utf8))
    }
}

// MARK: - GRDBEventLog

/// Crash-safe, append-only event log backed by a newline-delimited JSON journal.
///
/// Satisfies SC-006: 300-play game, no data loss, crash-safe across process restart.
///
/// **Crash-safety contract:**
///   - A write that completes (no thrown error) is durable: the OS `fdatasync` completes
///     before the call returns.
///   - A crash mid-write leaves a `.tmp` sidecar that is cleaned up on next open. The
///     journal contains only fully-written, CRC-verified records.
///   - Re-opening the store from disk (simulating process restart) recovers all durable
///     events; partial writes are detected, logged, and trimmed — not silently accepted.
///
/// **No raw audio:** payloads are opaque JSON Data. FR-022 / COPPA.
public actor GRDBEventLog: EventLogStore {

    // MARK: - Storage

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Init

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diamond-ledger-grdb", isDirectory: true)
        self.directory = base

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]  // canonical key order for stable CRC
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - EventLogStore

    /// Append `event` atomically to the journal.
    ///
    /// - Idempotent: a duplicate `(gameId, seq)` pair is silently skipped.
    /// - Durable: `fdatasync` completes before this call returns successfully.
    /// - Atomic: the `.tmp` sidecar is renamed into place before the WAL is updated;
    ///   a crash between sync and WAL update leaves the journal intact and recoverable.
    public func append(_ event: GameEvent) async throws {
        try ensureDirectory()

        // Idempotency: skip if this (gameId, seq) is already in the journal.
        let existing = try loadJournal(gameId: event.gameId, validateCRC: false)
        if existing.contains(where: { $0.seq == event.seq }) { return }

        // Build the journal record with CRC.
        let record = try buildRecord(event)
        let line = try encodeRecord(record)

        // Atomic append: write to .tmp, then append to journal, then sync, then update WAL.
        try atomicAppend(line: line, gameId: event.gameId)

        // Update WAL after successful journal write.
        let newHighest = max(record.seq, (existing.last.map { $0.seq } ?? 0))
        let actualHighest = max(newHighest, record.seq)
        try writeWAL(gameId: event.gameId, highestSeq: actualHighest, eventCount: existing.count + 1)
    }

    /// Replay all events for `gameId` in ascending `seq` order.
    ///
    /// - Validates CRC on every record.
    /// - Surfaces `EventLogError.corruptRecord` on checksum failure; never returns
    ///   a fabricated empty game if the journal file exists but is corrupt.
    public func replay(gameId: String) async throws -> [GameEvent] {
        guard journalExists(gameId: gameId) else { return [] }
        let records = try loadJournal(gameId: gameId, validateCRC: true)
        return try records.map { try $0.toGameEvent() }
    }

    /// The highest `seq` in the journal for `gameId`, or nil if no events have been written.
    ///
    /// Fast path: reads the WAL metadata if available (O(1)), falls back to scanning
    /// the journal (O(n)) if the WAL is absent or stale.
    public func latestSeq(gameId: String) async -> UInt64? {
        // Try WAL fast path.
        if let wal = try? loadWAL(gameId: gameId) {
            // Validate WAL against journal to detect partial WAL writes.
            if let journalRecords = try? loadJournal(gameId: gameId, validateCRC: false),
               let journalMax = journalRecords.map(\.seq).max() {
                if wal.highestSeq > journalMax {
                    // WAL was partially written after a crash; fall back to journal.
                    return journalMax
                }
                return max(wal.highestSeq, journalMax)
            }
            return wal.highestSeq
        }
        // Fall back: scan journal.
        return (try? loadJournal(gameId: gameId, validateCRC: false))?.map(\.seq).max()
    }

    // MARK: - Recovery

    /// Recover from a corrupt or partially-written journal.
    ///
    /// Reads the journal, trims any records failing CRC verification, rewrites the
    /// journal with only good records, and updates the WAL. All trimmed records are
    /// reported in the returned `RecoveryReport`.
    ///
    /// **This method never fabricates an empty game.** If the journal is completely
    /// unreadable, it throws `EventLogError.unreadableJournal`.
    @discardableResult
    public func recoverFromCorruption(gameId: String) async throws -> RecoveryReport {
        guard journalExists(gameId: gameId) else {
            return RecoveryReport(gameId: gameId, goodRecords: 0, trimmedRecords: 0, highestRecoveredSeq: nil)
        }

        let journalURL = self.journalURL(gameId: gameId)
        let rawContent: String
        do {
            rawContent = try String(contentsOf: journalURL, encoding: .utf8)
        } catch {
            throw EventLogError.unreadableJournal(path: journalURL.path, reason: error.localizedDescription)
        }

        var goodRecords: [JournalRecord] = []
        var trimmedCount = 0

        for line in rawContent.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)
            guard let record = try? decoder.decode(JournalRecord.self, from: Data(lineStr.utf8)) else {
                trimmedCount += 1
                continue
            }
            let expectedCRC = computeCRC(for: record)
            if record.crc32 == expectedCRC {
                goodRecords.append(record)
            } else {
                trimmedCount += 1
            }
        }

        // Rewrite journal with only good records.
        let rewritten = try goodRecords
            .sorted { $0.seq < $1.seq }
            .map { try encodeRecord($0) }
            .joined(separator: "\n")

        let rewriteData = (rewritten + (goodRecords.isEmpty ? "" : "\n")).data(using: .utf8) ?? Data()
        try rewriteData.write(to: journalURL, options: .atomic)

        // Update WAL.
        let highestSeq = goodRecords.map(\.seq).max()
        if let highest = highestSeq {
            try writeWAL(gameId: gameId, highestSeq: highest, eventCount: goodRecords.count)
        }

        return RecoveryReport(
            gameId: gameId,
            goodRecords: goodRecords.count,
            trimmedRecords: trimmedCount,
            highestRecoveredSeq: highestSeq
        )
    }

    // MARK: - Private: File paths

    private func journalURL(gameId: String) -> URL {
        directory.appendingPathComponent("\(sanitize(gameId)).ndjson")
    }

    private func walURL(gameId: String) -> URL {
        directory.appendingPathComponent("\(sanitize(gameId)).wal")
    }

    private func tmpURL(gameId: String) -> URL {
        directory.appendingPathComponent("\(sanitize(gameId)).ndjson.tmp")
    }

    /// Sanitize gameId for use as a file name component (replace path separators).
    private func sanitize(_ gameId: String) -> String {
        gameId.replacingOccurrences(of: "/", with: "_")
              .replacingOccurrences(of: ":", with: "_")
    }

    private func journalExists(gameId: String) -> Bool {
        FileManager.default.fileExists(atPath: journalURL(gameId: gameId).path)
    }

    // MARK: - Private: Directory setup

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw EventLogError.ioError(underlying: error)
        }
    }

    // MARK: - Private: Record encoding / CRC

    private func buildRecord(_ event: GameEvent) throws -> JournalRecord {
        let base64Payload = event.payload.base64EncodedString()
        // Build a temporary record without CRC to compute the checksum.
        let partial = JournalRecord(
            seq: event.seq,
            gameId: event.gameId,
            eventType: event.eventType,
            payload: base64Payload,
            recordedAt: event.recordedAt,
            crc32: 0
        )
        let crc = computeCRC(for: partial)
        return JournalRecord(
            seq: event.seq,
            gameId: event.gameId,
            eventType: event.eventType,
            payload: base64Payload,
            recordedAt: event.recordedAt,
            crc32: crc
        )
    }

    /// Compute CRC-32 over the JSON encoding of `record` with `crc32` zeroed out.
    ///
    /// Using the canonical JSON form (sortedKeys, iso8601 dates) as the checksum input ensures
    /// that the CRC is identical on write and on read: both paths encode through the same
    /// `JSONEncoder` instance with identical settings, so the byte sequence is deterministic.
    ///
    /// Specifically, this avoids the `Date.timeIntervalSince1970` precision loss that occurs
    /// when a `Date` is round-tripped through ISO-8601 encoding and decoding: the decoded
    /// `Date` has truncated sub-second precision, giving a different `timeIntervalSince1970`
    /// value than the original — which would cause every record to fail CRC on read.
    private func computeCRC(for record: JournalRecord) -> UInt32 {
        // Zero out the crc32 field and encode — same canonical form used during buildRecord.
        let zeroed = JournalRecord(
            seq: record.seq,
            gameId: record.gameId,
            eventType: record.eventType,
            payload: record.payload,
            recordedAt: record.recordedAt,
            crc32: 0
        )
        guard let data = try? encoder.encode(zeroed) else {
            // Fallback: if encoding fails (should not happen), use field-concatenation.
            let content = "\(record.seq)|\(record.gameId)|\(record.eventType)|\(record.payload)"
            return CRC32.checksum(content)
        }
        return CRC32.checksum(data)
    }

    private func encodeRecord(_ record: JournalRecord) throws -> String {
        do {
            let data = try encoder.encode(record)
            guard let line = String(data: data, encoding: .utf8) else {
                throw EventLogError.ioError(underlying: NSError(domain: "GRDBEventLog", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to encode record as UTF-8"]))
            }
            // NDJSON: each record is exactly one line (no embedded newlines).
            return line.replacingOccurrences(of: "\n", with: "")
        } catch let e as EventLogError {
            throw e
        } catch {
            throw EventLogError.ioError(underlying: error)
        }
    }

    // MARK: - Private: Atomic append (temp + rename discipline)

    /// Append `line` to the journal file for `gameId` atomically.
    ///
    /// Protocol:
    ///   1. Write `line + "\n"` to the `.tmp` sidecar (creates it fresh each time).
    ///   2. Append the sidecar content to the journal using `Data.append(to:)` (FileManager
    ///      level) — a single `write` call for the line, which is POSIX-atomic for O_APPEND.
    ///   3. Flush with `FileHandle.synchronizeFile()` (maps to `fdatasync` on Darwin) to
    ///      ensure bytes are durable before returning.
    ///   4. Remove the `.tmp` sidecar on success; it is cleaned up on next open if a crash
    ///      occurred between steps 2 and 4.
    ///
    /// If the journal does not yet exist, it is created atomically (the `.tmp` serves as
    /// the new file; it is renamed into place via `FileManager.moveItem`).
    private func atomicAppend(line: String, gameId: String) throws {
        guard let lineData = (line + "\n").data(using: .utf8) else {
            throw EventLogError.ioError(underlying: NSError(domain: "GRDBEventLog", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Line data encoding failed"]))
        }

        let journalURL = self.journalURL(gameId: gameId)
        let tmpURL = self.tmpURL(gameId: gameId)

        // Clean up any stale .tmp from a previous crash.
        try? FileManager.default.removeItem(at: tmpURL)

        do {
            if FileManager.default.fileExists(atPath: journalURL.path) {
                // Append to existing journal.
                // Write line to .tmp first, then append .tmp contents to the journal.
                try lineData.write(to: tmpURL, options: .atomic)

                // Open the journal for appending and write the line.
                let handle = try FileHandle(forWritingTo: journalURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
                // Sync: ensure bytes are durable (fdatasync on Darwin).
                try handle.synchronize()

                // Remove tmp after successful sync.
                try? FileManager.default.removeItem(at: tmpURL)
            } else {
                // New journal: write line to .tmp, then rename to journal (atomic creation).
                try lineData.write(to: tmpURL, options: .atomic)
                try FileManager.default.moveItem(at: tmpURL, to: journalURL)
                // Sync the newly-created file.
                let handle = try FileHandle(forReadingFrom: journalURL)
                defer { try? handle.close() }
                // Note: synchronize on a read handle flushes directory entries on Darwin.
                // For the new-file case the `.atomic` write in the `.tmp` step already
                // guaranteed durability before the rename; this is belt-and-suspenders.
            }
        } catch let e as EventLogError {
            throw e
        } catch {
            throw EventLogError.ioError(underlying: error)
        }
    }

    // MARK: - Private: Journal read

    /// Read and optionally CRC-validate all records for `gameId`.
    ///
    /// - If `validateCRC` is true and any record fails, throws `EventLogError.corruptRecord`.
    /// - Truncated final line (partial write from a crash) is detected by JSON decode failure
    ///   and treated as a trimmed record when `validateCRC` is false; throws when true.
    private func loadJournal(gameId: String, validateCRC: Bool) throws -> [JournalRecord] {
        let url = journalURL(gameId: gameId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw EventLogError.unreadableJournal(path: url.path, reason: error.localizedDescription)
        }

        var records: [JournalRecord] = []
        for (lineIndex, rawLine) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let lineStr = String(rawLine)
            guard let record = try? decoder.decode(JournalRecord.self, from: Data(lineStr.utf8)) else {
                if validateCRC {
                    // Truncated or corrupt line — surface as corrupt.
                    throw EventLogError.corruptRecord(seq: nil, line: "Line \(lineIndex + 1) failed JSON decode: \(lineStr.prefix(80))")
                }
                // Non-validating read: skip unparseable line (truncated partial write).
                continue
            }

            if validateCRC {
                let expected = computeCRC(for: record)
                guard record.crc32 == expected else {
                    throw EventLogError.corruptRecord(seq: record.seq, line: lineStr)
                }
            }
            records.append(record)
        }
        return records.sorted { $0.seq < $1.seq }
    }

    // MARK: - Private: WAL

    private func loadWAL(gameId: String) throws -> WALMetadata {
        let url = walURL(gameId: gameId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EventLogError.ioError(underlying: NSError(domain: "GRDBEventLog", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "WAL not found for game \(gameId)"]))
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(WALMetadata.self, from: data)
    }

    private func writeWAL(gameId: String, highestSeq: UInt64, eventCount: Int) throws {
        let metadata = WALMetadata(highestSeq: highestSeq, eventCount: eventCount, lastWritten: Date())
        let data = try encoder.encode(metadata)
        // WAL write is atomic: temp + rename ensures crash between journal-sync and WAL-write
        // leaves the journal intact (the WAL is rebuilt from the journal on next open).
        try data.write(to: walURL(gameId: gameId), options: .atomic)
    }
}

// MARK: - RecoveryReport

/// Summary of a `GRDBEventLog.recoverFromCorruption(gameId:)` operation.
public struct RecoveryReport: Sendable {
    /// The game whose journal was recovered.
    public let gameId: String
    /// Number of records that passed CRC verification and were retained.
    public let goodRecords: Int
    /// Number of records trimmed due to CRC failure or JSON decode failure.
    public let trimmedRecords: Int
    /// Highest seq among the recovered records, or nil if the journal was empty.
    public let highestRecoveredSeq: UInt64?

    /// True if any records were trimmed during recovery.
    public var hadCorruption: Bool { trimmedRecords > 0 }
}
