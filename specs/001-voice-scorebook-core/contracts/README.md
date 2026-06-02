# Primitive Contracts — Voice-to-Scorebook Core

**Feature:** `001-voice-scorebook-core` · **Plan:** [`plan.md`](../plan.md) · Art. I/XI contract-first.

These are the **public architecture** (Art. XI): the four atomic primitives, defined as
language-neutral contracts before implementation. Each is exposed identically to the iOS UI **and** to
an agent/API/CLI client (Art. II parity, FR-018) — the *same* core function backs both. Schemas are
illustrative pseudo-types; the Rust core + UniFFI surface is the reference binding.

## The four primitives

| Verb | Risk tier | File |
|------|-----------|------|
| `record_play` | Tier 2 (meaningful write, preview-then-confirm) | [`record_play.md`](./record_play.md) |
| `advance_runner` | Tier 2 | [`advance_runner.md`](./advance_runner.md) |
| `correct_event` | Tier 2 (reversible, history-preserving) | [`correct_event.md`](./correct_event.md) |
| `finalize_scorecard` | Tier 3 (produces the official record / export) | [`finalize_scorecard.md`](./finalize_scorecard.md) |

Atomicity (Art. III): each does **one** thing. A full game is composed by an agent or the UI from these
verbs + the reads below — no `manage_game` god-verb.

## Shared error model (structured, machine-readable — Art. I, no prose-only errors)

```
Error {
  code: ErrorCode,            // stable enum (below)
  message: string,            // human-readable; never the sole signal
  retryable: bool,
  details?: object            // e.g. { field, expected, got }
}
ErrorCode =
  | UNAUTHORIZED              // authority check failed (I5/FR-020)
  | PENDING_CONFIRMATION      // a prior play is unconfirmed; state cannot advance (FR-007)
  | AMBIGUOUS_INPUT           // needs clarification/manual entry, NOT a guess (FR-008)
  | JUDGMENT_REQUIRED         // facts classify as judgment; must open a decision, not resolve (FR-010)
  | CONTRADICTORY_STATE       // impossible play (e.g. 3rd out + further advance) — reject, don't corrupt
  | OUT_OF_FORMAT             // outside reduced v1 grammar; flag needs-review, never fabricate (FR-017)
  | INVALID_ARGUMENT          // schema/precondition violation
  | NOT_FOUND                 // unknown game/event id
```

## Authority (deterministic boundary policy — Art. XXV/XXVIII, FR-020)

Every primitive asserts authority **before** appending any event: the caller MUST be the **authenticated
account that owns the game**, or an agent that account has **explicitly authorized**. Authority is
asserted *and audited* at each call — not a non-empty "decider" string (the probe gap). Failure →
`UNAUTHORIZED`, no state change. (Org/multi-role permissions deferred.)

## Cross-cutting guarantees (apply to all four)

- **Determinism (FR-003/I6):** given the same confirmed event log, every primitive's resulting
  projection is byte-identical across iOS, Android, CLI, agent.
- **Idempotency:** each command carries a client-supplied `idempotency_key`; a duplicate key returns the
  original result without a second append (safe retry — Art. XXXIII).
- **Read-verify-correct (Art. XII):** every write is paired with reads — `get_game_state`,
  `list_game_events`, `get_play(seq)`, `get_proof_box(half_inning)`, `preview_*` — and is correctable.
- **Audit (Art. XXIII):** each call emits a `CapabilityInvocation` (actor, authority result, prior/after
  state refs, correlation/causation ids).
- **No raw audio (FR-022):** `record_play` accepts a *transcript/normalized facts*; any audio buffer is
  released by the caller immediately and never persisted.
- **Observability budget (Art. XXIV):** bounded — single-shot deterministic calls, no unbounded loops.

## Contract tests (Art. XI/XXXIV — exist before implementation)

Each primitive ships contract tests covering: happy path, every `ErrorCode` it can return, the authority
boundary (human + agent), idempotent retry, and the relevant invariant (e.g. `record_play` ⇒ a
mislabeled-judgment input still classifies as judgment; `finalize_scorecard` ⇒ export passes pinned
`cwevent`). Parity tests assert the agent/CLI path and the UI path produce identical results (SC-008).
