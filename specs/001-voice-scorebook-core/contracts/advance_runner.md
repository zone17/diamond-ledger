# Contract: `advance_runner`

**Verb** (Art. III): advance one or more base runners as a consequence of play, deterministically where
the rules force it, surfacing ambiguous advances for confirmation. **Risk tier:** 2.
**Spec:** FR-009, US1.

## Request
```
advance_runner(
  game_id: GameId,
  advance: { runner: RunnerId, from: Base, to: Base | Out, by_error?: Position },
  idempotency_key: string,
  actor: Actor
) -> AdvanceRunnerResult
```

## Response
```
AdvanceRunnerResult {
  applied_seq?: u64,                 // present if deterministically applied
  state_preview: GameState,
  judgment?: JudgmentDecision,       // present (Open) iff the advance is ambiguous (AmbiguousAdvance)
  needs: None | Confirm | Judgment
}
```

## Preconditions
- Authority holds (else `UNAUTHORIZED`).
- The runner exists on `from`; `to` is reachable and not contradictorily occupied.

## Behavior
- **Forced / deterministic** advance (per rules, as a consequence of the recorded play) → emit
  `RunnerAdvanced`, return `state_preview`, `needs: Confirm`.
- **Ambiguous** advance (not forced, not uniquely determined by the play) → emit `JudgmentOpened`
  (`AmbiguousAdvance`), `needs: Judgment` — **never assume** the advance (FR-009).
- Advancing a runner who is already out, or to an occupied base, or beyond a 3rd out →
  `CONTRADICTORY_STATE` (reject; do not corrupt state).

## Postconditions
- Base/out state reflects only **confirmed** advances; a run crossing the plate updates the line score and
  creates a `RunRecord` (with `earned_unearned = Pending` if the inning has an error/PB, I3).

## Errors
`UNAUTHORIZED` · `CONTRADICTORY_STATE` · `AMBIGUOUS_INPUT` · `INVALID_ARGUMENT` · `NOT_FOUND`.

## Idempotency / parity
`idempotency_key` dedupes. Human and agent callers produce identical advances/judgments for identical
facts (SC-008). Contract tests cover forced vs ambiguous vs contradictory advances.
