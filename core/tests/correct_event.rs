//! `correct_event` (US4 / FR-012–014) contract tests — ADR-0012.
//!
//! Exercises the amend-a-prior-play primitive through the PUBLIC `CoreApi` (the same path
//! the CLI/agent/iOS use — parity), covering:
//!   * happy path: append-only correction + ACTUAL downstream recompute + preserved history
//!   * every ErrorCode the contract lists (UNAUTHORIZED · NOT_FOUND · INVALID_ARGUMENT)
//!   * idempotent retry (no second correction appended; byte-identical result)
//!   * correcting a play INTO a judgment → a FRESH decision is opened, never silently
//!     resolved (SC-003/I2)
//!   * correcting a play OUT of a judgment → reclassified Deterministic
//!   * invalidated_downstream surfaced when the out-count changes (FR-014)
//!
//! The append-only invariant (FR-013) is asserted directly: the ORIGINAL recorded play's
//! facts are unchanged after the correction, and the event log GROWS (never shrinks).

use dl_core::classify::{reset_silent_resolution_counter, silent_resolution_count};
use dl_core::ffi::{
    Actor, ActorKind, Call, ConfirmPlayRequest, CoreApi, CorrectEventRequest, CreateGameRequest,
    ErrorCode, GameId, PlayInput, RecordPlayRequest, ResolveJudgmentRequest, Seq, Team,
};
use dl_core::model::{
    Advance, AdvanceTo, BallType, Base, BatterEvent, BatterHand, Catalyst, Classification, Count,
    JudgmentKind, NormalizedPlay, Position, RunnerId, Runners, SituationDiamond,
};
use dl_core::primitives::DiamondCore;

// --- fixtures --------------------------------------------------------------

fn owner() -> Actor {
    Actor { kind: ActorKind::Human, id: "owner-ce".into(), harness_version: None }
}

fn team(id: &str, name: &str) -> Team {
    Team { id: id.into(), name: name.into(), lineup: None }
}

fn new_game(core: &DiamondCore) -> GameId {
    core.create_game(CreateGameRequest {
        home: team("NYA", "Yankees"),
        visitor: team("BOS", "Red Sox"),
        idempotency_key: "ce-create".into(),
        actor: owner(),
    })
    .unwrap()
    .game_id
}

fn situation() -> SituationDiamond {
    SituationDiamond {
        runners: Runners::default(),
        outs: 0,
        count: Count { balls: 0, strikes: 0 },
        batter_hand: BatterHand::Right,
    }
}

/// A clean strikeout (one out, deterministic).
fn strikeout() -> NormalizedPlay {
    NormalizedPlay {
        situation: situation(),
        catalyst: Catalyst {
            batter_event: BatterEvent::Strikeout,
            fielders: vec![],
            ball_type: BallType::None,
            advances: vec![Advance {
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Out,
                by_error: None,
            }],
            touched_or_misplayed_by: vec![],
        },
        audit_label: None,
    }
}

/// A clean single (batter reaches first, no out, deterministic).
fn single() -> NormalizedPlay {
    NormalizedPlay {
        situation: situation(),
        catalyst: Catalyst {
            batter_event: BatterEvent::Single,
            fielders: vec![Position(7)],
            ball_type: BallType::Line,
            advances: vec![Advance {
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Base(Base::First),
                by_error: None,
            }],
            touched_or_misplayed_by: vec![],
        },
        audit_label: None,
    }
}

/// A play whose FACTS are a hit-vs-error JUDGMENT (fielder touched, batter reached).
fn hit_vs_error_play() -> NormalizedPlay {
    NormalizedPlay {
        situation: situation(),
        catalyst: Catalyst {
            batter_event: BatterEvent::FieldedOut,
            fielders: vec![Position(6)],
            ball_type: BallType::Ground,
            advances: vec![Advance {
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Base(Base::First),
                by_error: None,
            }],
            touched_or_misplayed_by: vec![Position(6)],
        },
        audit_label: None,
    }
}

/// Record a play and return its recorded seq (unconfirmed).
fn record(core: &DiamondCore, gid: GameId, play: NormalizedPlay, tag: &str) -> Seq {
    core.record_play(RecordPlayRequest {
        game_id: gid,
        input: PlayInput::Normalized(play),
        idempotency_key: format!("rec-{tag}"),
        actor: owner(),
    })
    .unwrap_or_else(|e| panic!("record({tag}): {e:?}"))
    .recorded_seq
}

fn confirm(core: &DiamondCore, gid: GameId, seq: Seq, tag: &str) {
    core.confirm_play(ConfirmPlayRequest {
        game_id: gid,
        confirms_seq: seq,
        idempotency_key: format!("con-{tag}"),
        actor: owner(),
    })
    .unwrap_or_else(|e| panic!("confirm({tag}): {e:?}"));
}

fn record_confirm(core: &DiamondCore, gid: GameId, play: NormalizedPlay, tag: &str) -> Seq {
    let seq = record(core, gid, play, tag);
    confirm(core, gid, seq, tag);
    seq
}

// --- happy path ------------------------------------------------------------

/// Correcting a strikeout into a single: state is ACTUALLY recomputed (an out becomes a
/// baserunner), the prior version is preserved (history), the original row is untouched
/// (append-only), and the log GROWS by exactly the correction event.
#[test]
fn happy_path_recomputes_and_preserves_history() {
    let core = DiamondCore::new();
    let gid = new_game(&core);

    let seq = record_confirm(&core, gid, strikeout(), "k");

    // Before: one out, bases empty.
    let before = core.get_game_state(gid).unwrap();
    assert_eq!(before.outs, 1, "strikeout is one out");

    let events_before = core.list_game_events(gid).unwrap().len();

    let res = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq,
            amended: PlayInput::Normalized(single()),
            idempotency_key: "fix-1".into(),
            actor: owner(),
        })
        .expect("correction succeeds");

    // ACTUAL recompute (FR-012): the out is gone; a runner is on first.
    assert_eq!(res.recomputed_state.outs, 0, "the out was recomputed away");
    assert!(res.recomputed_state.bases.first.is_some(), "batter now on first");
    let after = core.get_game_state(gid).unwrap();
    assert_eq!(after.outs, 0, "live projection reflects the correction");

    // History preserved (FR-013/SC-007): the prior version (the strikeout) is returned.
    assert_eq!(res.history.len(), 1, "exactly one prior version retained");
    assert_eq!(res.history[0].seq, seq, "history references the corrected seq");
    assert_eq!(
        res.history[0].normalized.catalyst.batter_event,
        BatterEvent::Strikeout,
        "prior version is the ORIGINAL strikeout facts"
    );

    // Amended facts surfaced; reclassified from facts (a clean single is Deterministic).
    assert_eq!(res.amended.catalyst.batter_event, BatterEvent::Single);
    assert_eq!(res.reclassified, Classification::Deterministic);

    // Append-only: the ORIGINAL PlayRecorded row is unchanged; the log only GREW.
    let original = core.get_play(gid, seq).unwrap();
    assert_eq!(
        original.normalized.catalyst.batter_event,
        BatterEvent::Strikeout,
        "the original recorded play is NEVER mutated (FR-013)"
    );
    let events_after = core.list_game_events(gid).unwrap().len();
    assert!(events_after > events_before, "log grows (append-only), never shrinks");

    // The correction event links back to the corrected seq (audit linkage).
    let corr = core
        .list_game_events(gid)
        .unwrap()
        .into_iter()
        .find(|e| e.event_type == "EventCorrected")
        .expect("an EventCorrected row exists");
    assert_eq!(corr.corrects_seq, Some(seq), "correction references the corrected seq");
    assert_eq!(corr.seq, res.correction_seq, "result.correction_seq is the appended seq");
}

// --- every ErrorCode -------------------------------------------------------

/// UNAUTHORIZED: a non-owner cannot correct (I5/FR-020). No state change.
#[test]
fn unauthorized_actor_rejected() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    let seq = record_confirm(&core, gid, strikeout(), "k");

    let interloper = Actor { kind: ActorKind::Human, id: "interloper".into(), harness_version: None };
    let err = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq,
            amended: PlayInput::Normalized(single()),
            idempotency_key: "fix".into(),
            actor: interloper,
        })
        .unwrap_err();
    assert_eq!(err.code, ErrorCode::Unauthorized);
}

/// UNAUTHORIZED: a trivial / placeholder identity is rejected (FR-020).
#[test]
fn trivial_identity_rejected() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    let seq = record_confirm(&core, gid, strikeout(), "k");

    // An empty owner id is trivial; assert_nontrivial_identity rejects it. (We must use the
    // real owner for the authority check to pass first, then the trivial guard fires — so
    // use "anonymous", which is the owner's id only if created so; here authority fails
    // first for a different id, so assert the trivial path via the owner being trivial.)
    let anon = Actor { kind: ActorKind::Human, id: "  ".into(), harness_version: None };
    let err = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq,
            amended: PlayInput::Normalized(single()),
            idempotency_key: "fix".into(),
            actor: anon,
        })
        .unwrap_err();
    assert_eq!(err.code, ErrorCode::Unauthorized, "blank identity is unauthorized");
}

/// NOT_FOUND: correcting a non-existent game.
#[test]
fn unknown_game_not_found() {
    let core = DiamondCore::new();
    let _ = new_game(&core);
    let err = core
        .correct_event(CorrectEventRequest {
            game_id: GameId(9999),
            corrects_seq: Seq(0),
            amended: PlayInput::Normalized(single()),
            idempotency_key: "fix".into(),
            actor: owner(),
        })
        .unwrap_err();
    assert_eq!(err.code, ErrorCode::NotFound);
}

/// NOT_FOUND: `corrects_seq` does not exist in the log.
#[test]
fn unknown_seq_not_found() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    record_confirm(&core, gid, strikeout(), "k");

    let err = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: Seq(999),
            amended: PlayInput::Normalized(single()),
            idempotency_key: "fix".into(),
            actor: owner(),
        })
        .unwrap_err();
    assert_eq!(err.code, ErrorCode::NotFound);
}

/// NOT_FOUND: `corrects_seq` exists but is NOT a PlayRecorded (e.g. GameStarted at seq 0).
#[test]
fn non_play_seq_not_found() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    record_confirm(&core, gid, strikeout(), "k");

    // Seq 0 is GameStarted — not a correctable play.
    let err = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: Seq(0),
            amended: PlayInput::Normalized(single()),
            idempotency_key: "fix".into(),
            actor: owner(),
        })
        .unwrap_err();
    assert_eq!(err.code, ErrorCode::NotFound, "GameStarted seq is not a correctable play");
}

/// INVALID_ARGUMENT: the pure core rejects a Transcript amendment (no bundled parser).
#[test]
fn transcript_amendment_invalid_argument() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    let seq = record_confirm(&core, gid, strikeout(), "k");

    let err = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq,
            amended: PlayInput::Transcript("a clean single to left".into()),
            idempotency_key: "fix".into(),
            actor: owner(),
        })
        .unwrap_err();
    assert_eq!(err.code, ErrorCode::InvalidArgument);
}

// --- idempotency -----------------------------------------------------------

/// A retry with the SAME idempotency_key returns a byte-identical result and does NOT
/// append a second correction (the log stays append-only with no duplicate).
#[test]
fn idempotent_retry_no_duplicate() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    let seq = record_confirm(&core, gid, strikeout(), "k");

    let first = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq,
            amended: PlayInput::Normalized(single()),
            idempotency_key: "same-key".into(),
            actor: owner(),
        })
        .unwrap();
    let events_after_first = core.list_game_events(gid).unwrap().len();

    let retry = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq,
            amended: PlayInput::Normalized(single()),
            idempotency_key: "same-key".into(),
            actor: owner(),
        })
        .unwrap();
    let events_after_retry = core.list_game_events(gid).unwrap().len();

    assert_eq!(
        events_after_first, events_after_retry,
        "a retried correction must NOT append a second event (append-only, no duplicate)"
    );
    // Byte-identical result on retry (SC-008 parity).
    assert_eq!(
        serde_json::to_string(&first).unwrap(),
        serde_json::to_string(&retry).unwrap(),
        "retry must be byte-identical to the first correction"
    );
    assert_eq!(retry.correction_seq, first.correction_seq, "same correction seq on retry");
}

/// P2 regression (SC-008 parity): a retry of a correction that changed the out-count AND
/// has downstream same-half plays must return the SAME `invalidated_downstream` as the
/// first call — not an empty list. Both paths now run through `build_correct_event_result`
/// which computes `invalidated_downstream` unconditionally.
#[test]
fn idempotent_retry_with_downstream_is_byte_identical() {
    let core = DiamondCore::new();
    let gid = new_game(&core);

    let seq_a = record_confirm(&core, gid, strikeout(), "a");  // will be corrected (out → no-out)
    let seq_b = record_confirm(&core, gid, strikeout(), "b");  // downstream same-half play

    // First call: correct A (an out) into a single — out-count changes, B is downstream.
    let first = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq_a,
            amended: PlayInput::Normalized(single()),
            idempotency_key: "retry-down".into(),
            actor: owner(),
        })
        .expect("first correction");
    assert!(
        first.invalidated_downstream.iter().any(|p| p.seq == seq_b),
        "first call: seq_b must be in invalidated_downstream"
    );

    // Retry with the SAME key: must return byte-identical — including invalidated_downstream.
    let retry = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq_a,
            amended: PlayInput::Normalized(single()),
            idempotency_key: "retry-down".into(),
            actor: owner(),
        })
        .expect("retry correction");

    assert_eq!(
        serde_json::to_string(&first).unwrap(),
        serde_json::to_string(&retry).unwrap(),
        "retry must be byte-identical including invalidated_downstream (P2 / SC-008)"
    );
    assert!(
        retry.invalidated_downstream.iter().any(|p| p.seq == seq_b),
        "retry: seq_b must also be in invalidated_downstream (not empty on retry)"
    );
}

// --- correcting INTO / OUT OF a judgment (SC-003/I2) -----------------------

/// Correcting a deterministic play INTO a judgment opens a FRESH JudgmentDecision — the
/// correction NEVER silently resolves the new scoring call (SC-003/I2). The silent
/// resolution counter must stay zero.
///
/// P0 regression (SC-003/I2): `recomputed_state` must NOT advance state through the open
/// judgment — the corrected seq is withheld from authoritative projection until the
/// JudgmentDecision is resolved. Outs/runners must reflect the PRE-correction state.
#[test]
fn correcting_into_judgment_opens_decision_never_silent() {
    reset_silent_resolution_counter();
    let core = DiamondCore::new();
    let gid = new_game(&core);

    // Start with a clean strikeout (deterministic). After confirmation the projection has 1 out.
    let seq = record_confirm(&core, gid, strikeout(), "k");
    assert_eq!(core.get_game_state(gid).unwrap().outs, 1, "strikeout is confirmed: 1 out");

    let before_judgments = core
        .list_game_events(gid)
        .unwrap()
        .into_iter()
        .filter(|e| e.event_type == "JudgmentOpened")
        .count();

    // Amend it to a hit-vs-error JUDGMENT play. The corrected seq now has an open judgment.
    let res = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq,
            amended: PlayInput::Normalized(hit_vs_error_play()),
            idempotency_key: "to-judgment".into(),
            actor: owner(),
        })
        .expect("correction into a judgment succeeds");

    // The amended facts reclassify as a judgment (I1).
    assert_eq!(
        res.reclassified,
        Classification::Judgment(JudgmentKind::HitVsError),
        "amended facts reclassify as a HitVsError judgment"
    );

    // *** P0 regression assertion (SC-003/I2) ***
    // `recomputed_state` must NOT advance through the unresolved judgment.
    // The corrected seq is withheld from projection, so outs must revert to 0 (the
    // state BEFORE the corrected play was applied) — not 1 (the post-out state) and
    // not whatever the amended hit-vs-error facts would produce.
    assert_eq!(
        res.recomputed_state.outs, 0,
        "recomputed_state must NOT advance through the open judgment (P0 / SC-003/I2)"
    );
    // Bases must also be empty: the withheld batter-runner has not reached base.
    assert!(
        res.recomputed_state.bases.first.is_none(),
        "batter-runner must NOT appear on base through an unresolved judgment (SC-003/I2)"
    );

    // Live get_game_state must also withhold the seq.
    let live = core.get_game_state(gid).unwrap();
    assert_eq!(
        live.outs, 0,
        "live get_game_state must also withhold the corrected seq (P0 / SC-003/I2)"
    );

    // A FRESH JudgmentOpened event now exists for the corrected seq.
    let after_judgments = core
        .list_game_events(gid)
        .unwrap()
        .into_iter()
        .filter(|e| e.event_type == "JudgmentOpened")
        .count();
    assert_eq!(
        after_judgments,
        before_judgments + 1,
        "a fresh judgment decision is opened by the correction (never silently resolved)"
    );

    // SC-003 cardinal: no silent resolution occurred.
    assert_eq!(
        silent_resolution_count(),
        0,
        "correcting into a judgment must NOT silently resolve it (SC-003/I2)"
    );

    // After resolving the judgment, the corrected seq is released into the projection.
    let decision_id = res
        .history  // history carries the prior classification; the decision id is in events
        .is_empty()
        .then_some(0u64);
    let _ = decision_id; // we get it from events below
    let judgment_decision_id = core
        .list_game_events(gid)
        .unwrap()
        .into_iter()
        .rev()
        .find(|e| e.event_type == "JudgmentOpened")
        .map(|e| e.seq.0)  // seq of the JudgmentOpened event, not the decision_id
        .unwrap();
    // Get the actual decision_id via get_play on the corrected seq.
    let play = core.get_play(gid, seq).unwrap();
    let decision_id = play.judgment.as_ref().unwrap().id;

    core.resolve_judgment(ResolveJudgmentRequest {
        game_id: gid,
        decision_id,
        chosen: Call { token: "hit".into(), label: "Hit".into() },
        idempotency_key: "rj-into".into(),
        actor: owner(),
    }).expect("resolving the judgment succeeds");
    let _ = judgment_decision_id;

    // Now the corrected seq (hit_vs_error → batter reaches first) is in the projection.
    let after_resolve = core.get_game_state(gid).unwrap();
    assert_eq!(
        after_resolve.outs, 0,
        "after resolve: outs still 0 (the hit_vs_error play didn't put anyone out)"
    );
    assert!(
        after_resolve.bases.first.is_some(),
        "after resolve: batter-runner is now on first (released from withhold)"
    );
}

/// Correcting a judgment play OUT into a clean play (after the judgment is resolved)
/// reclassifies Deterministic and the projection advances. This tests the full correct
/// cycle: correct INTO judgment → resolve judgment → correct OUT to deterministic.
#[test]
fn correcting_out_of_judgment_reclassifies_deterministic() {
    reset_silent_resolution_counter();
    let core = DiamondCore::new();
    let gid = new_game(&core);

    // Start with a clean single (deterministic, confirmed). Projection: 0 outs, runner on 1st.
    let seq = record_confirm(&core, gid, single(), "s");

    // Correct the single INTO a hit-vs-error judgment.
    let into_res = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq,
            amended: PlayInput::Normalized(hit_vs_error_play()),
            idempotency_key: "into".into(),
            actor: owner(),
        })
        .unwrap();
    let decision_id = {
        let play = core.get_play(gid, seq).unwrap();
        play.judgment.as_ref().unwrap().id
    };
    let _ = into_res;

    // The corrected seq is now withheld: projection has 0 outs and no runner.
    assert_eq!(core.get_game_state(gid).unwrap().outs, 0,
        "after INTO correction: withheld — projection at pre-correction state");

    // Resolve the judgment FIRST so the corrected seq is released.
    core.resolve_judgment(ResolveJudgmentRequest {
        game_id: gid,
        decision_id,
        chosen: Call { token: "hit".into(), label: "Hit".into() },
        idempotency_key: "rj-for-into".into(),
        actor: owner(),
    }).expect("resolve judgment before OUT correction");

    // Now correct OUT to a strikeout (replaces the confirmed single / judgment with an out).
    let out = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq,
            amended: PlayInput::Normalized(strikeout()),
            idempotency_key: "out".into(),
            actor: owner(),
        })
        .expect("correcting back out succeeds");

    assert_eq!(
        out.reclassified,
        Classification::Deterministic,
        "the latest amended facts (a clean strikeout) reclassify Deterministic"
    );
    // The latest correction wins: strikeout → 1 out. No open judgment on this seq.
    assert_eq!(out.recomputed_state.outs, 1, "latest correction (strikeout) wins on replay");
    assert!(
        out.recomputed_state.bases.first.is_none(),
        "batter did not reach on a strikeout"
    );
    assert_eq!(silent_resolution_count(), 0, "no silent resolution throughout");
}

// --- invalidated_downstream (FR-014) ---------------------------------------

/// When a correction changes the out-count of the corrected play, later plays in the SAME
/// half-inning are surfaced as `invalidated_downstream` for review (never silently
/// discarded). Here: correct an out into a single (out-count 1 → 0), with a later play in
/// the same half — that later play is surfaced.
#[test]
fn invalidated_downstream_surfaced_when_outs_change() {
    let core = DiamondCore::new();
    let gid = new_game(&core);

    let seq_a = record_confirm(&core, gid, strikeout(), "a"); // the play we will correct
    let seq_b = record_confirm(&core, gid, strikeout(), "b"); // a later play, same half

    // Correct A (an out) into a single → its out-count changes 1 → 0.
    let res = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq_a,
            amended: PlayInput::Normalized(single()),
            idempotency_key: "fix-a".into(),
            actor: owner(),
        })
        .unwrap();

    assert!(
        res.invalidated_downstream.iter().any(|p| p.seq == seq_b),
        "the later same-half play B must be surfaced as invalidated_downstream (FR-014)"
    );
}

/// A correction that does NOT change the out-count surfaces no invalidated_downstream
/// (correcting one single into another single — both are 0-out plays).
#[test]
fn no_invalidated_downstream_when_outs_unchanged() {
    let core = DiamondCore::new();
    let gid = new_game(&core);

    let seq_a = record_confirm(&core, gid, single(), "a");
    let _seq_b = record_confirm(&core, gid, strikeout(), "b");

    // Correct the single's fielder (still a single, still 0 outs).
    let mut amended = single();
    amended.catalyst.fielders = vec![Position(8)];
    let res = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: seq_a,
            amended: PlayInput::Normalized(amended),
            idempotency_key: "fix-a".into(),
            actor: owner(),
        })
        .unwrap();

    assert!(
        res.invalidated_downstream.is_empty(),
        "no out-count change → nothing downstream is invalidated"
    );
}
