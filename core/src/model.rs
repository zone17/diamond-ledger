//! Core domain types — the **normalized-fact schema** (T012).
//!
//! Reference for entity definitions and invariants:
//! [`data-model.md`](../../specs/001-voice-scorebook-core/data-model.md) §4, and
//! [`research.md`](../../specs/001-voice-scorebook-core/research.md) D5 (Reisner).
//!
//! ## Integer-only (ADR-0007 / D1 / FR-003 / I6)
//!
//! Every type in this module is integer / discrete. There are **no** `f32`/`f64`
//! fields anywhere; the crate-level `#![deny(clippy::float_arithmetic)]` lint guards
//! against accidental float math. Determinism is byte-identical across platforms.
//!
//! ## Classification is fact-derived (I1 / FR-006)
//!
//! The cardinal invariant of this schema: [`Classification`] is **derived from
//! [`NormalizedPlay`] facts**, never from a caller-supplied label. A play whose facts
//! constitute a judgment is flagged as a judgment even if it arrived labeled as
//! deterministic. See [`NormalizedPlay::audit_label`] — it is **AUDIT-ONLY** and is
//! never an input to `classify()`.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Identifiers
// ---------------------------------------------------------------------------

/// Opaque identifier for a runner within a game.
///
/// Integer-only (I6). Stable across a single game's event log; assigned when a
/// player reaches base. Distinct from a roster `Player` id — a `RunnerId`
/// identifies the *base-runner instance* a play reasons about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RunnerId(pub u32);

// Integer newtype → underlying builtin on the FFI boundary (I6, integer-only). A
// single-field tuple struct cannot be a `uniffi::Record`; `custom_newtype!` maps it
// transparently to its primitive instead (same wire shape as `serde(transparent)`).
#[cfg(feature = "uniffi")]
uniffi::custom_newtype!(RunnerId, u32);

// ---------------------------------------------------------------------------
// Fielding positions
// ---------------------------------------------------------------------------

/// A fielding position, numbered the Reisner / Project-Scoresheet way (D5).
///
/// `1..=9` are the standard scorekeeping positions (1=P, 2=C, 3=1B, 4=2B,
/// 5=3B, 6=SS, 7=LF, 8=CF, 9=RF). **`0` = DH** (designated hitter).
///
/// ⚠ Note (D5): `0=DH` differs from Retrosheet `start`-record DH handling; the
/// export layer owns the explicit mapping. This newtype is the *internal* fact
/// representation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Position(pub u8);

// Integer newtype → underlying builtin on the FFI boundary (I6, integer-only). A
// single-field tuple struct cannot be a `uniffi::Record`; `custom_newtype!` maps it
// transparently to its primitive instead (same wire shape as `serde(transparent)`).
#[cfg(feature = "uniffi")]
uniffi::custom_newtype!(Position, u8);

impl Position {
    /// The designated-hitter sentinel (`0`).
    pub const DH: Position = Position(0);

    /// `true` iff this is a valid scorekeeping position: `0` (DH) or `1..=9`.
    #[must_use]
    pub const fn is_valid(self) -> bool {
        self.0 <= 9
    }

    /// `true` iff this is one of the nine fielding positions (`1..=9`), excluding DH.
    #[must_use]
    pub const fn is_fielder(self) -> bool {
        self.0 >= 1 && self.0 <= 9
    }
}

// ---------------------------------------------------------------------------
// Bases
// ---------------------------------------------------------------------------

/// A base on the diamond. `Home` is both the origin of the batter and the
/// scoring destination.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum Base {
    /// Home plate — batter origin and scoring destination.
    Home,
    First,
    Second,
    Third,
}

/// Which side of the plate the batter hits from (a pre-play *fact*; an input to
/// classification's platoon-independent logic, recorded as part of the situation).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum BatterHand {
    Left,
    Right,
    /// Switch hitter (side not yet resolved for this plate appearance).
    Switch,
}

// ---------------------------------------------------------------------------
// Count
// ---------------------------------------------------------------------------

/// The ball/strike count — a pre-play fact (part of [`SituationDiamond`]).
///
/// Validity at rest (§6): `balls <= 3`, `strikes <= 2`. The struct stores raw
/// integers; validation lives in the rules layer so this fact type stays a pure
/// data carrier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Count {
    pub balls: u8,
    pub strikes: u8,
}

// ---------------------------------------------------------------------------
// Situation diamond (Reisner "top" — pre-play state)
// ---------------------------------------------------------------------------

/// Base occupancy before the play — which runner (if any) is on each base.
///
/// `None` means the base is empty. The batter is never represented here (they
/// occupy `Home` only as the catalyst's origin).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Runners {
    pub first: Option<RunnerId>,
    pub second: Option<RunnerId>,
    pub third: Option<RunnerId>,
}

/// The **situation diamond** (D5, Reisner top): the fully-specified pre-play
/// state a classification reasons from. Together with [`Catalyst`] this forms a
/// [`NormalizedPlay`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SituationDiamond {
    /// Runners on base before the play.
    pub runners: Runners,
    /// Outs before the play (`0..=2` at rest; a 3rd out ends the half-inning).
    pub outs: u8,
    /// Ball/strike count before the resolving pitch.
    pub count: Count,
    /// Side of the plate the batter hits from.
    pub batter_hand: BatterHand,
}

// ---------------------------------------------------------------------------
// Catalyst (Reisner "bottom" — what occurred)
// ---------------------------------------------------------------------------

/// The primary batter outcome of a play. Closed set for the reduced v1 grammar;
/// anything outside it lands on [`BatterEvent::Other`] and will classify as
/// `OutOfFormat` rather than be fabricated into a known event (FR-017).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum BatterEvent {
    Single,
    Double,
    Triple,
    HomeRun,
    Strikeout,
    Walk,
    IntentionalWalk,
    HitByPitch,
    /// Reached on / play involving a fielding error.
    Error,
    FieldersChoice,
    /// A batted ball fielded for an out (the generic "out" not covered by a
    /// more specific variant).
    FieldedOut,
    SacFly,
    SacBunt,
    StolenBase,
    CaughtStealing,
    WildPitch,
    PassedBall,
    /// Fallback for any event outside the reduced grammar (FR-017): never
    /// silently coerced into a known event — drives `OutOfFormat`.
    Other,
}

/// The trajectory / type of a batted ball (a fact that feeds classification, e.g.
/// distinguishing a line-drive single from a misplayed pop). `None` for events
/// with no batted ball (walk, strikeout looking, etc.).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum BallType {
    Ground,
    Line,
    Fly,
    Pop,
    Bunt,
    /// No batted ball on this play.
    None,
}

/// Where a runner ended up on the play.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum AdvanceTo {
    /// Advanced (or held) at a base.
    Base(Base),
    /// Retired on the play.
    Out,
}

/// A single runner advancement *fact* on the play (D5, §4).
///
/// `by_error` records the fielding position charged with the error that enabled
/// the advance, if any — a fact, not a judgment. Whether that error makes a run
/// unearned is resolved downstream (I3), not encoded here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Advance {
    /// Which runner advanced. (The batter-runner uses a `RunnerId` assigned when
    /// they become a runner.)
    pub runner: RunnerId,
    /// Base the runner started from.
    pub from: Base,
    /// Where the runner ended up (a base, or retired).
    pub to: AdvanceTo,
    /// Position charged with an error that enabled this advance, if any.
    pub by_error: Option<Position>,
}

/// The **catalyst** (D5, Reisner bottom): the complete fact-record of *what
/// occurred*. Classification reads only these facts (I1).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Catalyst {
    /// The primary batter outcome.
    pub batter_event: BatterEvent,
    /// Fielding sequence, in order (e.g. `[Position(6), Position(3)]` for 6-3).
    pub fielders: Vec<Position>,
    /// Batted-ball trajectory (`None` if no batted ball).
    pub ball_type: BallType,
    /// All runner advancements on the play (including the batter-runner).
    pub advances: Vec<Advance>,
    /// Positions that touched or misplayed the ball — the FACT that can make an
    /// apparent "single" a hit-vs-error *judgment* (I1).
    pub touched_or_misplayed_by: Vec<Position>,
}

// ---------------------------------------------------------------------------
// NormalizedPlay (the FACT representation — classification reads ONLY this)
// ---------------------------------------------------------------------------

/// The normalized **fact** representation of a play (FR-005): the pre-play
/// [`SituationDiamond`] plus the [`Catalyst`] of what occurred.
///
/// This is the *sole* input to `classify()` (I1). Everything here is an
/// observed fact; nothing here is a scoring decision.
///
/// ## `audit_label` is AUDIT-ONLY (I1 / FR-006)
///
/// `audit_label` carries a caller-supplied free-text label (e.g. what a voice
/// transcript or upstream tool *called* the play). It exists purely for audit
/// and provenance and **MUST NEVER** be read by `classify()` or any scoring
/// logic. Classification is derived from the facts above; if the facts say a
/// play is a judgment, it is flagged as a judgment regardless of this label
/// (FR-006/FR-006a). Treat it as opaque provenance, never as a control input.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct NormalizedPlay {
    /// Pre-play state (Reisner top).
    pub situation: SituationDiamond,
    /// What occurred (Reisner bottom).
    pub catalyst: Catalyst,
    /// AUDIT-ONLY caller-supplied label — NEVER an input to classification (I1).
    /// See the type-level docs above.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audit_label: Option<String>,
}

// ---------------------------------------------------------------------------
// Classification (the cardinal seam — I1 / I2)
// ---------------------------------------------------------------------------

/// The result of deriving a play's nature **from its facts** (I1).
///
/// Produced by `classify(&NormalizedPlay)` (implemented in the `classify`
/// module). Roughly ~85% `Deterministic` / ~15% `Judgment` / ~5% `OutOfFormat`
/// on representative corpora.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum Classification {
    /// Facts fully determine the scoring outcome; no human judgment required.
    Deterministic,
    /// Facts require a scoring *judgment* of the given kind (I1/I2): must open a
    /// judgment flag with a recorded decider before resolution.
    Judgment(JudgmentKind),
    /// Facts fall outside the reduced v1 grammar (FR-017): flagged for review,
    /// never fabricated into a known play.
    OutOfFormat(String),
}

/// The kind of scoring judgment a play's facts demand (data-model §4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum JudgmentKind {
    /// Hit vs. error on a ball a fielder touched/misplayed.
    HitVsError,
    /// Earned vs. unearned run determination.
    EarnedVsUnearned,
    /// Contested credit (e.g. which fielder is charged/credited).
    ContestedCredit,
    /// An advance the facts leave ambiguous (FR-009).
    AmbiguousAdvance,
}
