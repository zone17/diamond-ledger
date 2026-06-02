# Contract: `record_play`

**Verb** (Art. III): record one completed play from a natural-language description / normalized facts.
**Risk tier:** 2 (meaningful write; preview-then-confirm). **Spec:** FR-004–008, FR-010, US1/US2.

## Request
```
record_play(
  game_id: GameId,
  input: { transcript: string }                  // spoken/typed; parsed to facts by the front-end
         | { normalized: NormalizedPlay },        // agent/CLI may pass structured facts directly
  idempotency_key: string,
  actor: Actor
) -> RecordPlayResult
```
> A caller MAY include a `type` label for audit; it is **NEVER** an input to classification (FR-006/I1).

## Response
```
RecordPlayResult {
  recorded_seq: u64,
  normalized: NormalizedPlay,
  classification: Deterministic | Judgment(JudgmentKind) | OutOfFormat(reason),
  reisner: ReisnerCell,                 // rendered notation for the verify card
  state_preview: GameState,             // resulting state IF confirmed — not yet applied
  judgment?: JudgmentDecision,          // present (status=Open) iff classification = Judgment
  needs: None | Confirm | Clarify | Judgment   // what the loop requires next
}
```

## Preconditions
- Authority holds (else `UNAUTHORIZED`).
- No prior **unconfirmed** play (else `PENDING_CONFIRMATION`, FR-007).

## Behavior
1. Parse `transcript` → `NormalizedPlay` (front-end grammar parse) **or** accept `normalized` directly.
2. If facts are missing/contradictory or parse confidence is low → return `AMBIGUOUS_INPUT` with a single
   clarifying question or manual-entry option — **never guess** (FR-008). (Distinct from a judgment.)
3. `classify(NormalizedPlay)` from **facts** (I1):
   - `Deterministic` → return `state_preview` + `needs: Confirm`.
   - `Judgment(kind)` → emit `JudgmentOpened`, return the decision (recommendation + alternatives),
     `needs: Judgment`. **MUST NOT** resolve it here (else `silent_resolution_counter`++ → CI fail, I2).
   - `OutOfFormat` → flag needs-review, `OUT_OF_FORMAT`.
4. Append `PlayRecorded`. **State does not advance** until a subsequent `PlayConfirmed` (FR-007).

## Postconditions
- A `PlayRecorded` event exists; game state is unchanged until confirmation.
- Any run while the half-inning contains an error/PB will project `earned_unearned = Pending` (I3).

## Errors
`UNAUTHORIZED` · `PENDING_CONFIRMATION` · `AMBIGUOUS_INPUT` · `JUDGMENT_REQUIRED` (if a caller tries to
record a resolved judgment) · `CONTRADICTORY_STATE` · `OUT_OF_FORMAT` · `INVALID_ARGUMENT`.

## Idempotency / retry
`idempotency_key` dedupes; a retried key returns the original `RecordPlayResult` (no second append).

## Parity & tests
Human (transcript) and agent (normalized) paths converge on identical results given identical facts
(US1 scenario 4, SC-008). Contract tests include the **mislabeled-judgment** case: facts that are a
judgment but labeled deterministic MUST classify as judgment (FR-006a).
