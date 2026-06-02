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
use std::path::PathBuf;

use dl_core::ffi::{
    Actor, ActorKind, Call, ConfirmPlayRequest, CoreApi, CreateGameRequest,
    FinalizeMode, FinalizeRequest, GameId, PlayInput, RecordPlayRequest,
    ResolveJudgmentRequest, Team,
};
use dl_core::model::NormalizedPlay;
use dl_core::primitives::{CoreSnapshot, DiamondCore};

/// Where the CLI persists its event log between invocations (#128).
///
/// The `dl` CLI is otherwise stateless per process; persisting the append-only event log
/// to this file lets a game be built across separate `dl` commands (new-game → record →
/// confirm → … → finalize). Override with `$DL_STATE_FILE`; defaults to `./.dl-state.json`.
/// The log stays append-only — load, then the primitive appends; nothing is rewritten (I6).
fn state_file() -> PathBuf {
    env::var_os("DL_STATE_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(".dl-state.json"))
}

/// Load a persisted core, or a fresh one if no state file exists yet.
fn load_core() -> Result<DiamondCore, String> {
    let path = state_file();
    match std::fs::read_to_string(&path) {
        Ok(text) => {
            let snap: CoreSnapshot = serde_json::from_str(&text)
                .map_err(|e| format!("corrupt state file {}: {e}", path.display()))?;
            Ok(DiamondCore::restore(snap))
        }
        Err(ref e) if e.kind() == std::io::ErrorKind::NotFound => Ok(DiamondCore::new()),
        Err(e) => Err(format!("cannot read state file {}: {e}", path.display())),
    }
}

/// Persist the core's snapshot back to the state file (after a mutating command).
fn save_core(core: &DiamondCore) -> Result<(), String> {
    let path = state_file();
    let text = serde_json::to_string_pretty(&core.snapshot())
        .map_err(|e| format!("cannot serialize state: {e}"))?;
    std::fs::write(&path, text).map_err(|e| format!("cannot write state file {}: {e}", path.display()))
}

/// Commands that mutate the event log and therefore must persist afterward.
fn is_mutating(cmd: &str) -> bool {
    matches!(
        cmd,
        "new-game" | "record-play" | "confirm-play" | "resolve-judgment" | "finalize"
    )
}

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

    // #128: load any persisted game state so a game can be built across invocations.
    let core = match load_core() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    };

    let cmd = args[1].clone();
    match run(&core, &args) {
        Ok(json) => {
            // Persist AFTER a successful mutating command (append-only log; I6).
            if is_mutating(&cmd) {
                if let Err(e) = save_core(&core) {
                    eprintln!("Error: {}", e);
                    std::process::exit(1);
                }
            }
            println!("{}", serde_json::to_string_pretty(&json).unwrap());
        }
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
        // replay-core <ops.json> — the UI/core-path reference for parity (SC-008/T040).
        //
        // Runs a sequence of normalized operations through a FRESH in-memory `DiamondCore`
        // (no persistence) — exactly what the UniFFI/iOS UI path invokes — and prints the
        // final `GameState`. parity.sh compares this against the persisted multi-invocation
        // CLI/agent path for the same facts: byte-identical output proves SC-008 parity.
        "replay-core" => {
            if args.len() < 3 {
                return Err("Usage: dl replay-core <ops.json>".into());
            }
            let ops_text = std::fs::read_to_string(&args[2])
                .map_err(|e| format!("cannot read ops file {}: {e}", args[2]))?;
            let fresh = DiamondCore::new();
            replay_ops(&fresh, &ops_text)
        }
        "--help" | "-h" | "help" => {
            usage();
            std::process::exit(0);
        }
        other => Err(format!("Unknown command: {}. Use --help for usage.", other)),
    }
}

/// One operation in a `replay-core` ops file (the normalized agent/CLI op stream).
#[derive(serde::Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum ReplayOp {
    NewGame { home: String, visitor: String, owner: String },
    RecordPlay { game_id: u64, play: NormalizedPlay, owner: String },
    ConfirmPlay { game_id: u64, seq: u64, owner: String },
}

/// Replay an ops stream through `core` and return the final state of the last game touched.
fn replay_ops(core: &DiamondCore, ops_text: &str) -> Result<serde_json::Value, String> {
    let ops: Vec<ReplayOp> =
        serde_json::from_str(ops_text).map_err(|e| format!("invalid ops JSON: {e}"))?;
    let mut last_game: Option<GameId> = None;
    for (i, op) in ops.into_iter().enumerate() {
        match op {
            ReplayOp::NewGame { home, visitor, owner } => {
                let r = core
                    .create_game(CreateGameRequest {
                        home: Team { id: home.to_lowercase().replace(' ', "_"), name: home, lineup: None },
                        visitor: Team {
                            id: visitor.to_lowercase().replace(' ', "_"),
                            name: visitor,
                            lineup: None,
                        },
                        idempotency_key: format!("replay-new-{i}"),
                        actor: owner_actor(&owner),
                    })
                    .map_err(|e| format!("op {i} new-game: {e:?}"))?;
                last_game = Some(r.game_id);
            }
            ReplayOp::RecordPlay { game_id, play, owner } => {
                core.record_play(RecordPlayRequest {
                    game_id: GameId(game_id),
                    input: PlayInput::Normalized(play),
                    idempotency_key: format!("replay-rec-{i}"),
                    actor: owner_actor(&owner),
                })
                .map_err(|e| format!("op {i} record-play: {e:?}"))?;
                last_game = Some(GameId(game_id));
            }
            ReplayOp::ConfirmPlay { game_id, seq, owner } => {
                core.confirm_play(ConfirmPlayRequest {
                    game_id: GameId(game_id),
                    confirms_seq: seq,
                    idempotency_key: format!("replay-con-{i}"),
                    actor: owner_actor(&owner),
                })
                .map_err(|e| format!("op {i} confirm-play: {e:?}"))?;
                last_game = Some(GameId(game_id));
            }
        }
    }
    let gid = last_game.ok_or("ops stream was empty")?;
    core.get_game_state(gid)
        .map(|s| serde_json::to_value(s).unwrap())
        .map_err(|e| format!("{e:?}"))
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
