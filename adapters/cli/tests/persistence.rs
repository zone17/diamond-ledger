//! CLI cross-invocation persistence + parity smoke test (#128 / T040).
//!
//! Drives the real `dl` binary across SEPARATE processes (each `Command::new` is a fresh
//! invocation) sharing one `$DL_STATE_FILE`, proving a game can be built across commands
//! (the #128 capability) and that the persisted state replays deterministically.

use std::path::PathBuf;
use std::process::Command;

fn dl() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_dl"));
    c.current_dir(std::env::temp_dir());
    c
}

fn run(state: &str, args: &[&str]) -> (String, bool) {
    let out = dl()
        .env("DL_STATE_FILE", state)
        .args(args)
        .output()
        .expect("failed to run dl");
    (
        String::from_utf8_lossy(&out.stdout).to_string(),
        out.status.success(),
    )
}

/// A unique temp state-file path per test run.
fn temp_state(tag: &str) -> String {
    let mut p: PathBuf = std::env::temp_dir();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    p.push(format!("dl-state-{tag}-{nanos}.json"));
    p.to_string_lossy().to_string()
}

const GROUNDOUT: &str = r#"{"situation":{"runners":{"first":null,"second":null,"third":null},"outs":0,"count":{"balls":0,"strikes":0},"batter_hand":"right"},"catalyst":{"batter_event":"fielded_out","fielders":[6,3],"ball_type":"ground","advances":[{"runner":1,"from":"home","to":"out","by_error":null}],"touched_or_misplayed_by":[]}}"#;

#[test]
fn game_persists_across_invocations() {
    let state = temp_state("persist");
    let _ = std::fs::remove_file(&state);

    // 1) new-game (process 1)
    let (out, ok) = run(&state, &["new-game", "Hawks", "Eagles", "owner-1"]);
    assert!(ok, "new-game failed: {out}");
    assert!(out.contains("\"game_id\": 1"), "expected game_id 1: {out}");

    // 2) record-play (process 2 — must SEE game 1 from the persisted state)
    let (out, ok) = run(&state, &["record-play", "1", GROUNDOUT, "owner-1"]);
    assert!(ok, "record-play failed (game not persisted?): {out}");
    assert!(out.contains("\"recorded_seq\""), "expected a recorded_seq: {out}");

    // 3) confirm-play (process 3)
    let (out, ok) = run(&state, &["confirm-play", "1", "1", "owner-1"]);
    assert!(ok, "confirm-play failed: {out}");

    // 4) state (process 4 — the confirmed out must be visible)
    let (out, ok) = run(&state, &["state", "1"]);
    assert!(ok, "state failed: {out}");
    assert!(out.contains("\"outs\": 1"), "confirmed out not persisted: {out}");

    let _ = std::fs::remove_file(&state);
}

#[test]
fn record_play_without_persisted_game_is_an_error() {
    // A fresh state file with no game → record-play on game 1 must fail (NotFound),
    // proving the CLI is NOT silently fabricating a game.
    let state = temp_state("nogame");
    let _ = std::fs::remove_file(&state);
    let (out, ok) = run(&state, &["record-play", "1", GROUNDOUT, "owner-1"]);
    assert!(!ok, "record-play on a nonexistent game should fail, got: {out}");
    let _ = std::fs::remove_file(&state);
}
