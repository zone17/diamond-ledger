//! Reisner renderer + proof-box (T026/T027, FR-005/005a, SC-011).
//!
//! Renders `NormalizedPlay` facts into a `ReisnerCell` (situation-diamond + catalyst notation +
//! runner fate). Computes proof-box: `AB + BB + Sac + HBP + Interference = Runs + Putouts + LOB`.
//! Integer-only (ADR-0007/I6).

use crate::ffi::{Half, ProofBox, ReisnerCell, RunnerFate};
use crate::model::{AdvanceTo, Base, BatterEvent, NormalizedPlay, Runners};
use crate::rules::HalfInningCtx;

// ---------------------------------------------------------------------------
// Situation-diamond rendering
// ---------------------------------------------------------------------------

/// Render the situation diamond as a short glyph string.
///
/// Uses standard Project-Scoresheet occupancy encoding:
/// - `---` = bases empty
/// - `1--` = runner on first
/// - `-2-` = runner on second
/// - `--3` = runner on third
/// - `123` = bases loaded
///
/// (…and so on for every base-occupancy combination.)
pub fn render_situation_diamond(runners: &Runners, outs: u8) -> String {
    let first = if runners.first.is_some() { "1" } else { "-" };
    let second = if runners.second.is_some() { "2" } else { "-" };
    let third = if runners.third.is_some() { "3" } else { "-" };
    format!("{}{}{} {}", first, second, third, outs)
}

// ---------------------------------------------------------------------------
// Catalyst notation rendering
// ---------------------------------------------------------------------------

/// Render the catalyst notation string for a play (the "bottom" of the Reisner cell).
///
/// Maps `BatterEvent` + fielder sequence to standard notation:
/// - Hits: "1B", "2B", "3B", "HR"
/// - Strikeout: "K"
/// - Walk: "BB", "IBB"
/// - HBP: "HBP"
/// - Fielded outs: "6-3", "8", etc.
/// - Error: "E6"
/// - Sac fly/bunt: "SF7", "SH"
pub fn render_catalyst(play: &NormalizedPlay) -> String {
    let cat = &play.catalyst;
    match cat.batter_event {
        BatterEvent::Single => {
            if let Some(pos) = cat.fielders.first() {
                format!("1B-{}", pos.0)
            } else {
                "1B".into()
            }
        }
        BatterEvent::Double => {
            if let Some(pos) = cat.fielders.first() {
                format!("2B-{}", pos.0)
            } else {
                "2B".into()
            }
        }
        BatterEvent::Triple => {
            if let Some(pos) = cat.fielders.first() {
                format!("3B-{}", pos.0)
            } else {
                "3B".into()
            }
        }
        BatterEvent::HomeRun => "HR".into(),
        BatterEvent::Strikeout => "K".into(),
        BatterEvent::Walk => "BB".into(),
        BatterEvent::IntentionalWalk => "IBB".into(),
        BatterEvent::HitByPitch => "HBP".into(),
        BatterEvent::Error => {
            if let Some(pos) = cat.fielders.first() {
                format!("E{}", pos.0)
            } else {
                "E?".into()
            }
        }
        BatterEvent::FieldersChoice => {
            render_fielder_sequence(&cat.fielders)
        }
        BatterEvent::FieldedOut => {
            render_fielder_sequence(&cat.fielders)
        }
        BatterEvent::SacFly => {
            if let Some(pos) = cat.fielders.first() {
                format!("SF{}", pos.0)
            } else {
                "SF".into()
            }
        }
        BatterEvent::SacBunt => {
            render_fielder_sequence_prefix("SH", &cat.fielders)
        }
        BatterEvent::StolenBase => "SB".into(),
        BatterEvent::CaughtStealing => "CS".into(),
        BatterEvent::WildPitch => "WP".into(),
        BatterEvent::PassedBall => "PB".into(),
        BatterEvent::Other => "?".into(),
    }
}

fn render_fielder_sequence(fielders: &[crate::model::Position]) -> String {
    if fielders.is_empty() {
        return "?".into();
    }
    let parts: Vec<String> = fielders.iter().map(|p| p.0.to_string()).collect();
    parts.join("-")
}

fn render_fielder_sequence_prefix(prefix: &str, fielders: &[crate::model::Position]) -> String {
    if fielders.is_empty() {
        return prefix.into();
    }
    let seq = render_fielder_sequence(fielders);
    format!("{}{}", prefix, seq)
}

// ---------------------------------------------------------------------------
// Runner fate determination
// ---------------------------------------------------------------------------

/// Determine the `RunnerFate` for the batter-runner.
pub fn batter_runner_fate(play: &NormalizedPlay, out_number: u8) -> RunnerFate {
    let cat = &play.catalyst;
    for adv in &cat.advances {
        if adv.from == Base::Home {
            return match adv.to {
                AdvanceTo::Out => RunnerFate::PutOut { n: out_number },
                AdvanceTo::Base(Base::Home) => RunnerFate::Scored { rbi: is_rbi(play) },
                AdvanceTo::Base(_) => RunnerFate::LeftOnBase,
            };
        }
    }
    // No advance for batter — treat as out if it's a strikeout, else LOB.
    match cat.batter_event {
        BatterEvent::Strikeout => RunnerFate::PutOut { n: out_number },
        _ => RunnerFate::LeftOnBase,
    }
}

/// Heuristic: is this play an RBI?
/// - SacFly that scores a runner = RBI
/// - Hit that scores a runner = RBI (simplified: any run that scores is RBI unless it's an error)
fn is_rbi(play: &NormalizedPlay) -> bool {
    let cat = &play.catalyst;
    // No RBI on an error play.
    if cat.batter_event == BatterEvent::Error {
        return false;
    }
    // Check if any runner (not batter) scores.
    cat.advances.iter().any(|a| {
        a.from != Base::Home && matches!(a.to, AdvanceTo::Base(Base::Home))
    })
}

// ---------------------------------------------------------------------------
// Render a full ReisnerCell
// ---------------------------------------------------------------------------

/// Render a `NormalizedPlay` into a `ReisnerCell` (T026).
///
/// The `outs_before` parameter is the outs count before this play (0..=2),
/// used to compute the out number for the runner fate.
pub fn render_cell(play: &NormalizedPlay, outs_before: u8) -> ReisnerCell {
    let situation_diamond = render_situation_diamond(&play.situation.runners, play.situation.outs);
    let catalyst_symbols = render_catalyst(play);
    let out_n = outs_before + 1;
    let runner_fate = batter_runner_fate(play, out_n);

    ReisnerCell {
        situation_diamond,
        catalyst_symbols,
        pitch_marks: Vec::new(), // Pitch tracking not in MVP core
        runner_fate,
    }
}

// ---------------------------------------------------------------------------
// Proof-box (T027, FR-005a, SC-011)
// ---------------------------------------------------------------------------

/// Compute the proof box for a half-inning.
///
/// The accounting identity MUST hold:
///   `AB + BB + Sac + HBP + Interference = Runs + Putouts + Stranded`
///
/// `finalize_scorecard` returns an error if any proof box does not balance (SC-011).
pub fn compute_proof_box(ctx: &HalfInningCtx, inning: u8, half: Half) -> ProofBox {
    ProofBox {
        inning,
        half,
        ab: ctx.ab,
        bb: ctx.bb,
        sac: ctx.sac,
        hbp: ctx.hbp,
        interference: ctx.interference,
        runs: ctx.runs,
        putouts: ctx.putouts,
        stranded: ctx.stranded,
    }
}

/// Check whether a proof box balances.
///
/// Returns `Ok(())` if balanced, `Err(imbalance description)` otherwise (SC-011).
pub fn check_proof_box_balance(pb: &ProofBox) -> Result<(), String> {
    let left = pb.ab + pb.bb + pb.sac + pb.hbp + pb.interference;
    let right = pb.runs + pb.putouts + pb.stranded;
    if left == right {
        Ok(())
    } else {
        Err(format!(
            "Proof-box imbalance for inning {} {:?}: AB+BB+Sac+HBP+INT={} ≠ R+PO+LOB={} (SC-011)",
            pb.inning, pb.half, left, right
        ))
    }
}

// ---------------------------------------------------------------------------
// Tests (T028)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::{Half, RunnerFate};
    use crate::model::{
        Advance, AdvanceTo, BallType, BatterEvent, BatterHand, Catalyst, Count,
        NormalizedPlay, Position, RunnerId, Runners, SituationDiamond,
    };
    use crate::rules::HalfInningCtx;

    fn strikeout_play() -> NormalizedPlay {
        NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 2 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::Strikeout,
                fielders: vec![],
                ball_type: BallType::None,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: crate::model::Base::Home,
                    to: AdvanceTo::Out,
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        }
    }

    fn groundout_play() -> NormalizedPlay {
        NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(6), Position(3)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: crate::model::Base::Home,
                    to: AdvanceTo::Out,
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        }
    }

    fn single_play() -> NormalizedPlay {
        NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::Single,
                fielders: vec![Position(7)],
                ball_type: BallType::Line,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: crate::model::Base::Home,
                    to: AdvanceTo::Base(crate::model::Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        }
    }

    #[test]
    fn situation_diamond_empty_bases() {
        let runners = Runners::default();
        let s = render_situation_diamond(&runners, 0);
        assert_eq!(s, "--- 0");
    }

    #[test]
    fn situation_diamond_bases_loaded() {
        let runners = Runners {
            first: Some(RunnerId(1)),
            second: Some(RunnerId(2)),
            third: Some(RunnerId(3)),
        };
        let s = render_situation_diamond(&runners, 2);
        assert_eq!(s, "123 2");
    }

    #[test]
    fn catalyst_strikeout() {
        let play = strikeout_play();
        assert_eq!(render_catalyst(&play), "K");
    }

    #[test]
    fn catalyst_groundout_6_3() {
        let play = groundout_play();
        assert_eq!(render_catalyst(&play), "6-3");
    }

    #[test]
    fn catalyst_single_to_left() {
        let play = single_play();
        assert_eq!(render_catalyst(&play), "1B-7");
    }

    #[test]
    fn runner_fate_strikeout_putout() {
        let play = strikeout_play();
        let fate = batter_runner_fate(&play, 1);
        assert_eq!(fate, RunnerFate::PutOut { n: 1 });
    }

    #[test]
    fn runner_fate_single_left_on_base() {
        let play = single_play();
        let fate = batter_runner_fate(&play, 1);
        assert_eq!(fate, RunnerFate::LeftOnBase);
    }

    /// T027 / SC-011: proof box must balance.
    #[test]
    fn proof_box_balances_three_outs_no_runs() {
        // 3 groundouts, no runners, no runs.
        let ctx = HalfInningCtx {
            ab: 3,
            bb: 0,
            sac: 0,
            hbp: 0,
            interference: 0,
            runs: 0,
            putouts: 3,
            stranded: 0,
            ..Default::default()
        };
        let pb = compute_proof_box(&ctx, 1, Half::Top);
        assert!(check_proof_box_balance(&pb).is_ok(), "Proof box must balance");
    }

    #[test]
    fn proof_box_imbalance_detected() {
        let ctx = HalfInningCtx {
            ab: 3,
            bb: 0,
            sac: 0,
            hbp: 0,
            interference: 0,
            runs: 1, // But only 2 putouts + 1 stranded = 3, which equals AB+BB+... = 3. OK actually.
            putouts: 2,
            stranded: 1,
            ..Default::default()
        };
        let pb = compute_proof_box(&ctx, 1, Half::Top);
        // left = 3, right = 1+2+1 = 4 → doesn't balance
        // Wait: ab=3, runs=1, putouts=2, stranded=1 → left=3, right=4. Imbalanced!
        // Actually left=3+0+0+0+0=3, right=1+2+1=4. Should fail.
        // But wait: for 3 outs the normal case is 3 putouts, not 2. Let's test the actual imbalance.
        let result = check_proof_box_balance(&pb);
        assert!(result.is_err(), "Imbalanced proof box must fail");
    }

    #[test]
    fn proof_box_balanced_with_run() {
        // 2 ABs (out + single), 1 walk, 0 sac — runner scores on the single.
        // AB=2, BB=1 → left=3. R=1, PO=1, LOB=1 → right=3.
        let ctx = HalfInningCtx {
            ab: 2,
            bb: 1,
            sac: 0,
            hbp: 0,
            interference: 0,
            runs: 1,
            putouts: 1,
            stranded: 1,
            ..Default::default()
        };
        // Actually for the half-inning we need 3 outs to end it. Let's just verify the math.
        // This is a partial inning check.
        let pb = compute_proof_box(&ctx, 2, Half::Bottom);
        // left = 2+1 = 3, right = 1+1+1 = 3 → balanced.
        assert!(check_proof_box_balance(&pb).is_ok());
    }

    /// Insta golden snapshot for a rendered cell (T028).
    #[test]
    fn golden_snapshot_groundout_cell() {
        let play = groundout_play();
        let cell = render_cell(&play, 0);
        insta::assert_json_snapshot!("groundout_6_3_cell", cell);
    }

    #[test]
    fn golden_snapshot_single_cell() {
        let play = single_play();
        let cell = render_cell(&play, 0);
        insta::assert_json_snapshot!("single_to_left_cell", cell);
    }
}
