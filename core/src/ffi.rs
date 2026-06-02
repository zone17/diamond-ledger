//! FFI / boundary schema (T007, handoff **H1**) — the surface BOTH the Swift
//! `MockCore` and the real Rust core implement.
//!
//! This module defines the **language-neutral capability boundary** (Art. XI,
//! contract-first): the four atomic primitives + the read ops, their typed
//! request/result structs, and a single structured [`Error`] model. It is the
//! frozen schema Squad B codes the iOS `MockCore` against (T008) until the real
//! core swaps in at H1 (T037/T071) with no behavior change.
//!
//! Authoritative I/O contracts:
//! [`contracts/`](../../specs/001-voice-scorebook-core/contracts/) — README +
//! `record_play.md` · `advance_runner.md` · `correct_event.md` ·
//! `finalize_scorecard.md`. Entity shapes:
//! [`data-model.md`](../../specs/001-voice-scorebook-core/data-model.md) §4.
//!
//! ## Integer-only at the boundary (ADR-0007 / D1 / FR-003 / I6)
//!
//! Every field crossing this seam is integer / discrete / `String` — there are
//! **no** `f32`/`f64` anywhere. Any ratio (AVG, OBP, ERA …) is an adapter/UI
//! concern. The crate-level `#![deny(clippy::float_arithmetic)]` guards the math;
//! this schema keeps floats out of the *data* in the first place. Owned,
//! `serde`-serializable types only, so the boundary is JSON-faithful and the
//! mock/real cores are byte-for-byte interchangeable (SC-008 parity).
//!
//! ## Fact reuse (I1)
//!
//! The fact layer ([`crate::model`]) is reused verbatim — [`NormalizedPlay`],
//! [`Classification`], [`JudgmentKind`], [`RunnerId`], [`Position`], [`Base`],
//! [`Count`], [`Runners`]. This module adds only the *boundary* envelope
//! (requests, results, projected state, errors). Classification is always
//! fact-derived; nothing here lets a caller assert a play's nature (I1/FR-006).
//!
//! ## UniFFI (wired at H1 — T037 / ADR-0009)
//!
//! This surface is exported via UniFFI to Swift/Kotlin/CLI/agent from one artifact.
//! Every boundary type carries `#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]`
//! (structs) or `derive(uniffi::Enum)` (enums); the integer newtypes use
//! `uniffi::custom_newtype!` (mapped to their underlying integer); the structured
//! [`Error`] is a `uniffi::Record` thrown via the [`CoreFfiError`] enum (a
//! `uniffi::Error` must be an enum). The exported [`crate::primitives::DiamondCore`]
//! `impl` carries `#[uniffi::export]`. The original `// UNIFFI-EXPORT:` marker comments
//! are retained below as provenance next to each applied derive.
//!
//! All annotations are **feature-gated**: with the default (no `uniffi`) build they
//! vanish entirely, so the deterministic core, the no-float clippy gate, and the
//! CLI/agent adapters have zero FFI coupling. The `uniffi` feature is enabled only for
//! binding generation (`uniffi-bindgen`) and the iOS XCFramework
//! (`scripts/build-xcframework.sh`).

use serde::{Deserialize, Serialize};

use crate::model::{
    AdvanceTo, Base, Classification, Count, JudgmentKind, NormalizedPlay, Position, RunnerId,
    Runners,
};

// ===========================================================================
// Identifiers & actor
// ===========================================================================

/// Opaque identifier for a game. Stable across that game's whole event log.
///
/// Integer-only (I6). The owning account / authority is resolved against this id
/// at every primitive call (I5/FR-020).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)] (newtype → underlying u64 on the boundary)
#[serde(transparent)]
pub struct GameId(pub u64);

// Integer newtype → underlying builtin on the FFI boundary (I6, integer-only). A
// single-field tuple struct cannot be a `uniffi::Record`; `custom_newtype!` maps it
// transparently to its primitive instead (same wire shape as `serde(transparent)`).
#[cfg(feature = "uniffi")]
uniffi::custom_newtype!(GameId, u64);

/// Monotonic per-game event sequence number (the replay order, `seq`).
///
/// Returned by writes (`recorded_seq`, `applied_seq`, `correction_seq`) and used
/// by reads (`get_play`, `correct_event.corrects_seq`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Seq(pub u64);

// Integer newtype → underlying builtin on the FFI boundary (I6, integer-only). A
// single-field tuple struct cannot be a `uniffi::Record`; `custom_newtype!` maps it
// transparently to its primitive instead (same wire shape as `serde(transparent)`).
#[cfg(feature = "uniffi")]
uniffi::custom_newtype!(Seq, u64);

/// Whether the caller is a human operator or an authorized agent (data-model §2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ActorKind {
    Human,
    Agent,
}

/// The caller identity carried on every primitive (Art. II parity, FR-018/020).
///
/// Authority is asserted against the game owner / authorized agent before any
/// event is appended (I5) — this struct is *who is calling*, not a bare
/// "decider" string (the probe gap closed in the contracts README).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Actor {
    pub kind: ActorKind,
    /// Stable account / agent identity string (owner id, agent id, …).
    pub id: String,
    /// Agent harness/build version, for audit (`None` for human callers).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness_version: Option<String>,
}

// ===========================================================================
// Team / lineup (FR-001 — names-only allowed at game creation)
// ===========================================================================

/// One batting-order slot of a starting lineup (data-model §4, minimal form).
///
/// Integer/discrete/`String` only (I6). `field_pos` reuses the fact-layer
/// [`Position`] (`0` = DH, `1..=9` fielders). Mid-game substitutions are an event
/// concern (`Substitution`, FR-002) and are not carried on this create-time slot.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct LineupSlot {
    /// Batting order: `1..=9`, or `0` for the DH slot.
    pub batting_order: u8,
    /// Stable player id occupying the slot.
    pub player_id: String,
    /// Fielding position (reuses [`Position`]: `0` = DH, `1..=9`).
    pub field_pos: Position,
}

/// A team as supplied to [`CoreApi::create_game`] (data-model §4, FR-001).
///
/// Names-only is allowed (FR-001): `lineup` is optional, so a game can start with
/// just team names and have rosters filled in later. When present, `lineup` is the
/// starting batting order.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Team {
    /// Stable team identifier.
    pub id: String,
    /// Display name (e.g. `"Hawks"`).
    pub name: String,
    /// Starting batting order, if supplied (names-only games omit it, FR-001).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lineup: Option<Vec<LineupSlot>>,
}

// ===========================================================================
// Structured error model (Art. I — machine-readable, never prose-only)
// ===========================================================================

/// Stable, machine-readable error codes shared by all four primitives + reads.
///
/// Defined once in `contracts/README.md`; every variant maps to a precondition
/// or invariant in the per-primitive contracts. Treat the code — not the
/// `message` — as the control signal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ErrorCode {
    /// Authority check failed (I5/FR-020). No state change.
    Unauthorized,
    /// A prior play is unconfirmed; state cannot advance (FR-007).
    PendingConfirmation,
    /// Needs clarification / manual entry — NOT a guess (FR-008).
    AmbiguousInput,
    /// Facts classify as a judgment; must open a decision, not resolve (FR-010).
    JudgmentRequired,
    /// Impossible play (e.g. 3rd out + further advance) — reject, don't corrupt.
    ContradictoryState,
    /// Outside the reduced v1 grammar; flag needs-review, never fabricate (FR-017).
    OutOfFormat,
    /// Schema / precondition violation.
    InvalidArgument,
    /// Unknown game / event id.
    NotFound,
    /// A [`PlayInput::Transcript`] reached a *pure* core with no bundled grammar
    /// parser. The pure `dl-core` consumes `Normalized` facts only; transcript
    /// parsing lives in an adapter. Adapters that bundle a parser never return
    /// this — they normalize first (see [`PlayInput`] docs).
    TranscriptNotSupported,
}

/// A single structured-error detail entry (machine-readable diagnostics).
///
/// Modeled as explicit key/value strings rather than a free-form JSON object so
/// the type stays UniFFI-friendly and byte-stable across the boundary. Typical
/// keys: `field`, `expected`, `got`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ErrorDetail {
    pub key: String,
    pub value: String,
}

/// The boundary error envelope (Art. I): a stable [`ErrorCode`], a
/// human-readable `message` (never the sole signal), a `retryable` hint, and
/// optional structured `details`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Error)] #[uniffi(flat_error)]  (or a Record-style error)
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Error {
    pub code: ErrorCode,
    pub message: String,
    pub retryable: bool,
    /// Structured diagnostics (e.g. `{ field, expected, got }`), if any.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub details: Vec<ErrorDetail>,
}

impl Error {
    /// Construct a non-retryable error with no structured details.
    #[must_use]
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: false,
            details: Vec::new(),
        }
    }

    /// Builder: mark this error retryable (safe to retry with the same args).
    #[must_use]
    pub fn retryable(mut self) -> Self {
        self.retryable = true;
        self
    }

    /// Builder: attach one structured `key=value` detail.
    #[must_use]
    pub fn with_detail(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.details.push(ErrorDetail {
            key: key.into(),
            value: value.into(),
        });
        self
    }
}

impl core::fmt::Display for Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

/// The boundary result alias every primitive / read returns.
pub type CoreResult<T> = core::result::Result<T, Error>;

// ---------------------------------------------------------------------------
// Throwable FFI error (UniFFI, T037)
// ---------------------------------------------------------------------------

/// The throwable error UniFFI surfaces to Swift/Kotlin for the exported methods.
///
/// `uniffi::Error` must derive on an **enum** (a struct cannot be thrown), so this
/// single-variant wrapper carries the full structured [`Error`] record across the
/// boundary with **zero information loss**: callers read `err.code` (the stable
/// machine signal — Art. I), `err.message`, `err.retryable`, and `err.details`.
/// The `From<Error>` makes `core_result?` ergonomics work in the exported impl.
///
/// Only present in the `uniffi` build (the pure core throws plain [`Error`]).
#[cfg(feature = "uniffi")]
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum CoreFfiError {
    /// The structured boundary error (code + message + retryable + details).
    Core(Error),
}

#[cfg(feature = "uniffi")]
impl core::fmt::Display for CoreFfiError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            CoreFfiError::Core(e) => write!(f, "{e}"),
        }
    }
}

#[cfg(feature = "uniffi")]
impl std::error::Error for CoreFfiError {}

#[cfg(feature = "uniffi")]
impl From<Error> for CoreFfiError {
    fn from(e: Error) -> Self {
        CoreFfiError::Core(e)
    }
}

/// The result alias the UniFFI-exported methods return (throws [`CoreFfiError`]).
#[cfg(feature = "uniffi")]
pub type FfiResult<T> = core::result::Result<T, CoreFfiError>;

// ===========================================================================
// Loop-control & shared boundary enums
// ===========================================================================

/// What the read-verify-correct loop requires next after a write
/// (data-model §5 state machine).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum Needs {
    /// Nothing further — the step is complete.
    None,
    /// A `PlayConfirmed` is required before state advances (FR-007).
    Confirm,
    /// Ambiguous input — a single clarification / manual entry is required (FR-008).
    Clarify,
    /// Facts are a judgment — an open decision must be resolved/deferred (FR-010).
    Judgment,
}

/// Which half of the inning is in progress.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum Half {
    #[default]
    Top,
    Bottom,
}

/// Earned / unearned status of a scored run (I3).
///
/// `Pending` is **forced** for any run in a half-inning containing an error or
/// passed ball; it is resolved only by a [`JudgmentDecision`], never set at
/// projection time (FR-010a).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EarnedUnearned {
    Earned,
    Unearned,
    /// Cannot yet be decided (inning has an error/PB) — resolved by judgment.
    Pending,
}

// ===========================================================================
// Judgment decision (US2 — surfaced, never auto-resolved across the boundary)
// ===========================================================================

/// Status of an open scoring judgment (data-model §4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum JudgmentStatus {
    /// Awaiting a decider's call.
    Open,
    /// A call was recorded with a decider identity (FR-011).
    Resolved,
    /// Explicitly deferred (e.g. EarnedVsUnearned with no Rule 9.16 in v1).
    Pending,
}

/// A candidate scoring call for a judgment (recommendation or alternative).
///
/// Carried as an opaque, stable token string so the boundary stays
/// grammar-neutral; the rules layer owns the mapping to concrete outcomes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Call {
    /// Stable identifier for the call (e.g. `"hit"`, `"error:6"`).
    pub token: String,
    /// Human-readable label for display.
    pub label: String,
}

/// The core's recommended call plus a one-line rationale (US2).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Recommendation {
    pub call: Call,
    pub one_line_reason: String,
}

/// An open/resolved scoring judgment surfaced across the boundary (FR-010/011).
///
/// The core **never** silently resolves a judgment: it returns the decision
/// `Open` with a `recommendation` + `alternatives`; resolution requires a
/// recorded `decider` (I2). A judgment present in a result always pairs with
/// [`Needs::Judgment`].
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct JudgmentDecision {
    /// Stable id for the decision within the game's log.
    pub id: u64,
    pub kind: JudgmentKind,
    pub status: JudgmentStatus,
    pub recommendation: Recommendation,
    pub alternatives: Vec<Call>,
    /// The chosen call, once resolved (`None` while `Open`/`Pending`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chosen: Option<Call>,
    /// The recorded decider identity (FR-011) — present iff resolved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decider: Option<Actor>,
}

// ===========================================================================
// Projected game state (FR-002 — fully queryable at all times)
// ===========================================================================

/// One side's runs/hits/errors for a single inning of the line score.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct InningLine {
    pub runs: u32,
    pub hits: u32,
    pub errors: u32,
}

/// The per-side line score: one [`InningLine`] per inning played, in order.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct LineScore {
    /// Visiting side, inning-by-inning (index 0 = 1st inning).
    pub visitor: Vec<InningLine>,
    /// Home side, inning-by-inning.
    pub home: Vec<InningLine>,
}

/// A single pitch mark in the live pitch sequence (display/audit only).
///
/// Stable token string (e.g. `"B"`, `"C"`, `"S"`, `"F"`) so the boundary stays
/// integer/discrete with no enum churn at the FFI seam.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct PitchMark {
    pub mark: String,
}

/// Which roster player currently occupies a fielding position.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ActiveFielder {
    pub position: Position,
    /// Stable player id occupying the position.
    pub player_id: String,
}

/// The fully-queryable projected game state (FR-002, data-model §4).
///
/// Rebuilt deterministically by replaying the confirmed event log (I6). On a
/// write this appears as `state_preview` — the resulting state *if confirmed*,
/// not yet applied (FR-007).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct GameState {
    pub inning: u8,
    pub half: Half,
    pub count: Count,
    /// Base occupancy (reuses the fact-layer [`Runners`] shape).
    pub bases: Runners,
    /// Outs before the next play (`0..=2`; a 3rd out ends the half-inning).
    pub outs: u8,
    pub line_score: LineScore,
    /// Current batting-order index per side, `[visitor, home]` (`1..=9`/`0`=DH).
    ///
    /// A 2-element `Vec` (always exactly `[visitor, home]`), not a `[u8; 2]`: UniFFI
    /// has no fixed-size-array type, so the boundary uses a length-2 `Vec` to stay
    /// language-neutral. Internally the rules projection keeps a `[u8; 2]`.
    pub batting_index: Vec<u8>,
    pub pitch_sequence: Vec<PitchMark>,
    pub active_fielders: Vec<ActiveFielder>,
}

// ===========================================================================
// Reisner rendering & proof box
// ===========================================================================

/// How a runner's plate appearance / advance ended, for the Reisner cell.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum RunnerFate {
    /// Crossed the plate; `rbi` records whether it was an RBI.
    Scored { rbi: bool },
    /// Retired; `n` is the out number within the half-inning (`1..=3`).
    PutOut { n: u8 },
    /// Stranded on base at the half-inning's end.
    LeftOnBase,
}

/// A rendered Reisner / Project-Scoresheet cell for the verify card
/// (data-model §4).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ReisnerCell {
    /// Pre-rendered situation-diamond glyphs.
    pub situation_diamond: String,
    /// Catalyst notation symbols (e.g. `"6-3"`, `"K"`, `"S7"`).
    pub catalyst_symbols: String,
    /// Pitch marks rendered for the cell.
    pub pitch_marks: Vec<PitchMark>,
    pub runner_fate: RunnerFate,
}

/// The Reisner half-inning proof box (FR-005a).
///
/// MUST balance for every completed half-inning (SC-011):
/// `ab + bb + sac + hbp + interference = runs + putouts + stranded`.
/// `finalize_scorecard` **fails** if any proof box does not balance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ProofBox {
    pub inning: u8,
    pub half: Half,
    pub ab: u32,
    pub bb: u32,
    pub sac: u32,
    pub hbp: u32,
    pub interference: u32,
    pub runs: u32,
    pub putouts: u32,
    /// Runners physically on base at the 3rd out (force/DP outs are not stranded).
    pub stranded: u32,
}

/// The rendered human-readable scorebook (the official human record, US3).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ReisnerScorebook {
    /// One rendered cell per recorded play, in order.
    pub cells: Vec<ReisnerCell>,
    /// Per half-inning proof boxes (must each balance).
    pub proof_boxes: Vec<ProofBox>,
}

// ===========================================================================
// Retrosheet export (reduced grammar; cwevent-validated in CI)
// ===========================================================================

/// One reduced-grammar Retrosheet record (one of the 8 allowed types).
///
/// `record_type` is the leading keyword (`id`/`version`/`info`/`start`/`play`/
/// `sub`/`com`/`data`); `fields` are the comma-separated values for the row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct RetrosheetRecord {
    pub record_type: String,
    pub fields: Vec<String>,
}

/// A reference to a play in the event log (for invalidation / out-of-format lists).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct PlayRef {
    pub game_id: GameId,
    pub seq: Seq,
}

/// A reference to a judgment decision (for the unresolved list).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DecisionRef {
    pub game_id: GameId,
    pub decision_id: u64,
}

/// The reduced-but-valid Retrosheet event file (FR-015–017).
///
/// Authoritatively accepted only when the pinned `cwevent` v0.10.0 parses it
/// with zero stderr warnings and ≥1 event row (I4/SC-004) — enforced in CI, not
/// by the offline emitter. Plays outside the reduced grammar land in
/// `out_of_format_flags`, never fabricated into a `play` record (FR-017).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct RetrosheetExport {
    pub records: Vec<RetrosheetRecord>,
    pub out_of_format_flags: Vec<PlayRef>,
}

// ===========================================================================
// Request / result structs — one pair per primitive + read
// ===========================================================================

/// The two accepted forms of play input (contract `record_play` / `correct_event`).
///
/// Either way, classification is fact-derived (I1) and any caller-supplied label
/// is audit-only (FR-006, see `NormalizedPlay::audit_label`).
///
/// ## Core-vs-adapter contract (who consumes which variant)
///
/// The **grammar parser lives in the adapter, not in `dl-core`.** This shapes
/// which variant each implementor accepts:
///
/// - The **pure core** ([`CoreApi`] as implemented by `dl-core` and the Swift
///   `MockCore`) consumes [`Normalized`](PlayInput::Normalized) facts only. It
///   has no parser, so a [`Transcript`](PlayInput::Transcript) is rejected with
///   [`ErrorCode::TranscriptNotSupported`] — it is **never** guessed at or
///   silently dropped.
/// - An **adapter that bundles a parser** (e.g. the iOS front-end) accepts a
///   `Transcript`, parses it to a `NormalizedPlay`, and then calls the core with
///   the resulting `Normalized` facts. From the core's perspective every call is
///   already normalized.
///
/// Keeping `Transcript` on the boundary type lets one schema serve both layers
/// (contract parity, SC-008) without forcing the pure core to embed a grammar.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum PlayInput {
    /// Spoken/typed description; parsed to facts by an adapter's grammar. The
    /// pure core rejects this with [`ErrorCode::TranscriptNotSupported`].
    Transcript(String),
    /// Structured facts supplied directly (agent/CLI path, and the only form the
    /// pure core consumes).
    Normalized(NormalizedPlay),
}

// --- create_game ----------------------------------------------------------

/// Request for [`CoreApi::create_game`] (`contracts/create_game.md`).
///
/// Starts a new game from two teams (names-only allowed, FR-001). The owning
/// account is the `actor`; authority on every later primitive resolves against the
/// `game_id` this returns (I5).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CreateGameRequest {
    pub home: Team,
    pub visitor: Team,
    /// Dedupe key; a duplicate returns the original result, no second game.
    pub idempotency_key: String,
    pub actor: Actor,
}

/// Result of [`CoreApi::create_game`].
///
/// Emits `GameStarted` (FR-001). `state` is the fresh projected state (top of the
/// 1st, no outs, empty bases) for the new `game_id`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CreateGameResult {
    pub game_id: GameId,
    pub state: GameState,
}

// --- confirm_play ----------------------------------------------------------

/// Request for [`CoreApi::confirm_play`] (`contracts/confirm_play.md`).
///
/// The FR-007 read-verify gate: confirms a previously recorded play by its `seq`,
/// allowing projected state to actually advance. `confirms_seq` is the
/// `recorded_seq` returned by the prior `record_play`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ConfirmPlayRequest {
    pub game_id: GameId,
    /// The recorded play's `seq` being confirmed (FR-007).
    pub confirms_seq: u64,
    pub idempotency_key: String,
    pub actor: Actor,
}

/// Result of [`CoreApi::confirm_play`].
///
/// Emits `PlayConfirmed` (FR-007). `state` is the projection **after** the
/// confirmed play is applied — no longer a preview.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ConfirmPlayResult {
    pub state: GameState,
}

// --- resolve_judgment ------------------------------------------------------

/// Request for [`CoreApi::resolve_judgment`] (`contracts/resolve_judgment.md`).
///
/// Resolves an open scoring judgment (FR-011) by recording a `chosen` [`Call`].
/// The decider identity is the `actor` (I2): the core records *who* resolved it,
/// never resolving silently. `chosen` reuses the same [`Call`] token type the
/// judgment surfaced in its recommendation / alternatives.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ResolveJudgmentRequest {
    pub game_id: GameId,
    /// The open decision's id (from [`JudgmentDecision::id`]).
    pub decision_id: u64,
    /// The chosen call (one of the surfaced recommendation / alternatives).
    pub chosen: Call,
    pub idempotency_key: String,
    /// The decider whose identity is recorded on resolution (FR-011/I2).
    pub actor: Actor,
}

/// Result of [`CoreApi::resolve_judgment`].
///
/// Emits `JudgmentResolved` (FR-011). The returned `decision` is now
/// [`JudgmentStatus::Resolved`] with `chosen` + `decider` set (the `decider` is
/// the request `actor`). `state` reflects the resolved call.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ResolveJudgmentResult {
    pub decision: JudgmentDecision,
    pub state: GameState,
}

// --- record_play ----------------------------------------------------------

/// Request for [`CoreApi::record_play`] (`contracts/record_play.md`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct RecordPlayRequest {
    pub game_id: GameId,
    pub input: PlayInput,
    /// Dedupe key; a duplicate returns the original result, no second append.
    pub idempotency_key: String,
    pub actor: Actor,
}

/// Result of [`CoreApi::record_play`].
///
/// State **does not advance** until a subsequent confirm (FR-007); `state_preview`
/// is the resulting state *if confirmed*. A `judgment` is present (status `Open`)
/// iff `classification` is a [`Classification::Judgment`] (`needs = Judgment`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct RecordPlayResult {
    pub recorded_seq: Seq,
    pub normalized: NormalizedPlay,
    pub classification: Classification,
    pub reisner: ReisnerCell,
    /// Resulting state IF confirmed — not yet applied (FR-007).
    pub state_preview: GameState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub judgment: Option<JudgmentDecision>,
    pub needs: Needs,
}

// --- advance_runner -------------------------------------------------------

/// Where an advancing runner ended up on a confirmed advance.
///
/// This is shape-identical to the fact-layer [`crate::model::AdvanceTo`]
/// (`Base(Base)` | `Out`); it exists as a separate boundary type only so the FFI
/// envelope owns its own wire enum. The two are kept provably in lockstep by the
/// total [`From<AdvanceOutcome>`](AdvanceTo) conversion below — if either enum
/// gains or renames a variant, that `match` stops compiling, forcing both to move
/// together. Prefer converting via `.into()` over re-pattern-matching by hand.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum AdvanceOutcome {
    /// Advanced (or held) at a base.
    Base(Base),
    /// Retired on the play.
    Out,
}

impl From<AdvanceOutcome> for AdvanceTo {
    /// Lockstep bridge to the fact-layer twin (see [`AdvanceOutcome`] docs).
    ///
    /// Exhaustive by construction: a non-exhaustive `match` is a compile error,
    /// so the two identical shapes cannot silently diverge.
    fn from(outcome: AdvanceOutcome) -> Self {
        match outcome {
            AdvanceOutcome::Base(base) => AdvanceTo::Base(base),
            AdvanceOutcome::Out => AdvanceTo::Out,
        }
    }
}

/// The advance delta for [`CoreApi::advance_runner`] (`contracts/advance_runner.md`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct AdvanceDelta {
    pub runner: RunnerId,
    pub from: Base,
    pub to: AdvanceOutcome,
    /// Position charged with an error that enabled the advance, if any (a fact).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by_error: Option<Position>,
}

/// Request for [`CoreApi::advance_runner`].
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct AdvanceRunnerRequest {
    pub game_id: GameId,
    pub advance: AdvanceDelta,
    pub idempotency_key: String,
    pub actor: Actor,
}

/// Result of [`CoreApi::advance_runner`].
///
/// `applied_seq` is present iff the advance was forced/deterministic; an
/// ambiguous (not-forced) advance yields a `judgment` (`AmbiguousAdvance`) and
/// `needs = Judgment` — never an assumed advance (FR-009).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct AdvanceRunnerResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub applied_seq: Option<Seq>,
    pub state_preview: GameState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub judgment: Option<JudgmentDecision>,
    pub needs: Needs,
}

// --- correct_event --------------------------------------------------------

/// One preserved prior version of a corrected play (append-only history, FR-013).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Version {
    pub seq: Seq,
    pub normalized: NormalizedPlay,
    pub classification: Classification,
}

/// Request for [`CoreApi::correct_event`] (`contracts/correct_event.md`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CorrectEventRequest {
    pub game_id: GameId,
    /// The prior event being amended (else `NOT_FOUND`).
    pub corrects_seq: Seq,
    pub amended: PlayInput,
    pub idempotency_key: String,
    pub actor: Actor,
}

/// Result of [`CoreApi::correct_event`].
///
/// Correction is append-only (FR-013): the original is never mutated. The log is
/// **actually replayed** from `corrects_seq` and downstream projections are
/// recomputed (FR-012) — `recomputed_state` is the real result, not a flag.
/// `invalidated_downstream` plays are surfaced for review, never silently
/// discarded (FR-014).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CorrectEventResult {
    pub correction_seq: Seq,
    pub amended: NormalizedPlay,
    /// Judgment re-derived from the amended facts (I1).
    pub reclassified: Classification,
    pub recomputed_state: GameState,
    pub invalidated_downstream: Vec<PlayRef>,
    /// Prior version(s), preserved append-only (SC-007: 100% retained).
    pub history: Vec<Version>,
}

// --- finalize_scorecard ---------------------------------------------------

/// Whether a finalize produces the official record or an interim checkpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Enum)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum FinalizeMode {
    /// The official, exportable record (Tier 3).
    Final,
    /// An interim, non-official checkpoint.
    Checkpoint,
}

/// Request for [`CoreApi::finalize_scorecard`] (`contracts/finalize_scorecard.md`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct FinalizeRequest {
    pub game_id: GameId,
    pub mode: FinalizeMode,
    pub idempotency_key: String,
    pub actor: Actor,
}

/// The unresolved-items bundle reported by a finalize (non-blocking, FR-010a).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Unresolved {
    /// e.g. earned/unearned still `Pending` (I3) — reported, not blocking.
    pub pending_judgments: Vec<DecisionRef>,
}

/// Result of [`CoreApi::finalize_scorecard`].
///
/// Finalize **fails** (`CONTRADICTORY_STATE`) if any half-inning proof box does
/// not balance (SC-011); plays outside the reduced grammar are flagged in
/// `out_of_format`, never fabricated (FR-017). Deferred `Pending` earned/unearned
/// is reported under `unresolved`, not blocking (FR-010a).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct FinalizeResult {
    pub scorebook: ReisnerScorebook,
    pub retrosheet: RetrosheetExport,
    /// Per-half-inning proof boxes (each MUST balance).
    pub proof_box: Vec<ProofBox>,
    pub out_of_format: Vec<PlayRef>,
    pub unresolved: Unresolved,
}

// --- read ops -------------------------------------------------------------

/// One row of the event log for [`CoreApi::list_game_events`] (audit/replay view).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct EventSummary {
    pub seq: Seq,
    /// Event type keyword (e.g. `"PlayRecorded"`, `"EventCorrected"`).
    pub event_type: String,
    pub actor: Actor,
    /// The event this one corrects, if any (FR-012/013).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub corrects_seq: Option<Seq>,
}

/// A recorded play as returned by [`CoreApi::get_play`].
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
// UNIFFI-EXPORT: #[derive(uniffi::Record)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Play {
    pub seq: Seq,
    pub normalized: NormalizedPlay,
    pub classification: Classification,
    pub reisner: ReisnerCell,
    /// Whether this play has been confirmed (FR-007).
    pub confirmed: bool,
    /// Open/resolved judgment attached to the play, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub judgment: Option<JudgmentDecision>,
}

// ===========================================================================
// The capability boundary trait
// ===========================================================================

/// The capability boundary (handoff **H1**) — the four atomic write primitives
/// plus the read ops, implemented identically by the Swift `MockCore` (T008) and
/// the real Rust core (T037).
///
/// Every method returns the structured [`CoreResult`] — never panics on invalid
/// input. Writes are paired with reads for read-verify-correct (Art. XII), carry
/// an `idempotency_key` for safe retry (Art. XXXIII), and assert authority before
/// any append (I5/FR-020). Determinism: identical confirmed logs yield
/// byte-identical projections across iOS/Android/CLI/agent (I6/SC-008).
///
/// UNIFFI-EXPORT: the real-core `impl` block will carry `#[uniffi::export]`;
/// this trait stays plain so the mock can implement it without the macro.
pub trait CoreApi {
    // --- lifecycle & loop-control primitives ---

    /// Start a new game from two teams (names-only allowed) and return its
    /// `game_id` + fresh state (`contracts/create_game.md`). Emits `GameStarted`
    /// (FR-001).
    fn create_game(&self, req: CreateGameRequest) -> CoreResult<CreateGameResult>;

    /// Confirm a previously recorded play so projected state advances — the
    /// FR-007 read-verify gate (`contracts/confirm_play.md`). Emits
    /// `PlayConfirmed`.
    fn confirm_play(&self, req: ConfirmPlayRequest) -> CoreResult<ConfirmPlayResult>;

    /// Resolve an open scoring judgment by recording a chosen [`Call`] and the
    /// decider identity (`contracts/resolve_judgment.md`, FR-011). Never resolves
    /// silently (I2). Emits `JudgmentResolved`.
    fn resolve_judgment(
        &self,
        req: ResolveJudgmentRequest,
    ) -> CoreResult<ResolveJudgmentResult>;

    // --- write primitives (the only mutation entry-points, Art. III) ---

    /// Record one completed play from a transcript or normalized facts
    /// (`contracts/record_play.md`). Classifies on facts (I1); does **not**
    /// advance state until confirmed (FR-007).
    fn record_play(&self, req: RecordPlayRequest) -> CoreResult<RecordPlayResult>;

    /// Advance a base runner — deterministically where forced, surfacing
    /// ambiguous advances as judgments (`contracts/advance_runner.md`, FR-009).
    fn advance_runner(&self, req: AdvanceRunnerRequest) -> CoreResult<AdvanceRunnerResult>;

    /// Amend a prior play, replay downstream, and preserve history
    /// (`contracts/correct_event.md`, FR-012–014). Append-only (FR-013).
    fn correct_event(&self, req: CorrectEventRequest) -> CoreResult<CorrectEventResult>;

    /// Finalize the game (or checkpoint) into the human scorebook + reduced
    /// Retrosheet file (`contracts/finalize_scorecard.md`, FR-015–017). Tier 3.
    fn finalize_scorecard(&self, req: FinalizeRequest) -> CoreResult<FinalizeResult>;

    // --- read ops (read-verify-correct, Art. XII; fully queryable, FR-002) ---

    /// The fully-queryable projected [`GameState`] (FR-002).
    fn get_game_state(&self, game_id: GameId) -> CoreResult<GameState>;

    /// The append-only event log for the game, in `seq` order (audit/replay).
    fn list_game_events(&self, game_id: GameId) -> CoreResult<Vec<EventSummary>>;

    /// A single recorded play by its `seq` (else `NOT_FOUND`).
    fn get_play(&self, game_id: GameId, seq: Seq) -> CoreResult<Play>;

    /// The proof box for a given half-inning (the offline balance gate, SC-011).
    fn get_proof_box(&self, game_id: GameId, inning: u8, half: Half) -> CoreResult<ProofBox>;
}
