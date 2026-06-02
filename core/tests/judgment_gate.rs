//! SC-003 judgment gate integration test (T041).
//!
//! Reads evals/judgment-corpus/seed.jsonl (per evals/INTERFACE.md §1) and
//! runs classify() on each entry. HARD-FAILS on:
//!   1. Any entry classified as Deterministic or OutOfFormat.
//!   2. silent_resolution_counter > 0.
//!   3. Not all four trigger types present.
//!   4. Corpus absent or empty.
//!
//! Invoked by evals/runners/judgment-gate.sh.

use std::collections::HashSet;

use dl_core::classify::{
    classify_with_context, reset_silent_resolution_counter, silent_resolution_count, ClassifyContext,
};
use dl_core::model::{
    Advance, AdvanceTo, BallType, BatterEvent, BatterHand, Catalyst, Classification, Count,
    JudgmentKind, NormalizedPlay, Position, RunnerId, Runners, SituationDiamond, Base,
};
use serde::Deserialize;

// ---------------------------------------------------------------------------
// Corpus entry schema (evals/INTERFACE.md §1.1)
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct CorpusEntry {
    id: String,
    situation: SituationSchema,
    catalyst: CatalystSchema,
    expected_classification: String,
    trigger: String,
    #[serde(default)]
    inning_error_context: Option<InningErrorContext>,
    #[serde(default)]
    supplied_label: Option<String>, // Ignored by classify() — audit only
}

#[derive(Debug, Deserialize)]
struct SituationSchema {
    outs: u8,
    runners: RunnersSchema,
    count: CountSchema,
    batter_hand: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
struct RunnersSchema {
    #[serde(default)]
    first: bool,
    #[serde(default)]
    second: bool,
    #[serde(default)]
    third: bool,
}

#[derive(Debug, Deserialize)]
struct CountSchema {
    balls: u8,
    strikes: u8,
}

#[derive(Debug, Deserialize)]
struct CatalystSchema {
    batter_event: String,
    #[serde(default)]
    fielders: Vec<u8>,
    ball_type: String,
    advances: Vec<AdvanceSchema>,
    #[serde(default)]
    touched_or_misplayed_by: Vec<u8>,
}

#[derive(Debug, Deserialize)]
struct AdvanceSchema {
    runner: String,
    from: String,
    to: String,
    by_error: Option<u8>,
}

#[derive(Debug, Deserialize)]
struct InningErrorContext {
    has_error_or_pb: bool,
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

fn parse_batter_event(s: &str) -> BatterEvent {
    match s {
        "S" | "Single" => BatterEvent::Single,
        "D" | "Double" => BatterEvent::Double,
        "T" | "Triple" => BatterEvent::Triple,
        "HR" | "HomeRun" => BatterEvent::HomeRun,
        "K" | "Strikeout" => BatterEvent::Strikeout,
        "W" | "Walk" => BatterEvent::Walk,
        "IW" | "IntentionalWalk" => BatterEvent::IntentionalWalk,
        "HP" | "HitByPitch" => BatterEvent::HitByPitch,
        "E" | "Error" => BatterEvent::Error,
        "FC" | "FieldersChoice" => BatterEvent::FieldersChoice,
        "FieldedOut" => BatterEvent::FieldedOut,
        "SacFly" => BatterEvent::SacFly,
        "SacBunt" => BatterEvent::SacBunt,
        "StolenBase" => BatterEvent::StolenBase,
        "CaughtStealing" => BatterEvent::CaughtStealing,
        "WildPitch" => BatterEvent::WildPitch,
        "PassedBall" => BatterEvent::PassedBall,
        _ => BatterEvent::Other,
    }
}

fn parse_ball_type(s: &str) -> BallType {
    match s {
        "Ground" => BallType::Ground,
        "Line" => BallType::Line,
        "Fly" => BallType::Fly,
        "Pop" => BallType::Pop,
        "Bunt" => BallType::Bunt,
        _ => BallType::None,
    }
}

fn parse_base(s: &str) -> Base {
    match s {
        "home" => Base::Home,
        "first" | "1" => Base::First,
        "second" | "2" => Base::Second,
        "third" | "3" => Base::Third,
        _ => Base::Home,
    }
}

fn parse_advance_to(s: &str) -> AdvanceTo {
    match s {
        "out" => AdvanceTo::Out,
        other => AdvanceTo::Base(parse_base(other)),
    }
}

fn parse_runner_id(s: &str) -> RunnerId {
    match s {
        "batter" => RunnerId(0),
        "first" | "1" => RunnerId(1),
        "second" | "2" => RunnerId(2),
        "third" | "3" => RunnerId(3),
        _ => RunnerId(0),
    }
}

fn parse_batter_hand(s: Option<&String>) -> BatterHand {
    match s.map(|s| s.as_str()) {
        Some("R") => BatterHand::Right,
        Some("L") => BatterHand::Left,
        Some("S") => BatterHand::Switch,
        _ => BatterHand::Right,
    }
}

fn entry_to_play(entry: &CorpusEntry) -> NormalizedPlay {
    let runners = Runners {
        first: if entry.situation.runners.first { Some(RunnerId(1)) } else { None },
        second: if entry.situation.runners.second { Some(RunnerId(2)) } else { None },
        third: if entry.situation.runners.third { Some(RunnerId(3)) } else { None },
    };

    let advances: Vec<Advance> = entry
        .catalyst
        .advances
        .iter()
        .map(|a| Advance {
            runner: parse_runner_id(&a.runner),
            from: parse_base(&a.from),
            to: parse_advance_to(&a.to),
            by_error: a.by_error.map(Position),
        })
        .collect();

    NormalizedPlay {
        situation: SituationDiamond {
            runners,
            outs: entry.situation.outs,
            count: Count {
                balls: entry.situation.count.balls,
                strikes: entry.situation.count.strikes,
            },
            batter_hand: parse_batter_hand(entry.situation.batter_hand.as_ref()),
        },
        catalyst: Catalyst {
            batter_event: parse_batter_event(&entry.catalyst.batter_event),
            fielders: entry.catalyst.fielders.iter().map(|&p| Position(p)).collect(),
            ball_type: parse_ball_type(&entry.catalyst.ball_type),
            advances,
            touched_or_misplayed_by: entry.catalyst.touched_or_misplayed_by.iter().map(|&p| Position(p)).collect(),
        },
        // audit_label is deliberately NOT passed to classify() (FR-006/I1).
        audit_label: entry.supplied_label.clone(),
    }
}

fn expected_judgment_kind(s: &str) -> Option<JudgmentKind> {
    match s {
        "Judgment(HitVsError)" => Some(JudgmentKind::HitVsError),
        "Judgment(EarnedVsUnearned)" => Some(JudgmentKind::EarnedVsUnearned),
        "Judgment(ContestedCredit)" => Some(JudgmentKind::ContestedCredit),
        "Judgment(AmbiguousAdvance)" => Some(JudgmentKind::AmbiguousAdvance),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// The gate test
// ---------------------------------------------------------------------------

#[test]
fn judgment_gate_runner() {
    // Reset the SC-003 counter at the start.
    reset_silent_resolution_counter();

    // Locate corpus.
    let corpus_path = std::env::var("CORPUS_PATH").unwrap_or_else(|_| {
        let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| ".".into());
        format!("{}/../evals/judgment-corpus/seed.jsonl", manifest)
    });

    // Gate 4: corpus must exist.
    let corpus_text = std::fs::read_to_string(&corpus_path).unwrap_or_else(|e| {
        panic!(
            "HARD-FAIL: Corpus file not found or not readable at '{}': {} \
             (set CORPUS_PATH env var or run from the repo root)",
            corpus_path, e
        )
    });

    let lines: Vec<&str> = corpus_text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .collect();

    // Gate 4: must be non-empty.
    assert!(
        !lines.is_empty(),
        "HARD-FAIL: Corpus is empty (zero entries). A zero-size corpus is vacuous."
    );

    let mut trigger_types_seen: HashSet<String> = HashSet::new();
    let mut failures: Vec<String> = Vec::new();

    for (i, line) in lines.iter().enumerate() {
        let entry: CorpusEntry = serde_json::from_str(line).unwrap_or_else(|e| {
            panic!("HARD-FAIL: Failed to parse corpus entry {}: {}", i + 1, e)
        });

        let play = entry_to_play(&entry);
        let ctx = ClassifyContext {
            inning_has_error_or_pb: entry
                .inning_error_context
                .as_ref()
                .map(|c| c.has_error_or_pb)
                .unwrap_or(false),
        };

        // classify() MUST return Judgment (I1/FR-006).
        let result = classify_with_context(&play, &ctx);

        let expected_kind = expected_judgment_kind(&entry.expected_classification);
        let expected_kind = match expected_kind {
            Some(k) => k,
            None => {
                panic!(
                    "HARD-FAIL: Corpus entry '{}' has invalid expected_classification '{}'. \
                     All corpus entries must be Judgment variants.",
                    entry.id, entry.expected_classification
                );
            }
        };

        match &result {
            Classification::Judgment(got_kind) => {
                if *got_kind != expected_kind {
                    failures.push(format!(
                        "Entry '{}': expected {:?} but got {:?}",
                        entry.id, expected_kind, got_kind
                    ));
                } else {
                    trigger_types_seen.insert(entry.trigger.clone());
                }
            }
            Classification::Deterministic => {
                failures.push(format!(
                    "Entry '{}': classified as Deterministic (expected {:?}). \
                     The audit_label '{}' must NOT influence classification (FR-006/I1).",
                    entry.id,
                    expected_kind,
                    entry.supplied_label.as_deref().unwrap_or("none")
                ));
            }
            Classification::OutOfFormat(reason) => {
                failures.push(format!(
                    "Entry '{}': classified as OutOfFormat('{}') (expected {:?}).",
                    entry.id, reason, expected_kind
                ));
            }
        }
    }

    // Gate 2: silent_resolution_counter must be 0.
    let counter = silent_resolution_count();
    if counter > 0 {
        panic!(
            "HARD-FAIL: silent_resolution_counter = {} (must be 0). \
             Judgment mutations without an open flag + recorded decider were detected (SC-003/I2).",
            counter
        );
    }

    // Gate 3: all four trigger types must be present.
    let required_triggers = ["HitVsError", "EarnedVsUnearned", "ContestedCredit", "AmbiguousAdvance"];
    let mut missing_triggers: Vec<&str> = Vec::new();
    for t in &required_triggers {
        if !trigger_types_seen.contains(*t) {
            missing_triggers.push(t);
        }
    }
    if !missing_triggers.is_empty() {
        panic!(
            "HARD-FAIL: Corpus does not exercise all four trigger types. \
             Missing: {:?}. Present: {:?}. \
             A corpus that does not exercise all four triggers is vacuous.",
            missing_triggers,
            trigger_types_seen
        );
    }

    // Gate 1: report all classification failures.
    if !failures.is_empty() {
        panic!(
            "HARD-FAIL: {} corpus entr{} misclassified:\n{}",
            failures.len(),
            if failures.len() == 1 { "y" } else { "ies" },
            failures.join("\n")
        );
    }

    // All gates passed.
    println!(
        "SC-003 Judgment Gate: PASS\n\
         - {} entries checked\n\
         - {} trigger types covered: {:?}\n\
         - silent_resolution_counter = 0",
        lines.len(),
        trigger_types_seen.len(),
        trigger_types_seen
    );
}
