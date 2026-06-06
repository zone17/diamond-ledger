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
/// DL-154: the bridge now maps EVERY `batter_result` the (broadened, DL-151) grammar emits to
/// the correct `BatterEvent` + `advances` the real core classifies and records. Before DL-154 a
/// silent `default → groundOut` collapse turned "home run", "walk", "strikeout", "double play",
/// etc. into a 6-3 GROUND OUT (the broadened grammar was moot). That collapse is GONE: an
/// unrecognized `batter_result` is now surfaced as `BatterEvent.other` → the core classifies it
/// `OutOfFormat` (FR-017, never a fabricated ground-out).
///
/// Crucially the bridge supplies ONLY facts — it never sets a classification (I1). A clean play
/// (out / hit / walk / K / HR) carries an EMPTY `touchedOrMisplayedBy` and a faithful advance set,
/// so the core derives `Deterministic` (Card A). Only a genuine misplay (a ball a fielder
/// touched/misplayed that the batter reached on) carries the fielder under `touchedOrMisplayedBy`,
/// from which the core derives `Judgment(HitVsError)` (Card B). No `"script"`/label shortcut and
/// no fabricated judgment ever reaches the core.
///
/// ### Grammar `batter_result` → core `BatterEvent` → expected Card + state delta
/// (empty bases, 0 outs; deltas are at confirm time)
///
/// | `batter_result`        | `BatterEvent`     | facts                                   | Card | Δ state            |
/// |------------------------|-------------------|-----------------------------------------|------|--------------------|
/// | `groundout`            | `.fieldedOut`     | fielders, ball .ground, batter→out      | A    | +1 out             |
/// | `flyout`               | `.fieldedOut`     | fielder, ball .fly, batter→out          | A    | +1 out             |
/// | `strikeout`            | `.strikeout`      | batter→out, ball .none                   | A    | +1 out             |
/// | `strikeout_looking`    | `.strikeout`*     | batter→out, ball .none                   | A    | +1 out             |
/// | `walk`                 | `.walk`           | batter→first                            | A    | runner on 1st      |
/// | `intentional_walk`     | `.intentionalWalk`| batter→first                            | A    | runner on 1st      |
/// | `home_run`             | `.homeRun`        | batter→home, ball .fly                   | A    | +1 run, 0 outs     |
/// | `single`               | `.single`         | batter→first (≤1 fielder, no touch)     | A    | runner on 1st      |
/// | `double`               | `.double`         | batter→second (clean XBH)               | A    | runner on 2nd      |
/// | `triple`               | `.triple`         | batter→third (clean XBH)                | A    | runner on 3rd      |
/// | `hit_by_pitch`         | `.hitByPitch`     | batter→first                            | A    | runner on 1st      |
/// | `sac_fly`              | `.sacFly`         | fielder, ball .fly, batter→out          | A    | +1 out             |
/// | `sac_bunt`             | `.sacBunt`        | fielders, ball .bunt, batter→out        | A    | +1 out             |
/// | `reached_on_error`     | `.fieldedOut`     | fielder touched + batter→first          | B    | (resolve then +…)  |
/// | `double_play`          | `.fieldedOut`     | fielders, ball .ground, 2× →out         | A/B† | +2 outs            |
/// | *(unrecognized)*       | `.other`          | empty catalyst                          | OOF  | none (needs review)|
///
/// *The core's `BatterEvent` has no looking/swinging distinction — both Kl and K map to
///  `.strikeout` and record an identical +1 out. The Kl notation is not preserved by the core
///  model (documented limitation, see DL-154 follow-up).
/// †A double play is fact-derived: with a 3-fielder chain + 2 outs the core's classifier treats it
///  as `ContestedCredit` (who is credited the putouts/assists) — a genuine Card-B judgment, NOT a
///  collapse. The bridge emits the faithful fielder chain and lets the core decide; a 2-fielder
///  chain stays `Deterministic`. Either way the recorded state delta is +2 outs.
enum FactBridge {

    /// Build a `NormalizedPlay` from the fact map. Maps each grammar `batter_result` to the
    /// correct `BatterEvent` + advances the real core records; an UNRECOGNIZED `batter_result`
    /// surfaces as `BatterEvent.other` → `OutOfFormat` (never a fabricated ground-out, DL-154).
    static func normalizedPlay(from facts: [String: String]) -> NormalizedPlay {
        // Card B (WoZ): explicit misplayed-grounder marker → the FACT pattern the core classifies
        // as HitVsError (a grounder to SS the batter reached, with SS charged as the misplayer).
        if facts["script"] == "misplayed-grounder" {
            return misplayedGrounder()
        }

        // The grammar's concatenated fielder chain ("63"/"643"), or a single fielder digit.
        let fielders = parseFielders(facts["fielders"])
        let fielder = parseFielders(facts["fielder"])?.first

        switch facts["batter_result"] {

        // ── Outs (deterministic, Card A) ──────────────────────────────────────────────
        case "groundout", "ground_out":
            return fieldedOut(fielders: fielders ?? [Position(6), Position(3)], ballType: .ground)

        case "flyout", "fly_out":
            return fieldedOut(fielders: fielder.map { [$0] } ?? [Position(8)], ballType: .fly)

        case "strikeout", "strikeout_looking":
            // The core's BatterEvent has no looking/swinging split — both record +1 out (DL-154 †).
            return batterOut(event: .strikeout, fielders: [], ballType: .none)

        // ── On base, no fielder touch (deterministic, Card A) ─────────────────────────
        case "walk":
            return batterReaches(event: .walk, to: .first)

        case "intentional_walk":
            return batterReaches(event: .intentionalWalk, to: .first)

        case "hit_by_pitch":
            return batterReaches(event: .hitByPitch, to: .first)

        // ── Hits (deterministic, Card A) ──────────────────────────────────────────────
        // A clean hit carries EMPTY touchedOrMisplayedBy (else HitVsError fires) and, for the
        // single, ≤1 fielder (a 2+-fielder throw chain on a safe batter is the core's
        // ContestedCredit). Double/Triple use the clean-XBH BatterEvent so a 2-base batter
        // advance is NOT read as an AmbiguousAdvance.
        case "single":
            return cleanHit(event: .single, to: .first, fielders: fielder.map { [$0] } ?? [])

        case "double":
            return cleanHit(event: .double, to: .second, fielders: [])

        case "triple":
            return cleanHit(event: .triple, to: .third, fielders: [])

        case "home_run":
            // Batter circles the bases: Home → Home scores a run (no fielder, no out).
            return cleanHit(event: .homeRun, to: .home, fielders: [], ballType: .fly)

        // ── Sacrifices (deterministic, Card A) — batter retired, runner(s) implied ─────
        case "sac_fly":
            return batterOut(event: .sacFly, fielders: fielder.map { [$0] } ?? [Position(9)], ballType: .fly)

        case "sac_bunt":
            return batterOut(event: .sacBunt, fielders: fielders ?? [Position(1), Position(3)], ballType: .bunt)

        // ── Double play (fact-derived Card A or B) — TWO outs on one play ──────────────
        case "double_play":
            return doublePlay(fielders: fielders ?? [Position(6), Position(4), Position(3)])

        // ── Reached on error (fact-derived JUDGMENT, Card B) ──────────────────────────
        // A ball a fielder touched/misplayed that the batter reached on is a hit-vs-error
        // judgment (I1): FieldedOut + the fielder under touchedOrMisplayedBy + batter to first.
        case "reached_on_error":
            let pos = parseFielders(facts["error_position"])?.first ?? Position(6)
            return misplayedGrounder(at: pos)

        // ── Unrecognized / missing batter_result → OutOfFormat (FR-017) ───────────────
        // No silent ground-out collapse (the DL-154 fix). BatterEvent.other makes the core's
        // classifier return OutOfFormat — the play surfaces for review, it is NOT fabricated.
        default:
            return outOfFormat(audit: facts["batter_result"])
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

    /// The empty pre-play situation every bridged play starts from (bases empty, 0 outs, 0-0,
    /// right-handed). State the play actually advances is computed by the core's rules engine
    /// from the `advances` below — the situation is only the pre-play snapshot.
    private static func baseSituation() -> SituationDiamond {
        SituationDiamond(
            runners: Runners(first: nil, second: nil, third: nil),
            outs: 0,
            count: Count(balls: 0, strikes: 0),
            batterHand: .right
        )
    }

    /// A batter retired on the play (the batter-runner advance is `→ out`). One out, deterministic.
    /// Used for strikeout / sac fly / sac bunt (the catalyst differs only by event + fielders + ball).
    private static func batterOut(
        event: BatterEvent,
        fielders: [Position],
        ballType: BallType
    ) -> NormalizedPlay {
        NormalizedPlay(
            situation: baseSituation(),
            catalyst: Catalyst(
                batterEvent: event,
                fielders: fielders,
                ballType: ballType,
                advances: [
                    Advance(runner: RunnerId(1), from: .home, to: .out, byError: nil)
                ],
                touchedOrMisplayedBy: []
            ),
            auditLabel: nil
        )
    }

    /// A clean fielded out (ground out / fly out) — deterministic, `Needs.confirm` (Card A).
    /// Mirrors `groundout_play()` in `core/src/primitives/mod.rs`. `touchedOrMisplayedBy` is empty
    /// (a clean out the fielder converted, NOT a misplay the batter reached on).
    private static func fieldedOut(fielders: [Position], ballType: BallType) -> NormalizedPlay {
        batterOut(event: .fieldedOut, fielders: fielders, ballType: ballType)
    }

    /// The batter reaches a base on a NON-batted-ball event (walk / IBB / HBP) — deterministic.
    /// No fielders, no ball type, no fielder touch → the core classifies Deterministic (Card A).
    private static func batterReaches(event: BatterEvent, to base: Base) -> NormalizedPlay {
        NormalizedPlay(
            situation: baseSituation(),
            catalyst: Catalyst(
                batterEvent: event,
                fielders: [],
                ballType: .none,
                advances: [
                    Advance(runner: RunnerId(1), from: .home, to: .base(base), byError: nil)
                ],
                touchedOrMisplayedBy: []
            ),
            auditLabel: nil
        )
    }

    /// A clean hit (single / double / triple / home run) — deterministic, Card A.
    ///
    /// `touchedOrMisplayedBy` is EMPTY (else the core fires `Judgment(HitVsError)`). For a single,
    /// keep the chain to ≤1 fielder — a 2+-fielder throw chain on a safe batter is the core's
    /// `ContestedCredit`. Double/Triple pass their clean-XBH `BatterEvent` so a 2/3-base batter
    /// advance is NOT misread as an `AmbiguousAdvance`. Home run scores (Home → Home).
    private static func cleanHit(
        event: BatterEvent,
        to base: Base,
        fielders: [Position],
        ballType: BallType = .line
    ) -> NormalizedPlay {
        NormalizedPlay(
            situation: baseSituation(),
            catalyst: Catalyst(
                batterEvent: event,
                fielders: fielders,
                ballType: ballType,
                advances: [
                    Advance(runner: RunnerId(1), from: .home, to: .base(base), byError: nil)
                ],
                touchedOrMisplayedBy: []
            ),
            auditLabel: nil
        )
    }

    /// A double play — TWO outs on one play (the batter retired plus a runner forced/relayed out).
    ///
    /// Fact-derived classification (NOT fabricated): with a 3-fielder chain + 2 outs the core's
    /// classifier returns `Judgment(ContestedCredit)` (the credit among relaying fielders is the
    /// scorer's call); a 2-fielder chain stays `Deterministic`. The bridge emits the faithful chain
    /// and lets the core decide. Either way the rules engine records +2 outs.
    private static func doublePlay(fielders: [Position]) -> NormalizedPlay {
        NormalizedPlay(
            situation: baseSituation(),
            catalyst: Catalyst(
                batterEvent: .fieldedOut,
                fielders: fielders,
                ballType: .ground,
                advances: [
                    // Batter retired at first.
                    Advance(runner: RunnerId(1), from: .home, to: .out, byError: nil),
                    // The lead runner forced out (RunnerId(2) — the core counts the second out
                    // even when no prior runner is on base in a fresh-game test, see rules engine).
                    Advance(runner: RunnerId(2), from: .first, to: .out, byError: nil)
                ],
                touchedOrMisplayedBy: []
            ),
            auditLabel: nil
        )
    }

    /// An UNRECOGNIZED / unsupported `batter_result` → `BatterEvent.other`, which the core's
    /// classifier returns as `OutOfFormat` (FR-017). This REPLACES the pre-DL-154 silent
    /// `default → groundOut` collapse: an unknown fact map now surfaces for review instead of
    /// being fabricated into a fake ground-out. The original `batter_result` is carried in the
    /// AUDIT-ONLY `auditLabel` for provenance — the core NEVER reads it for classification (I1).
    private static func outOfFormat(audit: String?) -> NormalizedPlay {
        NormalizedPlay(
            situation: baseSituation(),
            catalyst: Catalyst(
                batterEvent: .other,
                fielders: [],
                ballType: .none,
                advances: [],
                touchedOrMisplayedBy: []
            ),
            auditLabel: audit
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
