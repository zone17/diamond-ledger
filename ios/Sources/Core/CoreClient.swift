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

    // MARK: Primitive 1 — record_play (US1 · FR-002 · contracts/record_play.md)
    //
    // Accepts a normalized-fact representation of a play (the transcript→parse layer produces
    // this; the core never sees raw audio or transcript). The core appends an event to the
    // immutable event log and returns an updated `GameState`.
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
    /// - Returns: Updated game state after the play is appended (pending confirmation).
    /// - Throws: `CoreError.unauthorized` if `ownerId` is invalid;
    ///           `CoreError.judgmentRequired` if the play requires scorer judgment (US2).
    func recordPlay(
        gameId: String,
        ownerId: String,
        normalizedFacts: [String: String],
        correlationId: String
    ) async throws -> GameState

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
