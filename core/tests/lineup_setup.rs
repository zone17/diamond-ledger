//! #177 — a game's lineup goes through the core: `create_game` stores a validated
//! lineup in `GameStarted`, and `get_game_setup` reads it back (ADR-0020, KTD1–KTD4).
//!
//! A lineup is stored or rejected with `INVALID_ARGUMENT`, never silently dropped
//! (Art. VII), and a game without a lineup serializes byte-identically to the
//! pre-#177 format (KTD3).

use dl_core::ffi::{
    Actor, ActorKind, CoreApi, CreateGameRequest, ErrorCode, GameId, LineupSlot, Team,
};
use dl_core::model::Position;
use dl_core::primitives::{CoreSnapshot, DiamondCore};

/// A snapshot written by the `dl` CLI before #177 (one lineup-less game).
const PRE_LINEUP_SNAPSHOT: &str = include_str!("fixtures/pre-lineup-snapshot.json");

fn owner() -> Actor {
    Actor { kind: ActorKind::Human, id: "owner-1".into(), harness_version: None }
}

fn slot(batting_order: u8, name: &str) -> LineupSlot {
    LineupSlot { batting_order, name: name.into(), player_id: None, field_pos: None }
}

fn names(names: &[&str]) -> Vec<LineupSlot> {
    names.iter().zip(1u8..).map(|(n, i)| slot(i, n)).collect()
}

fn team(id: &str, name: &str, lineup: Option<Vec<LineupSlot>>) -> Team {
    Team { id: id.into(), name: name.into(), lineup }
}

fn create(
    core: &DiamondCore,
    home: Option<Vec<LineupSlot>>,
    visitor: Option<Vec<LineupSlot>>,
) -> Result<GameId, dl_core::ffi::Error> {
    core.create_game(CreateGameRequest {
        home: team("hawks", "Hawks", home),
        visitor: team("owls", "Owls", visitor),
        idempotency_key: "lineup-create".into(),
        actor: owner(),
    })
    .map(|r| r.game_id)
}

/// Total rows across every game in the log (the "no event written" check).
fn log_len(core: &DiamondCore) -> usize {
    let v = serde_json::to_value(core.snapshot()).unwrap();
    v["log"]["games"]
        .as_object()
        .map(|games| games.values().map(|rows| rows.as_array().unwrap().len()).sum())
        .unwrap_or(0)
}

fn detail<'a>(err: &'a dl_core::ffi::Error, key: &str) -> Option<&'a str> {
    err.details.iter().find(|d| d.key == key).map(|d| d.value.as_str())
}

const NINE: [&str; 9] = [
    "Avery", "Blake", "Casey", "Drew", "Emery", "Finley", "Gray", "Harper", "Indy",
];

#[test]
fn nine_name_visitor_lineup_reads_back_in_order() {
    let core = DiamondCore::new();
    let gid = create(&core, None, Some(names(&NINE))).unwrap();

    let setup = core.get_game_setup(gid).unwrap();
    assert_eq!(setup.game_id, gid);
    assert_eq!(setup.home.id, "hawks");
    assert_eq!(setup.home.name, "Hawks");
    assert_eq!(setup.home.lineup, None, "no home lineup was supplied");
    assert_eq!(setup.visitor.id, "owls");
    assert_eq!(setup.visitor.name, "Owls");

    let visitor = setup.visitor.lineup.expect("visitor lineup stored");
    let got: Vec<&str> = visitor.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(got, NINE);
    for (s, i) in visitor.iter().zip(1u8..) {
        assert_eq!(s.batting_order, i);
        assert_eq!(s.player_id, None);
        assert_eq!(s.field_pos, None);
    }
}

#[test]
fn names_are_stored_trimmed() {
    let core = DiamondCore::new();
    let gid = create(&core, Some(vec![slot(1, "  Avery Lee \t"), slot(2, "Blake")]), None).unwrap();
    let home = core.get_game_setup(gid).unwrap().home.lineup.unwrap();
    assert_eq!(home[0].name, "Avery Lee");
    assert_eq!(home[1].name, "Blake");
}

#[test]
fn batting_order_gaps_are_kept_as_given() {
    let core = DiamondCore::new();
    let lineup = vec![slot(1, "Avery"), slot(2, "Blake"), slot(5, "Emery")];
    let gid = create(&core, Some(lineup), None).unwrap();
    let home = core.get_game_setup(gid).unwrap().home.lineup.unwrap();
    let orders: Vec<u8> = home.iter().map(|s| s.batting_order).collect();
    assert_eq!(orders, vec![1, 2, 5]);
}

#[test]
fn optional_player_id_and_position_round_trip() {
    let core = DiamondCore::new();
    let lineup = vec![LineupSlot {
        batting_order: 1,
        name: "Avery".into(),
        player_id: Some("p-1".into()),
        field_pos: Some(Position(6)),
    }];
    let gid = create(&core, Some(lineup.clone()), None).unwrap();
    assert_eq!(core.get_game_setup(gid).unwrap().home.lineup, Some(lineup));
}

/// Every KTD2 violation is INVALID_ARGUMENT naming the team and slot, and writes nothing.
///
/// Per-slot messages name the batting order the scorer typed (not the 0-based index),
/// and no message or detail echoes the offending name (player names stay local, FR-029).
#[test]
fn ill_formed_lineups_are_rejected_without_writing() {
    // 62 characters after trimming, built from a real-looking name.
    let long = "Ana Ruiz ".repeat(7);
    let control = "Bo\u{7}b Diaz";
    let twenty_one: Vec<LineupSlot> = (1u8..=21).map(|i| slot(i, "P")).collect();
    // (label, lineup, slot_index, batting_order; None where no single slot is at fault)
    let cases: Vec<(&str, Vec<LineupSlot>, &str, Option<&str>)> = vec![
        ("empty-after-trim name", vec![slot(1, "A"), slot(2, "   ")], "1", Some("2")),
        ("61-character name", vec![slot(1, &long)], "0", Some("1")),
        ("control character", vec![slot(1, "A"), slot(3, control)], "1", Some("3")),
        ("21 slots", twenty_one, "20", None),
        ("batting order 21", vec![slot(21, "A")], "0", Some("21")),
        ("batting order 0", vec![slot(0, "A")], "0", Some("0")),
        ("duplicate batting order", vec![slot(1, "A"), slot(1, "B")], "1", Some("1")),
        ("out of order", vec![slot(2, "A"), slot(1, "B")], "1", Some("1")),
        (
            "position 10",
            vec![LineupSlot {
                batting_order: 4,
                name: "A".into(),
                player_id: None,
                field_pos: Some(Position(10)),
            }],
            "0",
            Some("4"),
        ),
        (
            "empty player id",
            vec![LineupSlot {
                batting_order: 1,
                name: "A".into(),
                player_id: Some("  ".into()),
                field_pos: None,
            }],
            "0",
            Some("1"),
        ),
    ];

    for (label, bad, slot_index, batting_order) in cases {
        for side in ["home", "visitor"] {
            let core = DiamondCore::new();
            // A prior valid game, so "unchanged" is checked against a non-empty log.
            create(&core, None, None).unwrap();
            let before = log_len(&core);
            let snap_before = serde_json::to_value(core.snapshot()).unwrap();

            let (home, visitor) = if side == "home" {
                (Some(bad.clone()), Some(names(&["Ok"])))
            } else {
                (Some(names(&["Ok"])), Some(bad.clone()))
            };
            let err = create(&core, home, visitor).expect_err(label);
            assert_eq!(err.code, ErrorCode::InvalidArgument, "{label}: {err:?}");
            assert_eq!(detail(&err, "team"), Some(side), "{label}: {err:?}");
            assert_eq!(detail(&err, "slot_index"), Some(slot_index), "{label}: {err:?}");
            assert_eq!(detail(&err, "batting_order"), batting_order, "{label}: {err:?}");
            if let Some(order) = batting_order {
                let want = format!("{side} batting order {order}: ");
                assert!(err.message.starts_with(&want), "{label}: {:?}", err.message);
            }
            let echoed = [long.trim(), "Ana Ruiz", control, "Bo"];
            for text in std::iter::once(err.message.as_str())
                .chain(err.details.iter().map(|d| d.value.as_str()))
            {
                for name in echoed {
                    assert!(!text.contains(name), "{label}: error echoes a name: {err:?}");
                }
            }
            assert_eq!(log_len(&core), before, "{label}: no event may be written");
            // No game id was allocated and no authority recorded for a phantom game.
            let snap_after = serde_json::to_value(core.snapshot()).unwrap();
            assert_eq!(snap_after, snap_before, "{label}: snapshot unchanged");
        }
    }
}

#[test]
fn a_sixty_character_name_is_accepted() {
    let core = DiamondCore::new();
    // 60 Unicode scalar values, several of them multi-byte.
    let name = "é".repeat(60);
    let gid = create(&core, Some(vec![slot(1, &name)]), None).unwrap();
    assert_eq!(core.get_game_setup(gid).unwrap().home.lineup.unwrap()[0].name, name);
}

#[test]
fn twenty_slots_and_batting_order_twenty_are_accepted() {
    let core = DiamondCore::new();
    let lineup: Vec<LineupSlot> = (1u8..=20).map(|i| slot(i, "P")).collect();
    let gid = create(&core, Some(lineup), None).unwrap();
    assert_eq!(core.get_game_setup(gid).unwrap().home.lineup.unwrap().len(), 20);
}

/// KTD5: the core keeps per-team order and does not de-duplicate across teams.
#[test]
fn both_teams_may_carry_the_same_name() {
    let core = DiamondCore::new();
    let gid = create(&core, Some(names(&["Smith"])), Some(names(&["Smith"]))).unwrap();
    let setup = core.get_game_setup(gid).unwrap();
    assert_eq!(setup.home.lineup.unwrap()[0].name, "Smith");
    assert_eq!(setup.visitor.lineup.unwrap()[0].name, "Smith");
}

#[test]
fn get_game_setup_on_unknown_game_is_not_found() {
    let core = DiamondCore::new();
    let err = core.get_game_setup(GameId(99)).unwrap_err();
    assert_eq!(err.code, ErrorCode::NotFound);
}

/// KTD3: a lineup-less game's snapshot is byte-identical to the one the pre-#177 CLI
/// wrote for the same inputs (`dl new-game Hawks Owls owner-1`).
#[test]
fn lineup_less_game_serializes_byte_identically_to_pre_change_fixture() {
    let core = DiamondCore::new();
    core.create_game(CreateGameRequest {
        home: team("hawks", "Hawks", None),
        visitor: team("owls", "Owls", None),
        idempotency_key: "new-Hawks-Owls".into(),
        actor: owner(),
    })
    .unwrap();
    let now = serde_json::to_string_pretty(&core.snapshot()).unwrap();
    assert_eq!(now, PRE_LINEUP_SNAPSHOT);

    // An explicitly empty lineup is the same as none.
    let core = DiamondCore::new();
    core.create_game(CreateGameRequest {
        home: team("hawks", "Hawks", Some(vec![])),
        visitor: team("owls", "Owls", Some(vec![])),
        idempotency_key: "new-Hawks-Owls".into(),
        actor: owner(),
    })
    .unwrap();
    assert_eq!(serde_json::to_string_pretty(&core.snapshot()).unwrap(), PRE_LINEUP_SNAPSHOT);
}

#[test]
fn pre_lineup_snapshot_restores_with_empty_lineups() {
    let snap: CoreSnapshot = serde_json::from_str(PRE_LINEUP_SNAPSHOT).unwrap();
    let core = DiamondCore::restore(snap);
    let setup = core.get_game_setup(GameId(1)).unwrap();
    assert_eq!((setup.home.id.as_str(), setup.home.name.as_str()), ("hawks", "Hawks"));
    assert_eq!((setup.visitor.id.as_str(), setup.visitor.name.as_str()), ("owls", "Owls"));
    assert_eq!(setup.home.lineup, None);
    assert_eq!(setup.visitor.lineup, None);
}

/// A stored lineup survives a snapshot round trip (the CLI's restart path).
#[test]
fn lineup_survives_snapshot_restore() {
    let core = DiamondCore::new();
    let gid = create(&core, Some(names(&["Avery", "Blake"])), None).unwrap();
    let text = serde_json::to_string_pretty(&core.snapshot()).unwrap();
    let restored = DiamondCore::restore(serde_json::from_str(&text).unwrap());
    assert_eq!(restored.get_game_setup(gid).unwrap(), core.get_game_setup(gid).unwrap());
}

#[test]
fn slot_wire_json_is_snake_case_and_omits_absent_optionals() {
    let names_only = serde_json::to_string(&slot(3, "Avery")).unwrap();
    assert_eq!(names_only, r#"{"batting_order":3,"name":"Avery"}"#);

    let full = LineupSlot {
        batting_order: 1,
        name: "Avery".into(),
        player_id: Some("p-1".into()),
        field_pos: Some(Position(6)),
    };
    assert_eq!(
        serde_json::to_string(&full).unwrap(),
        r#"{"batting_order":1,"name":"Avery","player_id":"p-1","field_pos":6}"#
    );

    let core = DiamondCore::new();
    let gid = create(&core, None, Some(names(&["Avery"]))).unwrap();
    let setup = serde_json::to_value(core.get_game_setup(gid).unwrap()).unwrap();
    assert_eq!(setup["game_id"], 1);
    assert_eq!(setup["visitor"]["lineup"][0]["batting_order"], 1);
    assert!(setup["home"].get("lineup").is_none(), "absent lineup omitted: {setup}");
}
