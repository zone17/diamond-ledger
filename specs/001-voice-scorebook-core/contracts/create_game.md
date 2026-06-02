# Contract: `create_game`

**Verb** (Art. III): start a new game from two teams (names-only allowed) and return its `game_id` +
fresh state. **Risk tier:** 2 (meaningful write; creates the event log root). **Spec:** FR-001, US1.

## Request
```
create_game(
  game_id: —,                                    // assigned by the core, returned in the result
  home:    Team,                                 // { id, name, lineup?: [LineupSlot] }
  visitor: Team,                                 // names-only allowed (lineup optional, FR-001)
  idempotency_key: string,
  actor: Actor
) -> CreateGameResult
```
> `Team.lineup` is optional: a game MAY start with just team names and have rosters filled in later
> (FR-001). `LineupSlot { batting_order: 1..=9|0(DH), player_id, field_pos: 0..=9 }`.

## Response
```
CreateGameResult {
  game_id: GameId,                 // stable across this game's whole event log
  state: GameState                 // fresh: top of the 1st, 0 outs, empty bases
}
```

## Preconditions
- Authority holds — the `actor` is the authenticated account that will own the game (else `UNAUTHORIZED`,
  I5/FR-020). The owning account is recorded as `created_by`; all later primitives resolve authority
  against the returned `game_id`.
- `home` and `visitor` carry a non-empty `name`; any supplied `lineup` is well-formed (else
  `INVALID_ARGUMENT`).

## Behavior
1. Append `GameStarted` (FR-001) with payload `{ teams, optional lineups }`; assign a stable `game_id`.
2. Project the fresh `GameState` (inning 1, `Top`, count 0-0, no runners, 0 outs, empty line score).

## Postconditions
- A `GameStarted` event exists; the game is `InProgress` and fully queryable (`get_game_state`).

## Errors
`UNAUTHORIZED` · `INVALID_ARGUMENT`.

## Idempotency / retry
`idempotency_key` dedupes; a retried key returns the original `CreateGameResult` (no second game,
no second `GameStarted`).

## Parity & tests
Human (UI new-game) and agent/CLI (`new-game`) paths converge on identical `game_id`/state given identical
teams + key (SC-008). Contract tests cover: names-only creation, full-lineup creation, the authority
boundary (human + agent), idempotent retry, and rejection of an ill-formed lineup (`INVALID_ARGUMENT`).
