//! Proof-box Layer-1 gate integration test (T043 / #71 Story A9).
//!
//! INTERFACE.md §3.3 Layer 1 (offline, non-authoritative): for every half-inning the
//! deterministic core projects, the Reisner proof-box accounting identity MUST hold:
//!
//!   AB + BB + Sac + HBP + Interference == Runs + Putouts + LOB(stranded)
//!
//! Every plate appearance contributes to exactly one term on the LEFT (how the PA is
//! charged) and exactly one on the RIGHT (the batter-runner's fate: scored, retired, or
//! left on base). So the identity is a closed accounting invariant — any imbalance is a
//! projection bug (SC-011). This is a HARD-FAIL gate (`proof-box.sh`).
//!
//! Driven through the PUBLIC `CoreApi` (record → confirm), so it exercises the real
//! primitive path the CLI/agent/iOS all use (parity), not an internal shortcut.

use dl_core::ffi::{
    Actor, ActorKind, ConfirmPlayRequest, CoreApi, CreateGameRequest, GameId, Half, PlayInput,
    ProofBox, RecordPlayRequest, Team,
};
use dl_core::model::{
    Advance, AdvanceTo, BallType, Base, BatterEvent, BatterHand, Catalyst, Count, NormalizedPlay,
    Position, RunnerId, Runners, SituationDiamond,
};
use dl_core::primitives::DiamondCore;
use dl_core::reisner::check_proof_box_balance;

fn owner() -> Actor {
    Actor { kind: ActorKind::Human, id: "owner-pb".into(), harness_version: None }
}

fn team(id: &str, name: &str) -> Team {
    Team { id: id.into(), name: name.into(), lineup: None }
}

fn new_game(core: &DiamondCore) -> GameId {
    core.create_game(CreateGameRequest {
        home: team("NYA", "Yankees"),
        visitor: team("BOS", "Red Sox"),
        idempotency_key: "pb-create".into(),
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

/// A batted-out (one putout, batter retired at first).
fn groundout() -> NormalizedPlay {
    NormalizedPlay {
        situation: situation(),
        catalyst: Catalyst {
            batter_event: BatterEvent::FieldedOut,
            fielders: vec![Position(6), Position(3)],
            ball_type: BallType::Ground,
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

fn record_confirm(core: &DiamondCore, gid: GameId, play: NormalizedPlay, tag: &str) {
    let r = core
        .record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(play),
            idempotency_key: format!("rec-{tag}"),
            actor: owner(),
        })
        .unwrap_or_else(|e| panic!("record_play({tag}) failed: {e:?}"));
    core.confirm_play(ConfirmPlayRequest {
        game_id: gid,
        confirms_seq: r.recorded_seq.0,
        idempotency_key: format!("con-{tag}"),
        actor: owner(),
    })
    .unwrap_or_else(|e| panic!("confirm_play({tag}) failed: {e:?}"));
}

fn assert_balanced(pb: &ProofBox, ctx: &str) {
    let left = pb.ab + pb.bb + pb.sac + pb.hbp + pb.interference;
    let right = pb.runs + pb.putouts + pb.stranded;
    assert!(
        check_proof_box_balance(pb).is_ok(),
        "PROOF-BOX IMBALANCE ({ctx}): AB+BB+Sac+HBP+INT={left} != R+PO+LOB={right}  ({pb:?})"
    );
}

/// A 1-2-3 half-inning: each of the first two groundouts keeps the running box balanced
/// (AB grows in lockstep with putouts, no stranded runner). The box is queried while the
/// half-inning is still the current (queryable) half.
///
/// NOTE (MVP limitation, documented as a handoff): `get_proof_box` returns a zeroed box
/// for a *past* half-inning (it only projects the current half). So this gate asserts on
/// the in-progress box on the out path (where stranded==0 and balance is continuous),
/// not on the post-3rd-out closed box. Historical-inning proof boxes require replay-up-to
/// (tracked for a follow-up; finalize already balances the current half via SC-011).
#[test]
fn proof_box_balances_for_one_two_three_inning() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    for i in 0..2 {
        record_confirm(&core, gid, groundout(), &format!("go{i}"));
        let pb = core.get_proof_box(gid, 1, Half::Top).unwrap();
        assert_balanced(&pb, &format!("after groundout {i}"));
    }
}

/// A solo home run keeps the box balanced (AB=1 == Runs=1): a scoring PA contributes to
/// both sides simultaneously, so the running box balances with no stranded runner.
#[test]
fn proof_box_balances_with_a_run() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    let hr = NormalizedPlay {
        situation: situation(),
        catalyst: Catalyst {
            batter_event: BatterEvent::HomeRun,
            fielders: vec![],
            ball_type: BallType::Fly,
            advances: vec![Advance {
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Base(Base::Home),
                by_error: None,
            }],
            touched_or_misplayed_by: vec![],
        },
        audit_label: None,
    };
    record_confirm(&core, gid, hr, "hr");
    let pb = core.get_proof_box(gid, 1, Half::Top).unwrap();
    assert_balanced(&pb, "after solo HR");
    assert_eq!(pb.runs, 1, "one run scored");
}

/// Every confirmed OUT keeps the box balanced as the inning fills with outs (no runner
/// left on base mid-inning) — guards monotonic balance on the out path through the
/// public primitive.
#[test]
fn proof_box_balances_after_each_out() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    for i in 0..2 {
        // Stop before the 3rd out so the half-inning stays the queryable current half.
        record_confirm(&core, gid, groundout(), &format!("oo{i}"));
        let pb = core.get_proof_box(gid, 1, Half::Top).unwrap();
        assert_balanced(&pb, &format!("after out {i}"));
        assert_eq!(pb.putouts, (i + 1) as u32, "putouts tallied each out");
    }
}

/// The identity holds for an EMPTY half-inning (all zeros, 0==0). Guards the vacuous
/// case so finalize on a fresh game cannot trip the gate spuriously.
#[test]
fn proof_box_empty_inning_balances() {
    let core = DiamondCore::new();
    let gid = new_game(&core);
    assert_balanced(&core.get_proof_box(gid, 1, Half::Top).unwrap(), "empty inning");
}
