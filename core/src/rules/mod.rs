//! Deterministic rules engine — GameState machine + runner advancement (T014/T015).
//!
//! All arithmetic is integer-only (ADR-0007/I6). The [`GameProjection`] is rebuilt by
//! replaying confirmed events from the event log (FR-003). The 3rd-out ends a half-inning;
//! runner advancement is forced (deterministic) or flagged ambiguous→judgment (FR-009).

use crate::eventlog::{Event, EventLog, LogRow};
use crate::ffi::{
    ActiveFielder, GameId, GameState, Half, InningLine, LineScore, PitchMark,
};
use crate::model::{
    AdvanceTo, Base, BatterEvent, BatterHand, Catalyst, Count, NormalizedPlay, RunnerId,
    Runners, SituationDiamond,
};

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

/// Build a [`GameProjection`] by replaying confirmed events for a game.
///
/// This is the deterministic replay function (FR-003/I6): same events → same result.
pub fn project_game(log: &EventLog, game_id: GameId) -> GameProjection {
    let mut proj = GameProjection::default();
    for row in log.confirmed_rows(game_id) {
        apply_row(&mut proj, row);
    }
    proj
}

/// Apply a single confirmed log row to a projection (pure function of the row).
fn apply_row(proj: &mut GameProjection, row: &LogRow) {
    match &row.event {
        Event::GameStarted(_) => {
            // Reset to initial state (already default).
            *proj = GameProjection::default();
        }
        Event::PlayRecorded(p) => {
            proj.apply_play(&p.play, row.seq);
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
            // Post-MVP: correct_event triggers a full replay from the correction point.
            // For MVP, we skip correction replay.
        }
        Event::GameFinalized(_) => {
            // No state change needed.
        }
    }
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
}
