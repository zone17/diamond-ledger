# Phase 1 Data Model — Voice-to-Scorebook Core

**Feature:** `001-voice-scorebook-core` · **Plan:** [`plan.md`](./plan.md) · **Date:** 2026-06-01

Derived from the spec's Key Entities + the hardened invariants. The model is **event-sourced**: the
authoritative state is an append-only log of domain events; all queryable state (game state, scorecard,
proof box) is a **deterministic projection** rebuilt by replaying the log (FR-003 determinism, FR-013
append-only history). Types are language-neutral; the Rust core is the reference implementation.

---

## 1. Core invariants the model must enforce (the probe broke these once)

| # | Invariant | Where enforced |
|---|-----------|----------------|
| I1 | Judgment classification is **fact-derived**, never label-derived | `classify(facts) → Classification`, reads `NormalizedPlay`, ignores any caller `type` label |
| I2 | No-silent-judgment gate is **instrumented + adversarial** | `silent_resolution_counter` increments on any judgment mutation w/o open flag + decider; corpus = hard CI fail |
| I3 | Earned/unearned = **`PENDING`** in any error/passed-ball inning | `RunRecord.earned_unearned = Pending` set at projection time; resolved only by `JudgmentDecision` |
| I4 | Retrosheet acceptance = pinned **`cwevent`** | export validated in CI, not by the offline emitter alone |
| I5 | **Owner-as-decider** authority | every primitive asserts `authority` against game owner / authorized agent |
| I6 | **Determinism**: same confirmed events → byte-identical projection | integer-only core; replay is pure |

---

## 2. Events (the append-only log — the source of truth)

Each event is immutable, ordered by a monotonic `seq`, and carries provenance (Art. XIII/XXXII).

```
DomainEvent {
  seq: u64                      // monotonic per game; replay order
  game_id: GameId
  type: EventType               // see below
  payload: <type-specific>
  actor: Actor                  // { kind: Human|Agent, id, harness_version? }
  occurred_at: Timestamp        // wall clock (display/audit only; NOT used in scoring math → determinism)
  correlation_id: Uuid
  causation_id: Uuid?           // the event/command that caused this
  corrects_event_seq: u64?      // set only on a correction (points at the amended event)
}

EventType =
  | GameStarted          // FR-001  payload: teams, optional lineups
  | PlayRecorded         // FR-004/005  payload: NormalizedPlay (+ raw transcript ref, no audio)
  | RunnerAdvanced       // FR-009  payload: advancement delta (confirmed)
  | JudgmentOpened       // FR-010  payload: JudgmentDecision (status=Open, recommendation, alternatives)
  | JudgmentResolved     // FR-011  payload: { decision_id, chosen, decider: Actor }
  | EventCorrected       // FR-012  payload: amended NormalizedPlay; corrects_event_seq set
  | PlayConfirmed        // FR-007  payload: { confirms_seq }  (read-verify-correct gate)
  | ScorecardFinalized   // FR-015  payload: export manifest
```

**Correction is append-only** (FR-013): an `EventCorrected` references the original `seq`; the original
is never mutated/deleted. Replay applies corrections in order and **recomputes all downstream
projections** (FR-012/014), re-deriving classification for affected plays (I1).

---

## 3. Command/primitive inputs → events

| Primitive | Emits | Notes |
|-----------|-------|-------|
| `record_play` | `PlayRecorded` (+ maybe `JudgmentOpened`, `RunnerAdvanced`) | Must **not** advance state until `PlayConfirmed` (FR-007). Classification runs here on facts (I1). |
| `advance_runner` | `RunnerAdvanced` or `JudgmentOpened` (ambiguous advance) | Forced advances deterministic; ambiguous → judgment (FR-009). |
| `correct_event` | `EventCorrected` (+ downstream re-projection) | Surfaces invalidated downstream plays (FR-014). |
| `finalize_scorecard` | `ScorecardFinalized` | Requires authority (FR-020); emits human book + reduced-Retrosheet file. |

---

## 4. Entities (projections rebuilt from the log)

### Game
```
Game { id, home: Team, visitor: Team, status: InProgress|Finalized,
       state: GameState, plays: [Play], created_by: OwnerId }
```

### Team / Lineup / Player
```
Team { id, name, lineup: [LineupSlot] }              // FR-001 (names-only allowed)
LineupSlot { batting_order: 1..=9|0(DH), player: Player, field_pos: 1..=9|0, subs: [Substitution] }
Player { id, name, bats?, throws? }                  // bats/throws optional (cwevent emits '?' if absent)
Substitution { in: Player, out: Player, at_seq }     // FR-002 mid-game changes
```

### GameState (fully queryable at all times — FR-002)
```
GameState { inning: u8, half: Top|Bottom,
            count: { balls: 0..=3, strikes: 0..=2 },
            bases: { first?: RunnerId, second?: RunnerId, third?: RunnerId },
            outs: 0..=2,                              // 3rd out ends half-inning
            line_score: per-side R/H/E by inning,
            batting_index: per-side,
            pitch_sequence: [PitchMark],
            active_fielders: pos → Player }
```

### NormalizedPlay (the FACT representation — FR-005; classification reads ONLY this)
```
NormalizedPlay {
  situation: SituationDiamond { runners, outs, count, batter_hand },   // pre-play state (Reisner top)
  catalyst: Catalyst {                                                 // what occurred (Reisner bottom)
     batter_event: BatterEvent,        // S|D|T|HR|K|W|IW|HP|E|FC|FieldedOut|SacFly|SacBunt|...
     fielders: [Position],             // sequence, e.g. [6,3]; position 1..=9, 0=DH
     ball_type: Ground|Line|Fly|Pop|Bunt|None,
     advances: [Advance { runner, from, to|Out, by_error?: Position }],
     touched_or_misplayed_by: [Position],   // the FACT that can make a "single" a hit-vs-error judgment
  },
  // NOTE: a caller-supplied `type` label, if any, is recorded for audit but is NEVER an input to classify()
}
```

### Classification (the cardinal seam — I1/I2)
```
Classification = Deterministic | Judgment(JudgmentKind) | OutOfFormat(reason)
JudgmentKind = HitVsError | EarnedVsUnearned | ContestedCredit | AmbiguousAdvance
// classify(NormalizedPlay) derives this from facts; a play whose facts are a judgment is flagged
// even if it arrived labeled deterministic (FR-006/FR-006a).  ~85% Deterministic / ~15% Judgment / ~5% OutOfFormat.
```

### JudgmentDecision (US2)
```
JudgmentDecision { id, kind: JudgmentKind, status: Open|Resolved|Pending,
                   recommendation: { call, one_line_reason }, alternatives: [Call],
                   chosen?: Call, decider?: Actor }      // FR-011 records decider identity
// EarnedVsUnearned may be left status=Pending explicitly (FR-010a; no Rule 9.16 in v1).
```

### RunRecord
```
RunRecord { scorer: RunnerId, rbi: bool, earned_unearned: Earned|Unearned|Pending }
// Pending forced (I3) for ANY run in a half-inning containing an error or passed ball.
```

### Reisner rendering & ProofBox
```
ReisnerCell { situation_diamond, catalyst_symbols, pitch_marks, runner_fate: Scored{rbi}|PutOut{n}|LeftOnBase }
ProofBox { ab, bb, sac, hbp, interference, runs, putouts, stranded }   // FR-005a
// MUST balance every completed half-inning (SC-011): ab+bb+sac+hbp+interference = runs+putouts+stranded
// stranded = runners physically on base at the 3rd out; force/DP outs are not "stranded".
```

### RetrosheetExport
```
RetrosheetExport { records: [id|version|info|start|play|sub|com|data],   // reduced 8 types only
                   out_of_format_flags: [PlayRef] }                       // ~5% flagged, never fabricated (FR-017)
// validated by pinned cwevent v0.10.0 (I4/SC-004); attribution string on published output (D6 license).
```

### CapabilityInvocation (audit — Art. XXIII)
```
CapabilityInvocation { primitive, actor, authority_result, args_redacted, outcome,
                       prior_state_ref, resulting_state_ref, correlation_id, causation_id }
```

---

## 5. State transitions (half-inning + read-verify-correct)

```
record_play ─► PlayRecorded ──(classify)──► Deterministic ─► [pending confirm] ─► PlayConfirmed ─► state advances
                                          └► Judgment ─► JudgmentOpened ─► (one-tap) JudgmentResolved/Pending ─► confirm ─► advance
                                          └► OutOfFormat ─► flag needs-review (never auto-emit)
outs reaches 3 ─► half-inning ends ─► ProofBox MUST balance (SC-011) ─► switch half/inning
correct_event ─► EventCorrected ─► replay from corrected seq ─► downstream projections recompute ─► surface invalidated plays
```

**Hard rules:** state never advances on an unconfirmed entry (FR-007); a judgment never resolves without
an open flag + recorded decider (else the `silent_resolution_counter` increments → CI fails, I2); the
authority check (I5/FR-020) runs at **every** primitive before any event is appended.

---

## 6. Validation rules (selected)

- `count.balls ≤ 3`, `count.strikes ≤ 2`, `outs ≤ 2` at rest; a 3rd out terminates the half-inning.
- An advance to an occupied base, or a 3rd out plus further advance, is **contradictory** → reject/clarify
  (edge case), never corrupt state.
- Any run while `inning_has_error_or_pb` ⇒ `earned_unearned = Pending` (cannot be set Earned/Unearned by
  the engine).
- Export: a play whose facts fall outside the reduced grammar ⇒ `OutOfFormat`, emitted as a flag, not a
  fabricated `play` record.
