---
description: "Task list for voice-scorebook-core v1 — 3 parallel squads"
---

# Tasks: Voice-to-Scorebook Core (v1 — first slice US1 + US2 + US3)

**Input**: Design documents from `specs/001-voice-scorebook-core/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present)
**Branch**: `feat/product/DL-003-voice-scorebook-plan`
**Authority**: `.specify/memory/constitution.md` · **Decisions**: ADR-0006 (build authorized), ADR-0007 (tech stack)

## Organization

This list is **squad-primary** (3 independent domain-expert squads run in parallel — the execution
reality) while honoring the Spec Kit phase convention. Each task carries **`[A]`/`[B]`/`[C]` (squad)** +
**`[USx]`/`[FRx]`/`[SCx]` (traceability)**. The cross-squad **handoffs (H#)** are explicit; the
**Foundational phase front-loads the unblocking interfaces** so the squads don't block each other.

> **Tests are mandatory here** (not optional): the constitution requires contract tests (Art. XI/XXXIV)
> and eval coverage for agent behavior (Art. XXI). Contract/eval tasks are first-class below.

**Format**: `- [ ] T### [P?] [Squad][Story] Description with file path`
**[P]** = parallel-safe (different files, no incomplete dependency).

### The three squads → GitHub epics

| Squad | Epic | Owns | Surfaces |
|-------|------|------|----------|
| **A** | Deterministic Scoring Core & Agent Parity | `core/`, `adapters/` | Rust core, 4 primitives, judgment seam, Reisner/Retrosheet, UniFFI, CLI/agent |
| **B** | iOS Voice Client & Judgment UI | `ios/` | Two-engine ASR, grammar parse, V3 glance UI, persistence, sync, export UI |
| **C** | Standards, Eval Data & Software Factory | `evals/`, `.github/`, gold data | `cwevent` gate, fixtures, gold dataset, adversarial corpus, multi-target CI, outreach |

### MVP (the ADR-0006 demoable artifact) = US1 + US2 + US3

The first shippable slice requires convergence across all three squads. The **MVP critical path** is
marked **🎯** on tasks; everything else is either deferred (US4/sync) or hardening.

---

## Engineering Standards & AI-Agent Execution Conventions

These tasks are written to be executed by **elite engineers and/or AI coding agents (Claude Code, Codex)**
to a bleeding-edge bar. Every task — whoever runs it — follows these standards (they operationalize the
constitution; deviations need documented justification, Art. IX/XXXVII):

1. **Spec-driven, not vibe-driven.** The spec → plan → contracts → these tasks are the source of truth
   (Spec Kit). An agent implements *to the contract* (`contracts/`) and the Gherkin ACs below — it does
   not invent behavior. Each task is **self-contained** (exact file paths, the FR/SC it serves, its ACs)
   so an agent can execute it without rediscovering context.
2. **Compound Engineering loop per task** (Art. IX): Plan → Work → **Review (independent/adversarial)** →
   Compound. ~80% planning/verification, ~20% code. The agent that writes a change is **not** its sole
   verifier (Art. XX) — pair with a reviewer agent / `/ce:review` before merge.
3. **Eval-driven & test-first** (Art. XXI, X): the Gherkin ACs and the eval gates (SC-003 judgment gate,
   `cwevent` gate, no-float/determinism) are written/failing **before** implementation and are the
   definition of correct. Golden datasets + adversarial corpora are first-class, not afterthoughts.
4. **Deterministic gates are the quality bar, not opinion.** CI hard-fails (no-float lint, byte-identical
   determinism, SC-003 counter, pinned `cwevent`, secret/dep scan) gate merge. "It runs" is not "it's
   done" (Art. VI). Reproducibility: pinned toolchains, lockfiles, pinned `cwevent` + model assets
   (Art. XXXV/XXXVI).
5. **Agent-native parity by construction** (Art. II): every capability lands as a primitive callable by
   agent/CLI, verified by the parity eval (T040) — never UI-only.
6. **Parallel agents work in isolation.** Cross-squad work runs in separate directories; AI agents
   spawned for parallel tasks use **git worktree isolation** to avoid file conflicts, and the
   front-loaded interfaces (Phase 2) are the only synchronization points (H1/H2/H3).
7. **Observability & provenance** (Art. XXIII/XIII): every primitive emits a `CapabilityInvocation`
   (actor, authority result, prior/after state, correlation/causation ids) — traceable for humans and
   agents alike.
8. **Right-size the model** (Art. XIX): Haiku for research/inventory, Sonnet for implementation/tests,
   Opus for the architecture-sensitive seams (the judgment classifier, the FFI boundary, security).
9. **Branch + CI discipline** (Art. XVIII): typed branches, never `main`; `/watch-ci` after every
   push/PR/merge; architectural changes get an ADR (Art. XXXVIII).

> The cardinal seam (fact-derived classification + instrumented SC-003 gate) is the highest-rigor target:
> treat it as Opus-tier, adversarially reviewed, eval-gated work — it is the invariant the probe broke.

---

## Phase 1: Setup (Shared Infrastructure) — cross-squad, do first together

**Purpose**: monorepo skeleton + pinned toolchains + CI scaffold so all squads share one reproducible base.

- [ ] T001 [P] Create monorepo layout per plan.md (`core/`, `adapters/cli/`, `adapters/agent/`, `ios/`, `android/` (placeholder), `evals/`, `.github/`) — NEVER a `build/` source dir (silently `.gitignored`)
- [ ] T002 [P] [A] Pin Rust toolchain in `core/rust-toolchain.toml` + init `core/Cargo.toml` (workspace; deps: serde; dev: proptest, insta)
- [ ] T003 [P] [B] Init iOS app project `ios/` (Swift 6, min iOS 26 floor; SwiftPM) with placeholder `ios/Sources/` tree
- [ ] T004 [P] [C] Add CI workflow skeleton `.github/workflows/ci.yml` jobs: `core-build`, `core-eval`, `retrosheet-gate`, `ios-build` (advisory per ADR-0002)
- [ ] T005 [P] [C] Add `evals/` tree skeleton (`judgment-corpus/`, `gold/`, `retrosheet-fixtures/`, `runners/`) with READMEs stating honesty caveats (self-consistency vs field accuracy)
- [ ] T006 [P] Add Retrosheet attribution string to repo (`NOTICE`/export-credits) per D6 license terms

---

## Phase 2: Foundational — Cross-Squad Unblocking Interfaces (BLOCKS parallel work)

**Purpose**: freeze the contracts/schemas/stubs that let the three squads then run **independently**.
**⚠️ CRITICAL**: complete before squad epics start in parallel. Small, high-leverage, jointly owned.

- [ ] T007 [A] Define the FFI/JSON event + result schema in `core/src/ffi.rs` (4 primitives + plain owned types + typed `Error` enum) from `contracts/` — the boundary Squad B codes against **(H1 source)**
- [ ] T008 [P] [B] Generate a **stub/mock core** `ios/Sources/Core/MockCore.swift` implementing the T007 schema with canned results, so Squad B builds the full UI before the real core lands **(consumes H1)**
- [ ] T009 [A][C] **Freeze the reduced-Retrosheet grammar** (the v1 subset + the ~5% flag-for-manual list) as `specs/001-voice-scorebook-core/contracts/retrosheet-reduced-grammar.md` — Squad A's emitter and Squad C's fixtures both target this **(H2 source)**
- [ ] T010 [A][C] Define the **eval-harness interface** (corpus format, gold-game format, gate exit semantics) as `evals/INTERFACE.md`; A codes runners to it, C produces data to it **(H3 source)**
- [ ] T011 [P] [A] Author a **seed synthetic judgment corpus** `evals/judgment-corpus/seed.jsonl` (mislabeled-judgment cases) so the SC-003 gate is exercisable before the real corpus (C) exists
- [ ] T012 [P] [A] Define the normalized-fact schema (`SituationDiamond` + `Catalyst`) in `core/src/model.rs` from data-model.md §4 — the shared representation classification/render/export all read

**Checkpoint**: FFI schema (T007), mock core (T008), frozen grammar (T009), eval interface (T010) exist →
the three squads can now proceed in parallel.

---

## Epic A — Deterministic Scoring Core & Agent Parity  *(Squad A · Rust · `core/`)*

> Independent test: drive a full game headless via the CLI; assert byte-identical determinism, proof-box
> balance, fact-derived classification, and `cwevent`-clean export — no UI required.

### Story A2 — Game-state machine + append-only event log  *(US1 · FR-002/003/009 · I6)*

- [ ] T013 [A][US1] Implement append-only event log + monotonic seq + replay/projection in `core/src/eventlog/`
- [ ] T014 [A][US1] Implement `GameState` machine (count/bases/outs/inning/line-score/lineup, 3rd-out termination) in `core/src/rules/state.rs`
- [ ] T015 [A][US1] Implement deterministic runner advancement (forced vs ambiguous→judgment) in `core/src/rules/advance.rs` (FR-009)
- [ ] T016 [P] [A][US1] **No-float determinism guard**: CI-lint forbidding `f32`/`f64` in `core/`; determinism test (replay ×2 → byte-identical) in `core/tests/determinism.rs` (FR-003/I6)
- [ ] T017 [A][US1] Implement `record_play` primitive (parse-agnostic; accepts normalized facts) per `contracts/record_play.md` in `core/src/primitives/record_play.rs`
- [ ] T018 [A][US1] Implement `advance_runner` primitive per `contracts/advance_runner.md` in `core/src/primitives/advance_runner.rs`
- [ ] T019 [A][US1] Read-verify gate: state never advances on an unconfirmed entry (FR-007) — enforce in `core/src/primitives/` + test
- [ ] T020 [P] [A][US1] Contract tests for `record_play` + `advance_runner` (happy + every ErrorCode + idempotent retry) in `core/tests/contract/`

### Story A3 — Fact-derived judgment classifier + SC-003 counter (the cardinal seam)  *(US2 · FR-006/006a/010/010a · I1/I2/I3)*

- [ ] T021 [A][US2] Implement `classify(NormalizedPlay) -> Classification` reading **facts only**, ignoring any caller label, per data-model §4 + the Play-classification reference in `core/src/classify/mod.rs` (FR-006/I1)
- [ ] T022 [A][US2] Implement `JudgmentDecision` lifecycle (Open→Resolved/Pending, recommendation+alternatives, decider recorded) in `core/src/classify/judgment.rs` (FR-010/011)
- [ ] T023 [A][US2] Force `earned_unearned = PENDING` for any run in an error/PB half-inning; no Rule 9.16 (FR-010a/I3) in `core/src/classify/earned.rs`
- [ ] T024 [A][US2] **Instrumented silent-resolution counter** that increments on any judgment mutation without an open flag + decider, in `core/src/classify/guard.rs` (SC-003/I2) — wired to fail loud
- [ ] T025 [A][US2] Contract/negative tests: a mislabeled-judgment input still classifies as judgment; counter trips on a forced silent resolution, in `core/tests/contract/judgment.rs` (FR-006a)

### Story A4 — Reisner renderer + proof-box  *(US1 · FR-005/005a · SC-011)*

- [ ] T026 [P] [A][US1] Implement Reisner renderer (situation diamond + catalyst, position numbers 0=DH, runner-fate enum scored/putout/LOB) in `core/src/reisner/render.rs` (FR-005)
- [ ] T027 [P] [A][US1] Implement proof-box reconciliation (AB+BB+SAC+HBP+INT = R+PO+LOB; stranded = on-base at 3rd out) in `core/src/reisner/proof_box.rs` (FR-005a) — must balance every half-inning (SC-011)
- [ ] T028 [P] [A][US1] Golden snapshot tests (`insta`) for Reisner + proof-box in `core/tests/reisner.rs`

### Story A5 — Reduced-Retrosheet emitter  *(US3 · FR-016/017 · SC-004)*

- [ ] T029 [A][US3] Implement reduced-Retrosheet emitter (8 record types; reduced event grammar) targeting the frozen grammar (T009) in `core/src/retrosheet/emit.rs`
- [ ] T030 [A][US3] Implement out-of-format detection: the hard ~5% flagged needs-review, never fabricated (FR-017) in `core/src/retrosheet/out_of_format.rs`
- [ ] T031 [P] [A][US3] Golden snapshot tests for emitter output in `core/tests/retrosheet.rs` (validated authoritatively by C's `cwevent` gate via **H2**)

### Story A6 — `correct_event` + downstream recompute  *(US4 · FR-012/013/014 · SC-007)* — post-MVP

- [ ] T032 [A][US4] Implement `correct_event` per contract: append-only amendment, **actual** downstream recompute (runners/outs/line-score/notation/proof-box), reclassify affected plays in `core/src/primitives/correct_event.rs`
- [ ] T033 [A][US4] Surface invalidated-downstream plays for review (FR-014); preserve prior versions (FR-013/SC-007); contract tests in `core/tests/contract/correct.rs`

### Story A7 — `finalize_scorecard` + export assembly  *(US3 · FR-015 · SC-011)* 🎯

- [ ] T034 [A][US3] Implement `finalize_scorecard` per contract (authority check, proof-box-must-balance-or-fail, human book + Retrosheet export, report PENDING judgments) in `core/src/primitives/finalize.rs`
- [ ] T035 [P] [A][US3] Contract tests for `finalize_scorecard` (incl. unbalanced proof-box → fail) in `core/tests/contract/finalize.rs`

### Story A8 — UniFFI boundary + CLI/agent adapter (parity)  *(US1–US3 · FR-018/019/020 · SC-008)* 🎯

- [ ] T036 [A] Implement owner-as-decider authority assertion at **every** primitive boundary (FR-020/I5) in `core/src/authz.rs`
- [ ] T037 [A] Finalize the UniFFI surface (4 primitives + reads: get_game_state/list_events/get_play/get_proof_box) in `core/src/ffi.rs`; generate Swift + Kotlin bindings **(completes H1 — real core replaces mock)**
- [ ] T038 [P] [A] Build the **CLI adapter** (`adapters/cli/`) over the same primitives — the agent-parity surface (quickstart.md flow: new-game/record-play/confirm/resolve/finalize)
- [ ] T039 [P] [A] Build the **agent/API adapter** (`adapters/agent/`, native or WASM) exposing the same primitives with audit (`CapabilityInvocation`, Art. XXIII)
- [ ] T040 [A] Parity eval: CLI/agent path vs UI path produce identical results for identical facts (SC-008) in `evals/runners/parity.sh`

### Story A9 — Eval-harness mechanics  *(US2/US3 · SC-001/002/003/004)*

- [ ] T041 [P] [A] Implement the SC-003 judgment gate runner (`evals/runners/judgment-gate.sh`) — hard-fail on any silent resolution, consuming corpus per T010 interface
- [ ] T042 [P] [A] Implement the accuracy runner (`evals/runners/accuracy.sh`) — SC-001 ≥90% / SC-002 ≥85% vs gold; **advisory until the real gold dataset (C) lands (H3)**
- [ ] T043 [P] [A] Implement proof-box self-check runner (`evals/runners/proof-box.sh`) — Layer-1 offline check feeding C's 3-layer gate

**Checkpoint A**: headless core drives a full game via CLI; determinism + proof-box + fact-classification +
export all pass; parity holds. Ready for B integration (H1) and C validation (H2/H3).

---

## Epic B — iOS Voice Client & Judgment UI  *(Squad B · Swift · `ios/`)*

> Independent test: run the app against the **mock core** (T008) end-to-end — push-to-talk → V3 card →
> confirm/judgment → export — then swap in the real core (H1) with no behavior change.

### Story B1 — App scaffold + core wrapper  *(US1 · FR-024)* 🎯

- [ ] T044 [B][US1] SwiftPM wrapper package around the UniFFI XCFramework with a `CoreClient` protocol in `ios/Sources/Core/` (backed by MockCore until H1; pitfalls: modulemap rename, XCFramework cache)
- [ ] T045 [B][US1] App shell + New Game flow (two team names, optional lineups) in `ios/Sources/UI/NewGame/` (FR-001)

### Story B2 — Two-engine Transcriber  *(US1 · FR-004/026 · SC-005)* 🎯

- [ ] T046 [B][US1] Define `Transcriber` protocol + audio-buffer lifecycle that releases PCM immediately (no raw audio retained, FR-022) in `ios/Sources/Speech/Transcriber.swift`
- [ ] T047 [P] [B][US1] Apple `SpeechAnalyzer`/`DictationTranscriber` adapter with `contextualStrings` phrase biasing (baseball lexicon + roster) + `AssetInventory` preload-over-Wi-Fi in `ios/Sources/Speech/AppleTranscriber.swift`
- [ ] T048 [P] [B][US1] sherpa-onnx/Parakeet portable adapter (fallback + Android-reuse path) in `ios/Sources/Speech/SherpaTranscriber.swift`

### Story B3 — Deterministic grammar parse  *(US1 · FR-005/008)* 🎯

- [ ] T049 [B][US1] Transcript→`NormalizedPlay` grammar parser + normalizer ("to short"→SS, "threw him out at first"→6-3) in `ios/Sources/Parse/` (no LLM, v1)
- [ ] T050 [B][US1] Ambiguity path (FR-008): low-confidence/multi-mapping → single clarifying question or manual entry, never a silent guess

### Story B4 — V3 glance HUD + push-to-talk  *(US1 · SC-005)* 🎯

- [ ] T051 [B][US1] Glanceable game-state HUD (inning/half, outs dots, base diamond, count, line score, due-up) <1s readable, in `ios/Sources/UI/HUD/`
- [ ] T052 [B][US1] Push-to-talk control (hold-to-talk states idle→listening→processing→result) in `ios/Sources/UI/PushToTalk/`

### Story B5 — Card A (deterministic confirm) + read-verify loop  *(US1 · FR-007)* 🎯

- [ ] T053 [B][US1] Card A (plain-language restatement + secondary Reisner token + state delta + one-tap Confirm/Correct), auto-advance on confirm, in `ios/Sources/UI/CardA/`

### Story B6 — Card B (judgment) one-tap resolve  *(US2 · FR-010/011)* 🎯

- [ ] T054 [B][US2] Card B "Your call" — visually distinct posture, recommendation + one-line why, equally-tappable alternatives, ≤5s one-tap resolve; cannot advance with an unresolved judgment (incl. explicit "leave PENDING") in `ios/Sources/UI/CardB/`

### Story B7 — Event-sourced persistence (offline, no data loss)  *(US1 · FR-021/023 · SC-006)* 🎯

- [ ] T055 [B][US1] SQLite/GRDB (`SQLiteData`) append-only `events` table + replayed projections in `ios/Sources/Persistence/` — full 80–300-play game offline, crash-safe
- [ ] T056 [P] [B][US1] Offline integrity test: score a full game with no connectivity, no data loss (SC-006) in `ios/Tests/OfflineTests.swift`

### Story B8 — Retrosheet export UI  *(US3 · FR-015)* 🎯

- [ ] T057 [B][US3] Finalize + export UI: invoke `finalize_scorecard`, render the human book, share the `cwevent`-gated Retrosheet file (+ attribution) in `ios/Sources/UI/Export/`

### Story B9 — CloudKit sync  *(FR-023)* — post-MVP

- [ ] T058 [B] CloudKit private-DB event-log push (LWW, persisted outbound queue, no CRDTs) in `ios/Sources/Persistence/Sync/` — deferred with US4

**Checkpoint B**: full push-to-talk → glance card → confirm/judgment → export loop runs on device against
the mock core; swap to real core (H1) is a drop-in.

---

## Epic C — Standards, Eval Data & Software Factory  *(Squad C · `evals/`, `.github/`, gold data)*

> Independent test: the `cwevent` gate + reduced-grammar fixtures pass/fail correctly on sample event
> files with no dependency on Squad A's emitter; the gold game validates with `cwevent` clean.

### Story C1 — Pinned `cwevent` 3-layer CI gate  *(US3 · FR-016 · SC-004 · I4)* 🎯

- [ ] T059 [C][US3] CI job builds **Chadwick `cwevent` v0.10.0** from the pinned tarball (SHA256-verified, autotools) in `.github/workflows/ci.yml` (re-check for a newer tag before locking)
- [ ] T060 [C][US3] **Stderr-driven** acceptance gate `evals/runners/retrosheet-gate.sh`: fail if stderr ~ `WARNING|Invalid|Can't find|could not open` OR 0 event rows (NOT exit code); 3 layers (proof-box → cwevent → golden diff)

### Story C2 — Reduced-grammar Retrosheet fixtures  *(US3 · FR-016)*

- [ ] T061 [P] [C][US3] Author fixture dir(s) `evals/retrosheet-fixtures/<year>/` with mandatory `TEAM<year>` + optional `.ROS` + sample `.EVN` covering every reduced-grammar play type (targets frozen grammar T009)
- [ ] T062 [P] [C][US3] Author a malformed fixture that MUST trip the gate (negative test) + the golden `expected.csv` for Layer-3 regression

### Story C3 — Mislabeled-judgment adversarial corpus  *(US2 · FR-006a · SC-003)* 🎯

- [ ] T063 [C][US2] Grow the real mislabeled-judgment corpus `evals/judgment-corpus/corpus.jsonl` (facts = judgment, label = deterministic) across all v1 judgment triggers (hit/error, earned/unearned, contested credit, ambiguous advance) — replaces the seed (T011) via the T010 interface

### Story C4 — Gold-standard dataset  *(US1/US3 · SC-001/002 · D6)*

- [ ] T064 [C] **Build one gold game** (primary path): pick an MLB game with a published Retrosheet `.EVN`; capture/narrate audio; hand-score Reisner; independently hand-produce the event file; verify with pinned `cwevent`; cross-diff vs the published `.EVN` → `evals/gold/<game>/` (audio + Reisner + Retrosheet) **(completes H3)**
- [ ] T065 [P] [C] Package the gold game into the accuracy-eval format (T010 interface) so A's `accuracy.sh` (T042) measures field accuracy, not self-consistency

### Story C5 — Outreach: scorer cohort + amateur gold  *(SC-010 · ADR-0006 distribution tripwire)* — parallel lead-time

- [ ] T066 [P] [C] Open SABR Official Scoring Research Committee + Retrosheet (Tom Thress) relationships; recruit 2–3 active scorers to co-produce amateur gold games (beachhead-representative) — tracked, not build-blocking
- [ ] T067 [P] [C] Recruit the **~20 serious-scorer demo cohort** for the ADR-0006 first-slice demo; log access risk against the distribution tripwire (review 2026-07-31)

### Story C6 — Multi-target build CI + supply chain  *(Art. XXXV/XXXVI)*

- [ ] T068 [P] [C] CI matrix builds the Rust core for iOS (device+sim), Android ABIs, host CLI, WASM; caches XCFramework correctly (delete-before-regenerate) in `.github/workflows/ci.yml`
- [ ] T069 [P] [C] Wire the no-float lint (T016), determinism check, SC-003 gate (T041), and `cwevent` gate (T060) as CI hard-fails; pin model assets + dependencies (lockfiles)

### Story C7 — Privacy/observability factory checks  *(Art. XXIII/XXVI · FR-022/029)*

- [ ] T070 [P] [C] COPPA/process-don't-store CI check: assert no raw-audio persistence path + consent-flow presence (FR-022/029); secret scan (existing) extended

**Checkpoint C**: `cwevent` gate + fixtures green independently; gold game validates clean; corpus + CI
hard-fails wired. A's emitter (H2) and accuracy SCs (H3) now have authoritative validation.

---

## Phase Final-1: Integration & MVP Demo  *(US1 + US2 + US3 converge)* 🎯

- [ ] T071 [A][B] **H1 integration**: replace MockCore with the real UniFFI core in iOS; rerun the full loop; assert no behavior change
- [ ] T072 [A][C] **H2 integration**: run A's emitter output through C's pinned `cwevent` gate end-to-end (SC-004 zero errors)
- [ ] T073 [A][C] **H3 integration**: run A's accuracy runner against C's real gold game (SC-001/SC-002 now field-credible)
- [ ] T074 [A][B][C] End-to-end slice on real device: speak → score → judgment → confirm → finalize → `cwevent`-clean export; build the demo for the ~20-scorer cohort (ADR-0006 artifact)

## Phase Final-2: Polish & Cross-Cutting

- [ ] T075 [P] Run `quickstart.md` validation end-to-end (CLI + iOS)
- [ ] T076 [P] Field-test crowd-noise WER on short baseball phrases (the real ASR risk; ties SC-005/A5) — record results in `docs/evaluations/`
- [ ] T077 [P] Observability/audit review: every primitive emits `CapabilityInvocation` (Art. XXIII)
- [ ] T078 [P] Docs: update `docs/PROJECT_CONTEXT.md`, `DECISIONS.md` (if architecture shifted), `docs/evaluations/`
- [ ] T079 Run `/workflows:review` (independent verification, Art. XX) then `/ce:review` before merge
- [ ] T080 `/workflows:compound` — capture non-obvious learnings to `docs/solutions/`

---

## Definition of Done & Acceptance Criteria

### Global Definition of Done (applies to EVERY story/task before it can close)

A story/task is **Done** only when (subset of the constitution's 25-point DoD, Art. XXXIV):

- [ ] Code on a valid typed branch (`feat/<squad>/<TICKET>-<slug>`); **never `main`** (Art. XVIII).
- [ ] All ACs below pass; relevant tests green (`cargo test` / XCTest); **contract tests exist for any new
      primitive** (Art. XI); **eval coverage** exists for changed agent behavior (Art. XXI).
- [ ] Project hard-gates pass where touched: **no-float lint**, **determinism check**, **SC-003 judgment
      gate**, **pinned `cwevent` gate** — all green.
- [ ] Agent-native parity preserved (the capability is invokable by agent/CLI, not UI-only) (Art. II).
- [ ] Authority asserted at the boundary; least-privilege; no secrets; COPPA process-don't-store honored.
- [ ] Observability: important actions emit a `CapabilityInvocation` audit record (Art. XXIII).
- [ ] Independent verification where warranted (Art. XX); CI watched via `/watch-ci` after push/PR/merge.
- [ ] Docs updated; non-obvious learning compounded; `DECISIONS.md`/ADR updated for architectural change.
- [ ] Reviewed via `/ce:review` before merge.

### Per-story acceptance criteria (Gherkin) — the GitHub-issue ACs

> These are the testable ACs each GitHub **story** issue carries. They extend the spec's acceptance
> scenarios (spec.md §User Scenarios) to the squad/story granularity.

#### Epic A — Deterministic Scoring Core & Agent Parity

**Story A2 — Game-state machine + event log** (US1)
```gherkin
Scenario: A spoken deterministic play advances state correctly
  Given a game in progress with a batter at the plate
  When record_play receives facts for "ground ball to short, threw him out at first"
  Then the engine records a 6-3 putout, credits one out, and advances the batting order
  And the resulting state is returned as a preview that is NOT applied until confirmed
Scenario: State never advances on an unconfirmed entry
  Given a recorded play awaiting confirmation
  When a new record_play arrives before PlayConfirmed
  Then the engine returns PENDING_CONFIRMATION and the game state is unchanged
Scenario: Determinism
  Given the same confirmed event log
  When the projection is rebuilt twice
  Then the two outputs are byte-identical
```

**Story A3 — Fact-derived judgment classifier + SC-003 counter** (US2 · the cardinal seam)
```gherkin
Scenario: A mislabeled judgment is still flagged (fact-derived, not label-derived)
  Given a play whose facts are a hit-vs-error judgment but whose supplied type label is "single"
  When classify() runs
  Then the play is classified as Judgment(HitVsError) and surfaced for a decision
  And it is NOT silently resolved
Scenario: The silent-resolution counter trips on violation (gate is not vacuous)
  Given the adversarial judgment corpus
  When any book mutation resolves a fact-classified judgment without an open flag + recorded decider
  Then the silent_resolution_counter increments and the eval gate FAILS the build
Scenario: Earned/unearned defers in an error inning
  Given a run scores in a half-inning containing a defensive error
  When the run is recorded
  Then earned_unearned = PENDING and no earned/unearned status is asserted by the engine
```

**Story A4 — Reisner renderer + proof-box** (US1)
```gherkin
Scenario: Proof-box balances every completed half-inning
  Given a completed half-inning
  When the proof box is computed
  Then AB + BB + Sacrifices + HBP + Interference equals Runs + Putouts + Runners-stranded
Scenario: Reisner rendering is stable
  Given a recorded play
  When it is rendered
  Then the Reisner cell (situation diamond + catalyst + runner fate) matches the golden snapshot
```

**Story A5 — Reduced-Retrosheet emitter** (US3)
```gherkin
Scenario: In-format play emits a valid reduced-Retrosheet record
  Given a play within the frozen reduced grammar
  When the emitter runs
  Then it produces a play record that the pinned cwevent gate parses with zero errors
Scenario: Out-of-format play is flagged, never fabricated
  Given a play whose facts fall outside the reduced v1 grammar (the hard ~5%)
  When the game is finalized
  Then that play is flagged needs-review and NO fabricated play record is emitted
```

**Story A6 — `correct_event` + recompute** (US4 · post-MVP)
```gherkin
Scenario: Correction recomputes downstream and preserves history
  Given several recorded plays and an earlier misheard play
  When correct_event amends the earlier play
  Then downstream runners/outs/line-score/notation/proof-box are actually recomputed
  And the original version remains in an auditable history (no silent overwrite)
  And any downstream plays invalidated by the change are surfaced for review
```

**Story A7 — `finalize_scorecard`** (US3)
```gherkin
Scenario: Finalize produces agreeing book + export, or fails loudly
  Given a completed, fully-confirmed game
  When finalize_scorecard runs
  Then it produces a human book and a reduced-Retrosheet file that agree play-for-play
  And any unbalanced proof box causes finalize to FAIL rather than silently pass
  And unresolved PENDING judgments are reported, not auto-decided
```

**Story A8 — UniFFI + CLI/agent parity** (US1–US3)
```gherkin
Scenario: Agent path equals human path (parity)
  Given the same play facts
  When an agent/CLI invokes record_play and the UI path invokes record_play
  Then the resulting state, notation, classification, and verify semantics are identical
Scenario: Authority is enforced at the boundary
  Given a caller that is neither the game owner nor an explicitly authorized agent
  When any primitive is invoked
  Then it returns UNAUTHORIZED and appends no event
```

**Story A9 — Eval-harness mechanics** (US2/US3)
```gherkin
Scenario: Accuracy runner is honest about its inputs
  Given the eval suite runs against a self-constructed game (no real gold yet)
  When accuracy is reported
  Then SC-001/SC-002 results are labeled self-consistency (advisory), not field accuracy
  And they become hard/credible only once the real gold dataset (H3) is present
```

#### Epic B — iOS Voice Client & Judgment UI

**Story B2 — Two-engine Transcriber** (US1)
```gherkin
Scenario: Push-to-talk transcribes offline and retains no audio
  Given the device has no network connectivity and the ASR asset is preloaded
  When the scorer holds the button and speaks one play
  Then a transcript is produced on-device
  And the audio PCM buffer is released immediately and never written to disk
```

**Story B3 — Grammar parse + ambiguity** (US1)
```gherkin
Scenario: Low-confidence input asks, never guesses
  Given a transcript the grammar cannot map with confidence
  When parsing runs
  Then the app asks a single clarifying question or offers manual entry
  And it does NOT silently record a guessed play
```

**Story B4–B5 — V3 glance HUD + Card A** (US1 · SC-005)
```gherkin
Scenario: A deterministic play is confirmable at a glance
  Given a deterministic play has been recorded
  When Card A appears
  Then it shows a plain-language restatement with the Reisner token secondary and the state delta
  And one tap on Confirm advances to the next play
  And median eyes-on-screen time per play is <= 3 seconds (>= 80% of plays <= 1 phrase + 1 tap)
```

**Story B6 — Card B judgment** (US2)
```gherkin
Scenario: A judgment play stops and asks, visibly different
  Given a play classified as judgment
  When Card B appears
  Then it shows a visually distinct "Your call" posture with a recommendation + one-line why and equal alternatives
  And the scorer cannot advance to the next play without an explicit choice (including "leave PENDING")
  And resolving it takes one tap (<= 5s)
```

**Story B7 — Offline persistence** (US1 · SC-006)
```gherkin
Scenario: A full game survives offline with no data loss
  Given a full 80-300 play game scored with no connectivity
  When the app is backgrounded/relaunched mid-game
  Then every recorded event is intact and the game resumes exactly where it left off
```

**Story B8 — Export UI** (US3)
```gherkin
Scenario: One-tap export yields a cwevent-clean file
  Given a finalized game on device
  When the scorer taps Export
  Then a Retrosheet event file (with required attribution) and the human book are produced
  And the file passes the pinned cwevent gate with zero errors
```

#### Epic C — Standards, Eval Data & Software Factory

**Story C1 — `cwevent` 3-layer gate** (US3 · SC-004)
```gherkin
Scenario: The gate fails on warnings even when cwevent exits 0
  Given a generated event file that cwevent parses but emits a stderr WARNING for
  When the acceptance gate runs the pinned cwevent v0.10.0
  Then the gate FAILS (stderr matched WARNING|Invalid|Can't find|could not open) despite exit code 0
Scenario: The gate passes a clean file
  Given a valid reduced-grammar event file with its TEAM<year> file
  When the gate runs
  Then stderr is clean, >= 1 event row is emitted, and the golden diff matches expected.csv
```

**Story C3 — Adversarial corpus** (US2 · FR-006a)
```gherkin
Scenario: The corpus exercises every v1 judgment trigger
  Given the mislabeled-judgment corpus
  When it is run through classify()
  Then every entry (hit/error, earned/unearned, contested credit, ambiguous advance) is surfaced as judgment
  And zero entries are silently resolved
```

**Story C4 — Gold dataset** (SC-001/002 · D6)
```gherkin
Scenario: One credible gold game exists end-to-end
  Given an MLB game with a published Retrosheet .EVN
  When the gold game is built (audio + hand-scored Reisner + independently produced event file)
  Then the produced event file passes the pinned cwevent gate
  And it cross-diffs clean against the published .EVN
  And it is packaged so the accuracy runner measures field accuracy (H3 complete)
```

**Story C5 — Outreach** (SC-010 · ADR-0006 tripwire)
```gherkin
Scenario: The demo cohort and distribution risk are tracked
  Given the first-slice demo build target
  When ~20 serious scorers cannot be lined up within the build window
  Then the access/GTM red flag is logged against the ADR-0006 distribution tripwire (review 2026-07-31)
```

**Story C6 — Multi-target CI** (Art. XXXV)
```gherkin
Scenario: One core builds for all surfaces
  Given the Rust core
  When CI runs the build matrix
  Then it builds for iOS (device+sim), Android ABIs, host CLI, and WASM from the one crate
  And the no-float lint, determinism check, SC-003 gate, and cwevent gate are all CI hard-fails
```

#### Epic Foundations (cross-squad)

**Foundational interfaces (T007–T012)**
```gherkin
Scenario: Squads unblock without blocking each other
  Given the FFI schema, mock core, frozen reduced grammar, and eval-harness interface are committed
  When Squads A, B, C begin their epics
  Then B builds the full UI against the mock core, A+C develop emitter/gate against the frozen grammar,
       and A runs evals on the seed corpus — with no squad waiting on another's incomplete work
```

---

## Dependencies & Cross-Squad Handoffs

### Handoffs (the only hard cross-squad couplings — front-loaded in Phase 2)

| ID | From → To | Artifact | Unblocks | Mitigation |
|----|-----------|----------|----------|------------|
| **H1** | A → B | UniFFI core (T037) replaces MockCore (T008) | B's real integration | B builds against the **frozen FFI schema (T007)** + mock until then |
| **H2** | A ↔ C | A's emitter (T029) ↔ C's `cwevent` gate (T060) | Authoritative export validation | Both target the **frozen reduced grammar (T009)**; develop independently |
| **H3** | C → A | Real gold dataset (T064) → A's accuracy runner (T042) | Field-credible SC-001/002 | A runs on the **seed corpus (T011)** + synthetic until the gold game lands |

### Phase order

- **Phase 1 Setup** → **Phase 2 Foundational** (front-loads H1/H2/H3 interfaces) → **Epics A/B/C in
  PARALLEL** → **Integration (T071–T074)** → **Polish**.
- Within squads: model/schema → rules/services → primitives → adapters/UI → eval.
- **US4 (`correct_event`, T032–T033) + sync (T058)** are post-MVP — not in the first demo slice.
- **Rule 9.16** earned-run reconstruction is **out of v1** (earned/unearned = PENDING).

### Parallel opportunities

- After Phase 2, **all three squads run fully in parallel** (distinct directories, no shared files).
- `[P]` within a squad = parallel-safe (distinct files).
- C5 outreach (T066/T067) runs from day one (lead-time), independent of all code.

---

## User-Story Coverage (traceability across squads)

| Story | Squad A | Squad B | Squad C | MVP? |
|-------|---------|---------|---------|------|
| **US1** speak→score→Reisner→confirm | T013–T020, T026–T028 | T044–T056 | T064–T065 | 🎯 |
| **US2** judgment loop (never silent) | T021–T025 | T054 | T063 | 🎯 |
| **US3** Retrosheet export | T029–T031, T034–T035 | T057 | T059–T062 | 🎯 |
| **US4** correction (history) | T032–T033 | (UI later) | — | post-MVP |
| Parity (all) | T036–T040 | — | — | 🎯 |
| Eval/CI gates | T041–T043 | — | T068–T070 | 🎯 |

**Invariant coverage:** I1/I2 → T021/T024/T025/T063 · I3 → T023 · I4 → T059/T060/T072 · I5 → T036 ·
I6 → T016. **SC-003 (cardinal)** is gated by T024 (counter) + T025 (negative test) + T063 (corpus) +
T041 (runner) — wired CI hard-fail.

---

## GitHub Epic → Story → Subtask mapping (for `/speckit-taskstoissues`)

- **Epic A — Deterministic Scoring Core & Agent Parity** → Stories A2–A9 (above) → subtasks = their T-IDs.
- **Epic B — iOS Voice Client & Judgment UI** → Stories B1–B9 → subtasks = their T-IDs.
- **Epic C — Standards, Eval Data & Software Factory** → Stories C1–C7 → subtasks = their T-IDs.
- **Epic Foundations** (cross-squad) → Phase 1 Setup + Phase 2 Foundational (T001–T012) + Integration
  (T071–T074) → owned jointly, the synchronization points.

Suggested issue labels: `squad:A|B|C`, `epic:core|ios|factory|foundations`, `story:A2…C7`,
`us:1|2|3|4`, `mvp`, `blocked-by:H1|H2|H3`. Suggested milestone: **`v1-first-slice (US1+US2+US3 demo)`**.

---

## Implementation Strategy

1. **Together:** Phase 1 Setup + Phase 2 Foundational (the unblocking interfaces). Small, fast, shared.
2. **Parallel:** A/B/C run their epics independently against the frozen interfaces. B uses the mock core;
   A+C develop emitter/gate against the frozen grammar; A runs evals on the seed corpus while C builds gold.
3. **Converge:** Integration (H1/H2/H3) → the **US1+US2+US3 demo build** for ~20 scorers (the ADR-0006
   artifact + the A5 usability / crowd-noise field test).
4. **Defer:** US4 correction UI + CloudKit sync; Rule 9.16 stays out of v1.
