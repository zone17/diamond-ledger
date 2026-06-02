# Contract: `finalize_scorecard`

**Verb** (Art. III): finalize a game (or checkpoint) and produce the human scorebook + a reduced-but-valid
Retrosheet event file. **Risk tier:** 3 (produces the official/exportable record). **Spec:** FR-015–017,
US3, SC-004/SC-011.

## Request
```
finalize_scorecard(
  game_id: GameId,
  mode: Final | Checkpoint,
  idempotency_key: string,
  actor: Actor
) -> FinalizeResult
```

## Response
```
FinalizeResult {
  scorebook: ReisnerScorebook,             // rendered human-readable book
  retrosheet: RetrosheetExport,            // 8 record types; reduced grammar
  proof_box: [ProofBox],                   // per half-inning; MUST balance (SC-011)
  out_of_format: [PlayRef],                // ~5% flagged needs-review, never fabricated (FR-017)
  unresolved: { pending_judgments: [DecisionRef] }   // e.g. earned_unearned still Pending (I3)
}
```

## Preconditions
- Authority holds — the **owner** or an explicitly authorized agent (else `UNAUTHORIZED`, FR-020/I5).
- All plays are confirmed; open (non-`Pending`) judgments are resolved. Deferred `Pending`
  earned/unearned is allowed and reported under `unresolved`, not blocking (FR-010a).

## Behavior
1. Render the Reisner scorebook; compute each half-inning **proof box** — finalize **fails** if any proof
   box does not balance (SC-011), surfacing the discrepancy (not a silent pass).
2. Emit the reduced Retrosheet records (`id`, `version`, `info`[visteam/hometeam/date], `start`, `play`,
   `sub`, `com`, `data`). Any play outside the reduced grammar → `out_of_format` flag, **never** a
   fabricated `play` record (FR-017).
3. The export is **authoritatively accepted only when pinned `cwevent` v0.10.0 parses it with zero
   stderr warnings and ≥1 event row** (I4/SC-004) — enforced in CI, not by the offline emitter.
4. Published Retrosheet-derived output carries the required attribution string (D6 license).

## Postconditions
- A `ScorecardFinalized` event exists; the human book and the event file **agree play-for-play** (US3.1).

## Errors
`UNAUTHORIZED` · `INVALID_ARGUMENT` (unconfirmed plays / unresolved open judgments) ·
`OUT_OF_FORMAT` (reported, non-fatal) · `CONTRADICTORY_STATE` (proof box fails to balance).

## Idempotency / parity
`idempotency_key` dedupes; re-finalizing an unchanged game returns the same artifacts. Agent and human
exports are byte-identical (SC-008). Contract tests run the export through the pinned `cwevent` gate.
