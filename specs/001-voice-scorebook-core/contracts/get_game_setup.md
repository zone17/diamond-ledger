# Contract: `get_game_setup`

**Verb** (read, Art. XII): return the teams and lineups a game was started with. **Risk tier:** 0
(read-only; no event appended). **Spec:** FR-001, FR-002, #177. **Decision:** ADR-0020 (KTD4).

## Request
```
get_game_setup(game_id: GameId) -> GameSetup
```

## Response
```
GameSetup {
  game_id: GameId,
  home:    Team,        // { id, name, lineup?: [LineupSlot] }
  visitor: Team
}
```
> Each `Team` is projected from the game's `GameStarted` event. `lineup` is the stored batting order
> (validated and trimmed by [`create_game`](create_game.md)), in the order it was supplied, or absent
> (`None`, key omitted from the JSON) when the game was started without one, including games created
> before #177. Slots use the same `LineupSlot { batting_order, name, player_id?, field_pos? }` shape
> `create_game` accepts, so a setup read back can be sent again unchanged.

Example (visitor lineup only):
```json
{
  "game_id": 1,
  "home": { "id": "hawks", "name": "Hawks" },
  "visitor": {
    "id": "owls", "name": "Owls",
    "lineup": [ { "batting_order": 1, "name": "Avery" }, { "batting_order": 2, "name": "Blake" } ]
  }
}
```

## Preconditions
- The game exists (else `NOT_FOUND`).
- **No authority check.** This follows the convention of every existing read (`get_game_state`,
  `list_game_events`, `get_play`, `get_proof_box`): existence check only. The local state file is the
  trust boundary (ADR-0020). Any process that can read the state file can already read the names.

## Behavior
1. Find the game's `GameStarted` row and project its team ids, names, and lineups.
2. Append nothing; the result is a pure function of the event log.

## Why a separate read, not a `GameState` field
`GameState` rides every write's result and every `dl state` output. Adding the lineup there would
change those bytes for every game and couple the SC-008 parity diff to roster data. A separate read
keeps `GameState` byte-identical (KTD4).

## Errors
`NOT_FOUND`.

## Privacy
Player names may belong to minors. This read deliberately exposes them to any agent or CLI caller
(agent parity, Art. II), including hosted-model agents that may send them off the device. They are
never exported or logged by the core. See the FR-029 note in ADR-0020.

## Parity & tests
The UI (`CoreClient`), the CLI, and any agent read the same `GameSetup` through the same `CoreApi`
method (UniFFI `ffiGetGameSetup(gameId:)`). Tests in `core/tests/lineup_setup.rs` cover: round trip of
a names-only lineup, trimming, batting-order gaps, optional id and position, same names on both teams,
`NOT_FOUND` for an unknown game, a pre-#177 snapshot reading back with no lineups, and the
snake_case wire shape.
