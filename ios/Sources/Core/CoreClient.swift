/// CoreClient.swift — T003 / T044 (Squad B, Story B1)
///
/// Swift mirror of the Rust `CoreApi` exposed via UniFFI (ADR-0007, H1).
///
/// This protocol is the **sole seam** between the iOS layer and the deterministic Rust core.
/// Two conformers exist:
///   - `MockCore` (T008) — canned results used by Squad B while Squad A builds the real core.
///   - The generated UniFFI Swift bindings (T037/T044/T071) — drops in at H1 with no protocol
///     changes; all callers stay identical.
///
/// **Owner-as-decider** (FR-020 / I5 / T036): every mutating primitive requires an authenticated
/// `ownerId`. The core enforces this deterministically; passing an empty or anonymous string is
/// an authorization error.
///
/// **No business logic lives here.** This file is the interface declaration only.
/// Implement the four atomic primitives in the Rust core (`core/src/primitives/`).
///
/// - SeeAlso: `contracts/record_play.md`, `contracts/advance_runner.md`,
///   `contracts/correct_event.md`, `contracts/finalize_scorecard.md`
/// - SeeAlso: `ios/Sources/Core/MockCore.swift` (T008 — Squad B unblocking stub)
/// - TODO: T044 — wrap the real UniFFI XCFramework once H1 lands (T071).

import Foundation

// MARK: - Result & Error types
// These are Swift-side representations of the typed error enum in `core/src/ffi.rs` (T007).
// Keep in sync with the FFI boundary — any divergence is a compile-time break at H1.

/// Typed errors from the deterministic core (mirrors `CoreError` in `core/src/ffi.rs`).
public enum CoreError: Error, Sendable {
    /// The supplied owner identity is missing or does not match the game owner (FR-020 / I5).
    case unauthorized(String)
    /// A judgment play was encountered but no open flag + decider is present (SC-003 / I2).
    case judgmentRequired(String)
    /// The proof-box does not balance; finalize is rejected (FR-005a / SC-011).
    case proofBoxImbalance(String)
    /// The requested game or event was not found.
    case notFound(String)
    /// The operation is not valid for the current game state.
    case invalidState(String)
    /// An unexpected internal error in the core.
    case internalError(String)
}

extension CoreError: LocalizedError {
    /// Surface the core's actual message (carried in each case's associated value) so the UI shows
    /// the real reason — e.g. "invalid fielder position" — instead of Foundation's opaque default
    /// "The operation couldn't be completed. (Core.CoreError error 4.)" for a bare enum error.
    public var errorDescription: String? {
        switch self {
        case .unauthorized(let m), .judgmentRequired(let m), .proofBoxImbalance(let m),
             .notFound(let m), .invalidState(let m), .internalError(let m):
            return m
        }
    }
}

/// Opaque game-state snapshot returned by the core after each primitive.
/// Full structure is defined in `core/src/model.rs` (T012) and the FFI surface (T007).
/// TODO: replace with the generated UniFFI struct at H1 (T044 / T071).
public struct GameState: Sendable {
    public let gameId: String
    public let inning: Int
    public let isTopHalf: Bool
    public let outs: Int
    // Additional fields (bases, line score, due-up batter, etc.) added at T044 / H1.
}

/// Opaque handle identifying a recorded play.
/// TODO: replace with the generated UniFFI type at H1.
public struct PlayId: Sendable, Hashable {
    public let rawValue: String
}

// MARK: - RecordPlayResult
//
// Mirrors `ffi::RecordPlayResult` (core/src/ffi.rs). Carries the full judgment and loop-control
// payload so Card B can surface: the caller MUST NOT project down to bare GameState, which would
// silently drop `needs` and `judgment` and make Card B unreachable (P0 fix, H1-compatibility).
//
// Types referenced below (`RecordPlayClassification`, `RecordPlayNeeds`, `RecordPlayJudgment`,
// `ReisnerCellSnapshot`) are Swift-native aliases over the MockFFI shapes until H1 replaces them
// with the generated UniFFI structs.

/// Mirrors `ffi::Classification` at the protocol seam — keeps `CoreClient` concrete-type-free
/// while exposing the three lanes the read-verify-correct loop dispatches on.
public enum RecordPlayClassification: Sendable, Equatable {
    /// Facts unambiguously determine the play outcome. Card A path.
    case deterministic
    /// Facts require a scorer judgment of the specified kind. Card B path (I2/FR-010).
    case judgment(JudgmentKind)
    /// Input falls outside the reduced v1 grammar. Needs-review path (FR-017).
    case outOfFormat(String)
}

/// Mirrors `ffi::JudgmentKind` — the four possible scoring judgments.
public enum JudgmentKind: String, Sendable, Equatable {
    case hitVsError
    case earnedVsUnearned
    case contestedCredit
    case ambiguousAdvance
}

/// Mirrors `ffi::Needs` — what the loop requires next after `recordPlay`.
public enum RecordPlayNeeds: String, Sendable, Equatable {
    /// Nothing further — the step is complete.
    case none
    /// A confirm is required before state advances (FR-007). Card A.
    case confirm
    /// Ambiguous input — a single clarification is required (FR-008).
    case clarify
    /// Facts are a judgment — an open decision must be surfaced (FR-010). Card B.
    case judgment
}

/// Mirrors `ffi::JudgmentStatus`.
public enum JudgmentStatus: String, Sendable, Equatable {
    case open, resolved, pending
}

/// A candidate scoring call (recommendation or alternative). Mirrors `ffi::Call`.
public struct ScoringCall: Sendable, Equatable {
    public let token: String  // e.g. "hit", "error:6"
    public let label: String  // display, e.g. "Hit"
    public init(token: String, label: String) {
        self.token = token
        self.label = label
    }
}

/// The core's recommended call plus a one-line rationale. Mirrors `ffi::Recommendation`.
public struct ScoringRecommendation: Sendable, Equatable {
    public let call: ScoringCall
    public let oneLineReason: String
    public init(call: ScoringCall, oneLineReason: String) {
        self.call = call
        self.oneLineReason = oneLineReason
    }
}

/// Mirrors `ffi::Actor` — the recorded decider identity when a judgment is resolved (FR-011).
///
/// `kind` distinguishes human scorers from authorized agents (data-model §2). `harnessVersion` is
/// present for agent callers (audit); nil for human callers.
public struct Actor: Sendable, Equatable {
    public let kind: ActorKind
    /// Stable account / agent identity string (owner id, agent id, …).
    public let id: String
    /// Agent harness/build version (`nil` for human callers).
    public let harnessVersion: String?
    public init(kind: ActorKind, id: String, harnessVersion: String? = nil) {
        self.kind = kind
        self.id = id
        self.harnessVersion = harnessVersion
    }
}

/// Whether the caller is a human operator or an authorized agent. Mirrors `ffi::ActorKind`.
public enum ActorKind: String, Sendable, Equatable {
    case human
    case agent
}

/// An open or resolved scoring judgment. Mirrors `ffi::JudgmentDecision` (FR-010/011).
///
/// The core **never** auto-resolves a judgment (I2). When `status == .open`:
/// - `chosen` is `nil`
/// - `decider` is `nil`
/// These only become non-nil once the UI surfaces Card B and the scorer taps a call.
public struct RecordPlayJudgment: Sendable {
    public let id: UInt64
    public let kind: JudgmentKind
    public let status: JudgmentStatus
    public let recommendation: ScoringRecommendation
    public let alternatives: [ScoringCall]
    /// The chosen call — `nil` while `.open` or `.pending` (I2).
    public let chosen: ScoringCall?
    /// The recorded decider identity (FR-011) — `nil` iff unresolved.
    public let decider: Actor?
    public init(
        id: UInt64,
        kind: JudgmentKind,
        status: JudgmentStatus,
        recommendation: ScoringRecommendation,
        alternatives: [ScoringCall],
        chosen: ScoringCall?,
        decider: Actor?
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.recommendation = recommendation
        self.alternatives = alternatives
        self.chosen = chosen
        self.decider = decider
    }
}

/// The result of `recordPlay` — carries the full judgment payload and loop-control enum so the
/// caller can dispatch to Card A (`.deterministic`, `needs == .confirm`) or Card B
/// (`.judgment(...)`, `needs == .judgment`) without any data loss.
///
/// Mirrors `ffi::RecordPlayResult` (core/src/ffi.rs). The `statePreview` is the resulting state
/// **if confirmed** — it is NOT yet applied until a subsequent `confirmPlay` (FR-007).
///
/// TODO: At H1, replace this with the generated UniFFI type (T044 / T071).
public struct RecordPlayResult: Sendable {
    /// Monotonic per-game event sequence number of the recorded entry.
    public let recordedSeq: UInt64
    /// Fact-derived classification: determines Card A vs Card B (I1/FR-006).
    public let classification: RecordPlayClassification
    /// Loop-control: what the caller must do next (confirm / judgment / clarify / none).
    public let needs: RecordPlayNeeds
    /// Open judgment, present iff `classification == .judgment` (status always `.open` here).
    /// `nil` for deterministic and out-of-format plays.
    public let judgment: RecordPlayJudgment?
    /// Rendered Reisner cell for the verify card.
    public let reisner: ReisnerCellSnapshot
    /// Game state resulting IF this play is confirmed — not yet applied (FR-007).
    public let statePreview: GameState

    public init(
        recordedSeq: UInt64,
        classification: RecordPlayClassification,
        needs: RecordPlayNeeds,
        judgment: RecordPlayJudgment?,
        reisner: ReisnerCellSnapshot,
        statePreview: GameState
    ) {
        self.recordedSeq = recordedSeq
        self.classification = classification
        self.needs = needs
        self.judgment = judgment
        self.reisner = reisner
        self.statePreview = statePreview
    }
}

/// Mirrors `ffi::RunnerFate` for the Reisner cell.
public enum RunnerFate: Sendable, Equatable {
    case scored(rbi: Bool)
    case putOut(n: UInt8)
    case leftOnBase
}

/// A snapshot of a rendered Reisner cell for the verify card. Mirrors `ffi::ReisnerCell`.
/// Named `ReisnerCellSnapshot` to avoid any future conflict with a generated UniFFI type.
public struct ReisnerCellSnapshot: Sendable {
    public let situationDiamond: String
    public let catalystSymbols: String
    public let pitchMarks: [String]
    public let runnerFate: RunnerFate
    public init(
        situationDiamond: String,
        catalystSymbols: String,
        pitchMarks: [String],
        runnerFate: RunnerFate
    ) {
        self.situationDiamond = situationDiamond
        self.catalystSymbols = catalystSymbols
        self.pitchMarks = pitchMarks
        self.runnerFate = runnerFate
    }
}

// MARK: - CreateGameResult
//
// Result of `createGame` — mirrors the Rust `create_game` intent (data-model §2):
// a stable GameId plus the initial projected GameState (pre-play, both counts zero).

/// Result of `CoreClient.createGame(...)`.
public struct CreateGameResult: Sendable {
    /// Stable opaque game identifier (integer-valued at the Rust boundary, String here for Phase 1).
    public let gameId: String
    /// Initial projected game state (top of 1st, 0-0-0 count, bases empty).
    public let state: GameState
    public init(gameId: String, state: GameState) {
        self.gameId = gameId
        self.state = state
    }
}

// MARK: - ConfirmPlayResult / ResolveJudgmentResult
//
// Mirrors `ffi` confirm_play / resolve_judgment intent (FR-007 / FR-011).

/// Result of `CoreClient.confirmPlay(...)`. The confirmed state is now applied (FR-007).
public struct ConfirmPlayResult: Sendable {
    /// Sequence number of the now-confirmed event.
    public let confirmedSeq: UInt64
    /// Updated game state after the confirmation is applied.
    public let state: GameState
    public init(confirmedSeq: UInt64, state: GameState) {
        self.confirmedSeq = confirmedSeq
        self.state = state
    }
}

/// Result of `CoreClient.resolveJudgment(...)`. Contains the updated decision + applied state.
public struct ResolveJudgmentResult: Sendable {
    /// The judgment decision updated with the chosen call and decider identity (FR-011).
    public let decision: RecordPlayJudgment
    /// Game state after the judgment resolution is applied.
    public let state: GameState
    public init(decision: RecordPlayJudgment, state: GameState) {
        self.decision = decision
        self.state = state
    }
}

/// The human-readable scorebook plus the Retrosheet event file produced by `finalizeScorecard`.
/// TODO: replace with the generated UniFFI type at H1.
public struct FinalizedScorebook: Sendable {
    public let reisnerBook: String       // Human-readable Reisner notation
    public let retrosheetEvents: String  // Reduced-Retrosheet event file (cwevent-gated)
}

// MARK: - CoreClient protocol

/// The Swift mirror of the Rust `CoreApi`. Backed by `MockCore` (T008) until H1 (T071).
///
/// All methods are `async throws` — the FFI bridge is async; errors are typed `CoreError`.
/// All methods are `Sendable`-safe; the conforming type must be `actor` or internally synchronized.
public protocol CoreClient: Sendable {

    // MARK: Primitive 0 — create_game (data-model §2)
    //
    // Opens a new game for the given home/visitor teams and actor. Returns a stable game id
    // plus the initial projected GameState (top of 1st, zero count, bases empty).
    // Authority (ownerId) is required — empty ownerId → CoreError.unauthorized (I5/FR-020).

    /// Create a new game for the given teams.
    /// - Parameters:
    ///   - homeTeam: Home team name or identifier.
    ///   - visitorTeam: Visiting team name or identifier.
    ///   - ownerId: Authenticated owner identity (FR-020).
    ///   - correlationId: Caller-supplied idempotency key.
    /// - Returns: `CreateGameResult` with the stable game id and initial state.
    /// - Throws: `CoreError.unauthorized` if `ownerId` is empty.
    func createGame(
        homeTeam: String,
        visitorTeam: String,
        ownerId: String,
        correlationId: String
    ) async throws -> CreateGameResult

    // MARK: Primitive 1 — record_play (US1 · FR-002 · contracts/record_play.md)
    //
    // Accepts a normalized-fact representation of a play (the transcript→parse layer produces
    // this; the core never sees raw audio or transcript). The core appends an event to the
    // immutable event log and returns a `RecordPlayResult` carrying classification, needs,
    // judgment (if applicable), Reisner cell, and the state preview (not yet applied, FR-007).
    //
    // IMPORTANT: callers must NOT narrow the result to bare GameState — that drops `needs` and
    // `judgment`, making Card B (judgment path) unreachable (P0). Dispatch on `result.needs`.
    //
    // Idempotent on duplicate correlation IDs (FR-002 / Art. III).
    // Blocks state advance until the caller confirms (FR-007 / read-verify-correct loop).
    //
    // TODO: T044 — replace `[String: String]` normalizedFacts with the generated UniFFI type.

    /// Record a scored play from normalized facts (never raw audio).
    /// - Parameters:
    ///   - gameId: Identifies the game being scored.
    ///   - ownerId: Authenticated owner identity (FR-020). Must match the game owner.
    ///   - normalizedFacts: Fact representation of the play (T012 / `NormalizedPlay`).
    ///   - correlationId: Caller-supplied idempotency key.
    /// - Returns: `RecordPlayResult` carrying classification, needs, judgment (if any), Reisner
    ///            cell, and the state preview. Dispatch on `result.needs` to route Card A vs B.
    /// - Throws: `CoreError.unauthorized` if `ownerId` is empty or does not match the game owner.
    func recordPlay(
        gameId: String,
        ownerId: String,
        normalizedFacts: [String: String],
        correlationId: String
    ) async throws -> RecordPlayResult

    // MARK: Primitive 2 — advance_runner (US1 · FR-009 · contracts/advance_runner.md)
    //
    // Explicitly advances a runner to a base. Required when runner advancement is ambiguous
    // (the core marks those as judgment; the UI surfaces Card B / T054).
    //
    // TODO: T044 — replace `String` base with a typed enum.

    /// Advance a runner to a specified base.
    /// - Parameters:
    ///   - gameId: Identifies the game.
    ///   - ownerId: Authenticated owner identity (FR-020).
    ///   - runnerId: Identity of the runner being advanced.
    ///   - toBase: Target base ("1B", "2B", "3B", "H").
    ///   - correlationId: Idempotency key.
    /// - Returns: Updated game state.
    func advanceRunner(
        gameId: String,
        ownerId: String,
        runnerId: String,
        toBase: String,
        correlationId: String
    ) async throws -> GameState

    // MARK: Primitive 3 — correct_event (US4 · FR-012/013/014 · contracts/correct_event.md)
    //
    // Amends a prior applied play via an append-only amendment; triggers downstream recompute
    // (runners / outs / line-score / notation / proof-box). US4 / post-MVP.
    //
    // MVP scope (remediation I1): the "Correct" action in Card A (T053) amends only the
    // *pending unconfirmed* entry (re-record before confirm). Amending a *prior applied* play
    // requires this primitive and is gated OFF in the first demo slice.
    //
    // TODO: T044 — replace `[String: String]` with the generated UniFFI amendment type.

    /// Amend a previously applied play (US4 / post-MVP — gated OFF in first demo slice).
    /// - Parameters:
    ///   - gameId: Identifies the game.
    ///   - ownerId: Authenticated owner identity (FR-020).
    ///   - playId: The play being corrected.
    ///   - amendment: New normalized facts replacing the original.
    ///   - correlationId: Idempotency key.
    /// - Returns: Updated game state after downstream recompute.
    func correctEvent(
        gameId: String,
        ownerId: String,
        playId: PlayId,
        amendment: [String: String],
        correlationId: String
    ) async throws -> GameState

    // MARK: Primitive 3b — confirm_play (FR-007 · read-verify-correct loop)
    //
    // Applies the pending unconfirmed event to the log and advances projected state. The caller
    // must call this after `recordPlay` returns `needs == .confirm` (Card A path). State does not
    // advance until confirmation; any subsequent `recordPlay` on a game with a pending unconfirmed
    // entry is rejected with `CoreError.invalidState` (PendingConfirmation guard).
    //
    // Mirror of Rust `confirm_play { game_id, confirms_seq, actor }` (FR-007).

    /// Confirm the pending unconfirmed play and advance game state (FR-007 / Card A confirm tap).
    /// - Parameters:
    ///   - gameId: Identifies the game.
    ///   - confirmsSeq: The sequence number of the unconfirmed play being confirmed.
    ///   - ownerId: Authenticated owner identity (FR-020).
    ///   - correlationId: Idempotency key.
    /// - Returns: `ConfirmPlayResult` with the confirmed seq and applied game state.
    /// - Throws: `CoreError.unauthorized` if `ownerId` is empty;
    ///           `CoreError.invalidState` if no pending-unconfirmed entry exists.
    func confirmPlay(
        gameId: String,
        confirmsSeq: UInt64,
        ownerId: String,
        correlationId: String
    ) async throws -> ConfirmPlayResult

    // MARK: Primitive 3c — resolve_judgment (FR-011 · Card B resolution)
    //
    // Records the scorer's call for an open judgment decision plus the decider identity (FR-011).
    // The core rejects any attempt to auto-resolve (I2 — the human must tap). After resolution the
    // judgment's status transitions to `.resolved`; `chosen` and `decider` become non-nil.
    //
    // Mirror of Rust `resolve_judgment { game_id, decision_id, chosen, actor }` (FR-011).

    /// Resolve an open judgment with the scorer's chosen call and decider identity (FR-011 / Card B tap).
    /// - Parameters:
    ///   - gameId: Identifies the game.
    ///   - decisionId: The id of the open `JudgmentDecision` being resolved.
    ///   - chosen: The scorer's chosen `ScoringCall` (token + label from the alternatives list).
    ///   - ownerId: Authenticated owner identity (FR-020) — becomes the recorded decider.
    ///   - correlationId: Idempotency key.
    /// - Returns: `ResolveJudgmentResult` with the updated decision (status `.resolved`) and state.
    /// - Throws: `CoreError.unauthorized` if `ownerId` is empty;
    ///           `CoreError.notFound` if `decisionId` does not exist;
    ///           `CoreError.invalidState` if the judgment is already resolved.
    func resolveJudgment(
        gameId: String,
        decisionId: UInt64,
        chosen: ScoringCall,
        ownerId: String,
        correlationId: String
    ) async throws -> ResolveJudgmentResult

    // MARK: Primitive 4 — finalize_scorecard (US3 · FR-015 · contracts/finalize_scorecard.md)
    //
    // Closes the game: asserts authority, requires a balanced proof-box (FR-005a / SC-011),
    // reports any PENDING judgments, emits the human Reisner book and the reduced-Retrosheet
    // event file (cwevent-gated in CI, T059/T060).

    /// Finalize the scorecard and produce the human book + Retrosheet export.
    /// - Parameters:
    ///   - gameId: Identifies the game.
    ///   - ownerId: Authenticated owner identity (FR-020).
    ///   - correlationId: Idempotency key.
    /// - Returns: `FinalizedScorebook` with Reisner book + Retrosheet event file.
    /// - Throws: `CoreError.proofBoxImbalance` if the proof-box does not balance (SC-011);
    ///           `CoreError.judgmentRequired` if unresolved judgment plays remain.
    func finalizeScorecard(
        gameId: String,
        ownerId: String,
        correlationId: String
    ) async throws -> FinalizedScorebook

    // MARK: Read surface (T037 — get_game_state / list_events / get_play / get_proof_box)
    // TODO: T044 — add typed read methods once T037 finalizes the FFI surface.
}
