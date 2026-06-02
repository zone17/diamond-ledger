/// MockCore.swift — T008 (Squad B, Story B1) · handoff **H1** unblocking stub
///
/// A **canned, obviously-fake** implementation of the `CoreClient` boundary so Squad B can
/// build the entire iOS judgment-loop UI (Card A deterministic / Card B judgment, the
/// glanceable HUD, the confirm/correct flow) **before** the real Rust core lands at H1.
///
/// ## What this is (and is not)
///
/// - It **conforms to `CoreClient`** (the sole iOS↔core seam, `CoreClient.swift`). When the
///   generated UniFFI bindings drop in at H1 (T037/T044/T071), this file is deleted and the
///   real conformer is wired in its place — **no caller changes** (drop-in parity, SC-008).
/// - It returns **hardcoded, plausible** results by switching on the input. There is **zero**
///   scoring logic here: no classification, no replay, no proof-box math. Do not add any — the
///   real determinism lives in the Rust core (`core/src/`), guarded integer-only per ADR-0007.
/// - The richer typed shapes below (`MockFFI.*`) mirror the **frozen FFI schema** in
///   `core/src/ffi.rs` (T007) one-to-one, so reviewers can see the real boundary the mock stands
///   in for. They are translation references for H1, not a second source of truth.
///
/// ## Canned scripts (drive the two demo cards from `interaction-spec.md`)
///
/// - **Card A — deterministic** (the ~85%): a clear `"6-3"` ground out → a confirm-card preview
///   (`Classification.deterministic`, `Needs.confirm`).
/// - **Card B — judgment** (the ~15%, V3 "glance"): a misplayed grounder → an **open**
///   `HitVsError` decision with a recommendation + alternatives (`Needs.judgment`). The mock
///   **never** resolves it (I2) — the UI's tap resolves it.
///
/// - SeeAlso: `core/src/ffi.rs` (T007 frozen schema — translate shape here),
///   `core/src/model.rs` (T012 fact types), `CoreClient.swift` (T003 protocol),
///   `specs/001-voice-scorebook-core/prototype/interaction-spec.md` (V3 Card A vs Card B),
///   `specs/001-voice-scorebook-core/contracts/` (per-primitive I/O contracts).

import Foundation

// MARK: - MockFFI: Swift mirror of the frozen FFI schema (core/src/ffi.rs, T007)
//
// These types translate the SHAPE of `core/src/ffi.rs` into Swift so the canned results below
// are structurally faithful to the real boundary. Integer-only at the seam (ADR-0007 / I6):
// every field here is Int / discrete / String — NO Double/Float anywhere, exactly as in Rust.
// At H1 these are superseded by the generated UniFFI types; until then they document the target.
enum MockFFI {

    // --- Loop-control & shared enums (ffi.rs §Loop-control) ---

    /// Mirrors `ffi::Needs` — what the read-verify-correct loop requires next after a write.
    enum Needs: String, Sendable { case none, confirm, clarify, judgment }

    /// Mirrors `ffi::Half`.
    enum Half: String, Sendable { case top, bottom }

    /// Mirrors `model::Classification` (the fact-derived seam, I1).
    enum Classification: Sendable, Equatable {
        case deterministic
        case judgment(JudgmentKind)
        case outOfFormat(String)
    }

    /// Mirrors `model::JudgmentKind`.
    enum JudgmentKind: String, Sendable { case hitVsError, earnedVsUnearned, contestedCredit, ambiguousAdvance }

    /// Mirrors `ffi::JudgmentStatus`.
    enum JudgmentStatus: String, Sendable { case open, resolved, pending }

    // --- Judgment decision (US2 — surfaced, never auto-resolved) ---

    /// Mirrors `ffi::Call` — an opaque, stable call token + display label.
    struct Call: Sendable, Equatable {
        let token: String   // e.g. "hit", "error:6"
        let label: String   // display, e.g. "Hit"
    }

    /// Mirrors `ffi::Recommendation` — the core's suggested call + one-line why.
    struct Recommendation: Sendable, Equatable {
        let call: Call
        let oneLineReason: String
    }

    /// Mirrors `ffi::JudgmentDecision`. The mock always returns `.open` with a recommendation
    /// and alternatives; `chosen`/`decider` stay nil until the UI resolves it (I2).
    struct JudgmentDecision: Sendable {
        let id: UInt64
        let kind: JudgmentKind
        let status: JudgmentStatus
        let recommendation: Recommendation
        let alternatives: [Call]
        let chosen: Call?       // nil while .open / .pending
        let deciderId: String?  // recorded decider identity — present iff resolved (FR-011)
    }

    // --- Reisner rendering (ffi.rs §Reisner) ---

    /// Mirrors `ffi::RunnerFate` for the Reisner cell.
    enum RunnerFate: Sendable, Equatable {
        case scored(rbi: Bool)
        case putOut(n: UInt8)
        case leftOnBase
    }

    /// Mirrors `ffi::ReisnerCell` — the rendered verify-card cell.
    struct ReisnerCell: Sendable {
        let situationDiamond: String   // pre-rendered diamond glyphs
        let catalystSymbols: String    // e.g. "6-3", "K", "S7"
        let pitchMarks: [String]       // e.g. ["C", "B", "S"]
        let runnerFate: RunnerFate
    }

    // --- Projected game state (FR-002; ffi::GameState, integer-only) ---

    /// Mirrors `ffi::InningLine`.
    struct InningLine: Sendable, Equatable { let runs: Int; let hits: Int; let errors: Int }

    /// Mirrors `ffi::LineScore`.
    struct LineScore: Sendable { let visitor: [InningLine]; let home: [InningLine] }

    /// Mirrors `ffi::GameState` — the fully-queryable projected state. On a write this is the
    /// `state_preview` (the state IF confirmed — not yet applied, FR-007).
    struct GameState: Sendable {
        let inning: Int
        let half: Half
        let balls: Int
        let strikes: Int
        /// Base occupancy (mirrors `model::Runners`); true = occupied.
        let onFirst: Bool
        let onSecond: Bool
        let onThird: Bool
        let outs: Int
        let lineScore: LineScore
        /// Batting-order index per side `[visitor, home]` (1...9, 0 = DH).
        let battingIndex: [Int]
    }

    // --- record_play result (ffi::RecordPlayResult) ---

    /// Mirrors `ffi::RecordPlayResult`. State does NOT advance until confirm; a `judgment` is
    /// present (status `.open`) iff `classification` is `.judgment` (`needs = .judgment`).
    struct RecordPlayResult: Sendable {
        let recordedSeq: UInt64
        let classification: Classification
        let reisner: ReisnerCell
        let statePreview: GameState
        let judgment: JudgmentDecision?
        let needs: Needs
    }
}

// MARK: - MockCore

/// Canned `CoreClient` for Squad B. Switches on input to produce two demo cards (A and B),
/// a deterministic confirm flow, and a sample finalize export. **Obviously a mock** — every
/// branch returns a literal. Swapped out wholesale at H1 (drop-in, no caller changes).
///
/// `final class` (not `actor`) + immutable canned data ⇒ trivially `Sendable`. There is no
/// mutable state: the mock does not actually advance a game, so concurrent calls are safe.
public final class MockCore: CoreClient {

    public init() {}

    // MARK: Canned input scripts
    //
    // The Wizard-of-Oz facilitator (interaction-spec.md) selects a script by what the scorer
    // "said". We key off a recognizable marker in `normalizedFacts` / transcript so the demo is
    // deterministic. Anything unrecognized falls back to the deterministic 6-3 card.

    /// Marker the demo harness sets to pick the misplayed-grounder (Card B) script.
    /// e.g. `normalizedFacts["script"] = "misplayed-grounder"` or a transcript containing it.
    private static let judgmentScriptKey = "misplayed-grounder"

    /// Marker for the clear 6-3 deterministic ground out (Card A). Default when unspecified.
    private static let deterministicScriptKey = "6-3"

    private func selectsJudgment(_ facts: [String: String]) -> Bool {
        let blob = (facts["script"] ?? "") + " " + (facts["transcript"] ?? "") + " " + (facts["play"] ?? "")
        return blob.localizedCaseInsensitiveContains(Self.judgmentScriptKey)
            || blob.localizedCaseInsensitiveContains("error")
    }

    // MARK: Primitive 1 — record_play (US1/US2 · contracts/record_play.md)

    /// Returns a canned Card A (clear "6-3" ground out → confirm) or Card B (misplayed grounder
    /// → open HitVsError judgment). Authority is mocked: an empty `ownerId` is rejected exactly
    /// as the real core would (FR-020 / I5), so the UI's auth path is exercised.
    public func recordPlay(
        gameId: String,
        ownerId: String,
        normalizedFacts: [String: String],
        correlationId: String
    ) async throws -> GameState {
        guard !ownerId.isEmpty else {
            throw CoreError.unauthorized("MockCore: empty ownerId is not the game owner (FR-020/I5)")
        }

        // Build the rich FFI-shaped canned result (the shape the real core returns at H1) ...
        let ffiResult: MockFFI.RecordPlayResult = selectsJudgment(normalizedFacts)
            ? Self.cannedMisplayedGrounder()   // Card B — judgment
            : Self.cannedSixThreeGroundOut()   // Card A — deterministic

        // ... then project it down to the Phase-1 `CoreClient.GameState` the protocol returns
        // today. (At H1 the protocol's return type widens to the full FFI struct and this
        // narrowing disappears.)
        return Self.toClientState(gameId: gameId, ffiResult.statePreview)
    }

    /// CARD A — deterministic "6-3" ground out (the ~85%). `Classification.deterministic`,
    /// `Needs.confirm`, no judgment. Restates as "Ground out, short to first. 6-3."
    static func cannedSixThreeGroundOut() -> MockFFI.RecordPlayResult {
        MockFFI.RecordPlayResult(
            recordedSeq: 1,
            classification: .deterministic,
            reisner: MockFFI.ReisnerCell(
                situationDiamond: "◇",          // bases empty pre-play
                catalystSymbols: "6-3",         // SS to 1B
                pitchMarks: ["C", "B", "S"],    // called strike, ball, swinging strike
                runnerFate: .putOut(n: 1)       // batter-runner retired, 1st out
            ),
            statePreview: MockFFI.GameState(
                inning: 1, half: .top,
                balls: 0, strikes: 0,
                onFirst: false, onSecond: false, onThird: false,
                outs: 1,                        // 0 → 1 out on confirm
                lineScore: MockFFI.LineScore(
                    visitor: [MockFFI.InningLine(runs: 0, hits: 0, errors: 0)],
                    home: [MockFFI.InningLine(runs: 0, hits: 0, errors: 0)]
                ),
                battingIndex: [2, 1]            // visitor due-up advances to #2
            ),
            judgment: nil,
            needs: .confirm
        )
    }

    /// CARD B — misplayed grounder ⇒ **open** HitVsError judgment (the ~15%, V3 glance).
    /// The core REFUSES to decide (I2): status `.open`, a recommendation ("Looked like a clean
    /// single — Hit") + alternatives (Hit / Error). `chosen`/`decider` stay nil until the UI taps.
    static func cannedMisplayedGrounder() -> MockFFI.RecordPlayResult {
        let recommendation = MockFFI.Recommendation(
            call: MockFFI.Call(token: "hit", label: "Hit"),
            oneLineReason: "Looked like a clean single up the middle"
        )
        let decision = MockFFI.JudgmentDecision(
            id: 1,
            kind: .hitVsError,
            status: .open,                                   // NEVER resolved by the mock (I2)
            recommendation: recommendation,
            alternatives: [
                MockFFI.Call(token: "hit", label: "Hit"),
                MockFFI.Call(token: "error:6", label: "Error (SS)")
            ],
            chosen: nil,
            deciderId: nil
        )
        return MockFFI.RecordPlayResult(
            recordedSeq: 2,
            classification: .judgment(.hitVsError),
            reisner: MockFFI.ReisnerCell(
                situationDiamond: "◇",
                catalystSymbols: "?6",          // ball to SS, ruling pending
                pitchMarks: ["B", "X"],         // ball, ball in play
                runnerFate: .leftOnBase         // provisional until the call is made
            ),
            statePreview: MockFFI.GameState(
                inning: 1, half: .top,
                balls: 0, strikes: 0,
                onFirst: true, onSecond: false, onThird: false,   // batter-runner reached 1st
                outs: 0,
                lineScore: MockFFI.LineScore(
                    // hits vs errors deliberately left to the pending judgment — mock shows 0/0
                    visitor: [MockFFI.InningLine(runs: 0, hits: 0, errors: 0)],
                    home: [MockFFI.InningLine(runs: 0, hits: 0, errors: 0)]
                ),
                battingIndex: [2, 1]
            ),
            judgment: decision,
            needs: .judgment                    // UI MUST surface Card B; cannot advance unresolved
        )
    }

    // MARK: Primitive 2 — advance_runner (US1 · FR-009 · contracts/advance_runner.md)

    /// Canned forced advance: echoes a plausible post-advance state. Real ambiguous-advance
    /// judgments (FR-009) are out of scope for this stub's two demo scripts.
    public func advanceRunner(
        gameId: String,
        ownerId: String,
        runnerId: String,
        toBase: String,
        correlationId: String
    ) async throws -> GameState {
        guard !ownerId.isEmpty else {
            throw CoreError.unauthorized("MockCore: empty ownerId is not the game owner (FR-020/I5)")
        }
        let preview = MockFFI.GameState(
            inning: 1, half: .top,
            balls: 0, strikes: 0,
            onFirst: toBase == "1B",
            onSecond: toBase == "2B",
            onThird: toBase == "3B",
            outs: 0,
            lineScore: MockFFI.LineScore(
                visitor: [MockFFI.InningLine(runs: toBase == "H" ? 1 : 0, hits: 0, errors: 0)],
                home: [MockFFI.InningLine(runs: 0, hits: 0, errors: 0)]
            ),
            battingIndex: [2, 1]
        )
        return Self.toClientState(gameId: gameId, preview)
    }

    // MARK: Primitive 3 — correct_event (US4 · contracts/correct_event.md)
    //
    // Gated OFF in the first demo slice (CoreClient.swift note). The mock accepts the call and
    // echoes a plausible recomputed state so the "Correct" affordance can be wired in the UI;
    // it does NOT actually replay or preserve history (the real core owns FR-012/013/014).

    public func correctEvent(
        gameId: String,
        ownerId: String,
        playId: PlayId,
        amendment: [String: String],
        correlationId: String
    ) async throws -> GameState {
        guard !ownerId.isEmpty else {
            throw CoreError.unauthorized("MockCore: empty ownerId is not the game owner (FR-020/I5)")
        }
        // Canned "recomputed" state — visibly distinct so the UI can show a re-derive happened.
        let preview = MockFFI.GameState(
            inning: 1, half: .top,
            balls: 0, strikes: 0,
            onFirst: false, onSecond: false, onThird: false,
            outs: 1,
            lineScore: MockFFI.LineScore(
                visitor: [MockFFI.InningLine(runs: 0, hits: 1, errors: 0)],  // e.g. error → hit
                home: [MockFFI.InningLine(runs: 0, hits: 0, errors: 0)]
            ),
            battingIndex: [2, 1]
        )
        return Self.toClientState(gameId: gameId, preview)
    }

    // MARK: Primitive 4 — finalize_scorecard (US3 · contracts/finalize_scorecard.md)

    /// Returns a small **sample reduced-Retrosheet** event file + a human Reisner book string.
    /// Obviously canned (a one-play game). Mirrors the real `FinalizeResult.retrosheet` shape:
    /// the 8 allowed record types (`id`, `version`, `info`, `start`, `play`, `sub`, `com`,
    /// `data`), one per line. The real core's export is cwevent-gated in CI (I4/SC-004); this
    /// stub is illustrative only.
    public func finalizeScorecard(
        gameId: String,
        ownerId: String,
        correlationId: String
    ) async throws -> FinalizedScorebook {
        guard !ownerId.isEmpty else {
            throw CoreError.unauthorized("MockCore: empty ownerId is not the game owner (FR-020/I5)")
        }

        // Sample reduced-Retrosheet event file (one half-inning, one 6-3 ground out).
        let retrosheet = """
        id,MOCK\(gameId)0
        version,2
        info,visteam,MOK
        info,hometeam,DIA
        info,date,2026/06/01
        start,mock001,"Mock Leadoff",0,1,6
        play,1,0,mock001,00,CBS,63/G
        data,er,mock001,0
        """

        // Human-readable Reisner book (the official human record, US3) — canned one-cell view.
        let reisnerBook = """
        Reisner Scorebook (MOCK) — game \(gameId)
        ────────────────────────────────────────
        T1 │ #1  ◇  6-3  C B S   ① (out 1)
        ────────────────────────────────────────
        Proof box T1: AB 1 + BB 0 = Runs 0 + PO 1 + LOB 0  ✓ balanced
        """

        return FinalizedScorebook(reisnerBook: reisnerBook, retrosheetEvents: retrosheet)
    }

    // MARK: - Projection helper
    //
    // Narrows the rich `MockFFI.GameState` down to the Phase-1 `CoreClient.GameState` the
    // protocol returns today. Removed at H1 when the protocol adopts the full FFI struct.

    static func toClientState(gameId: String, _ s: MockFFI.GameState) -> GameState {
        GameState(
            gameId: gameId,
            inning: s.inning,
            isTopHalf: s.half == .top,
            outs: s.outs
        )
    }
}
