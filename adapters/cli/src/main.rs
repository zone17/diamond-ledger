//! Diamond Ledger CLI adapter (T038 — agent-parity surface).
//!
//! The CLI is a thin client over dl-core's four atomic primitives, providing
//! agent-native parity (Art. II/FR-018): the same capabilities invokable from the
//! command line as from the iOS app.
//!
//! Usage:
//!   dl new-game <home-name> <visitor-name> <owner-id>
//!   dl record-play <game-id> <normalized-play-json> <owner-id>
//!   dl confirm-play <game-id> <seq> <owner-id>
//!   dl resolve-judgment <game-id> <decision-id> <call-token> <call-label> <owner-id>
//!   dl finalize <game-id> <owner-id>
//!   dl state <game-id>

use std::env;

use dl_core::ffi::{
    Actor, ActorKind, Call, ConfirmPlayRequest, CoreApi, CreateGameRequest,
    FinalizeMode, FinalizeRequest, GameId, PlayInput, RecordPlayRequest,
    ResolveJudgmentRequest, Team,
};
use dl_core::model::NormalizedPlay;
use dl_core::primitives::DiamondCore;

fn owner_actor(id: &str) -> Actor {
    Actor {
        kind: ActorKind::Human,
        id: id.into(),
        harness_version: None,
    }
}

fn usage() {
    eprintln!("Diamond Ledger CLI (dl)");
    eprintln!("Usage:");
    eprintln!("  dl new-game <home-name> <visitor-name> <owner-id>");
    eprintln!("  dl record-play <game-id> <normalized-play-json> <owner-id>");
    eprintln!("  dl confirm-play <game-id> <seq> <owner-id>");
    eprintln!("  dl resolve-judgment <game-id> <decision-id> <call-token> <call-label> <owner-id>");
    eprintln!("  dl finalize <game-id> <owner-id>");
    eprintln!("  dl state <game-id>");
    eprintln!();
    eprintln!("All outputs are JSON. Use --help for detailed options.");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        usage();
        std::process::exit(1);
    }

    let core = DiamondCore::new();
    match run(&core, &args) {
        Ok(json) => println!("{}", serde_json::to_string_pretty(&json).unwrap()),
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

fn run(core: &DiamondCore, args: &[String]) -> Result<serde_json::Value, String> {
    let cmd = args[1].as_str();
    match cmd {
        "new-game" => {
            if args.len() < 5 {
                return Err("Usage: dl new-game <home-name> <visitor-name> <owner-id>".into());
            }
            let home_name = &args[2];
            let visitor_name = &args[3];
            let owner_id = &args[4];
            let req = CreateGameRequest {
                home: Team {
                    id: home_name.to_lowercase().replace(' ', "_"),
                    name: home_name.clone(),
                    lineup: None,
                },
                visitor: Team {
                    id: visitor_name.to_lowercase().replace(' ', "_"),
                    name: visitor_name.clone(),
                    lineup: None,
                },
                idempotency_key: format!("new-{}-{}", home_name, visitor_name),
                actor: owner_actor(owner_id),
            };
            core.create_game(req)
                .map(|r| serde_json::to_value(r).unwrap())
                .map_err(|e| format!("{:?}", e))
        }
        "record-play" => {
            if args.len() < 5 {
                return Err("Usage: dl record-play <game-id> <normalized-play-json> <owner-id>".into());
            }
            let game_id = GameId(args[2].parse::<u64>().map_err(|e| e.to_string())?);
            let play_json = &args[3];
            let owner_id = &args[4];
            let play: NormalizedPlay = serde_json::from_str(play_json)
                .map_err(|e| format!("Invalid play JSON: {}", e))?;
            let req = RecordPlayRequest {
                game_id,
                input: PlayInput::Normalized(play),
                idempotency_key: format!("record-{}", uuid_like()),
                actor: owner_actor(owner_id),
            };
            core.record_play(req)
                .map(|r| serde_json::to_value(r).unwrap())
                .map_err(|e| format!("{:?}", e))
        }
        "confirm-play" => {
            if args.len() < 5 {
                return Err("Usage: dl confirm-play <game-id> <seq> <owner-id>".into());
            }
            let game_id = GameId(args[2].parse::<u64>().map_err(|e| e.to_string())?);
            let seq = args[3].parse::<u64>().map_err(|e| e.to_string())?;
            let owner_id = &args[4];
            let req = ConfirmPlayRequest {
                game_id,
                confirms_seq: seq,
                idempotency_key: format!("confirm-{}-{}", game_id.0, seq),
                actor: owner_actor(owner_id),
            };
            core.confirm_play(req)
                .map(|r| serde_json::to_value(r).unwrap())
                .map_err(|e| format!("{:?}", e))
        }
        "resolve-judgment" => {
            if args.len() < 7 {
                return Err("Usage: dl resolve-judgment <game-id> <decision-id> <call-token> <call-label> <owner-id>".into());
            }
            let game_id = GameId(args[2].parse::<u64>().map_err(|e| e.to_string())?);
            let decision_id = args[3].parse::<u64>().map_err(|e| e.to_string())?;
            let call_token = &args[4];
            let call_label = &args[5];
            let owner_id = &args[6];
            let req = ResolveJudgmentRequest {
                game_id,
                decision_id,
                chosen: Call {
                    token: call_token.clone(),
                    label: call_label.clone(),
                },
                idempotency_key: format!("resolve-{}-{}", game_id.0, decision_id),
                actor: owner_actor(owner_id),
            };
            core.resolve_judgment(req)
                .map(|r| serde_json::to_value(r).unwrap())
                .map_err(|e| format!("{:?}", e))
        }
        "finalize" => {
            if args.len() < 4 {
                return Err("Usage: dl finalize <game-id> <owner-id>".into());
            }
            let game_id = GameId(args[2].parse::<u64>().map_err(|e| e.to_string())?);
            let owner_id = &args[3];
            let req = FinalizeRequest {
                game_id,
                mode: FinalizeMode::Final,
                idempotency_key: format!("finalize-{}", game_id.0),
                actor: owner_actor(owner_id),
            };
            core.finalize_scorecard(req)
                .map(|r| serde_json::to_value(r).unwrap())
                .map_err(|e| format!("{:?}", e))
        }
        "state" => {
            if args.len() < 3 {
                return Err("Usage: dl state <game-id>".into());
            }
            let game_id = GameId(args[2].parse::<u64>().map_err(|e| e.to_string())?);
            core.get_game_state(game_id)
                .map(|s| serde_json::to_value(s).unwrap())
                .map_err(|e| format!("{:?}", e))
        }
        "--help" | "-h" | "help" => {
            usage();
            std::process::exit(0);
        }
        other => Err(format!("Unknown command: {}. Use --help for usage.", other)),
    }
}

/// Simple monotonic counter for idempotency keys (MVP — not a real UUID).
fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    format!("{}", nanos)
}
