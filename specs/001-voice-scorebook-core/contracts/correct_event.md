# Contract: `correct_event`

**Verb** (Art. III): amend a previously recorded play; recompute downstream state; preserve full history.
**Risk tier:** 2 (reversible, history-preserving). **Spec:** FR-012–014, US4, Art. XII.

## Request
```
correct_event(
  game_id: GameId,
  corrects_seq: u64,                 // the prior event being amended
  amended: { transcript: string } | { normalized: NormalizedPlay },
  idempotency_key: string,
  actor: Actor
) -> CorrectEventResult
```

## Response
```
CorrectEventResult {
  correction_seq: u64,
  amended: NormalizedPlay,
  reclassified: Classification,            // judgment re-derived from amended facts (I1)
  recomputed_state: GameState,             // ACTUAL recompute, not a "recompute needed" flag (FR-012)
  invalidated_downstream: [PlayRef],       // later plays a correction breaks (e.g. changed out count)
  history: [Version]                       // prior version(s) preserved, append-only (FR-013)
}
```

## Preconditions
- Authority holds (else `UNAUTHORIZED`).
- `corrects_seq` exists (else `NOT_FOUND`).

## Behavior
1. Append `EventCorrected` referencing `corrects_seq` — **never** mutate/overwrite the original (FR-013).
2. **Replay** the log from `corrects_seq`, re-deriving classification (I1) and **actually recomputing**
   all affected downstream projections: runners, outs, line score, notation, **proof box** (FR-012).
3. Surface `invalidated_downstream` plays for review rather than silently discarding them (FR-014).
4. If the amended facts are a judgment, open a fresh `JudgmentDecision` (don't silently resolve, I2).

## Postconditions
- Downstream state is consistent with the amended play; every prior version remains in an auditable
  history (SC-007: 100% of corrections retain prior versions).

## Errors
`UNAUTHORIZED` · `NOT_FOUND` · `AMBIGUOUS_INPUT` · `CONTRADICTORY_STATE` · `INVALID_ARGUMENT`.

## Idempotency / parity
`idempotency_key` dedupes. Agent (`correct_event`) and human paths yield identical recompute + preserved
history (US4 scenario 3, SC-008).
