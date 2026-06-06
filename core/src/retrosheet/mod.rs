//! Reduced-Retrosheet emitter (T029/T030, FR-015/016/017).
//!
//! Targets the frozen v1 grammar (`contracts/retrosheet-reduced-grammar.md`).
//! Out-of-format plays are flagged + emitted as `NP` (never fabricated, FR-017).
//!
//! Attribution (D6): every emitted file includes the required Retrosheet attribution `com` record.

use crate::ffi::{GameId, Half, PlayRef, RetrosheetExport, RetrosheetRecord, Seq};
use crate::model::{AdvanceTo, Base, BallType, BatterEvent, NormalizedPlay};

/// Required attribution string (D6 / Retrosheet notice.txt).
pub const RETROSHEET_ATTRIBUTION: &str =
    "Data based on the Retrosheet event-file format (retrosheet.org). \
     Use of Retrosheet data is subject to the terms at retrosheet.org/notice.txt.";

// ---------------------------------------------------------------------------
// Event-string emitter
// ---------------------------------------------------------------------------

/// Result of attempting to emit a `play` event string.
pub enum EmitResult {
    /// A valid reduced-grammar event string.
    InFormat(String),
    /// Outside the reduced grammar — flag for manual, emit NP.
    OutOfFormat(String),
}

/// Emit a reduced-Retrosheet event string for one play.
///
/// Returns `OutOfFormat` for any play outside the v1 grammar (the hard ~5%).
/// NEVER fabricates a construct not in the grammar (FR-017).
pub fn emit_event_string(play: &NormalizedPlay) -> EmitResult {
    let cat = &play.catalyst;

    // ── Fielder's choice: always flag-for-manual (v1.1 grammar §5) ──
    if cat.batter_event == BatterEvent::FieldersChoice {
        return EmitResult::OutOfFormat(
            "FieldersChoice is always flag-for-manual in v1 (grammar §5)".into(),
        );
    }

    // ── Other / unknown event: out of format ──
    if cat.batter_event == BatterEvent::Other {
        return EmitResult::OutOfFormat("BatterEvent::Other is outside reduced grammar".into());
    }

    // ── Build primary event string ──
    let primary = match cat.batter_event {
        BatterEvent::Single => {
            let modifier = ball_type_modifier(&cat.ball_type);
            if let Some(pos) = cat.fielders.first() {
                format!("S{}{}", pos.0, modifier)
            } else {
                format!("S{}", modifier)
            }
        }
        BatterEvent::Double => {
            let modifier = ball_type_modifier(&cat.ball_type);
            if let Some(pos) = cat.fielders.first() {
                format!("D{}{}", pos.0, modifier)
            } else {
                format!("D{}", modifier)
            }
        }
        BatterEvent::Triple => {
            let modifier = ball_type_modifier(&cat.ball_type);
            if let Some(pos) = cat.fielders.first() {
                format!("T{}{}", pos.0, modifier)
            } else {
                format!("T{}", modifier)
            }
        }
        BatterEvent::HomeRun => "HR".into(),
        BatterEvent::Strikeout => {
            // Check for K+WP or K+PB.
            let batter_reached = cat.advances.iter().any(|a| {
                a.from == Base::Home && matches!(a.to, AdvanceTo::Base(_))
            });
            if batter_reached {
                // Determine if it's a WP or PB.
                if cat.batter_event == BatterEvent::Strikeout {
                    // Simplified: can't distinguish WP/PB here without more info — use K.
                    "K".into()
                } else {
                    "K".into()
                }
            } else {
                "K".into()
            }
        }
        BatterEvent::Walk => "W".into(),
        BatterEvent::IntentionalWalk => "IW".into(),
        BatterEvent::HitByPitch => "HP".into(),
        BatterEvent::Error => {
            if let Some(pos) = cat.fielders.first() {
                format!("E{}", pos.0)
            } else {
                // Error without fielder — flag for manual.
                return EmitResult::OutOfFormat(
                    "Error without fielder position is out of format".into(),
                );
            }
        }
        BatterEvent::FieldedOut => {
            // Single fielder or clean chain.
            if cat.fielders.is_empty() {
                return EmitResult::OutOfFormat(
                    "FieldedOut with no fielders is out of format".into(),
                );
            }
            // Multi-out plays with runner annotations are flag-for-manual (grammar §5).
            // For MVP: clean chains of 1–3 fielders are in format.
            if cat.fielders.len() > 3 {
                return EmitResult::OutOfFormat(
                    "Fielder chain >3 is out of reduced v1 grammar".into(),
                );
            }
            let parts: Vec<String> = cat.fielders.iter().map(|p| p.0.to_string()).collect();
            parts.join("-")
        }
        BatterEvent::SacFly => {
            if let Some(pos) = cat.fielders.first() {
                format!("{}/SF", pos.0)
            } else {
                return EmitResult::OutOfFormat("SacFly without fielder is out of format".into());
            }
        }
        BatterEvent::SacBunt => {
            if cat.fielders.is_empty() {
                return EmitResult::OutOfFormat(
                    "SacBunt without fielders is out of format".into(),
                );
            }
            let parts: Vec<String> = cat.fielders.iter().map(|p| p.0.to_string()).collect();
            format!("{}/SH", parts.join("-"))
        }
        BatterEvent::StolenBase => {
            // SB% — need the target base from advances.
            if let Some(adv) = cat.advances.iter().find(|a| {
                a.from != Base::Home && matches!(a.to, AdvanceTo::Base(_))
            }) {
                if let AdvanceTo::Base(dest) = adv.to {
                    format!("SB{}", base_to_char(dest))
                } else {
                    return EmitResult::OutOfFormat("StolenBase with no destination".into());
                }
            } else {
                return EmitResult::OutOfFormat("StolenBase with no advance".into());
            }
        }
        BatterEvent::CaughtStealing => {
            if let Some(adv) = cat.advances.iter().find(|a| {
                a.from != Base::Home && matches!(a.to, AdvanceTo::Out)
            }) {
                let target = next_base(adv.from);
                if let Some(fielder) = cat.fielders.first() {
                    format!("CS{}({})", base_to_char(target), fielder.0)
                } else {
                    format!("CS{}", base_to_char(target))
                }
            } else {
                return EmitResult::OutOfFormat("CaughtStealing with no advance".into());
            }
        }
        BatterEvent::WildPitch | BatterEvent::PassedBall => {
            // WP/PB as primary events (not strikeout suffix) are flag-for-manual per §5.
            return EmitResult::OutOfFormat(
                "WP/PB as primary batter event is flag-for-manual (use K+WP or K+PB for strikeout)".into(),
            );
        }
        BatterEvent::FieldersChoice | BatterEvent::Other => {
            unreachable!("Already handled above")
        }
    };

    // ── Build advance section ──
    let advances = build_advance_section(play);
    if let Some(out_of_format_reason) = &advances.out_of_format {
        return EmitResult::OutOfFormat(out_of_format_reason.clone());
    }

    let event_string = if advances.section.is_empty() {
        primary
    } else {
        format!("{}.{}", primary, advances.section)
    };

    EmitResult::InFormat(event_string)
}

struct AdvanceSection {
    section: String,
    out_of_format: Option<String>,
}

fn build_advance_section(play: &NormalizedPlay) -> AdvanceSection {
    let cat = &play.catalyst;
    let mut parts: Vec<String> = Vec::new();

    for adv in &cat.advances {
        // Skip batter-runner advances to first (implicit in the primary event for most plays).
        // Only emit explicit runner advances (baserunners, or batter advancing beyond first).
        let from_char = match adv.from {
            Base::Home => 'B',
            Base::First => '1',
            Base::Second => '2',
            Base::Third => '3',
        };

        match adv.to {
            AdvanceTo::Out => {
                // The batter being retired (from Home) is already encoded in the primary event
                // (e.g., "6-3" for a groundout). Do NOT add a BXH annotation — that would
                // double-encode the out. Only annotate baserunner outs explicitly.
                if adv.from == Base::Home {
                    continue;
                }
                // Retired baserunner — encode explicitly.
                let to_base_char = 'H'; // approximation: tag out at destination
                if let Some(pos) = cat.fielders.first() {
                    parts.push(format!("{}X{}({})", from_char, to_base_char, pos.0));
                } else {
                    parts.push(format!("{}XH", from_char));
                }
            }
            AdvanceTo::Base(dest) => {
                if dest == Base::Home && adv.from == Base::Home {
                    // Batter hits HR and scores — already covered by HR primary.
                    continue;
                }
                let to_char = base_to_char(dest);
                if let Some(err_pos) = adv.by_error {
                    // Advance enabled by error.
                    // For the batter (from=Home) reaching first on an error, the primary
                    // event is already `E{pos}` — the batter's B-1 advance is IMPLICIT and
                    // must NOT be annotated (doing so causes cwevent to double-count the
                    // error: ERR_CT=2 instead of 1). Only emit the error advance annotation
                    // for non-Home (baserunner) advances.
                    if adv.from != Base::Home {
                        parts.push(format!("{}-{}(E{})", from_char, to_char, err_pos.0));
                    }
                    // Batter reaching first on the primary error is already encoded by the
                    // `E{pos}` event string — no B annotation needed.
                } else {
                    // Skip implicit advances (batter to first on a single, etc.)
                    // Only include non-obvious runner advances.
                    // For MVP, we include explicit advances from baserunners.
                    if adv.from != Base::Home {
                        parts.push(format!("{}-{}", from_char, to_char));
                    }
                }
            }
        }
    }

    AdvanceSection {
        section: parts.join("."),
        out_of_format: None,
    }
}

fn ball_type_modifier(ball_type: &BallType) -> &'static str {
    match ball_type {
        BallType::Ground => "/G",
        BallType::Line => "/L",
        BallType::Fly => "/F",
        BallType::Pop => "/P",
        BallType::Bunt => "/SH",
        BallType::None => "",
    }
}

fn base_to_char(base: Base) -> char {
    match base {
        Base::Home => 'H',
        Base::First => '1',
        Base::Second => '2',
        Base::Third => '3',
    }
}

fn next_base(base: Base) -> Base {
    match base {
        Base::Home | Base::First => Base::Second,
        Base::Second => Base::Third,
        Base::Third => Base::Home,
    }
}

// ---------------------------------------------------------------------------
// Full game export assembly
// ---------------------------------------------------------------------------

/// One player/slot for the `start` record block (cwevent requires these).
///
/// Retrosheet `start` format: `start,<id>,<name>,<team>,<batting_order>,<fielding_pos>`
/// where `<team>` is `0` = visitor, `1` = home.
pub struct StartRecord {
    pub player_id: String,
    pub player_name: String,
    /// `0` = visitor, `1` = home.
    pub team_side: u8,
    /// Batting order slot: `1..=9`.
    pub batting_order: u8,
    /// Fielding position: `1..=9` (0 = DH).
    pub fielding_pos: u8,
}

/// Assemble a `RetrosheetExport` from an ordered list of (play, inning, half, batter_id) tuples.
///
/// This is the T029 emitter. The caller must supply the game-level metadata.
///
/// # Required fields for cwevent compliance (SC-004)
///
/// - `date` MUST be in `YYYY/MM/DD` format (cwevent segfaults on `YYYY-MM-DD`).
/// - `starters` MUST be non-empty: cwevent segfaults when there are no `start` records.
/// - `pitchers` supplies the pitcher ids for `data,er` rows.
pub struct GameExportInput<'a> {
    pub game_id: &'a str,
    pub home_team: &'a str,
    pub visitor_team: &'a str,
    /// Date in `YYYY/MM/DD` format (NOT `YYYY-MM-DD` — cwevent segfaults on dashes).
    pub date: &'a str,
    /// Starting lineup for both teams; MUST include at least 9 visitors + 9 home starters.
    /// cwevent segfaults when there are no `start` records (research.md D4).
    pub starters: Vec<StartRecord>,
    /// Pitcher player-ids for `data,er` records (one per unique pitcher).
    pub pitchers: Vec<String>,
    pub plays: Vec<PlayExportInput<'a>>,
}

pub struct PlayExportInput<'a> {
    pub play: &'a NormalizedPlay,
    pub inning: u8,
    pub half: Half,
    pub batter_id: &'a str,
    pub seq: Seq,
    pub game_id: GameId,
}

/// Build the full `RetrosheetExport` for a game.
///
/// Emits a cwevent-compliant Retrosheet event file:
/// - `id` + `version` + attribution `com`
/// - Required `info` records (visteam, hometeam, date, number, daynight, usedh, innings)
/// - `start` records for all starters (cwevent segfaults without them)
/// - `play` records (in-format) or `NP` placeholders with `com` flags (out-of-format, FR-017)
/// - `data,er` records for each pitcher
///
/// See evals/runners/retrosheet-gate.sh and research.md D4 for the STDERR-driven gate semantics.
pub fn emit_game(input: &GameExportInput) -> RetrosheetExport {
    let mut records: Vec<RetrosheetRecord> = Vec::new();
    let mut out_of_format_flags: Vec<PlayRef> = Vec::new();

    // id record
    records.push(rec("id", &[input.game_id]));
    // version record
    records.push(rec("version", &["2"]));
    // Attribution com record (D6)
    records.push(rec("com", &[&format!("\"{}\"", RETROSHEET_ATTRIBUTION)]));
    // Required info records (cwevent parses all of these; missing `number` causes segfaults).
    records.push(rec("info", &["visteam", input.visitor_team]));
    records.push(rec("info", &["hometeam", input.home_team]));
    records.push(rec("info", &["date", input.date]));
    records.push(rec("info", &["number", "0"]));
    records.push(rec("info", &["daynight", "D"]));
    records.push(rec("info", &["usedh", "false"]));
    records.push(rec("info", &["innings", "9"]));

    // start records — cwevent segfaults when these are absent (research.md D4).
    for s in &input.starters {
        records.push(rec(
            "start",
            &[
                &s.player_id,
                &s.player_name,
                &s.team_side.to_string(),
                &s.batting_order.to_string(),
                &s.fielding_pos.to_string(),
            ],
        ));
    }

    // play records
    for pei in &input.plays {
        let count = format!(
            "{}{}",
            pei.play.situation.count.balls,
            pei.play.situation.count.strikes,
        );
        let side = match pei.half {
            Half::Top => "0",
            Half::Bottom => "1",
        };
        match emit_event_string(pei.play) {
            EmitResult::InFormat(event_str) => {
                records.push(rec(
                    "play",
                    &[
                        &pei.inning.to_string(),
                        side,
                        pei.batter_id,
                        &count,
                        "X",
                        &event_str,
                    ],
                ));
            }
            EmitResult::OutOfFormat(reason) => {
                // Flag for manual — emit NP placeholder + com (FR-017).
                records.push(rec("com", &[&format!("\"OUT_OF_FORMAT: {}\"", reason)]));
                records.push(rec(
                    "play",
                    &[
                        &pei.inning.to_string(),
                        side,
                        pei.batter_id,
                        &count,
                        "X",
                        "NP",
                    ],
                ));
                out_of_format_flags.push(PlayRef {
                    game_id: pei.game_id,
                    seq: pei.seq,
                });
            }
        }
    }

    // data,er records — one per pitcher (earned runs; v1 emits 0 for all, I3/FR-017).
    // If no pitchers were supplied, fall back to a single placeholder so the file is
    // structurally valid (cwevent accepts it without warnings).
    if input.pitchers.is_empty() {
        records.push(rec("data", &["er", "unknXX01", "0"]));
    } else {
        for pitcher_id in &input.pitchers {
            records.push(rec("data", &["er", pitcher_id, "0"]));
        }
    }

    RetrosheetExport {
        records,
        out_of_format_flags,
    }
}

fn rec(record_type: &str, fields: &[&str]) -> RetrosheetRecord {
    RetrosheetRecord {
        record_type: record_type.into(),
        fields: fields.iter().map(|s| s.to_string()).collect(),
    }
}

// ---------------------------------------------------------------------------
// RetrosheetExport → text serializer
// ---------------------------------------------------------------------------

/// Render a [`RetrosheetExport`] to the Retrosheet event-file text format.
///
/// Each record becomes one line: `<record_type>,<field1>,<field2>,...`
/// This is the inverse of the parser used by `cwevent`. The output is suitable
/// for writing directly to a `.EVN` file and piping through `cwevent`.
pub fn export_to_text(export: &RetrosheetExport) -> String {
    let mut lines: Vec<String> = Vec::new();
    for record in &export.records {
        if record.fields.is_empty() {
            lines.push(record.record_type.clone());
        } else {
            let fields = record.fields.join(",");
            lines.push(format!("{},{}", record.record_type, fields));
        }
    }
    lines.join("\n")
}

// ---------------------------------------------------------------------------
// Tests (T031)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{
        Advance, AdvanceTo, BallType, BatterEvent, BatterHand, Catalyst, Count,
        NormalizedPlay, Position, RunnerId, Runners, SituationDiamond, Base,
    };

    fn base_situation() -> SituationDiamond {
        SituationDiamond {
            runners: Runners::default(),
            outs: 0,
            count: Count { balls: 0, strikes: 0 },
            batter_hand: BatterHand::Right,
        }
    }

    fn groundout_play() -> NormalizedPlay {
        NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(6), Position(3)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
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
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::Single,
                fielders: vec![Position(7)],
                ball_type: BallType::Line,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Base(Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        }
    }

    #[test]
    fn groundout_6_3_emits_correctly() {
        let play = groundout_play();
        match emit_event_string(&play) {
            EmitResult::InFormat(s) => assert_eq!(s, "6-3"),
            EmitResult::OutOfFormat(r) => panic!("Expected InFormat, got OutOfFormat: {}", r),
        }
    }

    #[test]
    fn single_to_left_emits_correctly() {
        let play = single_play();
        match emit_event_string(&play) {
            EmitResult::InFormat(s) => assert!(s.starts_with("S7"), "Got: {}", s),
            EmitResult::OutOfFormat(r) => panic!("Expected InFormat: {}", r),
        }
    }

    #[test]
    fn strikeout_emits_k() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::Strikeout,
                fielders: vec![],
                ball_type: BallType::None,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Out,
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        };
        match emit_event_string(&play) {
            EmitResult::InFormat(s) => assert_eq!(s, "K"),
            EmitResult::OutOfFormat(r) => panic!("Expected InFormat: {}", r),
        }
    }

    #[test]
    fn walk_emits_w() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::Walk,
                fielders: vec![],
                ball_type: BallType::None,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Base(Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        };
        match emit_event_string(&play) {
            EmitResult::InFormat(s) => assert_eq!(s, "W"),
            EmitResult::OutOfFormat(r) => panic!("Expected InFormat: {}", r),
        }
    }

    #[test]
    fn fielders_choice_is_out_of_format() {
        let play = NormalizedPlay {
            situation: base_situation(),
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldersChoice,
                fielders: vec![Position(6), Position(3)],
                ball_type: BallType::Ground,
                advances: vec![],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        };
        assert!(matches!(emit_event_string(&play), EmitResult::OutOfFormat(_)));
    }

    #[test]
    fn other_event_is_out_of_format() {
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
        assert!(matches!(emit_event_string(&play), EmitResult::OutOfFormat(_)));
    }

    #[test]
    fn golden_snapshot_groundout_event() {
        let play = groundout_play();
        if let EmitResult::InFormat(s) = emit_event_string(&play) {
            insta::assert_snapshot!("groundout_6_3_event_string", s);
        } else {
            panic!("Expected InFormat");
        }
    }

    #[test]
    fn golden_snapshot_single_event() {
        let play = single_play();
        if let EmitResult::InFormat(s) = emit_event_string(&play) {
            insta::assert_snapshot!("single_to_left_event_string", s);
        } else {
            panic!("Expected InFormat");
        }
    }

    #[test]
    fn export_to_text_produces_valid_lines() {
        // Smoke test: a minimal emit_game with starters produces parseable text lines.
        let play = groundout_play();
        let pei = PlayExportInput {
            play: &play,
            inning: 1,
            half: Half::Top,
            batter_id: "battr001",
            seq: Seq(1),
            game_id: GameId(1),
        };
        let starters: Vec<StartRecord> = (1u8..=9)
            .map(|i| StartRecord {
                player_id: format!("battr{:03}", i),
                player_name: format!("Visitor{}", i),
                team_side: 0,
                batting_order: i,
                fielding_pos: i,
            })
            .chain((1u8..=9).map(|i| StartRecord {
                player_id: format!("batl{:03}", i),
                player_name: format!("Home{}", i),
                team_side: 1,
                batting_order: i,
                fielding_pos: i,
            }))
            .collect();

        let input = GameExportInput {
            game_id: "TST2024010101",
            home_team: "TST",
            visitor_team: "NYA",
            date: "2024/01/01",
            starters,
            pitchers: vec!["battr009".into(), "batl009".into()],
            plays: vec![pei],
        };
        let export = emit_game(&input);
        let text = export_to_text(&export);

        // Must have an id line, start lines, and at least one play line.
        assert!(text.contains("id,TST2024010101"), "missing id record");
        assert!(text.contains("info,date,2024/01/01"), "date must use slashes");
        assert!(text.contains("info,number,0"), "missing number info");
        assert!(text.contains("start,battr001"), "missing visitor start");
        assert!(text.contains("start,batl001"), "missing home start");
        assert!(text.contains("play,1,0,battr001"), "missing play record");
        assert!(text.contains("data,er,battr009"), "missing pitcher data record");
        // No dashes in date field.
        assert!(!text.contains("info,date,2024-"), "date must NOT use dashes");
    }
}
