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
> `Team.lineup` is optional: a game MAY start with just team names (FR-001); an empty list is the
> same as none. `LineupSlot { batting_order: 1..=20, name, player_id?, field_pos?: 0..=9 }`: a slot
> needs only a `name`, so a names-only lineup is valid (ADR-0020 KTD1). Wire keys are snake_case and
> absent optionals are omitted, e.g. `{"batting_order":1,"name":"Avery"}`. The DH batting slot `0` is
> deferred with fielding positions.

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

### Lineup validation (ADR-0020 KTD2)
One core function checks each team's lineup, after the identity check and **before** any game id,
authority, or event is written, so a rejected lineup leaves the log unchanged. It is the same check
for the FFI, the CLI, and the CLI replay tool (they all go through `create_game`).
- At most **20** slots.
- `batting_order` in **1..=20**, unique and strictly increasing through the list. Gaps are allowed
  (`1, 2, 5` is stored as given), so a slot keeps the number the scorer gave it.
- `name` is **trimmed**, then must be non-empty, at most **60** Unicode scalar values, and free of
  control characters. The trimmed name is what is stored.
- `player_id`, when present, is non-empty; `field_pos`, when present, is a valid `Position` (`0..=9`).
- Names are **not** de-duplicated, within or across teams (two teams can share a surname, KTD5).

A violation is `INVALID_ARGUMENT` with structured details `team` (`home` | `visitor`), `slot_index`
(0-based index into the supplied list; `20` for a too-long lineup), and `field` (`lineup`,
`batting_order`, `name`, `player_id`, or `field_pos`).

## Behavior
1. Validate both lineups (above), then assign a stable `game_id` and append `GameStarted` (FR-001)
   with payload `{ teams, home_lineup?, visitor_lineup? }`. Each lineup is the validated, trimmed
   list, omitted from the JSON when empty, so a lineup-less game serializes byte-identically to the
   pre-#177 format and older state files load unchanged (KTD3).
2. Project the fresh `GameState` (inning 1, `Top`, count 0-0, no runners, 0 outs, empty line score).

## Postconditions
- A `GameStarted` event exists; the game is `InProgress` and fully queryable (`get_game_state`), and
  its teams and lineups read back through [`get_game_setup`](get_game_setup.md).
- A supplied lineup is either stored or rejected; it is never silently dropped (Art. VII).
- Player names stay local: they are not written to the Retrosheet export (which keeps synthetic
  starters) and are not logged (FR-029 note, ADR-0020).

## Errors
`UNAUTHORIZED` · `INVALID_ARGUMENT`.

## Idempotency / retry
`idempotency_key` dedupes; a retried key returns the original `CreateGameResult` (no second game,
no second `GameStarted`).

> **Known gap (deferred, ADR-0020):** the core registers the key but does not yet check it, so a
> retried `create_game` currently allocates a second game. Fixing the dedupe is separate follow-up
> work with its own tests.

## Parity & tests
Human (UI new-game) and agent/CLI (`new-game`) paths converge on identical `game_id`/state given identical
teams + key (SC-008). Contract tests cover: names-only creation, full-lineup creation, the authority
boundary (human + agent), idempotent retry, and rejection of an ill-formed lineup (`INVALID_ARGUMENT`).
Lineup storage, validation, and the pre-#177 byte-identity check live in `core/tests/lineup_setup.rs`.
