# Implementation Plan: Voice-to-Scorebook Core

**Branch**: `feat/product/DL-003-voice-scorebook-plan` | **Date**: 2026-06-01 | **Spec**: [`spec.md`](./spec.md)

**Input**: Feature specification from `specs/001-voice-scorebook-core/spec.md`

**Governance**: [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) ·
**Decisions**: [`DECISIONS.md`](../../DECISIONS.md) (ADR-0006 build authorization) ·
**Phase 0 research**: [`research.md`](./research.md) · **Interaction**: [`prototype/interaction-spec.md`](./prototype/interaction-spec.md) (V3 glance)

> **Decisions confirmed by the founder 2026-06-01** (surfaced for review, not silently chosen, Art. VI):
> **D1 core language = Rust + UniFFI**, **D2 ASR = two-engine**, **D3 first slice = US1 + US2 + US3
> (export included)**. Recorded in **[ADR-0007](../../DECISIONS.md)** (the Art. XXXVIII gate for the
> core-language choice). Core implementation (Phase A) is now unblocked.

## Summary

Build the v1 deterministic voice-to-scorebook core for the **serious/official scorekeeper** beachhead: a
spoken play (*"ground ball to short, threw him out at first"*) becomes a rules-correct **Reisner**-notation
entry in a complete game state, with the ~15% **scorer-judgment** plays surfaced for a one-tap decision
(**never silently auto-resolved**, fact-derived), and a reduced-but-valid **Retrosheet** event file gated
by pinned **Chadwick `cwevent`**. Delivered as an **iOS-first** consumer app (Android fast-follow), fully
**on-device/offline**, push-to-talk — with the four atomic primitives (`record_play`, `advance_runner`,
`correct_event`, `finalize_scorecard`) **co-equally callable by agent/API/CLI** (Art. II parity).

**Technical approach (recommended):** a **deterministic shell around probabilistic intelligence**
(Art. VII). The moat is a **single platform-independent Rust core** (rules engine + fact-derived judgment
classifier + Reisner renderer + proof-box + reduced-Retrosheet emitter), integer-only for byte-identical
determinism, exposed via **UniFFI** to Swift/Kotlin/CLI/agent from one artifact. A thin probabilistic
front-end (**on-device ASR + grammar-constrained parse**) proposes candidate events; the deterministic
core verifies and renders; the **read-verify-correct loop** keeps the human (or authorized agent) in
control. The **cardinal no-silent-judgment invariant is an architectural seam**: classification reads
normalized play *facts*, an **instrumented silent-resolution counter** trips on any judgment resolved
without an open flag + decider, and a **mislabeled-judgment adversarial corpus** is a **hard-fail CI gate**.

**Sequencing (ADR-0006-bound):** first shippable artifact = vertical slice **US1 + US2 + US3 (export)**,
demoable to ~20 real serious scorers (founder chose to include the Retrosheet export UI for a stronger
official-artifact story). The reduced-Retrosheet emitter lives in the core from the start (for the
`cwevent` gate + gold dataset). Correction *UI* (US4) + sync follow; full Rule 9.16 earned-run
reconstruction is deferred (earned/unearned = `PENDING`). The **gold-dataset + scorer-cohort sourcing**
runs as an explicit **parallel work-stream from day one**.

## Technical Context

**Language/Version** *(confirmed, ADR-0007)*: **Rust** (pinned toolchain, integer/fixed-point only,
no `f32`/`f64` in core — CI-linted) for the shared core; **Swift 6** (iOS app/adapter); **Kotlin**
(Android fast-follow adapter, same core).

**Primary Dependencies**:
- Core: Rust std only + `proptest`/`insta` (dev), `serde` (FFI payloads). **Minimal footprint** (Art. XXXVI).
- FFI: **UniFFI** (Swift XCFramework→SwiftPM; Kotlin/Gradle). Boundary = 4 primitives + plain owned types.
- iOS ASR *(confirmed, two-engine)*: Apple **`SpeechAnalyzer`/`DictationTranscriber`** (iOS 26) primary +
  **sherpa-onnx/Parakeet** portable (Android + fallback), behind one `Transcriber` protocol.
- Parse: **deterministic grammar-constrained parser** (v1, no LLM); FunctionGemma-270M+XGrammar = v2 path.
- iOS persistence: **SQLite/GRDB (`SQLiteData`)**, event-sourced append-only. Sync: **CloudKit private DB**.
- Acceptance gate: **Chadwick `cwevent` v0.10.0** (pinned, SHA256), built in CI via autotools.

**Storage**: On-device **SQLite** (append-only `events` table + replayed projections); cloud =
CloudKit private DB (sync/backup only). No raw audio retained (FR-022).

**Testing**: `cargo test` + `proptest` (adversarial play generation) + `insta` (golden Reisner/Retrosheet
snapshots); **`evals/`** harness (adversarial judgment corpus, gold-dataset accuracy, SC-003 counter,
`cwevent` 3-layer gate); XCTest (iOS adapter); contract tests per primitive (Art. XI).

**Target Platform**: **iOS 26+** (min floor set by `SpeechAnalyzer`; pre-26 fallback path) at launch;
Android fast-follow; the core also runs as a host CLI + server/WASM for agent parity.

**Project Type**: Mobile app (iOS-first) **+ portable core library + CLI/agent adapter** (multi-surface,
one core).

**Performance Goals**: Push-to-talk round-trip (speak→rendered card) bounded by the measurable SC-005 bar:
**median eyes-on-screen ≤3 s per play, ≥80% of plays ≤1 phrase + ≤1 tap**. Core scoring is
integer/discrete → sub-millisecond; the latency budget is dominated by ASR.

**Constraints**: Fully **offline** for an 80–300-play game with **no data loss** (FR-021/SC-006);
**deterministic** byte-identical output (FR-003/I6); **COPPA process-don't-store** (FR-022/FR-029);
on-device/on-battery; private-by-default (FR-023/FR-028).

**Scale/Scope**: v1 beachhead (handful→dozens of serious scorers across real games, SC-010); a game =
80–300 plays; reduced grammar covers ~95% of amateur plays, ~5% flagged for manual handling.

**Resolved decisions** (founder-confirmed 2026-06-01, **ADR-0007**): D1 = **Rust + UniFFI**; D2 =
**two-engine ASR**, min iOS = 26; D3 = first slice **US1 + US2 + US3 (export)**, US4 + sync follow.
*Open verification carried to implementation:* confirm `cwevent` pin after a final newer-tag check;
field-test crowd-noise WER before committing accuracy claims (the real technical risk, ties to SC-005).

## Constitution Check

*GATE: must pass before Phase 0 (passed — research.md exists) and re-checked after Phase 1 (below).*

| Article | Gate | Status in this plan |
|---|---|---|
| I — Tools are the product | Every action a documented tool/primitive | ✅ 4 atomic primitives + contracts (`contracts/`); UI is a client. |
| II — Agent-native parity | Agent can do everything a human can, no UI | ✅ Same Rust core behind app **and** CLI/agent; SC-008 parity eval. |
| III — Atomic composable verbs | No god-verbs | ✅ `record_play`/`advance_runner`/`correct_event`/`finalize_scorecard`. |
| VI — Agentic, not vibe | Output verified, honest uncertainty | ✅ Read-verify-correct loop; recommendations flagged, not silently locked. |
| VII — Deterministic shell | Critical behavior deterministic, LLM not sole enforcer | ✅ Rust core is source of truth; ASR/parse only *propose*; classification deterministic. |
| X / XI — Spec & contract-first | Typed contracts before impl | ✅ `contracts/` defines I/O, errors, permissions, risk tier, idempotency per primitive. |
| XII — Read/verify/correct/recover | No mutation-only | ✅ `correct_event` + append-only history + downstream recompute (FR-012/013/014). |
| XIII / XXXII — Structured state / events | Authoritative shared state, durable events | ✅ Event-sourced append-only log; projections by replay. |
| XX — Independent verification | Builder ≠ sole verifier | ✅ Adversarial corpus + `cwevent` external gate + (planned) review agents. |
| XXI — Eval-driven | Agent capabilities have eval coverage | ✅ `evals/`: judgment corpus, gold-dataset accuracy, injection/permission, SC-003. |
| XXIII — Observability | Important actions traceable | ✅ Every primitive call audited (decider identity, prior/after state, correlation id). |
| XXV / XXVIII — Risk-tiered autonomy / boundary policy | Authority enforced deterministically | ✅ Owner-as-decider asserted at every primitive (FR-020), not a non-empty string. |
| XXVI — Security hard gate | COPPA, least-privilege, no secrets | ✅ Process-don't-store; private-by-default; COPPA consent (FR-029). |
| XXXV — Reproducibility | Pinned deps, lockfiles | ✅ Pinned Rust toolchain, `cwevent` v0.10.0 SHA-pinned, model assets pinned. |
| XXXVII — Simplicity before scale theater | Smallest sufficient architecture | ✅ **No CRDTs** (single-writer); no LLM in v1 parse; one core crate. |
| XXXVIII — Decisions recorded | ADR for architectural change | ✅ **ADR-0007** records the core-language + v1 tech-architecture decision. |
| XL — Doc separation | Constitution/spec/plan/tasks separate | ✅ This plan = design only; no feature reqs leak into constitution. |

**Result: PASS.** ADR-0006 authorizes the build; **ADR-0007** records the now-confirmed core-language and
v1 technical-architecture decision (the previously-tracked gate — now satisfied).

## Project Structure

### Documentation (this feature)

```text
specs/001-voice-scorebook-core/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions D1–D8 (done)
├── data-model.md        # Phase 1 — entities, events, state machine (done)
├── quickstart.md        # Phase 1 — how to build/run/eval the core + CLI (done)
├── contracts/           # Phase 1 — the four primitive contracts + error model (done)
├── spec.md              # Feature spec (hardened)
├── probe-report.md      # Spec-coherence probe findings
├── prototype/           # V3 glance Wizard-of-Oz design reference
└── tasks.md             # Phase 2 — /speckit-tasks (NOT created here)
```

### Source Code (intended; recommended Rust-core layout)

```text
core/                          # Rust — the platform-independent deterministic moat (no f32/f64)
├── src/
│   ├── primitives/            # record_play · advance_runner · correct_event · finalize_scorecard
│   ├── rules/                 # state machine, runner advancement, deterministic scoring
│   ├── classify/              # FACT-derived judgment classifier (the cardinal seam) + corpus hooks
│   ├── reisner/               # situation-diamond + catalyst model, renderer, proof-box
│   ├── retrosheet/            # reduced-but-valid emitter (8 record types, reduced grammar)
│   ├── eventlog/              # append-only event model + replay/projection
│   ├── model.rs               # normalized-fact schema (NormalizedPlay, SituationDiamond, Catalyst, …)
│   ├── authz.rs               # owner-as-decider authority assertion (FR-020 / I5)
│   └── ffi.rs                 # UniFFI surface: 4 primitives + plain owned types + typed errors
├── tests/                     # contract tests + proptest invariants + insta golden snapshots
└── Cargo.toml                 # pinned toolchain; CI-linted no-float

adapters/
├── cli/                       # native CLI over the core (agent/API parity surface)
└── agent/                     # API/agent boundary (native or WASM) — same primitives

evals/                         # Article XXI durable eval artifacts
├── judgment-corpus/           # mislabeled-judgment adversarial corpus (FR-006a / SC-003 hard gate)
├── gold/                      # real multi-inning hand-scored game(s) + gold Retrosheet (D6)
├── retrosheet-fixtures/       # published .EVN regression fixtures (+ TEAM<yr>) for cwevent
└── runners/                   # SC-003 counter check, accuracy eval, 3-layer cwevent gate

ios/                           # Swift 6 app (iOS-first) — a CLIENT of the core
├── Sources/
│   ├── Auth/                  # email + social sign-in; authenticated owner identity (FR-020 / FR-028)
│   ├── Speech/                # Transcriber protocol: SpeechAnalyzer + sherpa-onnx adapters
│   ├── Parse/                 # grammar-constrained transcript→event normalizer/parser
│   ├── Core/                  # SwiftPM wrapper around the UniFFI XCFramework
│   ├── Persistence/           # SQLiteData event log + replay + CloudKit sync
│   └── UI/                    # V3 glance HUD + card A/B + push-to-talk + correction
└── Tests/

android/                       # fast-follow — same core via UniFFI Kotlin bindings (later phase)
```

**Structure Decision**: Multi-surface, **one core**. The Rust `core/` is the single source of truth;
`ios/`, `adapters/cli`, `adapters/agent`, and later `android/` are thin clients consuming the *same*
compiled primitives — this is how Art. II parity holds by construction rather than by re-implementation.
`evals/` is a first-class top-level tree (Art. XXI). **Do not** name any source dir `build/` (silently
`.gitignore`d — known anti-pattern).

## Phasing (high level; detailed tasks come from `/speckit-tasks`)

- **Phase A — Core + CLI + eval harness (headless, the moat).** Rust core: state machine, fact-derived
  classifier, Reisner renderer + proof-box, reduced-Retrosheet emitter, append-only event log. CLI/agent
  adapter (parity from day one). `evals/`: adversarial judgment corpus + instrumented SC-003 counter +
  pinned `cwevent` 3-layer gate. Determinism + proof-box + classification provable headless. *Unblocked
  by ADR-0007.*
- **Phase B — iOS first slice (US1 + US2 + US3 export), demoable to ~20 scorers.** UniFFI XCFramework;
  `Transcriber` (SpeechAnalyzer); grammar parse; V3 glance HUD + card A/B + push-to-talk; offline SQLite
  event log; **`finalize_scorecard` + Retrosheet export UI** (surfaces the core emitter, `cwevent`-gated).
  The ADR-0006 demand artifact.
- **Phase C — US4 correction UI + sync.** Downstream recompute + preserved history; CloudKit sync.
- **Parallel work-stream (from day one) — gold dataset + scorer cohort (D6).** Build one gold game from a
  published `.EVN`; SABR/Retrosheet outreach for amateur games + the ~20-scorer demo cohort. Feeds
  SC-001/SC-002 and ADR-0006's distribution tripwire.

## Complexity Tracking

| Item | Why needed | Note / simpler alt rejected |
|---|---|---|
| Two-engine ASR (Apple + sherpa) | iOS-first accuracy/privacy/cost **and** a clean Android story | Single-engine (sherpa everywhere) is simpler but forfeits Apple-native's free first-party iOS win; abstraction cost = one thin adapter. **Confirmed (ADR-0007).** |
| Multi-surface (core + iOS + CLI/agent) | Constitution Art. II parity is non-negotiable | Not optional; the cost is paid once at the FFI boundary, kept to 4 primitives + owned types. |
| Rust learning curve (small team) | Determinism + single-artifact parity justify it | Was the deciding variable; founder confirmed Rust. Core is bounded/integer/pure → safe end for learning Rust. **(ADR-0007.)** |

*No unjustified constitutional violations. The core-language gate is satisfied by **ADR-0007**.*
