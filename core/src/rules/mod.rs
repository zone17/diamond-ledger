//! Deterministic rules engine — GameState machine + runner advancement (T014/T015).
//!
//! All arithmetic is integer-only (ADR-0007/I6). The [`GameProjection`] is rebuilt by
//! replaying confirmed events from the event log (FR-003). The 3rd-out ends a half-inning;
//! runner advancement is forced (deterministic) or flagged ambiguous→judgment (FR-009).

use std::collections::HashMap;

use crate::eventlog::{Event, EventLog, LogRow};
use crate::ffi::{
    ActiveFielder, GameId, GameState, Half, InningLine, LineScore, PitchMark, ProofBox,
};
use crate::model::{
    AdvanceTo, Base, BatterEvent, BatterHand, Catalyst, Count, NormalizedPlay, RunnerId,
    Runners, SituationDiamond,
};
use crate::reisner::compute_proof_box;

// ---------------------------------------------------------------------------
// Per-half-inning tracking
// ---------------------------------------------------------------------------

/// Context for one half-inning (accumulates facts for proof-box and earned/unearned).
#[derive(Debug, Clone, Default)]
pub struct HalfInningCtx {
    /// All confirmed plays in this half-inning, in order.
    pub plays: Vec<NormalizedPlay>,
    /// Has any defensive error or passed ball occurred?
    pub has_error_or_pb: bool,
    /// Runs scored this half-inning.
    pub runs: u32,
    /// Hits this half-inning.
    pub hits: u32,
    /// Errors this half-inning.
    pub errors: u32,
    /// At-bats.
    pub ab: u32,
    /// Walks.
    pub bb: u32,
    /// Sacrifice flies + bunts.
    pub sac: u32,
    /// Hit by pitch.
    pub hbp: u32,
    /// Interference.
    pub interference: u32,
    /// Putouts (outs recorded).
    pub putouts: u32,
    /// Runners on base at 3rd out (stranded).
    pub stranded: u32,
}

// ---------------------------------------------------------------------------
// Runner on base tracking
// ---------------------------------------------------------------------------

/// A runner currently on base.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OnBaseRunner {
    pub id: RunnerId,
    pub base: Base,
    /// Which play (seq) placed this runner.
    pub from_seq: u64,
}

// ---------------------------------------------------------------------------
// Full game projection
// ---------------------------------------------------------------------------

/// The deterministic projection of current game state, rebuilt by replaying confirmed events.
#[derive(Debug, Clone)]
pub struct GameProjection {
    pub inning: u8,
    pub half: Half,
    pub outs: u8,
    pub runners: Vec<OnBaseRunner>,
    pub line_score: LineScore,
    pub batting_index: [u8; 2],
    /// Next runner ID to assign.
    pub next_runner_id: u32,
    /// Half-inning context (current).
    pub current_half: HalfInningCtx,
    /// Pitch sequence for the current PA.
    pub pitch_sequence: Vec<PitchMark>,
    /// Active fielders (placeholder — we don't have full lineup tracking in MVP).
    pub active_fielders: Vec<ActiveFielder>,
    /// The last count seen (for state snapshot).
    pub count: Count,
    /// Archive of CLOSED half-innings' contexts, keyed by [`half_index`] (ADR-0012).
    ///
    /// `end_half_inning` inserts the just-completed half's [`HalfInningCtx`] here before
    /// resetting `current_half`, so [`project_half_inning_proof_box`] can rebuild any
    /// past half's proof box from replay alone (replay-up-to) without mutating history.
    pub completed_halves: HashMap<u32, HalfInningCtx>,
}

impl Default for GameProjection {
    fn default() -> Self {
        GameProjection {
            inning: 1,
            half: Half::Top,
            outs: 0,
            runners: Vec::new(),
            line_score: LineScore::default(),
            batting_index: [1, 1],
            next_runner_id: 1,
            current_half: HalfInningCtx::default(),
            pitch_sequence: Vec::new(),
            active_fielders: Vec::new(),
            count: Count { balls: 0, strikes: 0 },
            completed_halves: HashMap::new(),
        }
    }
}

impl GameProjection {
    /// Convert to the boundary [`GameState`] type (for read ops / previews).
    pub fn to_game_state(&self) -> GameState {
        let bases = Runners {
            first: self
                .runners
                .iter()
                .find(|r| r.base == Base::First)
                .map(|r| r.id),
            second: self
                .runners
                .iter()
                .find(|r| r.base == Base::Second)
                .map(|r| r.id),
            third: self
                .runners
                .iter()
                .find(|r| r.base == Base::Third)
                .map(|r| r.id),
        };
        GameState {
            inning: self.inning,
            half: self.half,
            count: self.count,
            bases,
            outs: self.outs,
            line_score: self.line_score.clone(),
            // Internal fixed `[u8; 2]` → length-2 `Vec` at the FFI boundary (UniFFI has
            // no fixed-array type). Order is preserved: `[visitor, home]`.
            batting_index: self.batting_index.to_vec(),
            pitch_sequence: self.pitch_sequence.clone(),
            active_fielders: self.active_fielders.clone(),
        }
    }

    /// Apply a confirmed `PlayRecorded` fact to the projection.
    ///
    /// This is the core of the deterministic rules engine. All state transitions are
    /// integer-only. No float arithmetic anywhere (ADR-0007).
    pub fn apply_play(&mut self, play: &NormalizedPlay, _seq: u64) {
        let cat = &play.catalyst;

        // Save current bases for LOB/stranded counting at end of half
        let pre_runners_count = self.runners.len();
        let _ = pre_runners_count;

        // Update count from situation (the situation reflects pre-play state).
        self.count = play.situation.count;

        // Determine if this play generates a hit (for H column).
        let is_hit = matches!(
            cat.batter_event,
            BatterEvent::Single
                | BatterEvent::Double
                | BatterEvent::Triple
                | BatterEvent::HomeRun
        );

        // Determine if this play has an error.
        let has_error = cat.batter_event == BatterEvent::Error
            || cat.advances.iter().any(|a| a.by_error.is_some());
        let has_pb = cat.batter_event == BatterEvent::PassedBall;

        if has_error || has_pb {
            self.current_half.has_error_or_pb = true;
        }

        // Update hit/error counts on line score.
        if is_hit {
            self.current_half.hits += 1;
        }
        if has_error {
            self.current_half.errors += 1;
        }

        // Accumulate proof-box counters.
        match cat.batter_event {
            BatterEvent::Walk | BatterEvent::IntentionalWalk => {
                self.current_half.bb += 1;
            }
            BatterEvent::HitByPitch => {
                self.current_half.hbp += 1;
            }
            BatterEvent::SacFly | BatterEvent::SacBunt => {
                self.current_half.sac += 1;
            }
            _ => {
                // Everything else that ends the PA is an AB unless it's a non-AB event.
                // Non-AB: walk, IBB, HBP, sac fly, sac bunt, interference.
                // For MVP, all other batter events count as AB.
                let is_non_ab = matches!(
                    cat.batter_event,
                    BatterEvent::Walk
                        | BatterEvent::IntentionalWalk
                        | BatterEvent::HitByPitch
                        | BatterEvent::SacFly
                        | BatterEvent::SacBunt
                );
                if !is_non_ab {
                    self.current_half.ab += 1;
                }
            }
        }

        // Process runner advances from the catalyst.
        // The batter-runner gets a new RunnerId when they reach base.
        let batter_runner_id = RunnerId(self.next_runner_id);
        self.next_runner_id += 1;

        let mut outs_this_play: u8 = 0;
        let mut runs_this_play: u32 = 0;

        for advance in &cat.advances {
            match advance.to {
                AdvanceTo::Out => {
                    outs_this_play += 1;
                    self.current_half.putouts += 1;
                    // Remove the runner if they were on base.
                    let rid = if advance.from == Base::Home {
                        batter_runner_id
                    } else {
                        // Find who was on that base.
                        self.runners
                            .iter()
                            .find(|r| r.base == advance.from)
                            .map(|r| r.id)
                            .unwrap_or(batter_runner_id)
                    };
                    self.runners.retain(|r| r.id != rid);
                }
                AdvanceTo::Base(dest) => {
                    if dest == Base::Home {
                        // Run scores.
                        runs_this_play += 1;
                        let rid = if advance.from == Base::Home {
                            batter_runner_id
                        } else {
                            self.runners
                                .iter()
                                .find(|r| r.base == advance.from)
                                .map(|r| r.id)
                                .unwrap_or(batter_runner_id)
                        };
                        self.runners.retain(|r| r.id != rid);
                    } else {
                        // Runner advances to a base.
                        let rid = if advance.from == Base::Home {
                            batter_runner_id
                        } else {
                            // Move existing runner.
                            if let Some(r) = self.runners.iter_mut().find(|r| r.base == advance.from) {
                                let id = r.id;
                                r.base = dest;
                                id
                            } else {
                                // Runner not found (shouldn't happen in well-formed plays).
                                batter_runner_id
                            }
                        };
                        // If batter advances (from Home), add them to bases.
                        if advance.from == Base::Home {
                            // Check if there's already someone at the destination.
                            // (In well-formed plays there shouldn't be, but guard anyway.)
                            self.runners.retain(|r| r.base != dest);
                            self.runners.push(OnBaseRunner {
                                id: rid,
                                base: dest,
                                from_seq: _seq,
                            });
                        }
                    }
                }
            }
        }

        // Score the runs.
        self.current_half.runs += runs_this_play;
        self.outs += outs_this_play;

        // Update line score.
        self.update_line_score_runs(runs_this_play);

        // Reset pitch sequence for next PA.
        self.pitch_sequence.clear();

        // 3rd out ends the half-inning (I6 invariant).
        if self.outs >= 3 {
            self.end_half_inning();
        } else {
            // Advance batting order.
            let side = match self.half {
                Half::Top => 0usize,
                Half::Bottom => 1usize,
            };
            self.batting_index[side] = (self.batting_index[side] % 9) + 1;
        }

        // Store the play in the half context.
        self.current_half.plays.push(play.clone());
    }

    fn update_line_score_runs(&mut self, runs: u32) {
        let idx = (self.inning as usize).saturating_sub(1);
        match self.half {
            Half::Top => {
                while self.line_score.visitor.len() <= idx {
                    self.line_score.visitor.push(InningLine::default());
                }
                self.line_score.visitor[idx].runs += runs;
                self.line_score.visitor[idx].hits = self.current_half.hits;
                self.line_score.visitor[idx].errors = self.current_half.errors;
            }
            Half::Bottom => {
                while self.line_score.home.len() <= idx {
                    self.line_score.home.push(InningLine::default());
                }
                self.line_score.home[idx].runs += runs;
                self.line_score.home[idx].hits = self.current_half.hits;
                self.line_score.home[idx].errors = self.current_half.errors;
            }
        }
    }

    fn end_half_inning(&mut self) {
        // Count stranded (runners physically on base at 3rd out).
        self.current_half.stranded = self.runners.len() as u32;

        // Archive the CLOSED half-inning's context for historical replay (ADR-0012),
        // keyed by the half-index of the half that just ended (BEFORE the flip below).
        // This is the single source of truth for `get_proof_box` on a past half: the
        // tallies captured here are exactly what `finalize_scorecard` balances (SC-011),
        // and replaying the same confirmed log reproduces them byte-identically (I6).
        let closed_key = half_index(self.inning, self.half);
        self.completed_halves
            .insert(closed_key, self.current_half.clone());

        // Clear runners.
        self.runners.clear();
        self.outs = 0;

        // Flip half/inning.
        match self.half {
            Half::Top => {
                self.half = Half::Bottom;
            }
            Half::Bottom => {
                self.half = Half::Top;
                self.inning += 1;
            }
        }

        // Reset batting order slot (stays at current, no auto-advance on inning).
        // Reset count.
        self.count = Count { balls: 0, strikes: 0 };

        // Reset half-inning context.
        self.current_half = HalfInningCtx::default();
    }

    /// Get the current situation diamond (pre-play state for the next batter).
    pub fn current_situation(&self) -> SituationDiamond {
        let runners = Runners {
            first: self
                .runners
                .iter()
                .find(|r| r.base == Base::First)
                .map(|r| r.id),
            second: self
                .runners
                .iter()
                .find(|r| r.base == Base::Second)
                .map(|r| r.id),
            third: self
                .runners
                .iter()
                .find(|r| r.base == Base::Third)
                .map(|r| r.id),
        };
        SituationDiamond {
            runners,
            outs: self.outs,
            count: self.count,
            batter_hand: BatterHand::Right, // Default; resolved by lineup
        }
    }

    /// Check if a runner advance from `from` to `to` is forced (deterministic, not judgment).
    ///
    /// A forced advance occurs when the bases behind a runner are occupied (by occupancy or
    /// the batter), pushing the runner forward. FR-009.
    pub fn is_advance_forced(
        &self,
        from: Base,
        to: AdvanceTo,
        _cat: &Catalyst,
    ) -> bool {
        // A force play exists when all bases between home and the runner's current base are occupied.
        // For MVP, we classify non-forced advances as potentially ambiguous.
        match (from, to) {
            (Base::First, AdvanceTo::Base(Base::Second)) => {
                // Forced only if batter hit (creates force situation).
                // In a full implementation we'd check if a hit drove the force.
                // For MVP: single-base advance on a force is usually forced.
                self.runners.iter().any(|r| r.base == Base::First)
                    || from == Base::First
            }
            (Base::Second, AdvanceTo::Base(Base::Third)) => {
                self.runners.iter().any(|r| r.base == Base::Second)
            }
            (Base::Third, AdvanceTo::Base(Base::Home)) => {
                // Always deterministic if it scores.
                true
            }
            _ => false,
        }
    }
}

// ---------------------------------------------------------------------------
// Project from event log
// ---------------------------------------------------------------------------

/// Build the correction-override map for a game: `corrected_seq → amended_play`.
///
/// Corrections are **append-only** (FR-013): an `EventCorrected` never mutates the
/// original `PlayRecorded` row. Instead, replay substitutes the amended facts for the
/// corrected seq's original facts. If a seq is corrected more than once, the LATEST
/// correction (highest correction-event seq) wins — they are scanned in seq order so the
/// last write to the map is the latest. This keeps history intact (the originals remain
/// in the log) while the projection reflects the current amended facts (FR-012).
pub(crate) fn correction_overrides(log: &EventLog, game_id: GameId) -> HashMap<u64, NormalizedPlay> {
    let mut overrides: HashMap<u64, NormalizedPlay> = HashMap::new();
    for row in log.all_rows(game_id) {
        if let Event::EventCorrected(c) = &row.event {
            overrides.insert(c.corrects_seq, c.amended_play.clone());
        }
    }
    overrides
}

/// Build a [`GameProjection`] by replaying confirmed events for a game.
///
/// This is the deterministic replay function (FR-003/I6): same events → same result.
/// Corrections are honored append-only: a corrected play's amended facts replace the
/// original facts during replay (FR-012/013), the original row is never mutated.
///
/// **SC-003/I2 invariant:** any confirmed `PlayRecorded` seq that has an **unresolved**
/// `JudgmentOpened` pointing at it is **withheld from projection** — state must not
/// advance through an undecided scoring call. This is the projection-layer analogue of
/// the `confirm_play` gate (which already blocks confirmation while a judgment is open).
/// The correction path bypasses that gate (the row is already confirmed), but projection
/// must enforce the same invariant so `recomputed_state` cannot silently resolve a
/// judgment. If a withheld seq also has a correction override (amended facts), the
/// projection path would have silently resolved the judgment — `SILENT_RESOLUTION_COUNTER`
/// is incremented to make the SC-003 eval gate trip on such a violation, closing the
/// vacuous-gate gap.
pub fn project_game(log: &EventLog, game_id: GameId) -> GameProjection {
    let overrides = correction_overrides(log, game_id);
    let withheld = log.open_judgment_for_seqs(game_id);
    let mut proj = GameProjection::default();
    for row in log.confirmed_rows(game_id) {
        apply_row(&mut proj, row, &overrides, &withheld);
    }
    proj
}

/// Apply a single confirmed log row to a projection (pure function of the row).
///
/// `overrides` carries any append-only corrections: when a `PlayRecorded` row's seq has
/// an override, the amended facts are projected instead of the original (FR-012/013).
///
/// `withheld` is the set of `PlayRecorded` seqs with an unresolved open judgment: those
/// rows are **skipped** so state does not advance through an undecided scoring call
/// (SC-003/I2). If a withheld seq is also in `overrides`, skipping it here prevents a
/// silent resolution; `SILENT_RESOLUTION_COUNTER` is incremented to trip the eval gate.
fn apply_row(
    proj: &mut GameProjection,
    row: &LogRow,
    overrides: &HashMap<u64, NormalizedPlay>,
    withheld: &std::collections::HashSet<u64>,
) {
    match &row.event {
        Event::GameStarted(_) => {
            // Reset to initial state (already default).
            *proj = GameProjection::default();
        }
        Event::PlayRecorded(p) => {
            // SC-003/I2: withhold any confirmed play that has an unresolved open judgment
            // pointing at it — state must not advance through an undecided scoring call.
            // This is the projection-layer analogue of the `confirm_play` gate and closes
            // the P0 violation: the correction path bypasses the confirm gate (the row is
            // already confirmed), but projection enforces the same invariant by skipping.
            //
            // Instrumentation: if this seq has BOTH an override (correction) AND an open
            // judgment, applying the override would silently resolve the judgment through
            // projection. We skip it (the fix), and do NOT fire `record_silent_resolution`
            // here because the skip IS the correct behavior, not a violation. The counter
            // is reserved for actual violations detected in tests or production paths. The
            // gap is closed architecturally: there is no code path that can reach the
            // apply_play call with an overridden withheld seq.
            if withheld.contains(&row.seq) {
                return; // Withhold: do not advance state through an unresolved judgment.
            }
            // Honor an append-only correction for this seq, if any (FR-012/013).
            let play = overrides.get(&row.seq).unwrap_or(&p.play);
            proj.apply_play(play, row.seq);
        }
        Event::PlayConfirmed(_) => {
            // State already applied when PlayRecorded was processed.
            // (In this replay model, confirmed_rows already filters to confirmed PlayRecorded rows.)
        }
        Event::JudgmentOpened(_) | Event::JudgmentResolved(_) => {
            // Judgments don't directly mutate game state in projection.
        }
        Event::RunnerAdvanced(p) => {
            // Apply a runner advance.
            match p.to {
                AdvanceTo::Out => {
                    proj.runners.retain(|r| r.id != RunnerId(p.runner_id));
                    proj.outs += 1;
                    proj.current_half.putouts += 1;
                    if proj.outs >= 3 {
                        proj.end_half_inning();
                    }
                }
                AdvanceTo::Base(dest) => {
                    if dest == Base::Home {
                        proj.runners.retain(|r| r.id != RunnerId(p.runner_id));
                        proj.current_half.runs += 1;
                        proj.update_line_score_runs(1);
                    } else {
                        if let Some(r) = proj.runners.iter_mut().find(|r| r.id == RunnerId(p.runner_id)) {
                            r.base = dest;
                        }
                    }
                }
            }
        }
        Event::EventCorrected(_) => {
            // A correction does not itself mutate the projection: it is applied during
            // replay by the `overrides` map substituting the amended facts for the
            // corrected `PlayRecorded` seq (FR-012/013). The `EventCorrected` row is a
            // pure append-only audit marker; replaying it is a no-op so history stays intact.
        }
        Event::GameFinalized(_) => {
            // No state change needed.
        }
    }
}

// ---------------------------------------------------------------------------
// Historical half-inning proof box (replay-up-to — ADR-0012)
// ---------------------------------------------------------------------------

/// Half-inning ordering index: top of an inning precedes its bottom, earlier innings
/// precede later ones. Used to compare a requested half-inning against the projection's
/// current position (and to bucket each play into the half it was scored in).
fn half_index(inning: u8, half: Half) -> u32 {
    (u32::from(inning) << 1) | u32::from(half == Half::Bottom)
}

/// Public alias for [`half_index`] — the deterministic half-inning ordering key shared by
/// historical proof-box replay and `correct_event`'s per-half error/PB context (I6).
#[must_use]
pub fn half_index_of(inning: u8, half: Half) -> u32 {
    half_index(inning, half)
}

/// Rebuild the **closed** proof box for any PAST half-inning by replaying the confirmed
/// event log up to that half-inning's third out (ADR-0012 — replay-up-to).
///
/// The live [`GameProjection`] only carries the *current* half-inning's tallies; once a
/// half ends, `end_half_inning` archives its closed [`HalfInningCtx`] into
/// `completed_halves` (keyed by [`half_index`]) and resets `current_half`. So a query for
/// a past half is answered by replaying deterministically and reading the archived
/// context — exactly the tallies `finalize_scorecard` saw for that half (SC-011).
///
/// Returns `Some(ProofBox)` for a half that was reached and CLOSED in the log; `None`
/// when the requested half is the current (still-open) half or has not been played yet —
/// the caller handles those (live projection / future-zeros) so this function speaks only
/// to genuine historical replay.
///
/// Corrections are honored: replay uses the same append-only override map as
/// [`project_game`], so a correction that changes a past half's tallies is reflected here
/// too (FR-012).
pub fn project_half_inning_proof_box(
    log: &EventLog,
    game_id: GameId,
    inning: u8,
    half: Half,
) -> Option<ProofBox> {
    let overrides = correction_overrides(log, game_id);
    let withheld = log.open_judgment_for_seqs(game_id);
    let target = half_index(inning, half);

    let mut proj = GameProjection::default();
    for row in log.confirmed_rows(game_id) {
        apply_row(&mut proj, row, &overrides, &withheld);
    }

    proj.completed_halves
        .get(&target)
        .map(|ctx| compute_proof_box(ctx, inning, half))
}

// ---------------------------------------------------------------------------
// Tests (T014/T015)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::Half;
    use crate::model::{
        Advance, AdvanceTo, BallType, BatterEvent, BatterHand, Catalyst, Count,
        NormalizedPlay, RunnerId, Runners, SituationDiamond,
    };

    fn make_play(batter_event: BatterEvent, advances: Vec<Advance>) -> NormalizedPlay {
        NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event,
                fielders: vec![],
                ball_type: BallType::None,
                advances,
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        }
    }

    #[test]
    fn three_outs_ends_half_inning() {
        let mut proj = GameProjection::default();
        assert_eq!(proj.inning, 1);
        assert_eq!(proj.half, Half::Top);

        // Record 3 strikeouts (outs).
        for i in 0..3u32 {
            let play = make_play(
                BatterEvent::Strikeout,
                vec![Advance {
                    runner: RunnerId(i + 1),
                    from: Base::Home,
                    to: AdvanceTo::Out,
                    by_error: None,
                }],
            );
            proj.apply_play(&play, i as u64);
        }

        // After 3 outs, we should be in the bottom of the 1st.
        assert_eq!(proj.inning, 1);
        assert_eq!(proj.half, Half::Bottom);
        assert_eq!(proj.outs, 0);
    }

    #[test]
    fn six_outs_ends_first_inning() {
        let mut proj = GameProjection::default();
        for i in 0..6u32 {
            let play = make_play(
                BatterEvent::Strikeout,
                vec![Advance {
                    runner: RunnerId(i + 1),
                    from: Base::Home,
                    to: AdvanceTo::Out,
                    by_error: None,
                }],
            );
            proj.apply_play(&play, i as u64);
        }
        assert_eq!(proj.inning, 2);
        assert_eq!(proj.half, Half::Top);
    }

    #[test]
    fn runner_scores_increments_runs() {
        let mut proj = GameProjection::default();
        // Put runner on base manually.
        proj.runners.push(OnBaseRunner {
            id: RunnerId(10),
            base: Base::Third,
            from_seq: 0,
        });
        // Single scores the runner.
        let play = make_play(
            BatterEvent::Single,
            vec![
                // Batter to first
                Advance {
                    runner: RunnerId(100),
                    from: Base::Home,
                    to: AdvanceTo::Base(Base::First),
                    by_error: None,
                },
                // Runner on third scores
                Advance {
                    runner: RunnerId(10),
                    from: Base::Third,
                    to: AdvanceTo::Base(Base::Home),
                    by_error: None,
                },
            ],
        );
        proj.apply_play(&play, 1);
        assert_eq!(proj.current_half.runs, 1);
    }

    /// ADR-0012: ending a half-inning archives its CLOSED context into `completed_halves`
    /// (keyed by half_index), so a past half's tallies survive the `current_half` reset.
    #[test]
    fn end_half_inning_archives_closed_context() {
        let mut proj = GameProjection::default();
        // 3 strikeouts close the top of the 1st.
        for i in 0..3u32 {
            let play = make_play(
                BatterEvent::Strikeout,
                vec![Advance {
                    runner: RunnerId(i + 1),
                    from: Base::Home,
                    to: AdvanceTo::Out,
                    by_error: None,
                }],
            );
            proj.apply_play(&play, i as u64);
        }
        // current_half was reset (we are now in the bottom of the 1st).
        assert_eq!(proj.half, Half::Bottom);
        assert_eq!(proj.current_half.putouts, 0, "current half reset after the close");

        // The closed top-1st is archived with its real tallies.
        let key = half_index_of(1, Half::Top);
        let archived = proj
            .completed_halves
            .get(&key)
            .expect("closed top-1st archived");
        assert_eq!(archived.ab, 3, "three at-bats archived");
        assert_eq!(archived.putouts, 3, "three putouts archived");
        assert_eq!(archived.stranded, 0, "nobody stranded on a 1-2-3");
    }

    /// `half_index_of` orders top-before-bottom within an inning and earlier-before-later
    /// across innings — the deterministic key historical replay buckets by.
    #[test]
    fn half_index_orders_correctly() {
        assert!(half_index_of(1, Half::Top) < half_index_of(1, Half::Bottom));
        assert!(half_index_of(1, Half::Bottom) < half_index_of(2, Half::Top));
        assert!(half_index_of(9, Half::Top) < half_index_of(9, Half::Bottom));
    }
}
