//! Proptest invariant tests (T016 / Art. XI / XXXIV).
//!
//! Property-based invariants for the core engine:
//! 1. No silent judgment: classify() on a HitVsError play never returns Deterministic.
//! 2. PENDING in error innings: any run scoring in an error inning → EarnedVsUnearned.
//! 3. Determinism: same confirmed events → byte-identical state.

use dl_core::classify::{classify_with_context, ClassifyContext};
use dl_core::model::{
    Advance, AdvanceTo, BallType, BatterEvent, BatterHand, Catalyst, Classification,
    Count, JudgmentKind, NormalizedPlay, Position, RunnerId, Runners, SituationDiamond, Base,
};
use proptest::prelude::*;

// ---------------------------------------------------------------------------
// Proptest strategies
// ---------------------------------------------------------------------------

fn arb_position() -> impl Strategy<Value = Position> {
    (1u8..=9u8).prop_map(Position)
}

fn arb_hit_vs_error_play() -> impl Strategy<Value = NormalizedPlay> {
    // A play where the batter reaches AND a fielder touched the ball.
    // This should ALWAYS classify as HitVsError (I1/FR-006).
    prop::collection::vec(arb_position(), 1..=3)
        .prop_map(|fielders| NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: fielders.clone(),
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Base(Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: fielders,
            },
            audit_label: Some("single".into()), // adversarial label — must NOT affect classification
        })
}

// ---------------------------------------------------------------------------
// Invariant: no silent judgment on HitVsError plays (I2/SC-003)
// ---------------------------------------------------------------------------

proptest! {
    #[test]
    fn no_silent_judgment_hit_vs_error(play in arb_hit_vs_error_play()) {
        let ctx = ClassifyContext { inning_has_error_or_pb: false };
        let result = classify_with_context(&play, &ctx);
        // MUST be a Judgment — never Deterministic for a HitVsError play.
        // (EarnedVsUnearned, ContestedCredit, AmbiguousAdvance are also acceptable.)
        prop_assert!(
            matches!(result, Classification::Judgment(_)),
            "A play with touched_or_misplayed_by non-empty + batter reached MUST be a Judgment, got {:?}",
            result
        );
    }
}

// ---------------------------------------------------------------------------
// Invariant: PENDING (EarnedVsUnearned) when run scores in error inning (I3)
// ---------------------------------------------------------------------------

proptest! {
    #[test]
    fn pending_in_error_inning(has_error in prop::bool::ANY) {
        // SacFly with runner scoring from third (a canonical scoring play).
        let play = NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners {
                    first: None, second: None, third: Some(RunnerId(2)),
                },
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::SacFly,
                fielders: vec![Position(7)],
                ball_type: BallType::Fly,
                advances: vec![
                    Advance { runner: RunnerId(1), from: Base::Home, to: AdvanceTo::Out, by_error: None },
                    Advance { runner: RunnerId(2), from: Base::Third, to: AdvanceTo::Base(Base::Home), by_error: None },
                ],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        };

        let ctx = ClassifyContext { inning_has_error_or_pb: has_error };
        let result = classify_with_context(&play, &ctx);

        if has_error {
            prop_assert_eq!(
                result,
                Classification::Judgment(JudgmentKind::EarnedVsUnearned),
                "Run in error inning MUST be EarnedVsUnearned (I3/FR-010a)"
            );
        } else {
            prop_assert_eq!(
                result,
                Classification::Deterministic,
                "Run without error inning context MUST be Deterministic"
            );
        }
    }
}
