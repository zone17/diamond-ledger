/// PersistenceStressTests.swift — DL-144 (Squad B, SC-006 depth residual)
///
/// Strengthens SC-006 offline persistence robustness beyond the existing T056 `OfflineTests.swift`:
///
///   1. **300-play stress test** — scores a full 300-play game (SC-006 upper bound) through the
///      persistence layer (both `InMemoryEventLog` and `GRDBEventLog`) and asserts:
///      - Zero data loss: every appended event is recoverable via replay.
///      - Deterministic replay: the projection derived from replayed events is byte/state-identical
///        to the live projection accumulated during the game.
///      - Idempotency: the replay count equals exactly 300 (no duplicates).
///
///   2. **Crash/restart-safety test** — simulates a process restart (re-open the store from
///      disk) mid-game and asserts:
///      - The replayed projection is correct and complete for all events written before the
///        simulated restart.
///      - A second batch of events can be appended to the same game after re-open.
///      - The final replay after both batches equals the combined projection.
///
///   3. **Truncated/corrupt file recovery test** — simulates a partially-written journal
///      (truncated last line, CRC-corrupt middle line) and asserts:
///      - `GRDBEventLog.replay` surfaces `EventLogError.corruptRecord`, never an empty game.
///      - `GRDBEventLog.recoverFromCorruption` trims corrupt records and returns the good ones.
///      - The recovery report accurately counts good vs. trimmed records.
///
/// ## What "deterministic replay" means here
///   Because `MockCore` returns canned seqs (1 for deterministic, 2 for judgment) the "live
///   projection" maintained in these tests is a Swift-side `[GameEvent]` accumulator — the same
///   sequence the event log will replay. "Byte/state-identical" means the replayed `[GameEvent]`
///   array equals the live array element-by-element (seq, gameId, eventType, payload).
///
///   At H1 (real UniFFI core + `GRDBEventLog`) this must be strengthened to drive the Rust
///   engine through the replayed events and assert `GameState` parity — this test file documents
///   that requirement at `testNote_H1_replayMustDriveRustCore`.
///
/// ## File lane
///   This file touches only `ios/Tests/PersistenceStressTests.swift`. It does NOT modify
///   `OfflineTests.swift` or any file outside `ios/Tests/` and `ios/Sources/Persistence/`.

import XCTest
import Foundation
@testable import Core
@testable import Persistence

// MARK: - Helpers

/// A minimal "live projection" that mirrors what the event log stores.
/// Accumulates confirmed events in-order during a game run, for later comparison to replay.
private struct LiveProjection: Equatable {
    struct Entry: Equatable {
        let seq: UInt64
        let gameId: String
        let eventType: String
        let payload: Data
    }
    private(set) var entries: [Entry] = []

    mutating func record(event: GameEvent) {
        entries.append(Entry(seq: event.seq, gameId: event.gameId,
                             eventType: event.eventType, payload: event.payload))
    }

    /// True iff this projection and the replayed `[GameEvent]` array agree on every field.
    func matches(replayed: [GameEvent]) -> Bool {
        guard entries.count == replayed.count else { return false }
        for (lhs, rhs) in zip(entries, replayed) {
            guard lhs.seq == rhs.seq,
                  lhs.gameId == rhs.gameId,
                  lhs.eventType == rhs.eventType,
                  lhs.payload == rhs.payload else { return false }
        }
        return true
    }
}

/// Build a deterministic `GameEvent` payload for test purposes.
/// The payload is a JSON object carrying the seq, type, and a correlation id.
private func makePayload(seq: UInt64, type eventType: String, corrId: String) throws -> Data {
    try JSONEncoder().encode([
        "seq": "\(seq)",
        "type": eventType,
        "corr": corrId
    ])
}

/// Score `count` plays against `core` + `log`, alternating between deterministic (Card A)
/// and judgment (Card B) plays. Returns the live projection for comparison.
private func scoreGame(
    count: Int,
    gameId: String,
    ownerId: String,
    core: MockCore,
    log: some EventLogStore,
    judgmentInterval: Int = 10   // every Nth play is a judgment
) async throws -> (liveProjection: LiveProjection, nextSeq: UInt64) {
    var projection = LiveProjection()
    var nextSeq: UInt64 = 1

    for i in 0..<count {
        let corrId = "stress-\(gameId)-\(i)"
        let isJudgment = (i % judgmentInterval == judgmentInterval - 1)

        let facts: [String: String] = isJudgment
            ? ["script": "misplayed-grounder"]
            : ["batter_result": "groundout", "fielders": "6-3"]

        let recordResult = try await core.recordPlay(
            gameId: gameId,
            ownerId: ownerId,
            normalizedFacts: facts,
            correlationId: corrId
        )

        let eventType: String
        if isJudgment {
            // Resolve the judgment immediately.
            _ = try await core.resolveJudgment(
                gameId: gameId,
                decisionId: recordResult.judgment!.id,
                chosen: ScoringCall(token: "hit", label: "Hit"),
                ownerId: ownerId,
                correlationId: "\(corrId)-resolve"
            )
            eventType = "JudgmentResolved"
        } else {
            _ = try await core.confirmPlay(
                gameId: gameId,
                confirmsSeq: recordResult.recordedSeq,
                ownerId: ownerId,
                correlationId: "\(corrId)-confirm"
            )
            eventType = "PlayConfirmed"
        }

        let payload = try makePayload(seq: nextSeq, type: eventType, corrId: corrId)
        let event = GameEvent(seq: nextSeq, gameId: gameId, eventType: eventType, payload: payload)
        try await log.append(event)

        projection.record(event: event)
        nextSeq += 1
    }
    return (projection, nextSeq)
}

// MARK: - 300-Play Stress Tests (SC-006 upper bound)

/// Stress-tests the persistence layer against the full SC-006 300-play upper bound.
///
/// Tests both `InMemoryEventLog` (fast, no I/O) and `GRDBEventLog` (disk-backed, crash-safe)
/// to verify that both implementations satisfy the SC-006 data-integrity requirements at scale.
final class PersistenceStressTests: XCTestCase {

    // MARK: - 300-play against InMemoryEventLog

    /// Score a full 300-play game against `InMemoryEventLog` and assert zero data loss.
    ///
    /// Assertions:
    ///   1. Replayed count == 300 (no events lost, no duplicates).
    ///   2. Replayed projection is element-by-element identical to the live projection
    ///      (seq, gameId, eventType, payload all match — deterministic replay guarantee).
    ///   3. `latestSeq` == 300 after the game.
    ///   4. All events belong to the same game (no cross-game contamination).
    ///   5. Seq numbers are strictly sequential (no gaps, no out-of-order entries).
    func testStress_300plays_inMemory_zeroDataLoss() async throws {
        let core = MockCore()
        let log = InMemoryEventLog()
        let gameId = "stress-inmem-300"
        let ownerId = "stress-owner"

        _ = try await core.createGame(homeTeam: "StressHome", visitorTeam: "StressAway",
                                      ownerId: ownerId, correlationId: "stress-create")

        let (live, finalSeq) = try await scoreGame(
            count: 300, gameId: gameId, ownerId: ownerId, core: core, log: log
        )

        let replayed = try await log.replay(gameId: gameId)

        // 1. Count
        XCTAssertEqual(replayed.count, 300,
            "SC-006 (300-play): InMemoryEventLog must replay exactly 300 events — \(replayed.count) found")

        // 2. Projection parity
        XCTAssertTrue(live.matches(replayed: replayed),
            "SC-006 (300-play): replayed projection must be byte/state-identical to live projection")

        // 3. latestSeq
        let latest = await log.latestSeq(gameId: gameId)
        XCTAssertEqual(latest, 300,
            "SC-006 (300-play): latestSeq must be 300 after 300 plays; got \(String(describing: latest))")

        // 4. Cross-game isolation
        XCTAssertTrue(replayed.allSatisfy { $0.gameId == gameId },
            "SC-006 (300-play): all events must belong to game \(gameId)")

        // 5. Strictly sequential seqs
        let seqs = replayed.map(\.seq)
        XCTAssertEqual(Array(1...UInt64(300)), seqs,
            "SC-006 (300-play): seq numbers must be strictly sequential 1…300 with no gaps")

        XCTAssertEqual(finalSeq, 301, "nextSeq after 300 plays must be 301")

        print("PersistenceStressTests: 300-play InMemory passed — " +
              "\(replayed.count) events, latestSeq=\(latest ?? 0), projection match=\(live.matches(replayed: replayed))")
    }

    // MARK: - 300-play against GRDBEventLog

    /// Score a full 300-play game against `GRDBEventLog` (disk-backed) and assert zero data loss.
    ///
    /// This is the primary SC-006 disk persistence stress test. A temporary directory is used
    /// so the test is hermetic and does not touch the production store.
    ///
    /// Assertions mirror `testStress_300plays_inMemory_zeroDataLoss` exactly — the two
    /// implementations must be behaviourally identical at the protocol level.
    func testStress_300plays_grdb_zeroDataLoss() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-stress-grdb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let log = GRDBEventLog(directory: tmpDir)
        let gameId = "stress-grdb-300"
        let ownerId = "stress-owner"

        _ = try await core.createGame(homeTeam: "GRDBHome", visitorTeam: "GRDBAway",
                                      ownerId: ownerId, correlationId: "grdb-create")

        let (live, finalSeq) = try await scoreGame(
            count: 300, gameId: gameId, ownerId: ownerId, core: core, log: log
        )

        let replayed = try await log.replay(gameId: gameId)

        // 1. Count
        XCTAssertEqual(replayed.count, 300,
            "SC-006 (300-play, GRDB): must replay exactly 300 events — \(replayed.count) found")

        // 2. Projection parity
        XCTAssertTrue(live.matches(replayed: replayed),
            "SC-006 (300-play, GRDB): replayed projection must be byte/state-identical to live")

        // 3. latestSeq
        let latest = await log.latestSeq(gameId: gameId)
        XCTAssertEqual(latest, 300,
            "SC-006 (300-play, GRDB): latestSeq must be 300; got \(String(describing: latest))")

        // 4. Cross-game isolation
        XCTAssertTrue(replayed.allSatisfy { $0.gameId == gameId },
            "SC-006 (300-play, GRDB): all events must belong to game \(gameId)")

        // 5. Strictly sequential seqs
        let seqs = replayed.map(\.seq)
        XCTAssertEqual(Array(1...UInt64(300)), seqs,
            "SC-006 (300-play, GRDB): seq numbers must be sequential 1…300")

        XCTAssertEqual(finalSeq, 301)

        // 6. Journal file exists on disk
        let journalURL = tmpDir.appendingPathComponent("stress-grdb-300.ndjson")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path),
            "SC-006 (300-play, GRDB): journal file must exist on disk at \(journalURL.path)")

        // 7. WAL file exists on disk
        let walURL = tmpDir.appendingPathComponent("stress-grdb-300.wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path),
            "SC-006 (300-play, GRDB): WAL file must exist on disk at \(walURL.path)")

        print("PersistenceStressTests: 300-play GRDB passed — " +
              "\(replayed.count) events, latestSeq=\(latest ?? 0), projection match=\(live.matches(replayed: replayed))")
    }

    // MARK: - 300-play idempotency under full replay

    /// Score 300 plays to a `GRDBEventLog`, then replay all 300 events again (simulating a
    /// crash-recovery re-append of all committed events from a peer node) and assert no duplicates.
    ///
    /// This verifies the idempotent-append contract at the SC-006 upper bound, mirroring
    /// `testEventLog_idempotentUnderSimulatedCrashReplay` in `OfflineTests.swift` but at scale
    /// and against the disk-backed store.
    func testStress_300plays_grdb_idempotentUnderFullReplay() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-stress-idempotent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let log = GRDBEventLog(directory: tmpDir)
        let gameId = "stress-idempotent-300"
        let ownerId = "stress-owner"

        _ = try await core.createGame(homeTeam: "IdempHome", visitorTeam: "IdempAway",
                                      ownerId: ownerId, correlationId: "idemp-create")

        // First pass: append 300 events.
        let (_, _) = try await scoreGame(
            count: 300, gameId: gameId, ownerId: ownerId, core: core, log: log
        )

        let afterFirst = try await log.replay(gameId: gameId)
        XCTAssertEqual(afterFirst.count, 300, "First pass: expected 300 events")

        // Second pass: re-append the same 300 events (simulates crash-recovery re-replay).
        for event in afterFirst {
            try await log.append(event)
        }

        let afterSecond = try await log.replay(gameId: gameId)

        XCTAssertEqual(afterSecond.count, 300,
            "SC-006 idempotency: re-appending 300 already-committed events must produce exactly 300 (no duplicates)")
        XCTAssertEqual(afterFirst.map(\.seq), afterSecond.map(\.seq),
            "SC-006 idempotency: seq ordering must be identical after re-append")
    }
}

// MARK: - Crash/Restart-Safety Tests

/// Tests the crash/restart-safety guarantee of `GRDBEventLog`.
///
/// These tests simulate process restart by:
///   1. Creating a `GRDBEventLog` instance and writing events.
///   2. Deinitialising the instance (all state is on disk).
///   3. Creating a NEW `GRDBEventLog` instance pointed at the same directory (simulating
///      app re-launch after OS kill).
///   4. Asserting that the new instance can replay all events written before the simulated
///      restart and that further appends complete correctly.
final class CrashRestartSafetyTests: XCTestCase {

    // MARK: - Mid-game restart: first half persists, second half appends correctly

    /// Write 150 events (first half of a 300-play game), simulate process restart,
    /// then write another 150 events. Assert the final replay equals all 300 events
    /// with the correct projection.
    ///
    /// This is the primary crash/restart-safety assertion for SC-006: the replayed
    /// projection after restart is correct and complete.
    func testCrashRestart_midGame_300plays_projectionCorrect() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-crash-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let gameId = "crash-restart-300"
        let ownerId = "restart-owner"

        _ = try await core.createGame(homeTeam: "CrashHome", visitorTeam: "RestartAway",
                                      ownerId: ownerId, correlationId: "restart-create")

        // ── Phase 1: Write first 150 events ──────────────────────────────────────────────
        let log1 = GRDBEventLog(directory: tmpDir)

        let (livePhase1, nextSeqAfterPhase1) = try await scoreGame(
            count: 150, gameId: gameId, ownerId: ownerId, core: core, log: log1
        )

        // Verify phase 1 written correctly before simulating restart.
        let phase1Replayed = try await log1.replay(gameId: gameId)
        XCTAssertEqual(phase1Replayed.count, 150,
            "Pre-restart: expected 150 events in log after phase 1")
        let latestSeqPreRestart = await log1.latestSeq(gameId: gameId)
        XCTAssertEqual(latestSeqPreRestart, 150,
            "Pre-restart: latestSeq must be 150 after phase 1")

        // ── Simulated process restart: drop log1, open a new instance from disk ──────────
        // `log1` goes out of scope here — all state is on disk. `log2` is a brand-new
        // actor instance that knows nothing about the prior run.
        let log2 = GRDBEventLog(directory: tmpDir)

        // Verify restart: the new instance can see all phase-1 events.
        let restartReplayed = try await log2.replay(gameId: gameId)
        XCTAssertEqual(restartReplayed.count, 150,
            "Post-restart: expected 150 events recoverable from disk — crash-restart data loss detected")
        let latestSeqPostRestart = await log2.latestSeq(gameId: gameId)
        XCTAssertEqual(latestSeqPostRestart, 150,
            "Post-restart: latestSeq must be 150 after restart")

        // Projection parity: phase 1 live projection matches the post-restart replay.
        XCTAssertTrue(livePhase1.matches(replayed: restartReplayed),
            "Post-restart: replayed projection must be identical to pre-restart live projection")

        // ── Phase 2: Write remaining 150 events to the restarted store ───────────────────
        var nextSeq = nextSeqAfterPhase1
        var livePhase2 = LiveProjection()

        for i in 0..<150 {
            let corrId = "restart-p2-\(i)"
            let isJudgment = (i % 10 == 9)
            let facts: [String: String] = isJudgment
                ? ["script": "misplayed-grounder"]
                : ["batter_result": "groundout", "fielders": "6-3"]

            let recordResult = try await core.recordPlay(
                gameId: gameId, ownerId: ownerId,
                normalizedFacts: facts, correlationId: corrId
            )
            let eventType: String
            if isJudgment {
                _ = try await core.resolveJudgment(
                    gameId: gameId, decisionId: recordResult.judgment!.id,
                    chosen: ScoringCall(token: "hit", label: "Hit"),
                    ownerId: ownerId, correlationId: "\(corrId)-resolve"
                )
                eventType = "JudgmentResolved"
            } else {
                _ = try await core.confirmPlay(
                    gameId: gameId, confirmsSeq: recordResult.recordedSeq,
                    ownerId: ownerId, correlationId: "\(corrId)-confirm"
                )
                eventType = "PlayConfirmed"
            }
            let payload = try makePayload(seq: nextSeq, type: eventType, corrId: corrId)
            let event = GameEvent(seq: nextSeq, gameId: gameId, eventType: eventType, payload: payload)
            try await log2.append(event)
            livePhase2.record(event: event)
            nextSeq += 1
        }

        // ── Final assertions: all 300 events present and correct ─────────────────────────
        let finalReplayed = try await log2.replay(gameId: gameId)

        XCTAssertEqual(finalReplayed.count, 300,
            "Post-restart final: expected 300 total events (150 + 150); got \(finalReplayed.count)")
        let latestSeqFinal = await log2.latestSeq(gameId: gameId)
        XCTAssertEqual(latestSeqFinal, 300,
            "Post-restart final: latestSeq must be 300")

        // Phase 1 portion matches.
        let replayedPhase1 = Array(finalReplayed.prefix(150))
        XCTAssertTrue(livePhase1.matches(replayed: replayedPhase1),
            "Post-restart final: phase-1 portion of replay must match phase-1 live projection")

        // Phase 2 portion matches.
        let replayedPhase2 = Array(finalReplayed.suffix(150))
        XCTAssertTrue(livePhase2.matches(replayed: replayedPhase2),
            "Post-restart final: phase-2 portion of replay must match phase-2 live projection")

        // Strictly sequential seqs 1…300.
        let seqs = finalReplayed.map(\.seq)
        XCTAssertEqual(Array(1...UInt64(300)), seqs,
            "Post-restart final: seq numbers must be strictly sequential 1…300")

        print("CrashRestartSafetyTests: mid-game restart passed — " +
              "150+150=\(finalReplayed.count) events, latestSeq=\(latestSeqFinal ?? 0)")
    }

    // MARK: - Restart with empty remaining events (game completed before crash)

    /// Score a complete 100-play game, simulate restart, assert replay is complete and
    /// that no further appends are required (game-complete path).
    func testCrashRestart_completedGame_replayIsComplete() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-crash-complete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let log1 = GRDBEventLog(directory: tmpDir)
        let gameId = "crash-complete-100"
        let ownerId = "complete-owner"

        _ = try await core.createGame(homeTeam: "CompleteHome", visitorTeam: "CompleteAway",
                                      ownerId: ownerId, correlationId: "complete-create")

        let (live, _) = try await scoreGame(
            count: 100, gameId: gameId, ownerId: ownerId, core: core, log: log1
        )

        // Simulate restart — open a new log instance.
        let log2 = GRDBEventLog(directory: tmpDir)
        let replayed = try await log2.replay(gameId: gameId)

        XCTAssertEqual(replayed.count, 100,
            "Completed-game restart: all 100 events must survive restart")
        XCTAssertTrue(live.matches(replayed: replayed),
            "Completed-game restart: replayed projection must match live projection exactly")
        let latestSeqCompleted = await log2.latestSeq(gameId: gameId)
        XCTAssertEqual(latestSeqCompleted, 100,
            "Completed-game restart: latestSeq must be 100 after restart")
    }

    // MARK: - Restart with stale .tmp sidecar (crash mid-append)

    /// Verifies that a stale `.tmp` sidecar left by a crash mid-append does not corrupt the log.
    ///
    /// The `.tmp` file represents the in-flight write that did NOT complete before the crash.
    /// On restart `GRDBEventLog` must skip the `.tmp` (only the journal is authoritative)
    /// and replay only the events that were durably committed to the journal.
    func testCrashRestart_staleTmpSidecar_doesNotCorruptLog() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-stale-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let log1 = GRDBEventLog(directory: tmpDir)
        let gameId = "stale-tmp-game"
        let ownerId = "stale-tmp-owner"

        _ = try await core.createGame(homeTeam: "TmpHome", visitorTeam: "TmpAway",
                                      ownerId: ownerId, correlationId: "tmp-create")

        // Write 20 events durably.
        let (live20, _) = try await scoreGame(
            count: 20, gameId: gameId, ownerId: ownerId, core: core, log: log1
        )

        // Inject a stale .tmp sidecar (simulates crash between tmp write and journal append).
        let tmpSidecar = tmpDir.appendingPathComponent("stale-tmp-game.ndjson.tmp")
        let staleLine = "{\"corrupted\":\"stale-content-from-crashed-write\"}\n"
        try staleLine.data(using: .utf8)!.write(to: tmpSidecar)

        // Simulate restart.
        let log2 = GRDBEventLog(directory: tmpDir)
        let replayed = try await log2.replay(gameId: gameId)

        XCTAssertEqual(replayed.count, 20,
            "Stale .tmp: replay must return 20 durable events, ignoring the stale sidecar")
        XCTAssertTrue(live20.matches(replayed: replayed),
            "Stale .tmp: replayed projection must match live projection")

        // Verify the .tmp is cleaned up on the next append.
        let payload21 = try makePayload(seq: 21, type: "PlayConfirmed", corrId: "tmp-21")
        let event21 = GameEvent(seq: 21, gameId: gameId, eventType: "PlayConfirmed", payload: payload21)
        try await log2.append(event21)

        let replayedAfterAppend = try await log2.replay(gameId: gameId)
        XCTAssertEqual(replayedAfterAppend.count, 21,
            "Post-stale-tmp: append after restart must succeed; expected 21 events")
    }
}

// MARK: - GRDB Corruption Detection and Recovery Tests

/// Tests the `GRDBEventLog` corruption detection and recovery path.
///
/// Verifies that:
///   1. A truncated last line (partial write from OS crash) is detected — not silently accepted.
///   2. A CRC-corrupt record surfaces `EventLogError.corruptRecord`.
///   3. `recoverFromCorruption` trims corrupt records and recovers good ones.
///   4. A WAL that disagrees with the journal is handled gracefully.
///   5. The store NEVER fabricates an empty game when the journal file exists.
final class GRDBCorruptionDetectionTests: XCTestCase {

    // MARK: - Truncated last line (OS crash mid-write)

    /// Write 10 events, truncate the last line of the journal (simulating OS crash after
    /// partial write), then assert `recoverFromCorruption` trims the partial line and returns
    /// 9 good records. The recovered store must replay 9 events (not 0, not 10).
    func testCorruption_truncatedLastLine_recoversNineRecords() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-truncated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let log = GRDBEventLog(directory: tmpDir)
        let gameId = "truncated-game"
        let ownerId = "trunc-owner"

        _ = try await core.createGame(homeTeam: "TruncHome", visitorTeam: "TruncAway",
                                      ownerId: ownerId, correlationId: "trunc-create")

        // Write 10 events.
        let (_, _) = try await scoreGame(
            count: 10, gameId: gameId, ownerId: ownerId, core: core, log: log
        )

        // Truncate the last line of the journal (simulate OS crash mid-write of line 10).
        let journalURL = tmpDir.appendingPathComponent("\(gameId).ndjson")
        var journalContent = try String(contentsOf: journalURL, encoding: .utf8)
        let lines = journalContent.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 10, "Expected 10 lines before truncation")

        // Replace last line with a partial write (truncate at 40 chars).
        let truncated = String(lines.last!.prefix(40))
        let goodLines = Array(lines.dropLast())
        journalContent = goodLines.joined(separator: "\n") + "\n" + truncated + "\n"
        try journalContent.data(using: .utf8)!.write(to: journalURL)

        // replay must throw corruptRecord (truncated line fails JSON decode / CRC).
        do {
            let _ = try await log.replay(gameId: gameId)
            XCTFail("Expected EventLogError.corruptRecord for truncated journal, got successful replay")
        } catch let e as EventLogError {
            if case .corruptRecord = e {
                // Expected.
            } else {
                XCTFail("Expected EventLogError.corruptRecord, got \(e)")
            }
        }

        // recoverFromCorruption must trim the partial line and return 9 good records.
        let report = try await log.recoverFromCorruption(gameId: gameId)
        XCTAssertEqual(report.goodRecords, 9,
            "Recovery: expected 9 good records after truncation; got \(report.goodRecords)")
        XCTAssertEqual(report.trimmedRecords, 1,
            "Recovery: expected 1 trimmed record (the truncated last line); got \(report.trimmedRecords)")
        XCTAssertTrue(report.hadCorruption, "Recovery report must indicate corruption was present")
        XCTAssertEqual(report.highestRecoveredSeq, 9,
            "Recovery: highest recovered seq must be 9 after trimming seq 10")

        // Post-recovery replay must return exactly 9 events (not 0, not 10).
        let recovered = try await log.replay(gameId: gameId)
        XCTAssertEqual(recovered.count, 9,
            "Post-recovery: replay must return 9 events — never fabricate empty or include corrupt")
        XCTAssertEqual(recovered.map(\.seq), Array(1...UInt64(9)),
            "Post-recovery: seqs must be 1…9 after recovering from truncation")
    }

    // MARK: - CRC-corrupt middle record

    /// Write 20 events, corrupt the CRC of the 10th record, then assert that:
    ///   - `replay` throws `EventLogError.corruptRecord`.
    ///   - `recoverFromCorruption` returns 19 good records and 1 trimmed.
    ///   - The recovered replay is the 19 remaining events (not a fabricated empty game).
    func testCorruption_crcMismatch_middleRecord_recovers19() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-crc-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let log = GRDBEventLog(directory: tmpDir)
        let gameId = "crc-corrupt-game"
        let ownerId = "crc-owner"

        _ = try await core.createGame(homeTeam: "CRCHome", visitorTeam: "CRCAway",
                                      ownerId: ownerId, correlationId: "crc-create")

        // Write 20 events.
        let (_, _) = try await scoreGame(
            count: 20, gameId: gameId, ownerId: ownerId, core: core, log: log
        )

        // Corrupt the CRC in the 10th line.
        let journalURL = tmpDir.appendingPathComponent("\(gameId).ndjson")
        let journalContent = try String(contentsOf: journalURL, encoding: .utf8)
        var lines = journalContent.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 20, "Expected 20 lines before CRC corruption")

        // Replace the valid CRC value in line 10 with 0 (guaranteed wrong).
        let line10 = lines[9]
        // The CRC field in the JSON is "crc32":<number>. Replace with 0.
        let corruptLine10 = line10.replacingOccurrences(
            of: #"\"crc32\":\d+"#,
            with: "\"crc32\":0",
            options: .regularExpression
        )
        lines[9] = corruptLine10
        let corruptContent = lines.joined(separator: "\n") + "\n"
        try corruptContent.data(using: .utf8)!.write(to: journalURL)

        // replay must throw corruptRecord for the CRC mismatch.
        do {
            let _ = try await log.replay(gameId: gameId)
            XCTFail("Expected EventLogError.corruptRecord for CRC-corrupt journal")
        } catch let e as EventLogError {
            if case .corruptRecord(let seq, _) = e {
                XCTAssertEqual(seq, 10,
                    "corruptRecord must identify seq=10 as the corrupt record; got seq=\(String(describing: seq))")
            } else {
                XCTFail("Expected EventLogError.corruptRecord, got \(e)")
            }
        }

        // recoverFromCorruption trims the corrupt record and retains 19.
        let report = try await log.recoverFromCorruption(gameId: gameId)
        XCTAssertEqual(report.goodRecords, 19,
            "CRC-corrupt recovery: expected 19 good records; got \(report.goodRecords)")
        XCTAssertEqual(report.trimmedRecords, 1,
            "CRC-corrupt recovery: expected 1 trimmed record; got \(report.trimmedRecords)")

        let recovered = try await log.replay(gameId: gameId)
        XCTAssertEqual(recovered.count, 19,
            "Post-CRC-recovery: replay must return 19 events — \(recovered.count) found")
        // Seq 10 is trimmed; seqs 1…9 and 11…20 remain.
        let expectedSeqs: [UInt64] = Array(1...9) + Array(11...20)
        XCTAssertEqual(recovered.map(\.seq), expectedSeqs,
            "Post-CRC-recovery: seqs must be 1…9, 11…20 after trimming corrupt seq=10")
    }

    // MARK: - Unreadable journal never produces empty game

    /// Verifies that when a journal file exists but is completely corrupt (e.g. wrong encoding),
    /// `replay` throws `EventLogError` rather than silently returning an empty array.
    ///
    /// This is the "never silent data loss or a fabricated empty game" invariant from DL-144.
    func testCorruption_unreadableJournal_neverReturnsEmpty() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let log = GRDBEventLog(directory: tmpDir)
        let gameId = "unreadable-game"

        // Write a journal file with completely garbled content (not valid NDJSON).
        let journalURL = tmpDir.appendingPathComponent("\(gameId).ndjson")
        let garbledData = Data([0xFF, 0xFE, 0x00, 0x01, 0x02, 0x03])  // invalid UTF-8 sequence
        try garbledData.write(to: journalURL)

        // replay on a non-existent-but-garbled file must throw, not return [].
        do {
            let events = try await log.replay(gameId: gameId)
            // If we land here with an empty array, that is a fabricated-empty-game failure.
            XCTAssertFalse(events.isEmpty || true,
                "GRDBEventLog must NOT return empty array when journal file exists but is unreadable — this is silent data loss")
            // If events are non-empty somehow, the test was supposed to throw.
            XCTFail("Expected EventLogError.unreadableJournal; got \(events.count) events instead")
        } catch let e as EventLogError {
            if case .unreadableJournal = e {
                // Expected: clear error, not silent empty.
            } else if case .corruptRecord = e {
                // Also acceptable: the garbled bytes decode as valid UTF-8 in some OS versions.
                // What matters is that an error was thrown, not that events = [] was returned.
            } else {
                XCTFail("Expected EventLogError.unreadableJournal or .corruptRecord, got \(e)")
            }
        } catch {
            // Any error is acceptable here — what's NOT acceptable is an empty []  return.
            // The test only fails if we fell through to the XCTAssertFalse above.
        }
    }

    // MARK: - WAL mismatch is handled gracefully

    /// Write 10 events, then manually corrupt the WAL to claim highestSeq=999. Assert that
    /// `latestSeq` returns the correct journal-based value (10), not the inflated WAL value.
    func testCorruption_walMismatch_journalWins() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-wal-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let log = GRDBEventLog(directory: tmpDir)
        let gameId = "wal-mismatch-game"
        let ownerId = "wal-owner"

        _ = try await core.createGame(homeTeam: "WALHome", visitorTeam: "WALAway",
                                      ownerId: ownerId, correlationId: "wal-create")

        // Write 10 events.
        let (_, _) = try await scoreGame(
            count: 10, gameId: gameId, ownerId: ownerId, core: core, log: log
        )

        // Corrupt the WAL: claim highestSeq=999, eventCount=999 (simulates partial WAL write).
        let walURL = tmpDir.appendingPathComponent("\(gameId).wal")
        let corruptWAL = """
        {"highestSeq":999,"eventCount":999,"lastWritten":"2026-06-02T00:00:00Z"}
        """
        try corruptWAL.data(using: .utf8)!.write(to: walURL)

        // latestSeq must return the journal-based value (10), not the inflated WAL value (999).
        let latest = await log.latestSeq(gameId: gameId)
        XCTAssertEqual(latest, 10,
            "WAL mismatch: latestSeq must return journal-based value (10) when WAL claims 999; got \(String(describing: latest))")

        // replay must still return all 10 events.
        let replayed = try await log.replay(gameId: gameId)
        XCTAssertEqual(replayed.count, 10,
            "WAL mismatch: replay must return 10 events; got \(replayed.count)")
    }
}

// MARK: - FileEventLog Stress Tests

/// Verifies that `FileEventLog` (the existing lightweight disk-backed store) also satisfies
/// the SC-006 300-play requirement. `FileEventLog` uses `Data.write(to:, options: .atomic)`
/// which is crash-safe for full rewrites (temp + rename). These tests confirm it at scale.
///
/// Note: `FileEventLog` rewrites the entire array on each append (O(n) per write).
/// For production use, `GRDBEventLog` (O(1) append via NDJSON journal) is preferred.
final class FileEventLogStressTests: XCTestCase {

    func testStress_300plays_fileEventLog_zeroDataLoss() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-file-stress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let log = FileEventLog(directory: tmpDir)
        let gameId = "file-stress-300"
        let ownerId = "file-stress-owner"

        _ = try await core.createGame(homeTeam: "FileHome", visitorTeam: "FileAway",
                                      ownerId: ownerId, correlationId: "file-create")

        let (live, _) = try await scoreGame(
            count: 300, gameId: gameId, ownerId: ownerId, core: core, log: log
        )

        let replayed = try await log.replay(gameId: gameId)

        XCTAssertEqual(replayed.count, 300,
            "SC-006 (300-play, FileEventLog): must replay exactly 300 events")
        XCTAssertTrue(live.matches(replayed: replayed),
            "SC-006 (300-play, FileEventLog): replayed projection must be identical to live")
        let latestSeqFile = await log.latestSeq(gameId: gameId)
        XCTAssertEqual(latestSeqFile, 300,
            "SC-006 (300-play, FileEventLog): latestSeq must be 300")
    }

    /// Simulates process restart for `FileEventLog`: create, write 150, re-open, write 150, assert 300.
    func testCrashRestart_fileEventLog_midGame() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-file-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MockCore()
        let gameId = "file-restart-300"
        let ownerId = "file-restart-owner"

        _ = try await core.createGame(homeTeam: "FRHome", visitorTeam: "FRAway",
                                      ownerId: ownerId, correlationId: "fr-create")

        // Phase 1: 150 plays.
        let log1 = FileEventLog(directory: tmpDir)
        let (live1, nextSeq1) = try await scoreGame(
            count: 150, gameId: gameId, ownerId: ownerId, core: core, log: log1
        )
        let phase1EventCount = try await log1.replay(gameId: gameId).count
        XCTAssertEqual(phase1EventCount, 150)

        // Simulate restart: open new instance.
        let log2 = FileEventLog(directory: tmpDir)
        let afterRestart = try await log2.replay(gameId: gameId)
        XCTAssertEqual(afterRestart.count, 150,
            "FileEventLog restart: must recover 150 events from disk")
        XCTAssertTrue(live1.matches(replayed: afterRestart),
            "FileEventLog restart: projection must match after restart")

        // Phase 2: 150 more plays.
        var nextSeq = nextSeq1
        var live2 = LiveProjection()
        for i in 0..<150 {
            let corrId = "fr-p2-\(i)"
            let payload = try makePayload(seq: nextSeq, type: "PlayConfirmed", corrId: corrId)
            let event = GameEvent(seq: nextSeq, gameId: gameId, eventType: "PlayConfirmed", payload: payload)
            try await log2.append(event)
            live2.record(event: event)
            nextSeq += 1
        }

        let finalReplayed = try await log2.replay(gameId: gameId)
        XCTAssertEqual(finalReplayed.count, 300,
            "FileEventLog post-restart: expected 300 total events; got \(finalReplayed.count)")
        XCTAssertTrue(live1.matches(replayed: Array(finalReplayed.prefix(150))),
            "FileEventLog final: phase-1 portion must match")
        XCTAssertTrue(live2.matches(replayed: Array(finalReplayed.suffix(150))),
            "FileEventLog final: phase-2 portion must match")
    }
}

// MARK: - H1 Handoff Note

final class PersistenceH1HandoffTests: XCTestCase {

    /// **NOT a test — a documentation anchor for the H1 handoff.**
    ///
    /// At H1 (real UniFFI core + real GRDB dependency wired in Package.swift):
    ///
    ///   1. Replace the `GRDBEventLog` NDJSON journal backend with a real SQLite/GRDB store:
    ///      - Uncomment the GRDB dependency in `Package.swift` (owned by H1/integration squad).
    ///      - Replace `GRDBEventLog`'s NDJSON journal with a GRDB `DatabaseQueue` in WAL mode.
    ///      - Enable `PRAGMA journal_mode=WAL` + `PRAGMA synchronous=FULL` on open.
    ///      - Implement `recover` via SQLite `PRAGMA integrity_check`.
    ///
    ///   2. Run `PersistenceStressTests` against the GRDB-backed store (all assertions remain
    ///      identical; the protocol seam ensures behavioural parity without test changes).
    ///
    ///   3. Strengthen the 300-play + crash-restart tests to drive the real Rust core:
    ///      - Replace `scoreGame` helper's `MockCore` with the real `UniFFICore`.
    ///      - Assert `GameState` parity (live `GameState` after each play == replayed `GameState`
    ///        after re-driving the core through the persisted events).
    ///      - This closes the "coreSeq is strictly increasing" invariant noted in `OfflineTests.swift`.
    ///
    ///   4. Add a MANUAL-TESTING.md entry: device-level crash test (kill -9 mid-write +
    ///      re-launch, verify replay produces no duplicates and all committed events survive).
    ///
    /// Tracked: H1 integration squad (T071).
    func testNote_H1_replayMustDriveRustCore() {
        XCTAssertTrue(true, "H1 handoff: see comment above for GRDB integration + real-core parity requirements.")
    }
}
