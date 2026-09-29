//! Diamond Ledger CLI adapter (T038 — agent-parity surface).
//!
//! The CLI is a thin client over dl-core's four atomic primitives, providing
//! agent-native parity (Art. II/FR-018): the same capabilities invokable from the
//! command line as from the iOS app.
//!
//! Usage:
//!   dl new-game <home-name> <visitor-name> <owner-id> [--visitor-roster <list>] [--home-roster <list>]
//!   dl record-play <game-id> <normalized-play-json> <owner-id>
//!   dl confirm-play <game-id> <seq> <owner-id>
//!   dl resolve-judgment <game-id> <decision-id> <call-token> <call-label> <owner-id>
//!   dl finalize <game-id> <owner-id>
//!   dl state <game-id>
//!   dl setup <game-id>

use std::env;
use std::io::Write;
use std::path::{Path, PathBuf};

use dl_core::ffi::{
    Actor, ActorKind, Call, ConfirmPlayRequest, CoreApi, CorrectEventRequest, CreateGameRequest,
    FinalizeMode, FinalizeRequest, GameId, LineupSlot, PlayInput, RecordPlayRequest,
    ResolveJudgmentRequest, Seq, Team,
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
///
/// Write is **atomic**: the snapshot is written to a temp file in the SAME directory,
/// then `rename`d onto the final path. On POSIX `rename` within a directory is atomic,
/// so a crash mid-write leaves the prior state intact rather than a truncated/corrupt
/// log (the append-only invariant must never be observable as half-written, I6).
fn save_core(core: &DiamondCore) -> Result<(), String> {
    let path = state_file();
    let text = serde_json::to_string_pretty(&core.snapshot())
        .map_err(|e| format!("cannot serialize state: {e}"))?;

    // Temp file in the SAME directory as the target (rename is only atomic within a
    // filesystem; a same-dir temp guarantees that). Unique-enough name via uuid_like().
    let dir = path.parent().filter(|p| !p.as_os_str().is_empty());
    let tmp = match dir {
        Some(d) => d.join(format!(".dl-state.tmp.{}", uuid_like())),
        None => PathBuf::from(format!(".dl-state.tmp.{}", uuid_like())),
    };

    write_owner_only(&tmp, text.as_bytes())
        .map_err(|e| format!("cannot write temp state file {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &path).map_err(|e| {
        // Best-effort cleanup so a failed rename doesn't leak the temp file.
        let _ = std::fs::remove_file(&tmp);
        format!("cannot atomically replace state file {}: {e}", path.display())
    })
}

/// Create `path` and write `bytes` to it, readable and writable by the owner only (0600 on
/// Unix): the state file holds player names, which stay local (ADR-0020, FR-029). The mode
/// is set at creation, so the temp file is never briefly readable by others; the rename in
/// [`save_core`] carries it onto the state file, replacing any looser file that was there.
fn write_owner_only(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)?.write_all(bytes)
}

/// Commands that mutate the event log and therefore must persist afterward.
fn is_mutating(cmd: &str) -> bool {
    matches!(
        cmd,
        "new-game"
            | "record-play"
            | "confirm-play"
            | "resolve-judgment"
            | "correct-event"
            | "finalize"
    )
}

fn owner_actor(id: &str) -> Actor {
    Actor {
        kind: ActorKind::Human,
        id: id.into(),
        harness_version: None,
    }
}

/// A team named `name`, with the lineup parsed from an optional roster list.
///
/// Shared by `new-game` and the `replay-core` new-game op, so both paths build the same
/// `Team` and the core's `create_game` validation decides for both (ADR-0020 KTD2). An
/// unparseable roster is an error naming the entry, never its text (the caller adds which
/// roster).
fn team(name: &str, roster: Option<&str>) -> Result<Team, String> {
    Ok(Team {
        id: name.to_lowercase().replace(' ', "_"),
        name: name.to_string(),
        lineup: roster.map(roster_lineup).transpose()?.filter(|slots| !slots.is_empty()),
    })
}

/// Parse a comma-separated roster into batting-order slots: split on `,`, trim, drop empties.
///
/// Unnumbered names get batting orders `1..=N` in order, matching `dl-score --roster`. An
/// entry that starts with digits and a colon (`5:Cara Diaz`, spaces allowed around the
/// digits) gives its batting order explicitly, so a lineup can keep gaps (`1, 2, 5`) the
/// way the app sends it. Either every entry is numbered or none is. A name that itself
/// starts with `digits:` must therefore be numbered explicitly (`1:12:30 Club`); any
/// other colon is part of the name.
///
/// Names and the batting-order range (`1..=20`, increasing) are validated by the core, not
/// here. A number that is not an integer `1..=255` is an error here. An unnumbered list
/// longer than `u8::MAX` saturates its batting orders, which the core's 20-slot limit
/// rejects rather than this silently renumbering.
fn roster_lineup(list: &str) -> Result<Vec<LineupSlot>, String> {
    let entries: Vec<&str> = list.split(',').map(str::trim).filter(|e| !e.is_empty()).collect();
    let numbered = entries.iter().filter(|e| batting_order_prefix(e).is_some()).count();
    if numbered != 0 && numbered != entries.len() {
        return Err("numbers some entries (N:name) but not others; number all or none".into());
    }
    entries
        .iter()
        .enumerate()
        .map(|(i, entry)| {
            let (batting_order, name) = match batting_order_prefix(entry) {
                Some((order, name)) => {
                    let order = order.parse::<u8>().ok().filter(|o| *o >= 1).ok_or_else(|| {
                        format!("entry {}: batting order must be an integer 1..=255", i + 1)
                    })?;
                    (order, name.trim())
                }
                None => (u8::try_from(i + 1).unwrap_or(u8::MAX), *entry),
            };
            Ok(LineupSlot { batting_order, name: name.to_string(), player_id: None, field_pos: None })
        })
        .collect()
}

/// The `(digits, name)` of a roster entry numbered as `N:name`, or `None` if unnumbered.
fn batting_order_prefix(entry: &str) -> Option<(&str, &str)> {
    let (order, name) = entry.split_once(':')?;
    let order = order.trim();
    (!order.is_empty() && order.bytes().all(|b| b.is_ascii_digit())).then_some((order, name))
}

/// A core error as its structured JSON envelope (code, message, details), so a caller can
/// branch on `code` rather than parse prose (Art. I).
fn core_error(e: dl_core::ffi::Error) -> String {
    serde_json::to_string(&e).unwrap_or_else(|_| format!("{e:?}"))
}

fn usage() {
    eprintln!("Diamond Ledger CLI (dl)");
    eprintln!("Usage:");
    eprintln!("  dl new-game <home-name> <visitor-name> <owner-id> [--visitor-roster <list>] [--home-roster <list>]");
    eprintln!("      <list> is comma-separated names, batting 1..N in order (\"Ana Ruiz, Ben Ortiz\"),");
    eprintln!("      or every name numbered with its batting order (\"1:Ana Ruiz, 2:Ben Ortiz, 5:Cara Diaz\")");
    eprintln!("  dl record-play <game-id> <normalized-play-json> <owner-id>");
    eprintln!("  dl confirm-play <game-id> <seq> <owner-id>");
    eprintln!("  dl resolve-judgment <game-id> <decision-id> <call-token> <call-label> <owner-id>");
    eprintln!("  dl correct-event <game-id> <corrects-seq> <amended-play-json> <owner-id>");
    eprintln!("  dl finalize <game-id> <owner-id>");
    eprintln!("  dl state <game-id>");
    eprintln!("  dl setup <game-id>");
    eprintln!("  dl replay-core [--setup] <ops.json>");
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
            const USAGE: &str = "Usage: dl new-game <home-name> <visitor-name> <owner-id> \
                                 [--visitor-roster <list>] [--home-roster <list>]";
            if args.len() < 5 {
                return Err(USAGE.into());
            }
            let home_name = &args[2];
            let visitor_name = &args[3];
            let owner_id = &args[4];
            // Optional trailing roster flags, each taking one comma-separated value. Errors
            // name the argument's position, never its text: it may be a player's name.
            let (mut home_roster, mut visitor_roster) = (None, None);
            let mut flags = args.iter().enumerate().skip(5);
            while let Some((position, flag)) = flags.next() {
                let slot = match flag.as_str() {
                    "--home-roster" => &mut home_roster,
                    "--visitor-roster" => &mut visitor_roster,
                    _ => {
                        return Err(format!(
                            "new-game argument {position} is not --home-roster or --visitor-roster. {USAGE}"
                        ))
                    }
                };
                let (_, value) =
                    flags.next().ok_or_else(|| format!("{flag} requires a value. {USAGE}"))?;
                if slot.replace(value.as_str()).is_some() {
                    return Err(format!("{flag} given more than once. {USAGE}"));
                }
            }
            let req = CreateGameRequest {
                home: team(home_name, home_roster).map_err(|e| format!("--home-roster {e}"))?,
                visitor: team(visitor_name, visitor_roster)
                    .map_err(|e| format!("--visitor-roster {e}"))?,
                idempotency_key: format!("new-{}-{}", home_name, visitor_name),
                actor: owner_actor(owner_id),
            };
            core.create_game(req)
                .map(|r| serde_json::to_value(r).unwrap())
                .map_err(core_error)
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
                .map_err(core_error)
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
                confirms_seq: Seq(seq),
                idempotency_key: format!("confirm-{}-{}", game_id.0, seq),
                actor: owner_actor(owner_id),
            };
            core.confirm_play(req)
                .map(|r| serde_json::to_value(r).unwrap())
                .map_err(core_error)
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
                .map_err(core_error)
        }
        "correct-event" => {
            // Amend a prior play (US4 / FR-012–014). Append-only: this emits an
            // EventCorrected referencing <corrects-seq> and re-projects downstream state;
            // the original recorded play is never mutated. Agent/CLI parity (Art. II).
            if args.len() < 6 {
                return Err(
                    "Usage: dl correct-event <game-id> <corrects-seq> <amended-play-json> <owner-id>"
                        .into(),
                );
            }
            let game_id = GameId(args[2].parse::<u64>().map_err(|e| e.to_string())?);
            let corrects_seq = args[3].parse::<u64>().map_err(|e| e.to_string())?;
            let play_json = &args[4];
            let owner_id = &args[5];
            let play: NormalizedPlay = serde_json::from_str(play_json)
                .map_err(|e| format!("Invalid amended play JSON: {}", e))?;
            let req = CorrectEventRequest {
                game_id,
                corrects_seq: Seq(corrects_seq),
                amended: PlayInput::Normalized(play),
                idempotency_key: format!("correct-{}-{}-{}", game_id.0, corrects_seq, uuid_like()),
                actor: owner_actor(owner_id),
            };
            core.correct_event(req)
                .map(|r| serde_json::to_value(r).unwrap())
                .map_err(core_error)
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
                .map_err(core_error)
        }
        "state" => {
            if args.len() < 3 {
                return Err("Usage: dl state <game-id>".into());
            }
            let game_id = GameId(args[2].parse::<u64>().map_err(|e| e.to_string())?);
            core.get_game_state(game_id)
                .map(|s| serde_json::to_value(s).unwrap())
                .map_err(core_error)
        }
        // setup <game-id> — the teams and lineups the game was started with (#177, ADR-0020).
        "setup" => {
            if args.len() < 3 {
                return Err("Usage: dl setup <game-id>".into());
            }
            let game_id = GameId(args[2].parse::<u64>().map_err(|e| e.to_string())?);
            core.get_game_setup(game_id)
                .map(|s| serde_json::to_value(s).unwrap())
                .map_err(core_error)
        }
        // replay-core [--setup] <ops.json> — the UI/core-path reference for parity (SC-008/T040).
        //
        // Runs a sequence of normalized operations through a FRESH in-memory `DiamondCore`
        // (no persistence) — exactly what the UniFFI/iOS UI path invokes — and prints the
        // final `GameState`. parity.sh compares this against the persisted multi-invocation
        // CLI/agent path for the same facts: byte-identical output proves SC-008 parity.
        // With `--setup` it prints the last game's `GameSetup` instead, in the same process
        // (the fresh core is gone afterwards), for parity.sh's lineup diff against `dl setup`.
        "replay-core" => {
            let (setup, ops_path) = match args.get(2).map(String::as_str) {
                Some("--setup") => (true, args.get(3)),
                _ => (false, args.get(2)),
            };
            let ops_path = ops_path.ok_or("Usage: dl replay-core [--setup] <ops.json>")?;
            let ops_text = std::fs::read_to_string(ops_path)
                .map_err(|e| format!("cannot read ops file {ops_path}: {e}"))?;
            let fresh = DiamondCore::new();
            let gid = replay_ops(&fresh, &ops_text)?;
            if setup {
                fresh.get_game_setup(gid).map(|s| serde_json::to_value(s).unwrap())
            } else {
                fresh.get_game_state(gid).map(|s| serde_json::to_value(s).unwrap())
            }
            .map_err(core_error)
        }
        "--help" | "-h" | "help" => {
            usage();
            std::process::exit(0);
        }
        // Not echoed: a mistyped command line may carry a player's name.
        _ => Err("Unknown command. Use --help for usage.".into()),
    }
}

/// One operation in a `replay-core` ops file (the normalized agent/CLI op stream).
#[derive(serde::Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum ReplayOp {
    NewGame {
        home: String,
        visitor: String,
        owner: String,
        /// Optional comma-separated rosters, parsed exactly like `new-game`'s flags.
        #[serde(default)]
        home_roster: Option<String>,
        #[serde(default)]
        visitor_roster: Option<String>,
    },
    RecordPlay { game_id: u64, play: NormalizedPlay, owner: String },
    ConfirmPlay { game_id: u64, seq: u64, owner: String },
}

/// Replay an ops stream through `core` and return the id of the last game touched.
fn replay_ops(core: &DiamondCore, ops_text: &str) -> Result<GameId, String> {
    let ops: Vec<ReplayOp> =
        serde_json::from_str(ops_text).map_err(|e| format!("invalid ops JSON: {e}"))?;
    let mut last_game: Option<GameId> = None;
    for (i, op) in ops.into_iter().enumerate() {
        match op {
            ReplayOp::NewGame { home, visitor, owner, home_roster, visitor_roster } => {
                let r = core
                    .create_game(CreateGameRequest {
                        home: team(&home, home_roster.as_deref())
                            .map_err(|e| format!("op {i} new-game: home_roster {e}"))?,
                        visitor: team(&visitor, visitor_roster.as_deref())
                            .map_err(|e| format!("op {i} new-game: visitor_roster {e}"))?,
                        idempotency_key: format!("replay-new-{i}"),
                        actor: owner_actor(&owner),
                    })
                    .map_err(|e| format!("op {i} new-game: {}", core_error(e)))?;
                last_game = Some(r.game_id);
            }
            ReplayOp::RecordPlay { game_id, play, owner } => {
                core.record_play(RecordPlayRequest {
                    game_id: GameId(game_id),
                    input: PlayInput::Normalized(play),
                    idempotency_key: format!("replay-rec-{i}"),
                    actor: owner_actor(&owner),
                })
                .map_err(|e| format!("op {i} record-play: {}", core_error(e)))?;
                last_game = Some(GameId(game_id));
            }
            ReplayOp::ConfirmPlay { game_id, seq, owner } => {
                core.confirm_play(ConfirmPlayRequest {
                    game_id: GameId(game_id),
                    confirms_seq: Seq(seq),
                    idempotency_key: format!("replay-con-{i}"),
                    actor: owner_actor(&owner),
                })
                .map_err(|e| format!("op {i} confirm-play: {}", core_error(e)))?;
                last_game = Some(GameId(game_id));
            }
        }
    }
    last_game.ok_or_else(|| "ops stream was empty".to_string())
}

/// A collision-resistant token for idempotency keys / temp filenames (MVP — not a real UUID).
///
/// Combines the FULL nanosecond timestamp since the epoch with a process-wide atomic
/// counter, so two calls in the same nanosecond (rapid successive commands) still get
/// distinct tokens — `subsec_nanos()` alone collides on coarse-resolution clocks and
/// would alias idempotency keys.
fn uuid_like() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{nanos}-{seq}")
}
