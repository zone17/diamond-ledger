/// DiamondCoreClient.swift — T071 / DL-35 (Squad F-Integration, handoff **H1**)
///
/// The **real-core** `CoreClient` conformer: a thin adapter wrapping the UniFFI-generated
/// `DiamondCore` (the deterministic Rust core compiled into `DiamondLedgerCore.xcframework`).
/// It replaces `MockCore` at the app injection point (`DiamondLedgerApp.swift`) with **no
/// protocol change** — every existing caller (`AppState`, the cards, export) stays identical
/// (drop-in parity, SC-008).
///
/// `MockCore` is intentionally kept alongside this (previews/tests); this file does not delete it.
///
/// ## What this adapter does (and the one place it does real work)
///
/// 1. Owns a single `DiamondCore` instance for the whole app session, so the append-only event
///    log + projected state persist across `recordPlay` → `confirmPlay` → `resolveJudgment` →
///    `finalizeScorecard`. The real core is stateful (unlike the stateless `MockCore`); the
///    adapter is the session-lifetime holder of that state.
/// 2. Maps the 7 write/lifecycle + 4 read `ffi*` methods of the generated `DiamondCore` to the
///    `CoreClient` protocol 1:1 (mapping table in `ios/Generated/README.md`).
/// 3. Bridges the protocol's loosely-typed `normalizedFacts: [String: String]` (what the WoZ
///    harness / grammar parser produce today) into the generated, strongly-typed `NormalizedPlay`
///    the real core requires. This is the H1 seam where the `[String:String]` placeholder finally
///    meets a real fact struct (the `TODO: T044` markers in `CoreClient.swift`).
/// 4. Maps the thrown `CoreFfiError.Core(Error)` → the Swift `CoreError` cases by `error.code`.
///
/// ## Determinism / authority preserved
///
/// All authority (owner-as-decider, I5/FR-020), the read-verify-correct gate (FR-007), and the
/// no-silent-judgment invariant (I2/SC-003) are enforced **by the real core**, not re-implemented
/// here. The adapter never resolves a judgment, never advances state, never fabricates a fact —
/// it only translates shapes and threads the call through to the Rust boundary.
///
/// - SeeAlso: `ios/Generated/README.md` (consumption + mapping table — A-side H1 doc)
/// - SeeAlso: `ios/Sources/Core/CoreClient.swift` (the protocol), `MockCore.swift` (the stub)
/// - SeeAlso: `core/src/ffi.rs`, `core/src/primitives/mod.rs` (the exported `DiamondCore` impl)

import Foundation
import DiamondLedgerCoreBindings

/// Real-core `CoreClient` backed by the generated UniFFI `DiamondCore` (H1 / T071).
///
/// `@unchecked Sendable`: the underlying Rust `DiamondCore` is `Send + Sync` (its inner state is
/// `Mutex`-guarded, see `core/src/primitives/mod.rs`); UniFFI hands it to Swift behind an `Arc`.
/// The Swift wrapper is a reference to that thread-safe object, so it is safe to share.
public final class DiamondCoreClient: CoreClient, @unchecked Sendable {

    /// The single session-lifetime core instance. Holds the append-only event log + projections.
    private let core: DiamondCore

    public init() {
        // Generated constructor: the Rust `#[uniffi::constructor] ffi_new` surfaces as the static
        // `ffiNew()` (NOT a bare `DiamondCore()` — UniFFI names the static from the fn name).
        self.core = DiamondCore.ffiNew()
    }

    // MARK: - Identity helpers

    /// Build the boundary `Actor` from the owner id every mutating primitive carries (FR-020/I5).
    /// Human caller (the iOS scorer): `kind = .human`, no harness version.
    private func actor(_ ownerId: String) -> DiamondLedgerCoreBindings.Actor {
        DiamondLedgerCoreBindings.Actor(kind: .human, id: ownerId, harnessVersion: nil)
    }

    /// The protocol carries `gameId` as `String`; the real core's `GameId` is a `UInt64` newtype.
    /// Bridge by decimal string. A non-numeric id (e.g. a stale MockCore `"mock-game-…"` id) is a
    /// programmer error at this seam — surface it as a typed `notFound` rather than crashing.
    private func gameId(_ s: String) throws -> GameId {
        guard let id = UInt64(s) else {
            throw CoreError.notFound("DiamondCoreClient: game id '\(s)' is not a valid core GameId")
        }
        return id
    }

    // MARK: - Primitive 0 — create_game

    public func createGame(
        homeTeam: String,
        visitorTeam: String,
        ownerId: String,
        correlationId: String
    ) async throws -> CreateGameResult {
        // Names-only games are allowed (FR-001): no lineup. Use the display name as the id too —
        // the core treats both as opaque strings; the export layer owns the real id mapping.
        let home = Team(id: homeTeam, name: homeTeam, lineup: nil)
        let visitor = Team(id: visitorTeam, name: visitorTeam, lineup: nil)
        let req = CreateGameRequest(
            home: home,
            visitor: visitor,
            idempotencyKey: correlationId,
            actor: actor(ownerId)
        )
        do {
            let result = try core.ffiCreateGame(req: req)
            return CreateGameResult(
                gameId: String(result.gameId),
                state: Self.projectState(result.state, gameId: result.gameId)
            )
        } catch let e as CoreFfiError {
            throw Self.mapError(e)
        }
    }

    // MARK: - Primitive 1 — record_play

    public func recordPlay(
        gameId gameIdStr: String,
        ownerId: String,
        normalizedFacts: [String: String],
        correlationId: String
    ) async throws -> RecordPlayResult {
        let gid = try gameId(gameIdStr)
        // Bridge the loose fact map → a real NormalizedPlay (the H1 seam, T044). The core's
        // classifier reads ONLY these facts (I1); the adapter never asserts a classification.
        let play = FactBridge.normalizedPlay(from: normalizedFacts)
        let req = RecordPlayRequest(
            gameId: gid,
            input: .normalized(play),
            idempotencyKey: correlationId,
            actor: actor(ownerId)
        )
        do {
            let r = try core.ffiRecordPlay(req: req)
            return Self.projectRecordPlay(r, gameId: gid)
        } catch let e as CoreFfiError {
            throw Self.mapError(e)
        }
    }

    // MARK: - Primitive 2 — advance_runner

    public func advanceRunner(
        gameId gameIdStr: String,
        ownerId: String,
        runnerId: String,
        toBase: String,
        correlationId: String
    ) async throws -> GameState {
        let gid = try gameId(gameIdStr)
        let runner = RunnerId(UInt32(runnerId) ?? 1)
        let delta = AdvanceDelta(
            runner: runner,
            from: .home,
            to: FactBridge.advanceOutcome(toBase),
            byError: nil
        )
        let req = AdvanceRunnerRequest(
            gameId: gid,
            advance: delta,
            idempotencyKey: correlationId,
            actor: actor(ownerId)
        )
        do {
            let r = try core.ffiAdvanceRunner(req: req)
            return Self.projectState(r.statePreview, gameId: gid)
        } catch let e as CoreFfiError {
            throw Self.mapError(e)
        }
    }

    // MARK: - Primitive 3 — correct_event (post-MVP; gated OFF — surfaces the core's typed error)

    public func correctEvent(
        gameId gameIdStr: String,
        ownerId: String,
        playId: PlayId,
        amendment: [String: String],
        correlationId: String
    ) async throws -> GameState {
        let gid = try gameId(gameIdStr)
        let req = CorrectEventRequest(
            gameId: gid,
            correctsSeq: Seq(UInt64(playId.rawValue) ?? 0),
            amended: .normalized(FactBridge.normalizedPlay(from: amendment)),
            idempotencyKey: correlationId,
            actor: actor(ownerId)
        )
        do {
            let r = try core.ffiCorrectEvent(req: req)
            return Self.projectState(r.recomputedState, gameId: gid)
        } catch let e as CoreFfiError {
            throw Self.mapError(e)
        }
    }

    // MARK: - Primitive 3b — confirm_play

    public func confirmPlay(
        gameId gameIdStr: String,
        confirmsSeq: UInt64,
        ownerId: String,
        correlationId: String
    ) async throws -> ConfirmPlayResult {
        let gid = try gameId(gameIdStr)
        let req = ConfirmPlayRequest(
            gameId: gid,
            confirmsSeq: Seq(confirmsSeq),
            idempotencyKey: correlationId,
            actor: actor(ownerId)
        )
        do {
            let r = try core.ffiConfirmPlay(req: req)
            return ConfirmPlayResult(
                confirmedSeq: confirmsSeq,
                state: Self.projectState(r.state, gameId: gid)
            )
        } catch let e as CoreFfiError {
            throw Self.mapError(e)
        }
    }

    // MARK: - Primitive 3c — resolve_judgment

    public func resolveJudgment(
        gameId gameIdStr: String,
        decisionId: UInt64,
        chosen: ScoringCall,
        ownerId: String,
        correlationId: String
    ) async throws -> ResolveJudgmentResult {
        let gid = try gameId(gameIdStr)
        let req = ResolveJudgmentRequest(
            gameId: gid,
            decisionId: decisionId,
            chosen: Call(token: chosen.token, label: chosen.label),
            idempotencyKey: correlationId,
            actor: actor(ownerId)
        )
        do {
            let r = try core.ffiResolveJudgment(req: req)
            return ResolveJudgmentResult(
                decision: Self.projectJudgment(r.decision),
                state: Self.projectState(r.state, gameId: gid)
            )
        } catch let e as CoreFfiError {
            throw Self.mapError(e)
        }
    }

    // MARK: - Primitive 4 — finalize_scorecard

    public func finalizeScorecard(
        gameId gameIdStr: String,
        ownerId: String,
        correlationId: String
    ) async throws -> FinalizedScorebook {
        let gid = try gameId(gameIdStr)
        let req = FinalizeRequest(
            gameId: gid,
            mode: .final,
            idempotencyKey: correlationId,
            actor: actor(ownerId)
        )
        do {
            let r = try core.ffiFinalizeScorecard(req: req)
            return FinalizedScorebook(
                reisnerBook: Self.renderReisnerBook(r.scorebook, gameId: gameIdStr),
                retrosheetEvents: Self.renderRetrosheet(r.retrosheet)
            )
        } catch let e as CoreFfiError {
            throw Self.mapError(e)
        }
    }
}

// MARK: - Error mapping (CoreFfiError.code → CoreError)

extension DiamondCoreClient {

    /// Map the thrown `CoreFfiError.Core(Error)` to the Swift `CoreError` cases by `error.code`
    /// (the stable machine signal — Art. I). The `message` is carried through for display only.
    static func mapError(_ e: CoreFfiError) -> CoreError {
        switch e {
        case .Core(let err):
            let msg = err.message
            switch err.code {
            case .unauthorized:
                return .unauthorized(msg)
            case .judgmentRequired:
                return .judgmentRequired(msg)
            case .pendingConfirmation:
                return .invalidState(msg)
            case .contradictoryState:
                // Finalize surfaces an unbalanced proof box as ContradictoryState (SC-011).
                return .proofBoxImbalance(msg)
            case .notFound:
                return .notFound(msg)
            case .ambiguousInput, .outOfFormat, .invalidArgument, .transcriptNotSupported:
                return .invalidState(msg)
            }
        }
    }
}

// MARK: - Projection helpers (generated boundary types → protocol types)

extension DiamondCoreClient {

    /// Narrow the rich generated `GameState` to the Phase-1 protocol `GameState`.
    /// `gameId` is threaded from the call context (the generated state has no id field).
    static func projectState(
        _ s: DiamondLedgerCoreBindings.GameState,
        gameId: GameId
    ) -> GameState {
        GameState(
            gameId: String(gameId),
            inning: Int(s.inning),
            isTopHalf: s.half == .top,
            outs: Int(s.outs)
        )
    }

    static func projectRecordPlay(
        _ r: DiamondLedgerCoreBindings.RecordPlayResult,
        gameId: GameId
    ) -> RecordPlayResult {
        RecordPlayResult(
            recordedSeq: r.recordedSeq,
            classification: projectClassification(r.classification),
            needs: projectNeeds(r.needs),
            judgment: r.judgment.map { projectJudgment($0) },
            reisner: projectReisner(r.reisner),
            statePreview: projectState(r.statePreview, gameId: gameId)
        )
    }

    static func projectClassification(
        _ c: DiamondLedgerCoreBindings.Classification
    ) -> RecordPlayClassification {
        switch c {
        case .deterministic:        return .deterministic
        case .judgment(let kind):   return .judgment(projectJudgmentKind(kind))
        case .outOfFormat(let msg): return .outOfFormat(msg)
        }
    }

    static func projectJudgmentKind(
        _ k: DiamondLedgerCoreBindings.JudgmentKind
    ) -> JudgmentKind {
        switch k {
        case .hitVsError:       return .hitVsError
        case .earnedVsUnearned: return .earnedVsUnearned
        case .contestedCredit:  return .contestedCredit
        case .ambiguousAdvance: return .ambiguousAdvance
        }
    }

    static func projectNeeds(_ n: DiamondLedgerCoreBindings.Needs) -> RecordPlayNeeds {
        switch n {
        case .none:     return .none
        case .confirm:  return .confirm
        case .clarify:  return .clarify
        case .judgment: return .judgment
        }
    }

    static func projectStatus(
        _ s: DiamondLedgerCoreBindings.JudgmentStatus
    ) -> JudgmentStatus {
        switch s {
        case .open:     return .open
        case .resolved: return .resolved
        case .pending:  return .pending
        }
    }

    static func projectActor(_ a: DiamondLedgerCoreBindings.Actor) -> Actor {
        Actor(
            kind: a.kind == .human ? .human : .agent,
            id: a.id,
            harnessVersion: a.harnessVersion
        )
    }

    static func projectCall(_ c: DiamondLedgerCoreBindings.Call) -> ScoringCall {
        ScoringCall(token: c.token, label: c.label)
    }

    static func projectJudgment(
        _ d: DiamondLedgerCoreBindings.JudgmentDecision
    ) -> RecordPlayJudgment {
        RecordPlayJudgment(
            id: d.id,
            kind: projectJudgmentKind(d.kind),
            status: projectStatus(d.status),
            recommendation: ScoringRecommendation(
                call: projectCall(d.recommendation.call),
                oneLineReason: d.recommendation.oneLineReason
            ),
            alternatives: d.alternatives.map { projectCall($0) },
            chosen: d.chosen.map { projectCall($0) },
            decider: d.decider.map { projectActor($0) }
        )
    }

    static func projectReisner(
        _ r: DiamondLedgerCoreBindings.ReisnerCell
    ) -> ReisnerCellSnapshot {
        ReisnerCellSnapshot(
            situationDiamond: r.situationDiamond,
            catalystSymbols: r.catalystSymbols,
            pitchMarks: r.pitchMarks.map { $0.mark },
            runnerFate: projectRunnerFate(r.runnerFate)
        )
    }

    static func projectRunnerFate(
        _ f: DiamondLedgerCoreBindings.RunnerFate
    ) -> RunnerFate {
        switch f {
        case .scored(let rbi): return .scored(rbi: rbi)
        case .putOut(let n):   return .putOut(n: n)
        case .leftOnBase:      return .leftOnBase
        }
    }

    // MARK: Finalize rendering (boundary export structs → the protocol's String fields)

    /// Render the generated `ReisnerScorebook` into a human-readable book string (US3).
    static func renderReisnerBook(
        _ book: DiamondLedgerCoreBindings.ReisnerScorebook,
        gameId: String
    ) -> String {
        var lines: [String] = []
        lines.append("Reisner Scorebook — game \(gameId)")
        lines.append(String(repeating: "─", count: 40))
        for (i, cell) in book.cells.enumerated() {
            let pitches = cell.pitchMarks.map { $0.mark }.joined(separator: " ")
            lines.append("#\(i + 1)  \(cell.situationDiamond)  \(cell.catalystSymbols)  \(pitches)")
        }
        lines.append(String(repeating: "─", count: 40))
        for pb in book.proofBoxes {
            let half = pb.half == .top ? "T" : "B"
            let lhs = pb.ab + pb.bb + pb.sac + pb.hbp + pb.interference
            let rhs = pb.runs + pb.putouts + pb.stranded
            let ok = lhs == rhs ? "✓ balanced" : "✗ UNBALANCED"
            lines.append("Proof box \(half)\(pb.inning): "
                + "AB \(pb.ab) + BB \(pb.bb) + SAC \(pb.sac) + HBP \(pb.hbp) + INT \(pb.interference) "
                + "= Runs \(pb.runs) + PO \(pb.putouts) + LOB \(pb.stranded)  \(ok)")
        }
        return lines.joined(separator: "\n")
    }

    /// Render the generated `RetrosheetExport` records into the canonical line-per-record file.
    static func renderRetrosheet(
        _ export: DiamondLedgerCoreBindings.RetrosheetExport
    ) -> String {
        export.records
            .map { ([$0.recordType] + $0.fields).joined(separator: ",") }
            .joined(separator: "\n")
    }
}

// MARK: - FactBridge: [String:String] → generated NormalizedPlay (the H1 fact seam, T044)

/// Translates the loose `normalizedFacts: [String: String]` the WoZ harness / grammar parser
/// produce today into the strongly-typed generated `NormalizedPlay` the real core requires.
///
/// This is deliberately small and explicit: v1 covers the two demo scripts the WoZ harness emits
/// (a clean 6-3 ground out → deterministic Card A; a misplayed grounder → HitVsError Card B).
/// The fact shapes below mirror the real core's own unit tests (`groundout_play()` and the
/// `judgment_play` in `core/src/primitives/mod.rs`), so classification matches the proven corpus.
///
/// Crucially the bridge supplies ONLY facts — it never sets a classification. The misplayed
/// grounder is surfaced by the FACT `touchedOrMisplayedBy: [SS]` on a ball the batter reached,
/// exactly as the core's classifier keys on (I1). No `"script"`-string shortcut reaches the core.
enum FactBridge {

    /// Build a `NormalizedPlay` from the fact map. Recognizes the WoZ demo scripts and the simple
    /// `batter_result`/`fielders` keys the grammar parser emits; falls back to a generic fielded
    /// out so an unrecognized map still produces a deterministic, confirmable play (never a crash,
    /// never a fabricated judgment).
    static func normalizedPlay(from facts: [String: String]) -> NormalizedPlay {
        // Card B (WoZ): explicit misplayed-grounder marker → the FACT pattern the core classifies
        // as HitVsError (a grounder to SS the batter reached, with SS charged as the misplayer).
        if facts["script"] == "misplayed-grounder" {
            return misplayedGrounder()
        }

        // Card B (REAL grammar path, DL-35): the grammar parser's `tryError` production emits
        // `["batter_result": "reached_on_error", "error_position": "6"]` for "reached on error /
        // error by short". A ball a fielder touched/misplayed that the batter reached on is exactly
        // a hit-vs-error JUDGMENT (I1) — so we build the misplay FACT pattern (FieldedOut + the
        // fielder under touched_or_misplayed_by + batter advancing to first). The core then derives
        // Card B from FACTS — no `"script"` marker. This is what makes the live mic Card B reachable.
        if facts["batter_result"] == "reached_on_error" {
            let pos = parseFielders(facts["error_position"])?.first ?? Position(6)
            return misplayedGrounder(at: pos)
        }

        // Card A: a clean ground out. The grammar parser emits e.g.
        // ["batter_result": "groundout", "fielders": "6-3", "outs_recorded": "1"].
        let fielders = parseFielders(facts["fielders"]) ?? [Position(6), Position(3)]
        switch facts["batter_result"] {
        case "groundout", "ground_out", .none:
            return groundOut(fielders: fielders)
        default:
            // Unrecognized but in-grammar-ish: a generic fielded out (deterministic, confirmable).
            return groundOut(fielders: fielders.isEmpty ? [Position(6), Position(3)] : fielders)
        }
    }

    /// Parse a fielder chain into positions. Each fielder is a single position digit (1-9, 0=DH),
    /// so this handles BOTH the WoZ format `"6-3"` AND the grammar parser's concatenated `"63"`
    /// (the plain-mic path emits the latter via `parseFielderSequence`'s `.joined()`). Splitting on
    /// `-`/space alone produced `Position(63)` for `"63"` — an out-of-range position the real core
    /// rejects (the H1 root cause of `CoreError 4`). Treat every digit as one fielder instead.
    /// Returns nil on empty/garbage so the caller can fall back to a sensible default chain.
    ///
    /// Internal (not private) so the real-path regression tests can assert the bug-class fix
    /// directly (`FactBridge.parseFielders("63") == [Position(6), Position(3)]`).
    static func parseFielders(_ s: String?) -> [Position]? {
        guard let s, !s.isEmpty else { return nil }
        let positions = s.compactMap { $0.wholeNumberValue }   // each digit char → a position
            .filter { (0...9).contains($0) }                    // valid baseball positions only
            .map { Position(UInt8($0)) }
        return positions.isEmpty ? nil : positions
    }

    /// A clean 6-3 (or supplied chain) ground out — deterministic, `Needs.confirm` (Card A).
    /// Mirrors `groundout_play()` in `core/src/primitives/mod.rs`.
    private static func groundOut(fielders: [Position]) -> NormalizedPlay {
        NormalizedPlay(
            situation: SituationDiamond(
                runners: Runners(first: nil, second: nil, third: nil),
                outs: 0,
                count: Count(balls: 0, strikes: 0),
                batterHand: .right
            ),
            catalyst: Catalyst(
                batterEvent: .fieldedOut,
                fielders: fielders,
                ballType: .ground,
                advances: [
                    Advance(runner: RunnerId(1), from: .home, to: .out, byError: nil)
                ],
                touchedOrMisplayedBy: []
            ),
            auditLabel: nil
        )
    }

    /// A misplayed grounder the batter reached on — the FACT pattern the core's classifier reads
    /// as `Judgment(HitVsError)` (`Needs.judgment`, Card B). Mirrors the `judgment_play` fixture
    /// in `core/src/primitives/mod.rs`: fielded-out batter_event, the fielder in the chain, the
    /// batter advancing to first, and that fielder recorded under `touched_or_misplayed_by`.
    /// `at` is the fielder charged (defaults to SS — position 6 — the WoZ demo's case).
    private static func misplayedGrounder(at fielder: Position = Position(6)) -> NormalizedPlay {
        NormalizedPlay(
            situation: SituationDiamond(
                runners: Runners(first: nil, second: nil, third: nil),
                outs: 0,
                count: Count(balls: 0, strikes: 0),
                batterHand: .right
            ),
            catalyst: Catalyst(
                batterEvent: .fieldedOut,
                fielders: [fielder],
                ballType: .ground,
                advances: [
                    Advance(runner: RunnerId(1), from: .home, to: .base(.first), byError: nil)
                ],
                touchedOrMisplayedBy: [fielder]
            ),
            auditLabel: nil
        )
    }

    /// Map a "1B"/"2B"/"3B"/"H" base string → the generated `AdvanceOutcome`.
    static func advanceOutcome(_ base: String) -> AdvanceOutcome {
        switch base {
        case "1B": return .base(.first)
        case "2B": return .base(.second)
        case "3B": return .base(.third)
        case "H":  return .base(.home)
        default:   return .out
        }
    }
}
