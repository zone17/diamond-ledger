---
title: A derived export re-reading the event log must apply the same withhold/override rules as the canonical projection
date: 2026-06-03
category: best-practices
module: core/src/primitives (finalize_scorecard) + core/src/retrosheet
problem_type: best_practice
component: service_object
applies_when:
  - "Building a second consumer (export, report, snapshot) that re-reads an append-only event log"
  - "The canonical projection applies business rules (skip withheld rows, substitute corrections) the new consumer might not"
  - "Emitting an official/authoritative artifact (Retrosheet export, ledger statement, audit file) from sourced state"
tags: [event-sourcing, projection, append-only, export, source-of-truth, retrosheet, cwevent, sc-003, fr-012, data-integrity]
---

# A derived export must apply the same withhold/override rules as the canonical projection

## Context
The H2 work (PR #160) added a Retrosheet export that, to assign innings and emit play records,
**re-read the append-only event log directly** — iterating raw confirmed `PlayRecorded` facts. The
*canonical* projection (`project_game`) does NOT iterate raw facts: it **skips withheld seqs** (plays
with an unresolved `JudgmentOpened` — SC-003/I2) and **substitutes corrected facts** from the
amendment override map (`correct_event` / FR-012). Because `finalize_scorecard` reports — but does not
*block* on — open judgments, a game could finalize with an open judgment or an applied correction, and
the export would then emit the play with **stale or un-withheld facts** — an official record that
silently misrepresents a play the canonical state had withheld or amended. The proof-box/SC-011 gate
and SC-003 reporting were unaffected (they read from `project_game`); only the *export contents* drifted
from the source of truth. The review gate caught it before merge.

## Guidance
**Any second consumer that re-derives state by re-reading an event log must apply the *same* rules the
canonical projection applies — ideally by sharing the exact code path, not re-implementing the loop.**
A raw `for event in log { ... }` is almost never correct for a derived artifact, because the canonical
reader has earned rules (skip/withhold, override/amend, dedup, authority) that a fresh loop silently
drops.

```rust
// WRONG — export re-reads raw facts; diverges from project_game's rules
for seq in confirmed_play_seqs { emit(play_facts[seq]); }

// RIGHT — reuse the canonical reader's withhold + override rules
let withheld = log.open_judgment_for_seqs(game_id);     // SC-003: don't emit unresolved plays
let overrides = log.correction_overrides(game_id);      // FR-012: emit the amended facts
for seq in confirmed_play_seqs {
    if withheld.contains(&seq) { continue; }            // exclude from the official record
    emit(overrides.get(&seq).unwrap_or(&play_facts[seq]));
}
```

## Why This Matters
The export is the **authoritative external artifact** (the official scorebook / Retrosheet file). If it
disagrees with the in-app state, the product has two sources of truth and the *exported* one is wrong in
exactly the cases that matter most — contested judgments and corrections. Sharing the canonical reader's
rules is the only way to guarantee the export == the book. This is the same family as the cardinal
"never silently resolve a judgment": here the silent failure is *emitting* an unresolved/superseded play
as if it were final.

## When to Apply
- Whenever you add an export, snapshot, report, or second projection over an append-only log.
- Especially when the canonical projection has *conditional* logic (withhold, override, skip, dedup) — a
  naive re-read will miss it. Add a test that exercises the conditional case (here: finalize-with-open-
  judgment and finalize-after-correction, asserting the export excludes/substitutes correctly).

## Examples — and the cwevent export-conformance gotchas (same PR)
Proving the export end-to-end against the real **Chadwick `cwevent`** gate (SC-004) also surfaced
several non-obvious Retrosheet-conformance requirements (cwevent **segfaults** rather than erroring on
these — so only an end-to-end run catches them):
- **`start` records are mandatory** — cwevent segfaults without starter lineups (even synthetic 9-player
  ones for a no-roster v1).
- **`info,date` must be `YYYY/MM/DD`** — cwevent segfaults on `YYYY-MM-DD` (the frozen contract had
  dashes; bumped to v1.2 + ADR-0014).
- **Required `info` records:** `number`, `daynight`, `usedh`, `innings`.
- **Don't double-encode an error advance** — `E6.B-1(E6)` yields `ERR_CT=2`; suppress the implicit
  batter-advance annotation when the primary event is already `E$` (only for `from == Home`).
- The gate must stay **stderr-driven** (cwevent exits 0 on malformed plays) and a **hard** CI job (a
  `continue-on-error` on the new gate would have let a malformed export ship green).

## Related Issues
- DL-36 / H2 (PR #160) — the export, the fix, ADR-0014, the v1.2 contract bump.
- [[parallel-squad-integration]] §4 (green-CI≠correct — the gate caught this), and the cardinal
  no-silent-judgment seam ([[mock-to-real-stateful-core-swap]]).
