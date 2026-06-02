# PROJECT_CONTEXT.md — Diamond Ledger

> **Fast-orientation single source.** Load this to get current. The binding authority is the
> constitution (`.specify/memory/constitution.md`); this file is the map + index, kept in sync with
> `DECISIONS.md` and `docs/solutions/`. Last updated 2026-06-01 (plan 001 + ADR-0007).

## 1. What this is

**Diamond Ledger** — a voice-driven baseball scorebook. You speak a play
(*"ground ball to short, threw him out at first"*); a **deterministic scoring engine** renders it in
**Reisner** notation, tracks full game state, surfaces the ~15% scorer-judgment plays for a one-tap
decision (never silently), and exports a **Retrosheet**-compatible event file.

It is an **agent-native capability system** (not a UI-first app with AI bolted on): a graph of small,
permissioned, composable primitives where **humans and agents are equal first-class users**
(constitution Art. II). **North Star:** *can someone use this for something we never imagined?*

**Beachhead:** the serious/official scorekeeper (travel/HS/college statistician, Retrosheet/SABR
archivist). The rec parent is *expansion*, not the v1 target.

## 2. Status (2026-06-01)

| Phase | State |
|---|---|
| Constitution (40 articles) | ✅ ratified (ADR-0001) |
| Software factory (CI, hooks, branch discipline) | ✅ (ADR-0002/0004/0005) |
| Product: PR/FAQ → discovery → experiments | ✅ (verdict REFINE: beachhead = serious scorer) |
| **Spec 001** (voice-scorebook core) | ✅ specified → clarified ×2 → **probe-hardened** → merged |
| **Prototype** (judgment loop, Wizard-of-Oz) | ✅ merged; **V3 (glance)** chosen |
| **Build authorization** | ✅ **authorized ahead of A1/A3** (ADR-0006) |
| **Plan 001** (tech design + Phase 0/1 artifacts) | ✅ `plan.md` + research/data-model/contracts/quickstart; stack confirmed (ADR-0007) |
| **Tasks / implement** | ⏳ next — `/speckit-tasks` |

**Demand validation is a parallel instrument, not a gate** (ADR-0006). Build proceeds; A1/A3 runs
alongside with tripwires (review 2026-07-31). Riskiest assumption (paying-beachhead adoption;
Retrosheet valued beyond SABR) is **confidence-L, untested**.

## 3. Architecture quick ref (intended; no production code yet)

- **Pattern:** a **deterministic rules engine** (source of truth) wrapped around a **probabilistic
  interpreter** (speech/text → candidate event), with a **read-verify-correct loop**.
- **Primitives (atomic, agent + UI co-equal):** `record_play` · `advance_runner` · `correct_event` ·
  `finalize_scorecard`.
- **v1 surface:** a consumer mobile app, **iOS-first** (Android fast-follow), **on-device + offline**,
  push-to-talk. Same primitives invokable by agent/API/CLI (parity).
- **Standards:** **Reisner** notation (human book); **Retrosheet** event file (machine export),
  authoritative gate = **Chadwick `cwevent`** pinned.
- **Canonical interaction:** **V3 glance** judgment card (glanceable, one-tap, ≤5s eyes-down).
- **Spec:** `specs/001-voice-scorebook-core/spec.md` (32 FRs, 11 SCs).
- **Confirmed stack (ADR-0007):** **Rust** core (integer-only, no-float) + **UniFFI** → iOS/Android/CLI/
  agent from one artifact; ASR = Apple `SpeechAnalyzer` + sherpa-onnx/Parakeet (two-engine); grammar parse
  (no LLM v1); **`cwevent` v0.10.0** pinned (stderr-driven 3-layer gate); event-sourced SQLite/GRDB +
  CloudKit (no CRDTs). Plan + Phase 0/1 artifacts in `specs/001-voice-scorebook-core/`.

## 4. Decisions index (`DECISIONS.md`)

| ADR | Decision |
|---|---|
| 0001 | Ratify the engineering constitution |
| 0002 | Software factory: advisory CI + hook-based branch protection |
| 0003 | Compound-loop gate (merge-triggered) |
| 0004 | Hook hardening: branch-discipline defense-in-depth + compound-gate recursion fix |
| 0005 | Compound-gate recursion backstop (don't resolve volatile context via a racing live call) |
| **0006** | **Build authorized ahead of the A1/A3 demand gate → parallel instrument + tripwires** |
| **0007** | **v1 tech architecture: Rust core + UniFFI parity · two-engine ASR · pinned `cwevent` v0.10.0 · event-sourced SQLite/CloudKit · first slice US1+US2+US3** |
| **0008** | Cargo **workspace root at repo root** (members must live below root) · toolchain pin bumped 1.83→1.96 (proptest MSRV) |

## 5. Critical invariants (spec 001 — the probe broke these once; keep them)

| # | Invariant | Ref |
|---|---|---|
| I1 | Judgment classification is **fact-derived, never label-derived** | FR-006 / FR-010 |
| I2 | The no-silent-judgment gate is **instrumented + adversarial-corpus hard-fail** (not a dead counter) | FR-006a / SC-003 |
| I3 | Earned/unearned = **`PENDING`** for any run in an error inning (no Rule 9.16 in v1) | FR-010a / FR-017 |
| I4 | Retrosheet acceptance = **Chadwick `cwevent` pinned**; reduced validators non-authoritative | FR-016 / SC-004 |
| I5 | **Owner-as-decider** authority (org roles deferred) | FR-020 |
| I6 | Determinism: same confirmed inputs → identical output | FR-003 |

## 6. Critical patterns & learnings index (`docs/solutions/`)

**Canonical index layer (seeded 2026-06-02):** `patterns/critical-patterns.md` (P1 invariants:
assert-real-signal-not-proxy, fact-derived classification, no-float determinism, owner-as-decider) ·
`patterns/common-solutions.md` (P2/P3 index + fast-path checklists). Start there; the table below is
the underlying detail docs.

| Pattern | File |
|---|---|
| **Spec-coherence probe** — throwaway agent build to break a spec before production code | `design-patterns/spec-coherence-probe.md` |
| Discovery relocates the beachhead | `design-patterns/discovery-relocates-the-beachhead.md` |
| **Shell portability in agent batch automation** (zsh/BSD; spot-check before batching) + gh native sub-issues | `best-practices/shell-portability-in-agent-batch-automation.md` |
| **Verify generated code with the real toolchain** (not static review/advisory CI) + Cargo workspace gotchas | `best-practices/verify-generated-code-with-real-toolchain.md` |
| Spec Kit + CI/merge-gate gotchas | `conventions/speckit-branch-naming-and-merge-gotchas.md` |
| Hook command-string matching pitfalls | `best-practices/hook-command-string-matching-pitfalls.md` |
| `/watch-ci` gate choreography (+ `skipped`≠`failure`) | `workflow-issues/watch-ci-gate-choreography.md` |
| Private-repo branch-protection fallback · unauthored template root commit | `conventions/` |

## 7. Anti-patterns (do not reintroduce)

- **Classifying/gating on a caller-supplied label/type** instead of the underlying facts (exploitable).
- **Un-instrumented measurement gates** — a "0 / 100%" criterion that no code can make fail passes
  vacuously. Wire an adversarial corpus that trips it.
- **Spec Kit `NNN-` branch names** (fail the Article XVIII CI regex) — use `feat/<squad>/<TICKET>-<slug>`.
- **A `build/` source dir** (silently `.gitignore`d) — name it `app/` or force-add.
- **Committing/pushing to `main`** (hook-blocked) — always branch + PR; `/watch-ci` after.

## 8. Methodology & workflow

Spec Kit (constitution → specify → clarify → plan → tasks → implement) inside the **Compound
Engineering** loop (~80% planning/review). Design (the risky-interaction prototype) **leads** the
plan; run the **spec-coherence probe** before planning. Branch discipline is hook-enforced
(Article XVIII); after any push/PR/merge run **`/watch-ci`**; architectural changes get an ADR
(Article XXXVIII). See `CONTRIBUTING.md`.

## 9. Pointers

- Authority: `.specify/memory/constitution.md` · Decisions: `DECISIONS.md` · Workflow: `CONTRIBUTING.md`
- Product: `docs/product/` (PR-FAQ, discovery, experiments) · Spec + prototype: `specs/001-voice-scorebook-core/`
- Learnings: `docs/solutions/`
- **Pattern index layer:** ✅ seeded 2026-06-02 — `docs/solutions/patterns/critical-patterns.md` +
  `common-solutions.md` (ADR-0001 follow-up done). Keep them current after each `/ce-compound`.
