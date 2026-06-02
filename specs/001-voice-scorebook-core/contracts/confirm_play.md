# Contract: `confirm_play`

**Verb** (Art. III): confirm a previously recorded play so projected state advances — the read-verify gate.
**Risk tier:** 2 (meaningful write; the state-advance gate). **Spec:** FR-007, US1.

## Request
```
confirm_play(
  game_id: GameId,
  confirms_seq: Seq,                 // the recorded play's seq (record_play.recorded_seq)
  idempotency_key: string,
  actor: Actor
) -> ConfirmPlayResult
```

## Response
```
ConfirmPlayResult {
  state: GameState                   // projection AFTER the confirmed play is applied (no longer a preview)
}
```

## Preconditions
- Authority holds (else `UNAUTHORIZED`, I5/FR-020).
- `confirms_seq` references a recorded, **not-yet-confirmed** play (else `NOT_FOUND`, or
  `INVALID_ARGUMENT` if already confirmed / out of order).
- The play carries no unresolved **open** judgment — an open `Judgment` must be resolved first
  (`JUDGMENT_REQUIRED`).

## Behavior
1. Append `PlayConfirmed` (FR-007) with payload `{ confirms_seq }` — the read-verify-correct gate.
2. Advance projected state by applying the confirmed play; `state` is the post-apply projection
   (the `state_preview` from `record_play` is now realized).

## Postconditions
- A `PlayConfirmed` event exists; game state has advanced. A subsequent `record_play` is no longer
  blocked by `PENDING_CONFIRMATION` for this play.

## Errors
`UNAUTHORIZED` · `NOT_FOUND` (unknown `game_id`/`confirms_seq`) · `INVALID_ARGUMENT` (already confirmed /
out-of-order) · `JUDGMENT_REQUIRED` (an open judgment on the play must be resolved first) ·
`CONTRADICTORY_STATE`.

## Idempotency / retry
`idempotency_key` dedupes; re-confirming the same `confirms_seq` returns the original `ConfirmPlayResult`
without a second `PlayConfirmed`.

## Parity & tests
Human (tap-to-confirm) and agent/CLI (`confirm`) paths produce identical post-confirm state for the same
`seq` (SC-008). Contract tests cover: happy-path confirm, confirming an unknown/already-confirmed seq,
confirm blocked by an open judgment (`JUDGMENT_REQUIRED`), the authority boundary, and idempotent retry.
