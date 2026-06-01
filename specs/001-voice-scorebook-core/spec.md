# Feature Specification: Voice-to-Scorebook Core

**Feature Branch**: `001-voice-scorebook-core`

**Created**: 2026-06-01

**Status**: Draft

**Input**: User description: "Deterministic voice-to-scorebook core (record_play → advance_runner → finalize_scorecard, plus correct_event) for the serious/official scorekeeper beachhead — speak a play, a deterministic scoring engine interprets it against official baseball scoring rules, renders Reisner notation, maintains full game state, surfaces the ~15% scorer-judgment plays as one-tap confirmations rather than silently auto-resolving, and exports a reduced-but-valid Retrosheet-compatible event file."

> **Source of truth.** Distilled from `docs/product/PR-FAQ.md` (revised post-discovery) and
> `docs/product/discovery/` (00 brief, 01 research synthesis, 02 opportunity map, 03 assumption
> tests). Governed by `.specify/memory/constitution.md` — notably agent-native parity (Art. II),
> contract-first atomic primitives (Art. I, XI), deterministic policy at tool boundaries (Art. VII),
> the read-verify-correct loop and honest uncertainty (Art. VI), and risk-tiered autonomy (Art. XXV).
>
> **Validation-gate note (honesty, Art. VI).** Discovery's verdict was *REFINE, then test before
> build*. This spec is being written **ahead of** the A1/A3 demand falsification gate
> (≥8% commitment by 2026-07-31; see `docs/product/experiments/`). It is the *specification* of the
> first capability; the **decision to build it remains gated** on that experiment unless the project
> lead explicitly overrides. Recorded here so the dependency is not silently lost.

## Clarifications

### Session 2026-06-01

- Q: Is the v1 deliverable the capability/primitive layer only, or the full consumer mobile app? → A: **The full consumer mobile app (iOS + Android per the PR/FAQ).** The scoring engine, the four atomic primitives, the read-verify-correct loop, push-to-talk capture, offline-first storage, one-tap confirm/correct, and Retrosheet export are all delivered **through the shipping mobile app**; per the constitution's agent-native parity (Art. II) the same capabilities remain co-equally invokable by an agent/API/CLI.
- Q: Where do speech transcription and play interpretation run? → A: **On-device, offline-first.** Transcription and play parsing run locally on the phone; a full game scores with zero connectivity and the cloud is used only for later sync. Fits the "why now" (on-device ASR + constrained decoding), COPPA process-don't-store, the offline requirement, and gross margin.
- Q: What platform scope ships in v1? → A: **iOS-first, Android fast-follow.** iOS at launch (on-device ASR most mature on Apple silicon; the serious-scorer beachhead skews iOS), Android shortly after. Lowest engineering risk for a validation-stage v1.
- Q: How do pricing tiers gate features during the beachhead-validation v1? → A: **All core features open.** Retrosheet export and official-scorer judgment controls are available to the beachhead during validation; monetization/gating is deferred, because paywalling the exact O3/O4 value would suppress the demand signal the A1/A3 experiment must measure.
- Q: What account/auth and data-ownership model does v1 use? → A: **Email + social sign-in, private-by-default, explicit share links.** Each scorebook is private to its creator and shared only by explicit action; a COPPA-aligned consent flow governs any minors' data.
- Q: Which scoring/notation system is authoritative? → A: **The Reisner system** (`reisnerscorekeeping.com/how`) is the authoritative human-readable scorekeeping notation and scoring conventions the engine renders and validates against.

### Session 2026-06-01 — Spec-coherence probe hardening

A throwaway tracer-bullet engine was built from this spec and adversarially tested (`probe-report.md`,
workflow `wf_c29a9bd1-07b`). It proved the deterministic core is buildable (determinism, proof-box,
reduced-Retrosheet emission) **but broke the cardinal invariant**: judgment classification keyed on the
caller's play *type label* rather than play *facts*, so a mislabeled judgment call was silently resolved
(5/5 adversarial probes), and the SC-003 "0 silent resolutions" gate was un-instrumented (dead). These
resolutions harden the spec:

- Q: Make judgment classification fact-derived or label-derived? → A: **Fact-derived.** Classification MUST derive from normalized play facts, never a caller-supplied type/label (FR-006, FR-010).
- Q: How is SC-003 made measurable? → A: **Instrumented silent-resolution counter + a mislabeled-judgment adversarial corpus wired as a hard-fail eval gate** (SC-003, FR-006a).
- Q: How is earned/unearned handled before Rule 9.16? → A: **First-class deferred state** — any run in a half-inning containing an error attaches `earned_unearned = PENDING` (flag-and-defer, no reconstruction) (FR-010a, FR-017).
- Q: Which Retrosheet validator is the authoritative acceptance gate? → A: **Chadwick `cwevent`, pinned version**; any offline/reduced validator is explicitly non-authoritative (FR-016, SC-004).
- Q: How much authority/permission model in v1? → A: **Owner-as-decider, roles deferred** — the authenticated owning account (or an agent it explicitly authorizes) is the valid decider/finalizer; multi-role/org permissions deferred (FR-020).
- Q: Enumerate the ~85/15 play classes in-spec now? → A: **Yes** — a normative *Play classification reference* (in Requirements) lists the deterministic set and the fact-based judgment triggers, giving FR-006/FR-010 a testable reference and the adversarial corpus a baseline.
- Q: Proof-box term mapping & "runners stranded"? → A: defined in FR-005a.
- Q: Ambiguity for text/structured input (vs. ASR confidence)? → A: defined in FR-008.
- Q: Reisner situation-diamond/catalyst representation? → A: required as first-class structured fields in FR-005.
- Q: Downstream recompute on correction? → A: full recompute + surface, not flag-only (FR-012/FR-014).
- Q: Gold-dataset adequacy? → A: a **real, independent, multi-inning** hand-scored game is required before SC-001/SC-002 are credible (the probe's gold was agent-constructed/self-consistent only).

## User Scenarios & Testing *(mandatory)*

The beachhead user is the **serious/official scorekeeper** — a travel/select, high-school, or
college statistician/official scorer, or a Retrosheet/SABR archivist. The **v1 deliverable is a
shipping consumer mobile app (iOS + Android)**: the scorekeeper does everything below from the app —
push-to-talk capture, the one-tap confirm/correct loop, judgment decisions, offline play, and
Retrosheet export. Per the constitution, an **agent (or API/CLI client) is an equal first-class
user**: every journey is also performed through the *same* capabilities programmatically, with
identical effect and verify/correct semantics. The capabilities are atomic, composable verbs:
`record_play`, `advance_runner`, `correct_event`, `finalize_scorecard` — exposed in the app's UI and
to agents alike.

### User Story 1 - Score a play by speaking it (Priority: P1)

A scorekeeper sets up a game (two teams, optional lineups), watches a play, then presses to talk
and describes what happened in plain language — *"ground ball to short, threw him out at first."*
The system transcribes the speech, interprets it against the official rules, advances the game
state (count, runners, outs, inning, line score, batting order), renders the play in standard
Reisner notation, and shows the recorded result for one-tap confirmation before the next play.

**Why this priority**: This is the single hard thing the whole product must prove — *a spoken
sentence becomes a rules-correct entry in an official book*. With only this story, a scorer can keep
a complete deterministic book by voice, eyes on the field. It is the minimum viable, independently
demonstrable slice.

**Independent Test**: Start a game, speak a sequence of unambiguous plays, and verify the running
game state, notation, and line score match a hand-scored reference for each play — no other story
required.

**Acceptance Scenarios**:

1. **Given** a game in progress with a batter at the plate, **When** the scorer says *"ground ball
   to short, threw him out at first,"* **Then** the system records a 6-3 putout in Reisner notation,
   credits the out, advances to the next batter, and displays the result for confirmation before
   accepting the next play.
2. **Given** a runner on first and none out, **When** the scorer says *"line drive single to right,
   runner to third,"* **Then** the system records a single (notation), places the batter on first,
   advances the prior runner to third, updates the line score, and shows the new base state.
3. **Given** the scorer has not yet confirmed the displayed play, **When** they speak the next play,
   **Then** the system requires confirmation (or correction) of the pending play before applying the
   new one — it never advances state on an unconfirmed entry.
4. **Given** an agent client (not a human), **When** it invokes `record_play` with the same play
   description, **Then** the resulting game-state change, notation, and verify step are identical to
   the human path (agent-native parity).
5. **Given** a spoken description the interpreter cannot map with confidence, **When** it is
   ambiguous or low-confidence, **Then** the system asks a clarifying question (re-prompt) or offers
   a quick manual-entry fallback rather than guessing silently.

---

### User Story 2 - Decide the scorer-judgment plays, never silently (Priority: P1)

For the ~15% of plays that require scorer judgment — hit vs. error, earned vs. unearned run, who is
charged with the putout/assist — the system presents the play as an explicit decision with the
engine's recommended call and the alternatives, and records the human's (or authorized agent's)
choice in one tap. It **never** silently auto-resolves a judgment call.

**Why this priority**: This is the trust differentiator and the failure mode that would collapse the
"official, Retrosheet-compatible" promise for the very segment that validates the product
(Opportunity O3, accuracy/officialness, score 15). Silently guessing a hit/error is the cardinal
sin. Co-equal P1 with US1 because an official book is worthless if its judgment calls are fabricated.

**Independent Test**: Feed plays that are deterministically scorable and plays that require judgment;
verify that 100% of judgment plays stop and ask, present a defensible default plus alternatives, and
record who decided — and that 0% are auto-resolved silently.

**Acceptance Scenarios**:

1. **Given** a ball that a fielder reaches but misplays, **When** the play is recorded, **Then** the
   system classifies it as a judgment call, surfaces *hit vs. error* with its recommendation and
   reasoning, and waits for the scorer's one-tap decision before finalizing the entry.
2. **Given** a run scores in an inning where a defensive error occurred, **When** the run is recorded,
   **Then** the system attaches an `earned_unearned = PENDING` flag (FR-010a) and does not assert an
   earned/unearned status on its own (full Rule 9.16 reconstruction is deferred — see Scope), to be
   resolved only by an explicit decider.
3. **Given** a judgment decision has been made, **When** it is recorded, **Then** the entry stores
   the decider's identity (human scorer or authorized agent) and the chosen call, and renders the
   resulting notation accordingly.

---

### User Story 3 - Export a reduced-but-valid Retrosheet event file (Priority: P2)

When a game is complete (or at any checkpoint), the scorekeeper finalizes the scorecard and exports
the game as a Retrosheet-compatible event file plus the human-readable scorebook. The exported file
covers the reduced-but-valid format (play type + fielder sequence + result) and parses cleanly with
standard Retrosheet tooling.

**Why this priority**: Retrosheet portability is the second under-served opportunity (O4, score 14)
and the proof that a Diamond Ledger book is *the same kind of artifact* the pros use — the thing no
incumbent ships. It is P2 only because a correct book (US1+US2) must exist before exporting it is
meaningful.

**Independent Test**: Finalize a fully scored game and export it; verify the event file parses with
standard Retrosheet tooling with zero validation errors across all covered play types, and that the
human scorebook matches the exported events.

**Acceptance Scenarios**:

1. **Given** a completed, fully-confirmed game, **When** the scorer invokes `finalize_scorecard` and
   exports, **Then** the system produces a Retrosheet-compatible event file and a human-readable
   scorebook that agree play-for-play.
2. **Given** the exported event file, **When** it is parsed by standard Retrosheet tooling, **Then**
   it validates without errors for every play type in the reduced format.
3. **Given** a game containing a play type outside the reduced v1 format, **When** the game is
   finalized, **Then** the system clearly flags that play as needing manual handling rather than
   emitting an invalid or fabricated event.

---

### User Story 4 - Correct a prior play with history preserved (Priority: P2)

At any point the scorekeeper realizes an earlier play was misheard or misjudged. They say
*"correction"* (or an agent invokes `correct_event`), amend the prior play, and the system
recomputes downstream game state — while preserving the full history of the change rather than
silently overwriting it.

**Why this priority**: Correction is what makes the live read-verify-correct loop trustworthy and is
required by the constitution's honesty/auditability principle. P2 because it depends on plays
existing (US1) and on judgment handling (US2), but it is essential before a serious scorer will rely
on the book.

**Independent Test**: Record several plays, correct an earlier one, and verify the downstream state
(runners, outs, line score, notation) recomputes correctly and the prior version remains in an
auditable history.

**Acceptance Scenarios**:

1. **Given** a recorded play that was misheard, **When** the scorer issues a correction, **Then** the
   system applies the amended play, recomputes affected downstream state, and retains the original
   entry in a visible change history (no silent rewrite).
2. **Given** a correction that invalidates later plays (e.g., changes the out count), **When** it is
   applied, **Then** the system surfaces the affected downstream plays for review rather than
   discarding them silently.
3. **Given** a correction performed by an agent via `correct_event`, **When** it completes, **Then**
   the result and the preserved history are identical to the human-initiated path.

---

### Edge Cases

- **Ambiguous or low-confidence transcription** (accents, crowd noise, natural phrasing): the system
  re-prompts or offers quick manual entry; it must not silently record a guessed play.
- **Play spoken before the previous one is confirmed**: the pending entry must be confirmed or
  corrected first; state never advances on an unconfirmed play.
- **Impossible/contradictory description** (e.g., a third out when two are already out, or advancing
  a runner who is already out): the system rejects or asks for clarification rather than corrupting
  state; a third out correctly ends the half-inning.
- **Correction cascade**: an amended earlier play changes outs/runners for later plays — downstream
  entries are surfaced for review, not silently dropped.
- **Play outside the reduced v1 format** (~5% exotic plays / full earned-run counterfactual): flagged
  for manual handling and labeled honestly as approximate/needs-review, never fabricated as certain.
- **Network loss mid-game**: a full game continues offline with no data loss and syncs when
  connectivity returns.
- **Substitutions and lineup changes mid-game**: tracked sufficiently to keep batting order and
  fielder identity correct for notation and export.
- **Audio handling for minors**: voice is processed to extract the play and not retained as a stored
  recording by default (COPPA-aligned, process-don't-store).

## Requirements *(mandatory)*

### Functional Requirements

**Game setup & state**

- **FR-001**: System MUST let a user start a new game with two team names and, optionally, full
  lineups/rosters; a casual book MAY proceed with team names only.
- **FR-002**: System MUST maintain complete, queryable game state at all times: balls/strikes count,
  base occupancy, outs, inning and half, line score, batting-order position for each side, pitch
  sequence, and active fielders/lineup including substitutions.
- **FR-003**: System MUST treat every scoring change as deterministic and reproducible given the same
  confirmed inputs — the rules engine is the source of truth, not a probabilistic guess.

**Recording a play (`record_play`)**

- **FR-004**: Users MUST be able to record a completed play by speaking a natural-language
  description after the play (push-to-talk; not continuous listening).
- **FR-005**: System MUST transcribe the spoken description and interpret it into a structured
  scoring event, applying the official rules of baseball scoring to assign hits, outs, errors, and
  fielder credit, and to render the play in the **Reisner scorekeeping system** as defined at
  `reisnerscorekeeping.com/how` (the authoritative notation and scoring conventions). This includes
  Reisner's distinctive elements: the per-at-bat **situation diamond** (baserunners at the start of
  the play) plus the **catalyst** area (what occurred); standard position numbers (1–9, 0=DH);
  hit/out/event symbols (S/D/T/H with /G,/L,/B,/SF modifiers; K; position-number outs e.g. 6-3;
  W/IW/HP/E/FC/SB/CS/PO/PB/WP); pitch-count marks (balls, called vs. swinging strikes, fouls, ball
  in play); and runners-who-scored marked **circled (with RBI)** or **underlined (without RBI)**.
  The parsed structured event MUST model the **situation diamond** (pre-play base/out/count state) and
  the **catalyst** (what occurred) as first-class typed fields — not free-form prose — so classification
  (FR-006), rendering, the proof box, and export all read one shared representation.
- **FR-005a**: System MUST compute and be able to display the Reisner **proof box** reconciliation
  for each half-inning/game — *at-bats + walks + sacrifices + hit batsmen + interference = runs +
  putouts + runners stranded* — as an internal accuracy check. **Term mapping (normative):** walk/IBB
  → walks; HBP → hit batsmen; SF/SH → sacrifices; batter-interference calls → interference; a batter
  who reaches on an error is charged an at-bat (not a hit). **Runners stranded = runners physically on
  base at the third out** of the half-inning; runners retired on a force/double play are not counted
  as stranded. The proof box MUST balance for every completed half-inning (SC-011).
- **FR-006**: System MUST classify each play as either **deterministic** (auto-resolvable, ~85%) or
  **scorer-judgment** (~15%) **from the normalized play facts** (the situation diamond + catalyst of
  FR-005), per the *Play classification reference* below — **never** from a caller-supplied play
  type/label. A play whose facts constitute a judgment MUST be classified as judgment even if it
  arrives labeled as a deterministic type.
- **FR-006a**: The classifier MUST be validated by a **mislabeled-judgment adversarial corpus** —
  plays whose supplied type label is deterministic but whose facts are a judgment call. Any corpus
  play the system resolves without surfacing a judgment is a **hard eval-gate failure**; no build
  passes with a nonzero silent-resolution count (see SC-003).
- **FR-007**: System MUST display the recorded result (notation + resulting state) for explicit
  confirmation or correction **before** accepting the next play (read-verify-correct loop); it MUST
  NOT advance state on an unconfirmed entry.
- **FR-008**: System MUST re-prompt for clarification or offer manual entry — never silently guess —
  whenever interpretation is ambiguous. **Ambiguity is defined per input mode:** (a) **spoken** input —
  transcription/parse confidence below a configured threshold; (b) **structured/text** input — a play
  that maps to more than one valid scoring event, omits a field required to score it, or yields an
  out-of-format result. A clarification (missing/contradictory facts) is distinct from a scorer-
  judgment flag (a complete fact set that requires a ruling, FR-010).

**Runner advancement (`advance_runner`)**

- **FR-009**: System MUST advance base runners deterministically per the rules as a consequence of
  the recorded play, and MUST surface ambiguous advances for confirmation rather than assuming them.

**Scorer-judgment handling**

- **FR-010**: System MUST NOT silently auto-resolve any scorer-judgment call. Judgment status MUST be
  derived from the play **facts** (per the *Play classification reference* below), **never** from a
  caller-supplied play type/label — a play whose facts constitute a judgment is flagged even if it
  arrives labeled as a deterministic type. When a play is judgment, the system MUST present it with a
  recommended call, the alternatives, and accept a one-tap decision before the entry is finalized.
  The v1 judgment triggers: **hit vs. error** (reach or extra base on a ball a fielder touched,
  fielded, or misplayed), **earned vs. unearned** (FR-010a), and **contested putout/assist** —
  fielder's choice, or any play where which fielder is charged the putout / credited the assist is not
  uniquely determined by the facts (e.g. a rundown, shared-coverage tag).
- **FR-011**: System MUST record the identity of the decider (human scorer or authorized agent) and
  the chosen call for every judgment decision.
- **FR-010a**: A run that scores in any half-inning containing a defensive error or passed ball MUST
  be recorded with an `earned_unearned = PENDING` judgment flag (first-class deferred state) rather
  than tagged earned or unearned. v1 performs **no** Rule 9.16 counterfactual reconstruction
  (flag-and-defer, per FR-017); a PENDING tag is resolved only by an explicit decider (FR-011).

**Play classification reference (normative)** *(added 2026-06-01)*

Classification is derived from play **facts** (FR-006), not from any incoming label. The following is
the v1 reference partition; the adversarial corpus (FR-006a) tests it.

- **Deterministic (auto-resolvable, ~85%)** — scored without a judgment prompt when the facts are
  unambiguous: strikeout; walk / IBB / HBP; clean base hit (S/D/T/HR) with an unambiguous fielder;
  routine fielded out with a clear fielder sequence (e.g. 6-3, 4-3); flyout / lineout / popout; force
  out; sacrifice fly / bunt; clean stolen base / caught stealing / wild pitch / passed ball;
  deterministic forced runner advancement; third-out half-inning termination.
- **Scorer-judgment (requires a decision, ~15%)** — flagged from facts regardless of any incoming
  label: **hit vs. error**; **earned vs. unearned** (`earned_unearned = PENDING`, FR-010a);
  **contested putout/assist** (fielder credit); and **ambiguous runner advancement** (an advance not
  forced and not uniquely determined by the play, FR-009).
- **Out-of-format (~5%)** — a play whose facts fall outside the reduced v1 representation: flagged
  needs-review, never fabricated (FR-017).

**Correction (`correct_event`)**

- **FR-012**: Users MUST be able to correct any previously recorded play; on correction the system
  MUST **actually recompute** all affected downstream state (runners, outs, line score, notation, and
  the proof box) — not merely flag that a recompute is required — and re-derive judgment classification
  for the affected plays.
- **FR-013**: System MUST preserve the full history of corrections (append-only / auditable); it MUST
  NOT silently overwrite a prior entry.
- **FR-014**: System MUST surface downstream plays invalidated by a correction for review rather than
  discarding them.

**Finalize & export (`finalize_scorecard`)**

- **FR-015**: Users MUST be able to finalize a game and produce both a human-readable scorebook and a
  **Retrosheet-compatible event file**.
- **FR-016**: The exported event file MUST conform to the **reduced-but-valid** Retrosheet format
  (play type + fielder sequence + result, covering ~95% of amateur plays) and MUST parse without
  errors under the **authoritative acceptance gate — Chadwick `cwevent` at a pinned version** (the
  version recorded in the plan) — for all covered play types. Any in-process/offline or reduced
  validator used for fast local feedback is **explicitly non-authoritative** and never substitutes for
  the pinned Chadwick gate in CI/acceptance.
- **FR-017**: System MUST flag any play outside the reduced v1 format (including runs whose
  earned/unearned status would require full Rule 9.16 counterfactual reconstruction) for manual
  handling, labeled honestly as approximate/needs-review — never emitted as fabricated certainty.

**Agent-native parity & primitives (constitution Art. I, II, XI)**

- **FR-018**: Every capability available to a human (`record_play`, `advance_runner`, `correct_event`,
  `finalize_scorecard`, game setup, judgment decisions, export) MUST be available to an agent/API/CLI
  client as a discoverable, permissioned, atomic primitive with identical effect and identical
  verify/correct semantics.
- **FR-019**: Each primitive MUST have an explicit contract (inputs, outputs, errors, side effects)
  and be independently composable into a full game without hidden coupling.
- **FR-020**: Permissioned actions (making a judgment decision, finalizing the official book) MUST
  enforce authority deterministically at the capability boundary, for human and agent callers alike.
  **v1 authority model (owner-as-decider; clarified 2026-06-01):** the valid decider/finalizer is the
  **authenticated account that owns the game**, or an agent that account has **explicitly authorized**
  to act on its behalf; authority MUST be asserted and audited at every primitive call (not merely a
  non-empty decider string). Full multi-role / organization permission models (owner / scorer / viewer
  / agent scopes) are **deferred** to a later release.

**Offline & privacy**

- **FR-021**: System MUST allow a complete game (on the order of 80–300 plays) to be scored fully
  offline and synced later with no data loss.
- **FR-022**: System MUST process voice to extract the play and MUST NOT retain raw audio as a stored
  recording by default (COPPA-aligned, process-don't-store).
- **FR-023**: A scored game's data MUST belong to the account/owner that created it and be shared only
  on explicit action by that owner.

**Mobile-app surface, platforms & access (v1)** *(clarified 2026-06-01)*

- **FR-024**: The v1 deliverable MUST be a consumer mobile app through which a scorekeeper performs
  every journey — push-to-talk capture, the read-verify/one-tap confirm-correct loop, judgment
  decisions, offline scoring, and Retrosheet export — with the four atomic primitives surfaced in
  the UI.
- **FR-025**: v1 MUST ship on **iOS first**, with **Android as a fast-follow**; the scoring engine,
  primitives, and Retrosheet output MUST be platform-independent so the Android release reuses them
  without behavioral divergence.
- **FR-026**: Speech transcription and play interpretation MUST run **on-device**; a complete game
  MUST be scorable with **no network connectivity**, with cloud used only for later sync (reinforces
  FR-021 offline and FR-022 process-don't-store).
- **FR-027**: v1 MUST make all core scoring capabilities — including official-scorer judgment
  controls and Retrosheet export — **available to the beachhead without paywall gating** during the
  validation period (monetization/tiering deferred so it does not suppress the demand signal).
- **FR-028**: The app MUST support **email and social sign-in**; each scorebook MUST be **private to
  its creator by default** and shareable only by explicit action (e.g., a share link).
- **FR-029**: Where a scorebook involves a minor's data, the app MUST apply a **COPPA-aligned
  consent flow** (verified parental consent, data minimization) before that data is collected or
  shared.

### Key Entities *(include if feature involves data)*

- **Game**: A single scored contest. Holds the two teams, the ordered sequence of plays, the current
  and final game state, and finalization/export status.
- **Team / Lineup / Player**: The participating sides, their batting order and fielding assignments,
  and substitutions over the course of the game.
- **Plate Appearance / At-Bat**: A batter's turn, linking pitch sequence, count progression, and the
  resulting play.
- **Play (Scoring Event)**: A single recorded event — its spoken source, parsed structured form,
  Reisner notation, deterministic-vs-judgment classification, and resulting state delta.
- **Base/Runner State**: Occupancy of the bases and runner advancement resulting from each play.
- **Judgment Decision**: A required scorer call (hit/error, earned/unearned, fielder credit), its
  recommended default, the chosen value, and the decider's identity.
- **Correction / Change History**: The append-only record of amendments to prior plays, preserving
  earlier versions.
- **Scorebook (human-readable)**: The rendered, shareable book in standard notation.
- **Retrosheet Event File**: The machine-readable, reduced-but-valid export of the game's events.
- **Capability/Primitive Invocation**: A permissioned call (by human or agent) to an atomic verb,
  with its contract, authority check, and audit trail.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a real, hand-scored gold-standard game, **≥90%** of *unambiguous* plays are scored
  structurally correct (play type + fielder sequence + result) versus the reference, measured by an
  automated scoring-accuracy eval suite.
- **SC-002**: End-to-end game accuracy after the confirm/correct loop is **≥85%** versus the
  gold-standard hand-scored Retrosheet file.
- **SC-003**: **100%** of fact-classified scorer-judgment plays (hit/error, earned/unearned, contested
  credit) are surfaced for an explicit decision; **0%** are silently auto-resolved. Enforced by an
  **instrumented silent-resolution counter** that increments on *any* book mutation resolving a
  fact-classified judgment without an open flag + recorded decider, **plus** the mislabeled-judgment
  adversarial corpus (FR-006a) wired as a **hard-fail eval gate** — a nonzero count fails the build.
  (The probe found a non-instrumented version of this gate passes vacuously; it MUST be a live
  counter that fails on violation. The hardest, most trust-critical guarantee.)
- **SC-004**: Exported event files parse under the authoritative gate — **Chadwick `cwevent`, pinned
  version (FR-016)** — with **zero** validation errors for every play type in the reduced format. A
  reduced/offline validator MAY gate locally but is non-authoritative.
- **SC-005**: In live/Wizard-of-Oz usability measurement, **≥80%** of plays are captured with ≤1
  spoken phrase + ≤1 tap, and median eyes-on-screen time per play is **≤3 seconds** (attention is not
  recreated; ties to discovery A5).
- **SC-006**: A complete game can be scored fully offline and synced afterward with **no data loss**.
- **SC-007**: Any prior play can be corrected with the original preserved in an auditable history —
  **100%** of corrections retain prior versions (no silent overwrite).
- **SC-008**: **Every** human capability is verifiably invokable by an agent/API/CLI client with an
  identical result and identical verify/correct semantics (agent-native parity holds across all
  primitives).
- **SC-009**: **No** raw audio is retained as a stored recording by default after a play is parsed.
- **SC-010**: At least a handful of real serious/official scorers keep a complete, exportable book on
  the system across real games with a per-game correction rate low enough that they do not abandon
  (the beachhead-proof outcome from the discovery brief).
- **SC-011**: For every completed game, the rendered book conforms to the **Reisner** conventions and
  the **proof-box reconciliation balances** (at-bats + walks + sacrifices + hit batsmen + interference
  = runs + putouts + runners stranded) — a deterministic, automatable correctness check.

## Assumptions

- **Delivery surface (v1 = the full consumer mobile app).** *(Clarified 2026-06-01.)* v1 ships as a
  **consumer mobile app (iOS + Android)** through which the scorekeeper performs every journey:
  push-to-talk capture, the read-verify / one-tap confirm-correct loop, judgment decisions, offline
  scoring, and Retrosheet export. The deterministic rules engine and the four atomic primitives
  (`record_play`, `advance_runner`, `correct_event`, `finalize_scorecard`) power the app *and*, per
  the constitution's agent-native parity (Art. II), remain **co-equally invokable by an agent/API/CLI**
  with identical effect — agent parity is a co-equal requirement, not the sole framing. The shipping
  app is the v1 deliverable; the primitive layer is how it is built so parity holds.
- **Notation & format standards**: the **Reisner scorekeeping system** (`reisnerscorekeeping.com/how`)
  is the authoritative human-readable notation and scoring conventions (situation/catalyst at-bat
  model, position numbers, hit/out/event symbols, pitch-count marks, circled/underlined scorers,
  proof-box reconciliation); the **Retrosheet** event-file format is the machine-readable export.
  Retrosheet is openly licensed and implemented to spec, not licensed from anyone.
- **Speech-to-text runs on-device** *(clarified)* and is integrated from a best-in-class on-device
  ASR capability, not built from scratch. A complete game scores offline; cloud is sync-only. The
  moat is the deterministic rules engine + the natural-language-to-event interpreter + the eval
  harness — not the ASR.
- **Platforms** *(clarified)*: **iOS first, Android fast-follow**; the engine/primitives/export are
  platform-independent so Android reuses them without behavioral divergence.
- **Access/monetization** *(clarified)*: during beachhead validation, **all core features (judgment
  controls + Retrosheet export) are open** — tiering/paywall is deferred so it does not distort the
  A1/A3 demand signal.
- **Accounts & sharing** *(clarified)*: email + social sign-in; scorebooks private-by-default, shared
  only by explicit link/action; COPPA-aligned consent where minors' data is involved.
- **Reduced-but-valid first**: v1 covers play type + fielder sequence + result (~95% of amateur
  plays). **Full earned-run counterfactual reconstruction (MLB Rule 9.16)** and the most exotic
  Retrosheet modifiers are **explicitly deferred** to a later release; v1 flags those for manual
  review rather than guessing.
- **Push-to-talk, offline-first** is assumed (speak after each play), which also resolves the battery
  and COPPA/privacy constraints by architecture.
- **Beachhead user** is the serious/official scorekeeper (travel/select, HS/college statistician,
  Retrosheet/SABR archivist); the rec/tee-ball parent is **expansion**, not a v1 target.
- **Baseball only** in v1; softball is the planned second sport, not in scope here.
- **A gold-standard, hand-scored game dataset** — **real, independent, and multi-inning** (not self-
  or agent-constructed) — is required before SC-001/SC-002 can be measured against ground truth;
  obtain it by partnering with real scorers / SABR-adjacent volunteers. (The spec-coherence probe's
  gold was a tiny agent-constructed game that proves *representability/self-consistency only*, not
  field accuracy — see `probe-report.md`.)

### Explicitly out of scope (v1)

Per the PR/FAQ "What we are NOT doing" list: no live video streaming, no recruiting marketplace or
social network, no automatic camera/computer-vision scoring (voice is the input), no sports other
than baseball, no full league/tournament management (scheduling, brackets, umpire assignment), no
wearables/sensor hardware, and no full earned-run counterfactual reconstruction.

## Dependencies

- **Validation gate (process dependency)**: Discovery directs that the A1/A3 demand smoke-test clear
  its falsification threshold (≥8% commitment by 2026-07-31; `docs/product/experiments/`) before
  engineering the rules engine. This specification may precede that gate, but the build decision
  remains subject to it unless explicitly overridden by the project lead.
- A reliable **on-device** speech-to-text capability (offline-capable on iOS at launch).
- A complete, tested encoding of the official baseball scoring rules, the **Reisner** notation/scoring
  conventions (`reisnerscorekeeping.com/how`), and the **Retrosheet** specification.
- Mobile/offline storage and sync within the iOS (then Android) app.
- **Chadwick `cwevent`** (pinned version) as the authoritative Retrosheet validation gate (FR-016 / SC-004).
- A **real, independent, multi-inning** gold-standard scored-game dataset (a Reisner-scored game with a
  matching gold Retrosheet file) — required before SC-001/SC-002 are credible.
- A **mislabeled-judgment adversarial corpus** (FR-006a) as a hard-fail gate for the no-silent-judgment
  invariant (SC-003).
