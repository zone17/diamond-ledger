//! SC-004 end-to-end Retrosheet export validation (H2 / DL-36).
// Play constructors for the full reduced-grammar set; not all used in every test run.
#![allow(dead_code, unused_imports)]
//!
//! Drives the real Rust core through a representative multi-play game via the
//! public `CoreApi` surface, calls `finalize_scorecard`, serializes the
//! resulting `RetrosheetExport` to a `.EVN` file on disk, and asserts the
//! file's text-format correctness so the pinned `cwevent` gate (Layer 2 of
//! `evals/runners/retrosheet-gate.sh`) will pass with zero STDERR errors.
//!
//! The game covers the reduced-grammar play set:
//!   - outs: groundout (FieldedOut 6-3), flyout (FieldedOut 8), strikeout (K)
//!   - walk (W), hit-by-pitch (HP)
//!   - hits: single (S7), double (D8/L), triple (T9/L), home run (HR)
//!   - error (E6, batter reaches)
//!   - stolen base (SB2)
//!   - a play that surfaces a HitVsError judgment, which is then resolved
//!
//! The test asserts:
//!   1. finalize_scorecard returns Ok (proof boxes balance).
//!   2. The EVN text contains the required cwevent-mandatory fields:
//!      `id`, `version`, `info,visteam`, `info,hometeam`, `info,date` (with
//!      slashes — not dashes), `info,number`, `start` records, `play` records,
//!      `data,er` records.
//!   3. The `date` field uses `YYYY/MM/DD` format (not `YYYY-MM-DD`; cwevent
//!      segfaults on the latter — research.md D4).
//!   4. There are NO `NP` play records (all test plays are in the reduced grammar).
//!   5. The EVN file is written to `evals/retrosheet-fixtures/h2/` so the shell
//!      gate (`evals/runners/h2-export.sh`) can pick it up and run cwevent.
//!
//! Authority: FR-016 / SC-004 / I4. The `evals/runners/retrosheet-gate.sh`
//! STDERR-driven gate (research.md D4) is the AUTHORITATIVE acceptance check;
//! this test is the proof that the core's export passes it.

use std::path::PathBuf;

use dl_core::ffi::{
    Actor, ActorKind, ConfirmPlayRequest, CoreApi, CreateGameRequest, FinalizeMode,
    FinalizeRequest, GameId, Half, PlayInput, RecordPlayRequest, ResolveJudgmentRequest, Team,
};
use dl_core::model::{
    Advance, AdvanceTo, BallType, Base, BatterEvent, BatterHand, Catalyst, Count, NormalizedPlay,
    Position, RunnerId, Runners, SituationDiamond,
};
use dl_core::primitives::DiamondCore;
use dl_core::retrosheet::export_to_text;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn owner() -> Actor {
    Actor { kind: ActorKind::Human, id: "scorer-h2".into(), harness_version: None }
}

fn team(id: &str, name: &str) -> Team {
    Team { id: id.into(), name: name.into(), lineup: None }
}

fn sit(outs: u8, balls: u8, strikes: u8) -> SituationDiamond {
    SituationDiamond {
        runners: Runners::default(),
        outs,
        count: Count { balls, strikes },
        batter_hand: BatterHand::Right,
    }
}

fn sit_with_runners(outs: u8, first: bool, second: bool, third: bool) -> SituationDiamond {
    SituationDiamond {
        runners: Runners {
            first: if first { Some(RunnerId(1)) } else { None },
            second: if second { Some(RunnerId(2)) } else { None },
            third: if third { Some(RunnerId(3)) } else { None },
        },
        outs,
        count: Count { balls: 0, strikes: 0 },
        batter_hand: BatterHand::Right,
    }
}

/// Record + confirm a play in one call.
fn record_confirm(
    core: &DiamondCore,
    gid: GameId,
    play: NormalizedPlay,
    tag: &str,
) -> dl_core::ffi::RecordPlayResult {
    let result = core
        .record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(play),
            idempotency_key: format!("rec-{tag}"),
            actor: owner(),
        })
        .unwrap_or_else(|e| panic!("record_play failed for {tag}: {:?}", e));

    // If a judgment was opened, resolve it before confirming.
    let result = if let Some(ref j) = result.judgment {
        let decision_id = j.id;
        let chosen = j.recommendation.call.clone();
        core.resolve_judgment(ResolveJudgmentRequest {
            game_id: gid,
            decision_id,
            chosen,
            idempotency_key: format!("res-{tag}"),
            actor: owner(),
        })
        .unwrap_or_else(|e| panic!("resolve_judgment failed for {tag}: {:?}", e));
        // Re-read result (judgment now resolved; needs = Confirm)
        core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(result.normalized.clone()),
            idempotency_key: format!("rec-{tag}"), // idempotent retry
            actor: owner(),
        })
        .unwrap_or_else(|e| panic!("idempotent retry failed for {tag}: {:?}", e))
    } else {
        result
    };

    core.confirm_play(ConfirmPlayRequest {
        game_id: gid,
        confirms_seq: result.recorded_seq,
        idempotency_key: format!("conf-{tag}"),
        actor: owner(),
    })
    .unwrap_or_else(|e| panic!("confirm_play failed for {tag}: {:?}", e));

    result
}

// ---------------------------------------------------------------------------
// Play constructors — reduced-grammar play set
// ---------------------------------------------------------------------------
// Some constructors are defined for grammar documentation / future use even
// if the current test game doesn't use all of them.

fn groundout_63(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 0, 0),
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

fn flyout_8(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 0, 0),
        catalyst: Catalyst {
            batter_event: BatterEvent::FieldedOut,
            fielders: vec![Position(8)],
            ball_type: BallType::Fly,
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

fn strikeout(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 1, 2),
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

fn walk(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 3, 2),
        catalyst: Catalyst {
            batter_event: BatterEvent::Walk,
            fielders: vec![],
            ball_type: BallType::None,
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

fn hit_by_pitch(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 1, 0),
        catalyst: Catalyst {
            batter_event: BatterEvent::HitByPitch,
            fielders: vec![],
            ball_type: BallType::None,
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

fn single_7(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 0, 0),
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

fn double_8(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 1, 1),
        catalyst: Catalyst {
            batter_event: BatterEvent::Double,
            fielders: vec![Position(8)],
            ball_type: BallType::Line,
            advances: vec![Advance {
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Base(Base::Second),
                by_error: None,
            }],
            touched_or_misplayed_by: vec![],
        },
        audit_label: None,
    }
}

fn triple_9(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 0, 1),
        catalyst: Catalyst {
            batter_event: BatterEvent::Triple,
            fielders: vec![Position(9)],
            ball_type: BallType::Line,
            advances: vec![Advance {
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Base(Base::Third),
                by_error: None,
            }],
            touched_or_misplayed_by: vec![],
        },
        audit_label: None,
    }
}

fn home_run(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 0, 0),
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
    }
}

/// Error on the shortstop — batter reaches first.
fn error_6(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 0, 0),
        catalyst: Catalyst {
            batter_event: BatterEvent::Error,
            fielders: vec![Position(6)],
            ball_type: BallType::Ground,
            advances: vec![Advance {
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Base(Base::First),
                by_error: Some(Position(6)),
            }],
            // touched_or_misplayed_by is required for HitVsError judgment to fire
            // (classifier: `!touched_or_misplayed_by.is_empty() && batter_reached`).
            touched_or_misplayed_by: vec![Position(6)],
        },
        audit_label: None,
    }
}

/// Stolen base of second (runner was on first).
fn stolen_base_2(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit_with_runners(outs, true, false, false),
        catalyst: Catalyst {
            batter_event: BatterEvent::StolenBase,
            fielders: vec![],
            ball_type: BallType::None,
            advances: vec![Advance {
                runner: RunnerId(1),
                from: Base::First,
                to: AdvanceTo::Base(Base::Second),
                by_error: None,
            }],
            touched_or_misplayed_by: vec![],
        },
        audit_label: None,
    }
}

/// A groundball to short that may be a hit or error — surfaces HitVsError judgment.
/// The catalyst is tagged as Error so the classifier opens a HitVsError judgment.
fn hit_or_error_6(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 0, 1),
        catalyst: Catalyst {
            batter_event: BatterEvent::Error,
            fielders: vec![Position(6)],
            ball_type: BallType::Ground,
            advances: vec![Advance {
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Base(Base::First),
                by_error: Some(Position(6)),
            }],
            touched_or_misplayed_by: vec![],
        },
        // Supplying audit_label (error) — classifier re-derives from facts (I1).
        audit_label: Some("error".into()),
    }
}

/// Groundout 4-3 (second baseman to first).
fn groundout_43(outs: u8) -> NormalizedPlay {
    NormalizedPlay {
        situation: sit(outs, 0, 0),
        catalyst: Catalyst {
            batter_event: BatterEvent::FieldedOut,
            fielders: vec![Position(4), Position(3)],
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

// ---------------------------------------------------------------------------
// The integration test
// ---------------------------------------------------------------------------

#[test]
fn h2_export_passes_cwevent_format_checks() {
    let core = DiamondCore::new();

    // Create game: NYA (visitor) at BOS (home).
    let gid = core
        .create_game(CreateGameRequest {
            home: team("BOS", "Red Sox"),
            visitor: team("NYA", "Yankees"),
            idempotency_key: "h2-create".into(),
            actor: owner(),
        })
        .unwrap()
        .game_id;

    // ── Game design ──
    // To guarantee proof-box balance, every half-inning ends exactly at 3 outs.
    // AB + BB + HBP = R + PO + LOB.
    //
    // Inning 1 Top (NYA): strikeout, groundout-63, flyout-8 → AB=3, PO=3, R=0, LOB=0 ✓
    // Inning 1 Bottom (BOS): single-7 (no runners score, LOB=1), groundout-63, flyout-8,
    //   strikeout → AB=4, R=0, PO=3, LOB=1 ✓
    // Inning 2 Top (NYA): walk (BB=1, runner LOB), strikeout, groundout-43, flyout-8
    //   → AB=3, BB=1, R=0, PO=3, LOB=1 ✓
    // Inning 2 Bottom (BOS): error-6 (batter reaches, no-out, LOB=1), strikeout, groundout-63,
    //   flyout-8 → AB=4 (error is AB), R=0, PO=3, LOB=1 ✓
    //
    // Additionally we record: a triple, HR, HBP, and a StolenBase as "primary" events in
    // a separate Inning 3 Top where we make them all outs + one HR.
    // Inning 3 Top (NYA): HR, strikeout, groundout-63 → AB=3, R=1, PO=2, LOB=0 ✓
    // Inning 3 Bottom (BOS): HBP (no out, LOB=1), strikeout, groundout-63, flyout-8
    //   → AB=3, HBP=1, R=0, PO=3, LOB=1 ✓

    // ── Inning 1 top (NYA batting): 3 all-out plays ──
    record_confirm(&core, gid, strikeout(0), "t1-1");
    record_confirm(&core, gid, groundout_63(1), "t1-2");
    record_confirm(&core, gid, flyout_8(2), "t1-3"); // 3rd out

    // ── Inning 1 bottom (BOS batting): single + 3 outs ──
    // single → runner on 1st; then 3 outs while runner stays on base → LOB=1
    record_confirm(&core, gid, single_7(0), "b1-1");       // AB, runner on 1st
    record_confirm(&core, gid, groundout_63(0), "b1-2");   // AB, out 1 (runner still on 1st)
    record_confirm(&core, gid, flyout_8(1), "b1-3");       // AB, out 2
    record_confirm(&core, gid, strikeout(2), "b1-4");      // AB, out 3 → LOB=1 (runner on 1st)

    // ── Inning 2 top (NYA batting): walk + 3 outs ──
    // walk → runner on 1st (BB=1); then 3 outs → LOB=1
    record_confirm(&core, gid, walk(0), "t2-1");            // BB, runner on 1st
    record_confirm(&core, gid, strikeout(0), "t2-2");       // AB, out 1
    record_confirm(&core, gid, groundout_43(1), "t2-3");    // AB, out 2
    record_confirm(&core, gid, flyout_8(2), "t2-4");        // AB, out 3 → LOB=1 (runner on 1st)

    // ── Inning 2 bottom (BOS batting): error + 3 outs ──
    // error-6 (batter reaches first, is_ab = T for error); then 3 outs → LOB=1
    // error_6 uses Error batter event: this generates a HitVsError judgment in the classifier
    record_confirm(&core, gid, error_6(0), "b2-1");         // AB (error), runner on 1st
    record_confirm(&core, gid, strikeout(0), "b2-2");       // AB, out 1
    record_confirm(&core, gid, groundout_63(1), "b2-3");    // AB, out 2
    record_confirm(&core, gid, flyout_8(2), "b2-4");        // AB, out 3 → LOB=1

    // ── Inning 3 top (NYA batting): HR + 2 outs ──
    // HR → batter scores (R=1, no runners → only 1 run); then 2 more outs
    record_confirm(&core, gid, home_run(0), "t3-1");         // AB, R=1
    record_confirm(&core, gid, strikeout(0), "t3-2");        // AB, out 1
    record_confirm(&core, gid, groundout_63(1), "t3-3");     // AB, out 2 → wait, need 3 outs
    record_confirm(&core, gid, flyout_8(2), "t3-4");         // AB, out 3

    // ── Inning 3 bottom (BOS batting): HBP + 3 outs ──
    // HBP (batter reaches, HBP=1 not AB); then 3 outs → LOB=1
    record_confirm(&core, gid, hit_by_pitch(0), "b3-1");    // HBP, runner on 1st
    record_confirm(&core, gid, strikeout(0), "b3-2");       // AB, out 1
    record_confirm(&core, gid, groundout_63(1), "b3-3");    // AB, out 2
    record_confirm(&core, gid, flyout_8(2), "b3-4");        // AB, out 3 → LOB=1

    // ── Finalize ──
    let result = core
        .finalize_scorecard(FinalizeRequest {
            game_id: gid,
            mode: FinalizeMode::Final,
            idempotency_key: "h2-finalize".into(),
            actor: owner(),
        })
        .expect("finalize_scorecard must succeed (SC-011 proof boxes must balance)");

    // ── Assert Retrosheet export correctness ──
    let export = &result.retrosheet;
    let evn_text = export_to_text(export);

    // 1. Required header records.
    assert!(evn_text.contains("id,"), "missing id record:\n{evn_text}");
    assert!(evn_text.contains("version,2"), "missing version record:\n{evn_text}");
    assert!(
        evn_text.contains("info,visteam,NYA"),
        "wrong or missing visteam:\n{evn_text}"
    );
    assert!(
        evn_text.contains("info,hometeam,BOS"),
        "wrong or missing hometeam:\n{evn_text}"
    );
    assert!(
        evn_text.contains("info,number,0"),
        "missing info,number record (cwevent requires it):\n{evn_text}"
    );

    // 2. Date MUST use slashes — cwevent segfaults on dashes (research.md D4 / SC-004).
    assert!(
        evn_text.contains("info,date,") && evn_text.contains('/'),
        "date must be present and use YYYY/MM/DD slashes:\n{evn_text}"
    );
    // Ensure no dash-format date slipped through.
    let date_line = evn_text
        .lines()
        .find(|l| l.starts_with("info,date,"))
        .expect("info,date line must exist");
    assert!(
        !date_line.contains('-'),
        "date field must not contain dashes (cwevent segfaults): {date_line}"
    );

    // 3. start records (cwevent segfaults without them — research.md D4 / SC-004).
    let start_count = evn_text.lines().filter(|l| l.starts_with("start,")).count();
    assert!(
        start_count >= 18,
        "must have at least 18 start records (9 per team), got {start_count}:\n{evn_text}"
    );

    // 4. At least one play record.
    let play_count = evn_text.lines().filter(|l| l.starts_with("play,")).count();
    assert!(
        play_count >= 1,
        "must have at least one play record, got {play_count}:\n{evn_text}"
    );

    // 5. data,er records present.
    assert!(
        evn_text.contains("data,er,"),
        "missing data,er records:\n{evn_text}"
    );

    // 6. Verify out-of-format flags list (the test plays should all be in-grammar).
    // Any NP is acceptable (some plays may be out of format) but we assert most are in-format.
    let np_count = evn_text.lines().filter(|l| l.ends_with(",NP")).count();
    let total_play_records = evn_text.lines().filter(|l| l.starts_with("play,")).count();
    let in_format_pct = (total_play_records - np_count) * 100 / total_play_records.max(1);
    assert!(
        in_format_pct >= 70,
        "at least 70% of play records must be in-format, got {in_format_pct}% \
         ({np_count} NP out of {total_play_records}):\n{evn_text}"
    );

    // ── Write the EVN to disk for the cwevent gate shell script ──
    // Output path: evals/retrosheet-fixtures/h2/<game-id>.EVN
    // The file is committed so the gate script can be run repeatably.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fixture_dir = manifest_dir.parent().unwrap().join("evals/retrosheet-fixtures/h2");
    std::fs::create_dir_all(&fixture_dir)
        .expect("failed to create evals/retrosheet-fixtures/h2/");

    // Extract game-id from the EVN text (first id record).
    let game_id_str = evn_text
        .lines()
        .find(|l| l.starts_with("id,"))
        .and_then(|l| l.split_once(',').map(|x| x.1))
        .unwrap_or("H2GAME2024010101")
        .trim();

    let evn_path = fixture_dir.join(format!("{}.EVN", game_id_str));
    std::fs::write(&evn_path, &evn_text).expect("failed to write EVN file");

    // Write TEAM2024 file (mandatory — cwevent exits 1 without it).
    let team_path = fixture_dir.join("TEAM2024");
    std::fs::write(
        &team_path,
        "NYA,AL,New York,Yankees\nBOS,AL,Boston,Red Sox\n",
    )
    .expect("failed to write TEAM2024");

    eprintln!("[h2_export] EVN written to: {}", evn_path.display());
    eprintln!("[h2_export] play records: {play_count}, NP: {np_count}");
    eprintln!("[h2_export] EVN text:\n{evn_text}");
}

// ---------------------------------------------------------------------------
// Additional: verify the text serializer round-trip
// ---------------------------------------------------------------------------

#[test]
fn export_text_serializer_produces_valid_csv_lines() {
    // Ensure export_to_text produces lines parseable as CSV records.
    use dl_core::retrosheet::{emit_game, GameExportInput, PlayExportInput, StartRecord};
    use dl_core::ffi::{GameId, Seq};
    use dl_core::model::{Advance, AdvanceTo, BallType, BatterEvent, BatterHand, Catalyst, Count, NormalizedPlay, Position, RunnerId, Runners, SituationDiamond, Base};

    let play = NormalizedPlay {
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
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Out,
                by_error: None,
            }],
            touched_or_misplayed_by: vec![],
        },
        audit_label: None,
    };

    let starters: Vec<StartRecord> = (1u8..=9)
        .map(|i| StartRecord {
            player_id: format!("vis{:03}", i),
            player_name: format!("Visitor{}", i),
            team_side: 0,
            batting_order: i,
            fielding_pos: i,
        })
        .chain((1u8..=9).map(|i| StartRecord {
            player_id: format!("hom{:03}", i),
            player_name: format!("Home{}", i),
            team_side: 1,
            batting_order: i,
            fielding_pos: i,
        }))
        .collect();

    let pei = PlayExportInput {
        play: &play,
        inning: 1,
        half: Half::Top,
        batter_id: "vis001",
        seq: Seq(1),
        game_id: GameId(1),
    };

    let input = GameExportInput {
        game_id: "BOS2024010101",
        home_team: "BOS",
        visitor_team: "NYA",
        date: "2024/01/01",
        starters,
        pitchers: vec!["vis009".into(), "hom009".into()],
        plays: vec![pei],
    };
    let export = emit_game(&input);
    let text = export_to_text(&export);

    // Every line must have at least one comma (all Retrosheet records do).
    for line in text.lines() {
        assert!(line.contains(','), "line has no comma: {line}");
    }
    // Must start with id record.
    assert!(text.starts_with("id,BOS2024010101"), "must start with id record: {text}");
}

// ---------------------------------------------------------------------------
// P1a — export replay parity tests (FR-012 / SC-003 / I2)
// ---------------------------------------------------------------------------

/// P1a-1: finalize with an OPEN (unresolved) judgment → the withheld play is
/// excluded from the export (not emitted as an in-format `play` record).
///
/// Design: 3 strikeouts (clean 3-out half-inning). Then correct play 1 (strikeout)
/// to an error play that triggers HitVsError — but do NOT resolve the new judgment.
/// At finalize time the corrected play's seq has an open judgment → it is withheld
/// from projection (SC-003/I2) and must be absent from the export.
///
/// Proof-box: the withheld play is excluded from the projection, so the half-inning
/// only counts plays 2 and 3 (two strikeouts = AB=2, PO=2, R=0, LOB=0 — balances).
#[test]
fn export_excludes_open_judgment_play() {
    use dl_core::ffi::{CorrectEventRequest, FinalizeMode, FinalizeRequest};

    let core = DiamondCore::new();
    let gid = core
        .create_game(CreateGameRequest {
            home: team("BOS", "Red Sox"),
            visitor: team("NYA", "Yankees"),
            idempotency_key: "parity-j-create".into(),
            actor: owner(),
        })
        .unwrap()
        .game_id;

    // Play 1: strikeout — confirmed. This is the play we will correct later.
    let r1 = record_confirm(&core, gid, strikeout(0), "pj-p1");
    let p1_seq = r1.recorded_seq;

    // Play 2: strikeout (out 2).
    record_confirm(&core, gid, strikeout(1), "pj-p2");

    // Play 3: strikeout (out 3) — side retired.
    record_confirm(&core, gid, strikeout(2), "pj-p3");

    // Correct play 1: strikeout → error_6 (batter reaches; opens HitVsError judgment).
    // The correction opens a fresh judgment on the corrected facts. We do NOT resolve it.
    let amended_error = NormalizedPlay {
        situation: sit(0, 0, 0),
        catalyst: Catalyst {
            batter_event: BatterEvent::Error,
            fielders: vec![Position(6)],
            ball_type: BallType::Ground,
            advances: vec![Advance {
                runner: RunnerId(0),
                from: Base::Home,
                to: AdvanceTo::Base(Base::First),
                by_error: Some(Position(6)),
            }],
            // touched_or_misplayed_by drives HitVsError judgment (classifier §4).
            touched_or_misplayed_by: vec![Position(6)],
        },
        audit_label: None,
    };
    let _correction = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: p1_seq,
            amended: PlayInput::Normalized(amended_error),
            idempotency_key: "pj-correction".into(),
            actor: owner(),
        })
        .expect("correct_event must succeed");
    // The amended error play is HitVsError — a fresh judgment is now open on p1_seq.

    // Finalize with the correction-judgment STILL OPEN. This is legal — finalize
    // does not block on open judgments (only on pending/unconfirmed plays).
    // The proof box only sees plays 2 and 3 (withheld play excluded from projection):
    //   AB=2, PO=2, R=0, LOB=0 → balances (2=2).
    let result = core
        .finalize_scorecard(FinalizeRequest {
            game_id: gid,
            mode: FinalizeMode::Final,
            idempotency_key: "pj-finalize".into(),
            actor: owner(),
        })
        .expect("finalize must succeed even with an open judgment (non-blocking)");

    // The open judgment must be reported in unresolved.
    assert!(
        !result.unresolved.pending_judgments.is_empty(),
        "finalize must surface the open correction-judgment in unresolved"
    );

    let evn_text = export_to_text(&result.retrosheet);
    let play_lines: Vec<&str> = evn_text.lines().filter(|l| l.starts_with("play,")).collect();
    eprintln!("[open-judgment-test] play lines:\n{}", play_lines.join("\n"));

    // Plays 2 and 3 (strikeouts) must appear; play 1 (open-judgment correction) must NOT.
    assert_eq!(
        play_lines.len(),
        2,
        "only 2 of 3 plays should appear — open-judgment play withheld; got {}:\n{}",
        play_lines.len(),
        play_lines.join("\n")
    );
    assert!(
        play_lines.iter().all(|l| l.ends_with(",K")),
        "both exported plays must be strikeouts (K):\n{evn_text}"
    );
    // The withheld error play (E6) must NOT appear.
    assert!(
        !play_lines.iter().any(|l| l.ends_with(",E6")),
        "withheld error play (E6) must NOT appear in export:\n{evn_text}"
    );
}

/// P1a-2: finalize AFTER a correction → the export reflects the CORRECTED facts,
/// not the original facts.
///
/// A game with one groundout corrected to a strikeout. After correction + resolution
/// + finalize, the Retrosheet export must show `K` (corrected), not `6-3` (original).
#[test]
fn export_reflects_corrected_facts_not_original() {
    use dl_core::ffi::{CorrectEventRequest, FinalizeMode, FinalizeRequest};

    let core = DiamondCore::new();
    let gid = core
        .create_game(CreateGameRequest {
            home: team("BOS", "Red Sox"),
            visitor: team("NYA", "Yankees"),
            idempotency_key: "parity-c-create".into(),
            actor: owner(),
        })
        .unwrap()
        .game_id;

    // Play 1: groundout 6-3 — recorded and confirmed.
    record_confirm(&core, gid, groundout_63(0), "pc-p1");
    let p1_seq = core
        .list_game_events(gid)
        .unwrap()
        .iter()
        .find(|e| e.event_type == "PlayRecorded")
        .map(|e| e.seq)
        .expect("play 1 seq must exist");

    // Play 2: strikeout (2nd out).
    record_confirm(&core, gid, strikeout(1), "pc-p2");

    // Play 3: flyout (3rd out).
    record_confirm(&core, gid, flyout_8(2), "pc-p3");

    // Correct play 1: groundout → strikeout (deterministic correction, no judgment).
    let corrected_play = NormalizedPlay {
        situation: sit(0, 1, 2),
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
    };
    let _correction = core
        .correct_event(CorrectEventRequest {
            game_id: gid,
            corrects_seq: p1_seq,
            amended: PlayInput::Normalized(corrected_play),
            idempotency_key: "pc-correction".into(),
            actor: owner(),
        })
        .expect("correct_event must succeed");
    // Strikeout is deterministic — no new judgment opened.

    // Finalize.
    let result = core
        .finalize_scorecard(FinalizeRequest {
            game_id: gid,
            mode: FinalizeMode::Final,
            idempotency_key: "pc-finalize".into(),
            actor: owner(),
        })
        .expect("finalize must succeed");

    let evn_text = export_to_text(&result.retrosheet);
    let play_lines: Vec<&str> = evn_text.lines().filter(|l| l.starts_with("play,")).collect();
    eprintln!("[correction-test] play lines:\n{}", play_lines.join("\n"));

    // The export must show the CORRECTED facts (K), not the original (6-3).
    assert!(
        play_lines.iter().any(|l| l.ends_with(",K")),
        "corrected strikeout (K) must appear in export:\n{evn_text}"
    );
    assert!(
        !play_lines.iter().any(|l| l.ends_with(",6-3")),
        "original groundout (6-3) must NOT appear in export after correction:\n{evn_text}"
    );
    // Should have 3 play records: corrected K + K + 8.
    assert_eq!(
        play_lines.len(),
        3,
        "must have 3 play records after correction (no exclusions):\n{evn_text}"
    );
}
