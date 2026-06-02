# Contract: `resolve_judgment`

**Verb** (Art. III): resolve an open scoring judgment by recording a chosen call **and the decider
identity**. **Risk tier:** 2 (meaningful write; records a human/agent decision). **Spec:** FR-011, US2.

## Request
```
resolve_judgment(
  game_id: GameId,
  decision_id: u64,                  // the open JudgmentDecision.id
  chosen: Call,                      // one of the surfaced recommendation / alternatives ({ token, label })
  idempotency_key: string,
  actor: Actor                       // the DECIDER — recorded on resolution (FR-011/I2)
) -> ResolveJudgmentResult
```
> `chosen` reuses the same `Call` token type the judgment surfaced; the core never invents a new call.

## Response
```
ResolveJudgmentResult {
  decision: JudgmentDecision,        // now status=Resolved, with chosen + decider (= actor) set
  state: GameState                   // projection reflecting the resolved call
}
```

## Preconditions
- Authority holds — the **owner** or an explicitly authorized agent (else `UNAUTHORIZED`, FR-020/I5).
- `decision_id` references an **open** judgment (else `NOT_FOUND`; resolving an already-resolved decision
  with a different call is `INVALID_ARGUMENT`).
- `chosen` is one of the decision's recommendation / alternatives (else `INVALID_ARGUMENT`).

## Behavior
1. Append `JudgmentResolved` (FR-011) with payload `{ decision_id, chosen, decider: actor }`. The decider
   identity is **always** recorded — the core **never** resolves a judgment silently (I2; a silent
   resolution increments `silent_resolution_counter` → CI fail).
2. Mark the decision `Resolved`, set `chosen` + `decider`, and recompute the projection (e.g. a
   hit-vs-error call updates H/E and may resolve a `Pending` earned/unearned, I3).

## Postconditions
- A `JudgmentResolved` event exists; the decision is `Resolved` with a recorded decider (SC-003: zero
  silent resolutions). `Needs::Judgment` no longer blocks the play.

## Errors
`UNAUTHORIZED` · `NOT_FOUND` (unknown `game_id`/`decision_id`) · `INVALID_ARGUMENT` (call not among the
surfaced options / decision already resolved) · `CONTRADICTORY_STATE`.

## Idempotency / retry
`idempotency_key` dedupes; replaying the same resolution returns the original `ResolveJudgmentResult`
without a second `JudgmentResolved`.

## Parity & tests
Human (one-tap resolve) and agent/CLI (`resolve --call ... --decider ...`) paths produce identical resolved
decisions + state for the same inputs (SC-008). Contract tests cover: happy-path resolve, an unknown
decision, a call outside the offered options (`INVALID_ARGUMENT`), the **decider-always-recorded** invariant
(I2/SC-003), the authority boundary (human + agent), and idempotent retry.
