//! CLI game lineup: set, read back across processes, and parity (#177 U2, ADR-0020).
//!
//! Drives the real `dl` binary as separate processes sharing one `$DL_STATE_FILE`, like
//! `persistence.rs`. `dl new-game … --visitor-roster/--home-roster` stores a lineup through
//! `create_game`; `dl setup` reads it back; `dl replay-core --setup` must build the same one.

use std::path::PathBuf;
use std::process::{Command, Output};

/// The state file the pre-#177 CLI wrote for `dl new-game Hawks Owls owner-1`.
const PRE_LINEUP_SNAPSHOT: &str = include_str!("../../../core/tests/fixtures/pre-lineup-snapshot.json");

/// What the pre-#177 CLI printed for `dl new-game Hawks Owls owner-1`.
const PRE_LINEUP_NEW_GAME_STDOUT: &str = r#"{
  "game_id": 1,
  "state": {
    "active_fielders": [],
    "bases": {
      "first": null,
      "second": null,
      "third": null
    },
    "batting_index": [
      1,
      1
    ],
    "count": {
      "balls": 0,
      "strikes": 0
    },
    "half": "top",
    "inning": 1,
    "line_score": {
      "home": [],
      "visitor": []
    },
    "outs": 0,
    "pitch_sequence": []
  }
}
"#;

fn dl(state: &str, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_dl"))
        .current_dir(std::env::temp_dir())
        .env("DL_STATE_FILE", state)
        .args(args)
        .output()
        .expect("failed to run dl")
}

fn stdout(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).to_string()
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).to_string()
}

fn json(out: &Output) -> serde_json::Value {
    serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("stdout is not JSON ({e}): {}", stdout(out)))
}

/// A unique temp path per test run.
fn temp_path(tag: &str) -> String {
    let mut p: PathBuf = std::env::temp_dir();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    p.push(format!("dl-lineup-{tag}-{nanos}.json"));
    p.to_string_lossy().to_string()
}

#[test]
fn roster_flags_round_trip_through_a_separate_process() {
    let state = temp_path("roundtrip");
    let _ = std::fs::remove_file(&state);

    let out = dl(
        &state,
        &[
            "new-game",
            "Hawks",
            "Owls",
            "owner-1",
            "--visitor-roster",
            "Ana Ruiz, Ben Ortiz",
            "--home-roster",
            " Cy Park,,Dee Lang , ",
        ],
    );
    assert!(out.status.success(), "new-game failed: {}", stderr(&out));

    // A separate process reads the persisted lineup back.
    let out = dl(&state, &["setup", "1"]);
    assert!(out.status.success(), "setup failed: {}", stderr(&out));
    let setup = json(&out);
    assert_eq!(setup["game_id"], 1);
    assert_eq!(setup["visitor"]["name"], "Owls");
    assert_eq!(
        setup["visitor"]["lineup"],
        serde_json::json!([
            {"batting_order": 1, "name": "Ana Ruiz"},
            {"batting_order": 2, "name": "Ben Ortiz"}
        ])
    );
    // Split on ',', trim, drop empties, number 1..=N in order (dl-score --roster).
    assert_eq!(
        setup["home"]["lineup"],
        serde_json::json!([
            {"batting_order": 1, "name": "Cy Park"},
            {"batting_order": 2, "name": "Dee Lang"}
        ])
    );

    let _ = std::fs::remove_file(&state);
}

#[test]
fn one_roster_flag_leaves_the_other_team_without_a_lineup() {
    let state = temp_path("oneside");
    let _ = std::fs::remove_file(&state);

    let out = dl(&state, &["new-game", "Hawks", "Owls", "owner-1", "--visitor-roster", "Ana"]);
    assert!(out.status.success(), "new-game failed: {}", stderr(&out));
    let setup = json(&dl(&state, &["setup", "1"]));
    assert!(setup["home"].get("lineup").is_none(), "home lineup should be absent: {setup}");
    assert_eq!(setup["visitor"]["lineup"][0]["name"], "Ana");

    let _ = std::fs::remove_file(&state);
}

#[test]
fn pre_lineup_state_file_loads_and_reads_back_without_lineups() {
    let state = temp_path("oldfile");
    std::fs::write(&state, PRE_LINEUP_SNAPSHOT).unwrap();

    let out = dl(&state, &["setup", "1"]);
    assert!(out.status.success(), "setup on an old state file failed: {}", stderr(&out));
    let setup = json(&out);
    assert_eq!(setup["home"]["name"], "Hawks");
    assert_eq!(setup["visitor"]["name"], "Owls");
    assert!(setup["home"].get("lineup").is_none(), "home lineup should be absent: {setup}");
    assert!(setup["visitor"].get("lineup").is_none(), "visitor lineup should be absent: {setup}");
    // `setup` is a read: the state file is untouched.
    assert_eq!(std::fs::read_to_string(&state).unwrap(), PRE_LINEUP_SNAPSHOT);

    let _ = std::fs::remove_file(&state);
}

#[test]
fn setup_of_an_unknown_game_is_not_found() {
    let state = temp_path("unknown");
    let _ = std::fs::remove_file(&state);
    let out = dl(&state, &["setup", "7"]);
    assert!(!out.status.success(), "setup of a missing game should fail: {}", stdout(&out));
    assert!(stderr(&out).contains("\"not_found\""), "expected not_found: {}", stderr(&out));
}

#[test]
fn an_invalid_name_is_rejected_by_the_core_and_changes_no_state() {
    let state = temp_path("invalid");
    std::fs::write(&state, PRE_LINEUP_SNAPSHOT).unwrap();
    let long_name = "x".repeat(61);

    let out = dl(
        &state,
        &["new-game", "Rays", "Cubs", "owner-1", "--home-roster", &format!("Ana,{long_name}")],
    );
    assert!(!out.status.success(), "a 61-char name must be rejected: {}", stdout(&out));
    assert!(stdout(&out).is_empty(), "no result on rejection: {}", stdout(&out));
    // The core's structured error, as JSON: code, team, slot and field.
    let err = stderr(&out);
    let body = err.trim().strip_prefix("Error: ").unwrap_or_else(|| panic!("stderr: {err}"));
    let e: serde_json::Value = serde_json::from_str(body).unwrap_or_else(|x| panic!("{x}: {err}"));
    assert_eq!(e["code"], "invalid_argument", "{err}");
    let details = e["details"].to_string();
    for want in [r#""team""#, r#""home""#, r#""slot_index""#, r#""1""#, r#""name""#] {
        assert!(details.contains(want), "details missing {want}: {err}");
    }
    assert_eq!(
        std::fs::read_to_string(&state).unwrap(),
        PRE_LINEUP_SNAPSHOT,
        "a rejected new-game must not change the state file"
    );

    // With no state file yet, a rejection must not create one.
    let fresh = temp_path("invalid-fresh");
    let _ = std::fs::remove_file(&fresh);
    let out = dl(&fresh, &["new-game", "Rays", "Cubs", "owner-1", "--visitor-roster", &long_name]);
    assert!(!out.status.success());
    assert!(!std::path::Path::new(&fresh).exists(), "a rejected new-game wrote a state file");

    let _ = std::fs::remove_file(&state);
}

#[test]
fn malformed_roster_flags_are_usage_errors() {
    let state = temp_path("usage");
    let _ = std::fs::remove_file(&state);
    for args in [
        &["new-game", "Hawks", "Owls", "owner-1", "--visitor-roster"][..],
        &["new-game", "Hawks", "Owls", "owner-1", "--roster", "Ana"][..],
        &["new-game", "Hawks", "Owls", "owner-1", "extra"][..],
        &["new-game", "Hawks", "Owls", "owner-1", "--home-roster", "A", "--home-roster", "B"][..],
    ] {
        let out = dl(&state, args);
        assert!(!out.status.success(), "{args:?} should fail: {}", stdout(&out));
        assert!(!std::path::Path::new(&state).exists(), "{args:?} wrote a state file");
    }
}

#[test]
fn new_game_without_roster_flags_is_byte_identical_to_before() {
    let state = temp_path("noflags");
    let _ = std::fs::remove_file(&state);

    let out = dl(&state, &["new-game", "Hawks", "Owls", "owner-1"]);
    assert!(out.status.success(), "new-game failed: {}", stderr(&out));
    assert_eq!(stdout(&out), PRE_LINEUP_NEW_GAME_STDOUT);
    assert_eq!(std::fs::read_to_string(&state).unwrap(), PRE_LINEUP_SNAPSHOT);

    let _ = std::fs::remove_file(&state);
}

/// `replay-core --setup` must build the same lineup as the persisted CLI path, and the
/// comparison must be able to fail: a replay op that omits the roster differs.
#[test]
fn replay_core_setup_matches_the_cli_and_can_diverge() {
    let state = temp_path("parity");
    let _ = std::fs::remove_file(&state);
    let roster = "Ana Ruiz, Ben Ortiz";
    let out = dl(&state, &["new-game", "Hawks", "Owls", "owner-1", "--visitor-roster", roster]);
    assert!(out.status.success(), "new-game failed: {}", stderr(&out));
    let cli_setup = stdout(&dl(&state, &["setup", "1"]));

    let replay = |ops: serde_json::Value| {
        let path = temp_path("ops");
        std::fs::write(&path, ops.to_string()).unwrap();
        let out = dl(&temp_path("unused"), &["replay-core", "--setup", &path]);
        let _ = std::fs::remove_file(&path);
        out
    };

    let with_roster = replay(serde_json::json!([
        {"op": "new-game", "home": "Hawks", "visitor": "Owls", "owner": "owner-1",
         "visitor_roster": roster}
    ]));
    assert!(with_roster.status.success(), "replay failed: {}", stderr(&with_roster));
    assert_eq!(stdout(&with_roster), cli_setup, "replay-core --setup diverged from dl setup");

    let without_roster = replay(serde_json::json!([
        {"op": "new-game", "home": "Hawks", "visitor": "Owls", "owner": "owner-1"}
    ]));
    assert!(without_roster.status.success(), "replay failed: {}", stderr(&without_roster));
    assert_ne!(stdout(&without_roster), cli_setup, "the setup comparison cannot go red");

    // The replay path runs the same core validation.
    let invalid = replay(serde_json::json!([
        {"op": "new-game", "home": "Hawks", "visitor": "Owls", "owner": "owner-1",
         "home_roster": "x".repeat(61)}
    ]));
    assert!(!invalid.status.success(), "replay accepted a 61-char name");
    assert!(stderr(&invalid).contains("\"invalid_argument\""), "{}", stderr(&invalid));

    let _ = std::fs::remove_file(&state);
}

/// The core error envelope behind a failed command's `Error: ` prefix on stderr.
fn error_json(out: &Output) -> serde_json::Value {
    let err = stderr(out);
    let body = err.trim().strip_prefix("Error: ").unwrap_or_else(|| panic!("stderr: {err}"));
    serde_json::from_str(body).unwrap_or_else(|x| panic!("stderr is not a JSON error ({x}): {err}"))
}

/// Every command reports a core error as the same parseable JSON envelope, not just
/// `new-game` and `setup` (Art. I).
#[test]
fn older_commands_report_core_errors_as_json() {
    let state = temp_path("errjson");
    let _ = std::fs::remove_file(&state);
    for args in [
        &["state", "999"][..],
        &["confirm-play", "999", "1", "owner-1"][..],
        &["finalize", "999", "owner-1"][..],
    ] {
        let out = dl(&state, args);
        assert!(!out.status.success(), "{args:?} should fail: {}", stdout(&out));
        assert_eq!(error_json(&out)["code"], "not_found", "{args:?}");
    }
}

/// `N:` prefixes give explicit batting orders, gaps kept, on both the CLI and replay paths.
#[test]
fn prefixed_roster_keeps_gapped_batting_orders() {
    let state = temp_path("gapped");
    let _ = std::fs::remove_file(&state);
    let roster = "1:Ana Ruiz, 2: Ben Ortiz ,5:Cara Diaz";
    let out = dl(&state, &["new-game", "Hawks", "Owls", "owner-1", "--home-roster", roster]);
    assert!(out.status.success(), "new-game failed: {}", stderr(&out));
    let out = dl(&state, &["setup", "1"]);
    assert_eq!(
        json(&out)["home"]["lineup"],
        serde_json::json!([
            {"batting_order": 1, "name": "Ana Ruiz"},
            {"batting_order": 2, "name": "Ben Ortiz"},
            {"batting_order": 5, "name": "Cara Diaz"}
        ])
    );

    let ops = temp_path("gapped-ops");
    let op = serde_json::json!([
        {"op": "new-game", "home": "Hawks", "visitor": "Owls", "owner": "owner-1",
         "home_roster": roster}
    ]);
    std::fs::write(&ops, op.to_string()).unwrap();
    let replay = dl(&temp_path("unused"), &["replay-core", "--setup", &ops]);
    assert!(replay.status.success(), "replay failed: {}", stderr(&replay));
    assert_eq!(stdout(&replay), stdout(&out), "replay-core --setup diverged from dl setup");

    let _ = std::fs::remove_file(&ops);
    let _ = std::fs::remove_file(&state);
}

/// A name with a colon is a name unless it starts with `digits:`.
#[test]
fn a_colon_in_an_unprefixed_name_is_kept() {
    let state = temp_path("colon");
    let _ = std::fs::remove_file(&state);
    let out = dl(
        &state,
        &["new-game", "Hawks", "Owls", "owner-1", "--visitor-roster", "Ana: The Great, B2:Ben"],
    );
    assert!(out.status.success(), "new-game failed: {}", stderr(&out));
    assert_eq!(
        json(&dl(&state, &["setup", "1"]))["visitor"]["lineup"],
        serde_json::json!([
            {"batting_order": 1, "name": "Ana: The Great"},
            {"batting_order": 2, "name": "B2:Ben"}
        ])
    );
    let _ = std::fs::remove_file(&state);
}

/// Mixed or out-of-range prefixes are usage errors that name the item, never its value,
/// and write nothing; an in-range order the core rejects is the core's JSON error.
#[test]
fn bad_batting_order_prefixes_are_usage_errors() {
    let state = temp_path("prefix");
    let _ = std::fs::remove_file(&state);
    for roster in ["1:Ana Ruiz, Ben Ortiz", "Ana Ruiz, 2:Ben Ortiz", "0:Ana Ruiz", "256:Ana Ruiz",
                   "99999999999999999999:Ana Ruiz"] {
        let out = dl(&state, &["new-game", "Hawks", "Owls", "owner-1", "--home-roster", roster]);
        assert!(!out.status.success(), "{roster:?} should fail: {}", stdout(&out));
        let err = stderr(&out);
        assert!(err.contains("--home-roster"), "{roster:?}: {err}");
        assert!(!err.contains("Ana") && !err.contains("Ben"), "{roster:?} echoed a name: {err}");
        assert!(!std::path::Path::new(&state).exists(), "{roster:?} wrote a state file");
    }

    let out = dl(&state, &["new-game", "Hawks", "Owls", "owner-1", "--home-roster", "21:Ana Ruiz"]);
    assert_eq!(error_json(&out)["code"], "invalid_argument");
    assert!(!std::path::Path::new(&state).exists(), "a rejected lineup wrote a state file");

    // The replay path shares the parser.
    let ops = temp_path("prefix-ops");
    let op = serde_json::json!([
        {"op": "new-game", "home": "Hawks", "visitor": "Owls", "owner": "owner-1",
         "visitor_roster": "1:Ana Ruiz, Ben Ortiz"}
    ]);
    std::fs::write(&ops, op.to_string()).unwrap();
    let out = dl(&temp_path("unused"), &["replay-core", "--setup", &ops]);
    assert!(!out.status.success(), "replay accepted a mixed roster");
    let err = stderr(&out);
    assert!(err.contains("visitor_roster") && !err.contains("Ana"), "{err}");
    let _ = std::fs::remove_file(&ops);
}

/// Usage errors say where the bad argument was, not what it was: a stray argument may be
/// a player's name (FR-029).
#[test]
fn usage_errors_do_not_echo_argument_values() {
    let state = temp_path("echo");
    let _ = std::fs::remove_file(&state);
    for args in [
        &["new-game", "Hawks", "Owls", "owner-1", "Ana Ruiz"][..],
        &["new-game", "Hawks", "Owls", "owner-1", "--home-roster", "Cy", "Ana Ruiz"][..],
        &["Ana Ruiz"][..],
    ] {
        let out = dl(&state, args);
        assert!(!out.status.success(), "{args:?} should fail: {}", stdout(&out));
        assert!(!stderr(&out).contains("Ana"), "{args:?} echoed a value: {}", stderr(&out));
    }
}

/// The state file holds player names, so it is owner-only, even when it replaces a
/// file that was not.
#[cfg(unix)]
#[test]
fn state_file_is_owner_only() {
    use std::os::unix::fs::PermissionsExt;

    let state = temp_path("perms");
    std::fs::write(&state, PRE_LINEUP_SNAPSHOT).unwrap();
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o644)).unwrap();
    let out = dl(&state, &["new-game", "Rays", "Cubs", "owner-1", "--home-roster", "Ana Ruiz"]);
    assert!(out.status.success(), "new-game failed: {}", stderr(&out));
    let mode = std::fs::metadata(&state).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "state file mode {mode:o}");

    let fresh = temp_path("perms-fresh");
    let _ = std::fs::remove_file(&fresh);
    let out = dl(&fresh, &["new-game", "Rays", "Cubs", "owner-1"]);
    assert!(out.status.success(), "new-game failed: {}", stderr(&out));
    let mode = std::fs::metadata(&fresh).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "fresh state file mode {mode:o}");

    let _ = std::fs::remove_file(&state);
    let _ = std::fs::remove_file(&fresh);
}
