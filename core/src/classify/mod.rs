//! Fact-derived judgment classifier — the cardinal seam (T021–T024, FR-006/I1/I2).
//!
//! `classify()` derives `Classification` from `NormalizedPlay` **facts only**.
//! It NEVER reads `audit_label` (FR-006/FR-006a/I1).
//!
//! ## Silent-resolution counter (SC-003/T024)
//!
//! The [`SILENT_RESOLUTION_COUNTER`] increments whenever a judgment is mutated
//! (state advanced, call recorded) without an open `JudgmentDecision` (status=Open)
//! and a recorded `decider`. A non-zero counter is a hard CI gate failure (SC-003).

use std::sync::atomic::{AtomicU64, Ordering};

use crate::model::{BatterEvent, Classification, JudgmentKind, NormalizedPlay};

// ---------------------------------------------------------------------------
// Silent-resolution counter (SC-003/T024)
// ---------------------------------------------------------------------------

/// Instrumented counter: increments on any silent judgment resolution.
///
/// This counter is the enforcement mechanism for SC-003 / I2: "no judgment may be
/// silently resolved without an open flag + recorded decider." A non-zero value means
/// the invariant was violated and the eval gate MUST fail (exit 1).
///
/// Callers: increment via [`record_silent_resolution`]; read via [`silent_resolution_count`].
pub static SILENT_RESOLUTION_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Increment the silent-resolution counter. Called by any code path that would silently
/// resolve a judgment without an open flag + decider.
#[inline]
pub fn record_silent_resolution() {
    SILENT_RESOLUTION_COUNTER.fetch_add(1, Ordering::SeqCst);
}

/// Read the current silent-resolution count.
#[must_use]
#[inline]
pub fn silent_resolution_count() -> u64 {
    SILENT_RESOLUTION_COUNTER.load(Ordering::SeqCst)
}

/// Reset the counter (for tests and eval gate runners).
///
/// NOT for production use — resetting mid-game would defeat the SC-003 gate.
/// Exposed unconditionally so integration tests (in `core/tests/`) can use it.
pub fn reset_silent_resolution_counter() {
    SILENT_RESOLUTION_COUNTER.store(0, Ordering::SeqCst);
}

// ---------------------------------------------------------------------------
// Additional context passed alongside the play (not part of NormalizedPlay)
// ---------------------------------------------------------------------------

/// Extra context that cannot be derived from per-play facts alone.
///
/// `classify_with_context` accepts this alongside the play when the caller has
/// inning-level knowledge (e.g., has_error_or_pb from the half-inning scan).
/// The pure `classify()` function is used when no extra context is available.
#[derive(Debug, Clone, Default)]
pub struct ClassifyContext {
    /// True if the current half-inning already contains at least one error or passed ball.
    /// Required to mechanically derive the `EarnedVsUnearned` trigger (I3/FR-010a).
    pub inning_has_error_or_pb: bool,
}

// ---------------------------------------------------------------------------
// The cardinal classify function (T021, FR-006/I1)
// ---------------------------------------------------------------------------

/// Classify a normalized play by its **facts only** (I1/FR-006).
///
/// - NEVER reads `audit_label` — it is opaque provenance, not a control signal.
/// - A play whose facts constitute a judgment is classified as `Judgment(kind)`
///   regardless of any caller-supplied label (FR-006a).
/// - Returns `OutOfFormat` for plays outside the reduced v1 grammar (FR-017).
///
/// This is the public entry point for the MVP (no inning context).
#[must_use]
pub fn classify(play: &NormalizedPlay) -> Classification {
    classify_with_context(play, &ClassifyContext::default())
}

/// Classify with additional half-inning context (for EarnedVsUnearned, I3).
#[must_use]
pub fn classify_with_context(play: &NormalizedPlay, ctx: &ClassifyContext) -> Classification {
    let cat = &play.catalyst;

    // ── Out of format first (FR-017) ──────────────────────────────────────────
    if cat.batter_event == BatterEvent::Other {
        return Classification::OutOfFormat(
            "BatterEvent::Other is outside the reduced v1 grammar (FR-017)".into(),
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // JUDGMENT TRIGGER PRIORITY (established by the adversarial corpus; #127 reconcile):
    //
    //   1. EarnedVsUnearned  — inning context + run scores (most specific context)
    //   2. AmbiguousAdvance  — the advance ITSELF is what's contested:
    //        (a) error-enabled extra-base advance (overthrow: hit-vs-error on the BASES)
    //        (b) deflection-enabled scoring advance (≥2 fielders touched the ball)
    //        (c) non-scoring baserunner 2+ bases without error
    //        (d) batter 2+ bases on a non-clean-XBH without error
    //   3. ContestedCredit   — multi-fielder relay/DP CREDIT (who is charged/credited)
    //   4. HitVsError        — fielder touch + batter reaches (the at-bat hit-vs-error)
    //
    // Ordering rationale (all four kinds still SURFACE a judgment, so SC-003/I2 holds
    // regardless of kind — the kind only decides WHICH question the scorer is asked):
    // AmbiguousAdvance precedes ContestedCredit/HitVsError because when an error or a
    // multi-fielder deflection ENABLED the advance, the open question is the advance
    // attribution (how many bases are hit vs error), not the at-bat credit. This makes
    // the classifier agree with corpus-019 (deflected scoring advance) and corpus-020
    // (overthrow extra-base advance), which earlier mis-fired as ContestedCredit /
    // HitVsError. See #127 and docs/solutions for the call.
    // ─────────────────────────────────────────────────────────────────────────

    let run_scores = cat.advances.iter().any(|a| {
        matches!(a.to, crate::model::AdvanceTo::Base(crate::model::Base::Home))
    });

    // ── 1. EarnedVsUnearned trigger (I3/FR-010a) ──────────────────────────────
    // Any run that scores in a half-inning that has an error or passed ball MUST be
    // flagged PENDING (no Rule 9.16 in v1). This has the highest priority because the
    // inning context is the most specific constraint.
    if ctx.inning_has_error_or_pb && run_scores {
        return Classification::Judgment(JudgmentKind::EarnedVsUnearned);
    }

    // ── 2. AmbiguousAdvance trigger ────────────────────────────────────────────
    // The contested thing is the ADVANCE attribution. Checked before ContestedCredit
    // and HitVsError (#127): when a misplay/overthrow enabled the advance, "how many
    // bases are a hit vs an error" is the scorer's call, not the at-bat credit.
    {
        let is_home_run = cat.batter_event == BatterEvent::HomeRun;
        let is_clean_extra_base_hit = matches!(
            cat.batter_event,
            BatterEvent::Double | BatterEvent::Triple | BatterEvent::HomeRun
        );
        // (b) Deflection-enabled scoring advance: the ball was touched/misplayed by
        // 2+ fielders AND a run scored. The deflection makes the advance attribution
        // (clean hit vs misplay-enabled) ambiguous → AmbiguousAdvance, NOT a relay-RBI
        // ContestedCredit (which needs a single clean relay). Distinguishes corpus-019
        // (touched=[8,4]) from corpus-013 (touched=[9], one fielder → ContestedCredit).
        if run_scores && cat.touched_or_misplayed_by.len() >= 2 {
            return Classification::Judgment(JudgmentKind::AmbiguousAdvance);
        }
        if !is_home_run {
            for adv in &cat.advances {
                // (a) Error-enabled extra-base advance by the BATTER-RUNNER (the overthrow
                // case): an error is attributed on a batter advance that moved 2+ bases.
                // How many of those bases are a hit vs an error is the scorer's call →
                // AmbiguousAdvance (corpus-020). Restricted to `from == Home` so that an
                // error advancing a *prior* runner while the batter cleanly reached first
                // stays the at-bat HitVsError (corpus-004), not an ambiguous advance.
                if adv.by_error.is_some() {
                    if adv.from == crate::model::Base::Home && base_distance(adv.from, adv.to) >= 2 {
                        return Classification::Judgment(JudgmentKind::AmbiguousAdvance);
                    }
                    continue;
                }
                // (c) Non-scoring baserunner 2+ bases without error.
                if adv.from != crate::model::Base::Home {
                    let goes_to_home = matches!(adv.to, crate::model::AdvanceTo::Base(crate::model::Base::Home));
                    if !goes_to_home && base_distance(adv.from, adv.to) >= 2 {
                        return Classification::Judgment(JudgmentKind::AmbiguousAdvance);
                    }
                }
                // (d) Batter 2+ bases on a non-clean-extra-base-hit without error.
                if adv.from == crate::model::Base::Home
                    && !is_clean_extra_base_hit
                    && base_distance(adv.from, adv.to) >= 2
                {
                    return Classification::Judgment(JudgmentKind::AmbiguousAdvance);
                }
            }
        }
    }

    // ── 3. ContestedCredit trigger ─────────────────────────────────────────────
    // The contested thing is the fielding CREDIT (which fielder is charged/credited),
    // not the advance. Three patterns:
    // (a) single-deflection relay RBI: 2+ fielders + run scores + exactly one fielder
    //     touched (a 2+-fielder deflection scoring advance is AmbiguousAdvance above).
    // (b) 3+ fielders in chain + 2+ runner outs → DP/TP credit contested.
    // (c) safe batter on a multi-fielder THROW chain (a throw was made to retire the
    //     batter but they reached): the call is error-on-the-receiver vs hit vs FC —
    //     a contested credit among fielders. Distinguishes corpus-015 (batter_event
    //     `Single` + fld=[9,3], a throw to first) from corpus-001 (`FieldedOut` +
    //     fld=[6,3]) which is the at-bat HitVsError below.
    {
        let relay_rbi_contested = cat.fielders.len() >= 2
            && run_scores
            && !cat.touched_or_misplayed_by.is_empty();
        let dp_credit_contested = cat.fielders.len() >= 3
            && cat.advances.iter().filter(|a| matches!(a.to, crate::model::AdvanceTo::Out)).count() >= 2;
        let batter_reached_safe = cat.advances.iter().any(|a| {
            a.from == crate::model::Base::Home && matches!(a.to, crate::model::AdvanceTo::Base(_))
        });
        let safe_throw_chain_contested = cat.fielders.len() >= 2
            && batter_reached_safe
            && !run_scores
            && matches!(
                cat.batter_event,
                BatterEvent::Single | BatterEvent::FieldersChoice | BatterEvent::Error
            );
        if relay_rbi_contested || dp_credit_contested || safe_throw_chain_contested {
            return Classification::Judgment(JudgmentKind::ContestedCredit);
        }
    }

    // ── 4. HitVsError trigger (I1/FR-006) ─────────────────────────────────────
    // Fielder touched or misplayed the ball AND the batter-runner reached base safely.
    // Fact-derived; fires regardless of any audit_label (FR-006a).
    // NOTE: Runs after AmbiguousAdvance + ContestedCredit (corpus priority, #127).
    let batter_reached = cat.advances.iter().any(|a| {
        a.from == crate::model::Base::Home && matches!(a.to, crate::model::AdvanceTo::Base(_))
    });
    if !cat.touched_or_misplayed_by.is_empty() && batter_reached {
        return Classification::Judgment(JudgmentKind::HitVsError);
    }

    // ── All remaining plays are deterministic ─────────────────────────────────
    Classification::Deterministic
}

/// Count the number of bases from `from` to `to` (for ambiguous advance detection).
/// Returns 0 for Out.
fn base_distance(from: crate::model::Base, to: crate::model::AdvanceTo) -> u8 {
    use crate::model::{AdvanceTo, Base};
    let from_n = match from {
        Base::Home => 0u8,
        Base::First => 1,
        Base::Second => 2,
        Base::Third => 3,
    };
    let to_n = match to {
        AdvanceTo::Out => return 0,
        AdvanceTo::Base(Base::Home) => 4u8,
        AdvanceTo::Base(Base::First) => 1,
        AdvanceTo::Base(Base::Second) => 2,
        AdvanceTo::Base(Base::Third) => 3,
    };
    to_n.saturating_sub(from_n)
}

// ---------------------------------------------------------------------------
// Tests (T025 — negative tests, adversarial invariants)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{
        Advance, AdvanceTo, BallType, BatterEvent, BatterHand, Catalyst, Classification,
        Count, JudgmentKind, NormalizedPlay, Position, RunnerId, Runners, SituationDiamond,
    };

    fn base_situation() -> SituationDiamond {
        SituationDiamond {
            runners: Runners::default(),
            outs: 0,
            count: Count { balls: 0, strikes: 0 },
            batter_hand: BatterHand::Right,
        }
    }

    /// T025 / FR-006a: a play whose facts are HitVsError but whose label is "single"
    /// MUST still classify as Judgment(HitVsError).
    #[test]
    fn mislabeled_single_classifies_as_hit_vs_error() {
        reset_silent_resolution_counter();
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(6), Position(3)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: crate::model::Base::Home,
                    to: AdvanceTo::Base(crate::model::Base::First),
                    by_error: None,
                }],
                // Fielder touched the ball — this is the fact that drives HitVsError.
                touched_or_misplayed_by: vec![Position(6)],
            },
            // audit_label says "single" — this is the adversarial mislabel.
            audit_label: Some("single".into()),
        };
        let result = classify(&play);
        assert_eq!(
            result,
            Classification::Judgment(JudgmentKind::HitVsError),
            "Mislabeled play must classify from facts, not the audit_label (FR-006a/I1)"
        );
        // Counter must NOT have incremented — we correctly surfaced this as a judgment.
        assert_eq!(silent_resolution_count(), 0, "Counter must not trip on correct judgment surfacing");
    }

    /// The silent-resolution counter trips when code forces a silent resolution.
    #[test]
    fn silent_resolution_counter_trips_on_violation() {
        reset_silent_resolution_counter();
        // Simulate a bug: code silently resolves a judgment without an open flag.
        record_silent_resolution(); // This is what a buggy code path would do.
        assert!(
            silent_resolution_count() > 0,
            "Counter must increment when a silent resolution is recorded (SC-003)"
        );
    }

    /// A strikeout (no fielder contact, no ambiguous advance) is Deterministic.
    #[test]
    fn strikeout_is_deterministic() {
        reset_silent_resolution_counter();
        let play = NormalizedPlay {
            situation: base_situation(),
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
        };
        assert_eq!(classify(&play), Classification::Deterministic);
    }

    /// A walk is Deterministic.
    #[test]
    fn walk_is_deterministic() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::Walk,
                fielders: vec![],
                ball_type: BallType::None,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: crate::model::Base::Home,
                    to: AdvanceTo::Base(crate::model::Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        };
        assert_eq!(classify(&play), Classification::Deterministic);
    }

    /// A home run is Deterministic.
    #[test]
    fn home_run_is_deterministic() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::HomeRun,
                fielders: vec![],
                ball_type: BallType::Fly,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: crate::model::Base::Home,
                    to: AdvanceTo::Base(crate::model::Base::Home),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        };
        assert_eq!(classify(&play), Classification::Deterministic);
    }

    /// BatterEvent::Other → OutOfFormat (FR-017).
    #[test]
    fn other_batter_event_is_out_of_format() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::Other,
                fielders: vec![],
                ball_type: BallType::None,
                advances: vec![],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        };
        assert!(matches!(classify(&play), Classification::OutOfFormat(_)));
    }

    /// EarnedVsUnearned: run scores in error inning (I3/FR-010a).
    #[test]
    fn earned_vs_unearned_in_error_inning() {
        reset_silent_resolution_counter();
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::SacFly,
                fielders: vec![Position(7)],
                ball_type: BallType::Fly,
                advances: vec![
                    Advance {
                        runner: RunnerId(1),
                        from: crate::model::Base::Home,
                        to: AdvanceTo::Out,
                        by_error: None,
                    },
                    // Runner on third scores.
                    Advance {
                        runner: RunnerId(2),
                        from: crate::model::Base::Third,
                        to: AdvanceTo::Base(crate::model::Base::Home),
                        by_error: None,
                    },
                ],
                touched_or_misplayed_by: vec![],
            },
            audit_label: Some("groundout".into()), // adversarial label
        };
        let ctx = ClassifyContext { inning_has_error_or_pb: true };
        let result = classify_with_context(&play, &ctx);
        assert_eq!(
            result,
            Classification::Judgment(JudgmentKind::EarnedVsUnearned),
            "Run scoring in error inning must be EarnedVsUnearned (I3/FR-010a)"
        );
    }

    /// Same run without error inning context → Deterministic.
    #[test]
    fn run_scores_no_error_inning_is_deterministic() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::SacFly,
                fielders: vec![Position(7)],
                ball_type: BallType::Fly,
                advances: vec![
                    Advance {
                        runner: RunnerId(1),
                        from: crate::model::Base::Home,
                        to: AdvanceTo::Out,
                        by_error: None,
                    },
                    Advance {
                        runner: RunnerId(2),
                        from: crate::model::Base::Third,
                        to: AdvanceTo::Base(crate::model::Base::Home),
                        by_error: None,
                    },
                ],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        };
        let ctx = ClassifyContext { inning_has_error_or_pb: false };
        assert_eq!(classify_with_context(&play, &ctx), Classification::Deterministic);
    }

    /// AmbiguousAdvance: baserunner advances 2+ non-scoring bases without attributed error.
    #[test]
    fn ambiguous_advance_flagged() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::Single,
                fielders: vec![Position(4), Position(6)],
                ball_type: BallType::Ground,
                advances: vec![
                    Advance {
                        runner: RunnerId(1),
                        from: crate::model::Base::Home,
                        to: AdvanceTo::Base(crate::model::Base::First),
                        by_error: None,
                    },
                    // Runner on first advances to third (2 non-scoring bases) without error.
                    // AmbiguousAdvance: scorer must determine if it's fielder indifference or hit.
                    Advance {
                        runner: RunnerId(2),
                        from: crate::model::Base::First,
                        to: AdvanceTo::Base(crate::model::Base::Third),
                        by_error: None,
                    },
                ],
                touched_or_misplayed_by: vec![],
            },
            audit_label: Some("single".into()),
        };
        // First→Third is 2 non-scoring bases, no error → AmbiguousAdvance.
        assert_eq!(
            classify(&play),
            Classification::Judgment(JudgmentKind::AmbiguousAdvance)
        );
    }

    // -----------------------------------------------------------------------
    // #127 — trigger-priority reconciliation (corpus-015 / 019 / 020).
    // All three still surface as JUDGMENTS (SC-003 holds); these lock in the
    // fact-justified KIND each play's facts demand.
    // -----------------------------------------------------------------------

    /// corpus-020: batter-runner advances 2+ bases with an error on the advance
    /// (the overthrow) → AmbiguousAdvance, NOT HitVsError.
    #[test]
    fn overthrow_extra_base_batter_advance_is_ambiguous_advance() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(5), Position(3)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(0),
                    from: crate::model::Base::Home,
                    to: AdvanceTo::Base(crate::model::Base::Third),
                    by_error: Some(Position(5)),
                }],
                touched_or_misplayed_by: vec![Position(5)],
            },
            audit_label: Some("single".into()),
        };
        assert_eq!(
            classify(&play),
            Classification::Judgment(JudgmentKind::AmbiguousAdvance),
            "Overthrow extra-base batter advance is AmbiguousAdvance (#127 / corpus-020)"
        );
    }

    /// corpus-004 guard: an error advancing a PRIOR runner while the batter cleanly
    /// reaches first stays HitVsError (the at-bat is the call), NOT AmbiguousAdvance.
    #[test]
    fn prior_runner_error_advance_stays_hit_vs_error() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(9)],
                ball_type: BallType::Fly,
                advances: vec![
                    Advance {
                        runner: RunnerId(0),
                        from: crate::model::Base::Home,
                        to: AdvanceTo::Base(crate::model::Base::First),
                        by_error: None,
                    },
                    Advance {
                        runner: RunnerId(1),
                        from: crate::model::Base::First,
                        to: AdvanceTo::Base(crate::model::Base::Third),
                        by_error: Some(Position(9)),
                    },
                ],
                touched_or_misplayed_by: vec![Position(9)],
            },
            audit_label: None,
        };
        assert_eq!(
            classify(&play),
            Classification::Judgment(JudgmentKind::HitVsError),
            "Prior-runner error advance keeps the at-bat HitVsError (#127 / corpus-004 guard)"
        );
    }

    /// corpus-019: a scoring advance where the ball was touched/misplayed by 2+
    /// fielders (a deflection) → AmbiguousAdvance, NOT a relay-RBI ContestedCredit.
    #[test]
    fn deflection_scoring_advance_is_ambiguous_advance() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::Single,
                fielders: vec![Position(8), Position(4)],
                ball_type: BallType::Ground,
                advances: vec![
                    Advance {
                        runner: RunnerId(0),
                        from: crate::model::Base::Home,
                        to: AdvanceTo::Base(crate::model::Base::First),
                        by_error: None,
                    },
                    Advance {
                        runner: RunnerId(2),
                        from: crate::model::Base::Second,
                        to: AdvanceTo::Base(crate::model::Base::Home),
                        by_error: None,
                    },
                ],
                touched_or_misplayed_by: vec![Position(8), Position(4)],
            },
            audit_label: Some("single".into()),
        };
        assert_eq!(
            classify(&play),
            Classification::Judgment(JudgmentKind::AmbiguousAdvance),
            "2-fielder deflection scoring advance is AmbiguousAdvance (#127 / corpus-019)"
        );
    }

    /// corpus-013 guard: a single-fielder-touch scoring advance with 2 fielders in the
    /// chain stays a relay-RBI ContestedCredit (only ONE fielder touched).
    #[test]
    fn single_touch_relay_rbi_stays_contested_credit() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::SacFly,
                fielders: vec![Position(9), Position(2)],
                ball_type: BallType::Fly,
                advances: vec![Advance {
                    runner: RunnerId(3),
                    from: crate::model::Base::Third,
                    to: AdvanceTo::Base(crate::model::Base::Home),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![Position(9)],
            },
            audit_label: None,
        };
        assert_eq!(
            classify(&play),
            Classification::Judgment(JudgmentKind::ContestedCredit),
            "Single-touch relay RBI stays ContestedCredit (#127 / corpus-013 guard)"
        );
    }

    /// corpus-015: a safe batter on a multi-fielder throw chain (a throw was made to
    /// retire the batter, who reached) → ContestedCredit, NOT HitVsError.
    #[test]
    fn safe_batter_throw_chain_is_contested_credit() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::Single,
                fielders: vec![Position(9), Position(3)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(0),
                    from: crate::model::Base::Home,
                    to: AdvanceTo::Base(crate::model::Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![Position(9)],
            },
            audit_label: Some("single".into()),
        };
        assert_eq!(
            classify(&play),
            Classification::Judgment(JudgmentKind::ContestedCredit),
            "Safe batter on a 2-fielder throw chain is ContestedCredit (#127 / corpus-015)"
        );
    }

    /// corpus-001 guard: a `FieldedOut` where the batter reached after a fielder touch
    /// stays HitVsError (the at-bat hit-vs-error), distinct from corpus-015's `Single`
    /// throw-chain ContestedCredit.
    #[test]
    fn fielded_out_batter_reached_stays_hit_vs_error() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(6), Position(3)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(0),
                    from: crate::model::Base::Home,
                    to: AdvanceTo::Base(crate::model::Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![Position(6)],
            },
            audit_label: None,
        };
        assert_eq!(
            classify(&play),
            Classification::Judgment(JudgmentKind::HitVsError),
            "FieldedOut + batter reached stays HitVsError (#127 / corpus-001 guard)"
        );
    }
}
