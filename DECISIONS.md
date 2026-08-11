# Architecture Decision Record (DECISIONS.md)

This file records architectural and governance decisions for Diamond Ledger, per Article XXXVIII
of the constitution (`.specify/memory/constitution.md`). Each entry is append-only; supersede
rather than rewrite. Newest decisions at the top.

---

## ADR-0016 — v1 owner identity is on-device Sign in with Apple; no-backend email/password deferred (T081)

- **Status:** Accepted
- **Date:** 2026-06-26
- **Owner:** Squad B (T081, Story B0, #117/#118)
- **Implements:** Owner-as-decider authority (FR-020/I5/T036), private-by-default (FR-023),
  account/sign-in (FR-028), COPPA-aligned consent (FR-029); unblocks H1 real-core integration on
  device (the core's authority assertion needs a *real* owner identity, not a stub).
- **Tickets:** #118 (T081), #117 (Story B0); toward #34 (F-Integration MVP demo), #38 (T074)

### Context

The Rust core (`core/src/authz.rs`) does **authorization, not authentication**: every primitive
calls `assert_authority(actor, game_authority)` (is `actor.id == owner_id`?) and
`assert_nontrivial_identity(actor)` (reject empty / `anonymous` / `unknown`). It deliberately
*trusts the adapter* to supply a real identity — proving the caller is who they claim is the
client's job. Today the iOS client supplies that identity from a **dev stub** (`AppState.devSignIn`
→ `dev-owner-<slug>`), so every authority and privacy claim (FR-020/FR-023) is currently vacuous,
and `AppState.devSignIn` is not `#if DEBUG`-gated — it compiles into release.

The spec asks for **email + social sign-in** (FR-028) while also requiring the app to be **fully
offline / on-device** with the cloud used "only for later sync" (FR-026). These collide: an
offline app with **no backend** has nothing to verify an email **password** against. Shipping an
email/password form that silently accepts anything (as the current `SignInView` catch-block does in
DEBUG) would be **fake authentication** — exactly the kind of proxy-not-real-signal the project
forbids.

### Decision

1. **Sign in with Apple is the real v1 owner identity.** `ASAuthorizationAppleIDCredential.user`
   is a stable, app+team-scoped, opaque identifier that is established on-device and persists
   offline after first sign-in. The v1 `ownerId` is `apple:<credential.user>` — namespaced by
   method so provenance is auditable and method namespaces can never collide.
2. **Persist the session in the Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`):
   `{ ownerId, displayName, method }`. On launch, restore it and — for Apple sessions — verify
   `ASAuthorizationAppleIDProvider.getCredentialState`; if the credential was revoked, sign out.
3. **Email + password is deferred to the sync/backend milestone**, not shipped as a local fake.
   The `SignInMethod.email`/`.google` cases remain in the type for forward-compat; the UI presents
   only Apple for v1 (+ the `#if DEBUG` dev button). When a backend exists, email/password becomes
   a real provider with the same `AuthSession` shape.
4. **COPPA (FR-029): a minimal on-device age-gate now; verified parental consent deferred** with
   the backend (verifiable consent is an out-of-band/server process — it cannot be done credibly
   offline). The gate runs once **per owner** before any game is recorded; under-13 is blocked from
   recording pending the consent flow. This keeps the T070 privacy marker honest rather than
   decorative. Two properties make it honest rather than nominal, both added during T081 review:
   - **The answer binds to the `ownerId`, not the device.** A device-global answer let one owner's
     response pre-answer the gate for the next person to sign in — on the shared family device this
     app is built for, an adult's "13 or older" would have silently opened recording for a child.
   - **A known under-13 owner keeps no persisted session.** Sign-in necessarily writes
     `{ownerId, displayName}` to the Keychain before the gate can be shown, so answering "under 13"
     deletes that item (and keeps deleting it on any later sign-in by that owner). Without this,
     "No under-13 PII stored" was false: a child's real name and a persistent identifier stayed at
     rest until they chose to sign out.
5. **The core is unchanged.** `assert_nontrivial_identity` already rejects trivial ids; the agent
   parity path keeps its named capability identity (`dl-score-harness`, a tracked trust boundary
   per Art. XXIX). The only core-adjacent fix is at the iOS layer: **gate `AppState.devSignIn` in
   `#if DEBUG`** so a release build cannot mint a `dev-owner-*` identity.

### Why this is the right move

It makes the authority/privacy claims **real** with the **minimum** that an offline app can honestly
support, and it is the App-Store-required path anyway (an app with third-party or account sign-in
must offer Sign in with Apple). It avoids building — and then having to secure and migrate — a
password store the offline architecture cannot validate. It is squarely "minimal real sign-in"
per T081, and it unblocks H1 (real core on device) without waiting on a backend.

### Alternatives Considered

1. **Email + password now, validated locally.** Rejected: with no backend there is nothing to
   validate against; it is fake auth that implies a security guarantee it cannot keep.
2. **Anonymous device identity (Keychain-generated UUID), no provider.** Rejected as the *primary*
   path: it is a real *local* id but not a real *account* (no recovery, not portable across
   devices, indistinguishable from the stub we are removing). Retained only as a possible
   explicitly-labeled "local-only" fallback if a user has no Apple ID — out of scope for this slice.
3. **Stand up a backend auth service for v1.** Rejected: violates the offline-first architecture
   (FR-026) and ADR-0007's no-CRDT/sync-later posture; large scope for a demand-unvalidated product.
4. **Keep the dev stub for the demo.** Rejected: the ~20-scorer demo (T074) is the artifact that
   feeds the 2026-07-31 demand review; a stubbed owner makes its authority/privacy story untrue.

### Threat model (Art. XXVI/XXVIII/XXIX)

- **Identity origin:** on iOS the `ownerId` comes from a Keychain-stored Apple credential, never
  from a user-typed field — so a user cannot impersonate another owner by typing their id. Games
  are local and owner-bound; cross-device access requires sync (post-v1), where server-side
  authorization will be (re)introduced.
- **Adapter trust:** the core trusts the adapter's `owner_id` by design. The agent/CLI surface
  (`dl-score-harness`) is a named, documented capability identity — not ambient authority.
- **Storage:** Keychain item is device-scoped (`…ThisDeviceOnly`); no password is stored (Apple
  holds the credential); "Hide My Email" is supported (we never store email). No identity is logged.
  The item is deleted outright once an owner answers the age gate as under 13 (§4). Note the item
  is not migrated to another device, but *is* included in an encrypted local backup — treat it as
  device-scoped, not backup-exempt.

### Reversibility

High. All changes are on the iOS auth seam behind the existing `AuthSession`/`AuthStore` API and a
new Keychain helper; the core, the contracts of every scoring primitive, and the agent path are
untouched. Adding email/password later is additive (a new provider returning the same session).

### Impact

- **Agent-native:** unchanged — the headless path keeps its capability identity; parity holds.
- **Security/privacy:** authority (FR-020) and private-by-default (FR-023) become *real*; the
  release dev-stub hole is closed; a COPPA gate exists before any recording (FR-029).
- **Build/provisioning:** requires the `com.apple.developer.applesignin` entitlement + the
  capability enabled in the Apple Developer portal for the app id — a **human provisioning step**.
  Code + `project.yml` entitlement land here; the portal toggle is a handoff item.
- **Verification:** the Sign-in-with-Apple flow needs a real device + Apple ID + Xcode 26; like the
  ASR leg it is **device-gated** — unit-testable parts (owner-id derivation, Keychain round-trip,
  COPPA gate state) are covered; the full flow is verified on device.
- **Follow-ups:** (a) email/password + Google as real providers when the sync backend exists;
  (b) verified parental consent flow (FR-029) with that backend; (c) explicit share-link (T082,
  #119); (d) "local-only" no-Apple-ID fallback identity if demand surfaces it.

---

## ADR-0015 — Headless transcript→score pipeline (`dl-score`) + macOS core slice: agent/CLI parity for scoring

- **Status:** Accepted
- **Date:** 2026-06-09
- **Owner:** F-Integration (DL-37)
- **Implements:** Agent/CLI parity for scoring (Art. II / FR-018); the `$DL_PIPELINE_SCORER`
  interface the eval harness (`evals/runners/accuracy.sh`) was designed for; headless coverage of
  SC-001/SC-002 prerequisites.
- **Tickets:** DL-37 (toward #34 F-Integration, #37 H3, #65 accuracy)

### Context

The deterministic scoring pipeline — `transcript → GrammarParser → FactBridge → real Rust core →
classification + Reisner cell` — existed **only inside the iOS app**. There was no way to run it
off the device: not from a CLI, not from CI, not from an agent. Two concrete consequences:

1. **Parity violation (Art. II / FR-018).** "Same primitives invokable by agent/API/CLI" did not
   hold for the single most important capability — scoring a play. The capability was trapped
   behind the SwiftUI push-to-talk UI.
2. **Accuracy was unmeasurable headlessly.** `evals/runners/accuracy.sh`'s field-accuracy branch
   requires `$DL_PIPELINE_SCORER` (an end-to-end scorer binary). None existed, so the whole
   accuracy story was stuck at "self-consistency, advisory" with no path to a real number — the
   exact vacuous-measurement risk the project warns about.

The core ships as a UniFFI XCFramework, but only with **iOS** slices (device + simulator), so even
the Rust core could not be linked into a macOS host binary.

### Decision

1. **Add a macOS slice to the core XCFramework.** `scripts/build-xcframework.sh` now also builds
   `dl-core` for `aarch64-apple-darwin` + `x86_64-apple-darwin` and adds a `macos-arm64_x86_64`
   slice. The core is platform-independent (integer-only, no iOS deps), so this is free.
2. **Decouple the ASR value layer from the iOS engines.** `Transcript` / `TranscriberEngine` /
   `ConfidenceMapping` move from the iOS-only `DiamondSpeech` target into a new Foundation-only
   `SpeechTypes` target. `Parse` now depends on `SpeechTypes`, not the SpeechAnalyzer engines, so
   the parser is cross-platform. `DiamondSpeech` re-exports `SpeechTypes` (`@_exported`) so existing
   `import DiamondSpeech` consumers are unchanged.
3. **Ship `dl-score`, a headless macOS CLI** (`ios/Sources/DLScore`): reads transcript lines, runs
   `GrammarParser → DiamondCoreClient (real core)`, emits one JSON object per line
   (classification, judgment-required, recommended call, Reisner cell, extracted facts). One
   transcript = one fresh game (sidesteps the FR-007 pending-confirmation guard; matches the
   per-transcript corpus model). It is a **measurement tool** — it never aborts; per-line failures
   are reported in the line's `error` field.
4. **Add a transcript→score regression gate** (`evals/runners/transcript-score.sh` +
   `evals/transcript-regression/cases.jsonl`) as a **HARD CI gate** on `macos-latest`. Because the
   core runs as the macOS slice (only the macOS SDK + rust needed — both on GitHub runners), this
   is a real gate, unlike the advisory `ios-build` (which needs the iOS-26 SDK).

### Why this is the right move (and what it caught)

Building the harness immediately surfaced a real regression: every deterministic play was rendering
the **same** Reisner cell (`6-3` groundout) — home runs, walks, flyouts all scored as a 6-3
groundout. Root cause: the work branched off a `main` that predated DL-154/#162 (the FactBridge
play-type fix). After rebasing onto #162, the harness confirmed correct per-play rendering
(HR→HR, walk→BB, flyout→8, K→K, error→judgment/Card B). This converted #162 from "compiled but
unrun" to "measured-correct end-to-end" — and the gate would catch that whole class of regression
on the next PR. **The audio→transcript (ASR) leg stays device/sim-bound** (`DiamondSpeech`,
iOS-26 `SpeechAnalyzer`); this ADR covers only the deterministic transcript→score leg, where most
of the scoring risk lives and which we fully control.

### Alternatives Considered

1. **Run the scorer on the iOS Simulator (no macOS slice).** Drive the existing sim XCFramework
   slice via `xcrun simctl spawn` / an XCUITest harness. Rejected: heavyweight and flaky for CI,
   needs the iOS-26 SDK (the very constraint that makes `ios-build` advisory), and still wouldn't
   give a plain CLI binary an agent can invoke.
2. **Port the GrammarParser to Rust** so the whole pipeline lives in the existing `adapters/cli`
   Rust binary (no Swift, no macOS slice). Rejected for v1: the parser is a reviewed, hardened
   Swift artifact (DL-151) and a rewrite would duplicate it and risk behavioral drift; reusing it
   via a thin Swift CLI is lower-risk. (A future Rust port remains open if Android needs it.)
3. **Keep accuracy "self-consistency, advisory" until the gold game lands.** Rejected: leaves the
   make-or-break capability unmeasured indefinitely and violates parity (Art. II) in the meantime.
4. **Score full games (sequential confirm/resolve) from the start** rather than one-play-per-game.
   Deferred (follow-up a): needs a judgment-resolution policy and gold per-play state; the
   per-transcript model matches the existing corpora and unblocks the parity + measurement win now.

### Reversibility

High. `SpeechTypes` is a pure refactor (types moved, re-exported). The macOS slice is additive
(iOS slices unchanged). `dl-score` + the regression gate are new, isolated artifacts.

### Impact

- **Agent-native:** Restores scoring parity for the read/classify leg — an agent/CLI can now score
  a transcript headlessly, including the judgment payload (decision id + alternatives) needed to
  resolve a Card B. The write/lifecycle verbs (confirm/resolve/finalize/correct) remain UI-only —
  a tracked parity gap (follow-up d).
- **Testing:** First headless coverage of the **deterministic, isolated-play** transcript→score
  seam; HARD CI gate. NOT covered: state-dependent scoring (runners/outs/inning — fresh-game-per-
  line), the audio→transcript ASR leg (device-bound), and the four judgment kinds beyond HitVsError.
- **Security:** No new attack surface — `dl-score` reads stdin/a file and emits JSON; no network,
  no auth, no secrets, no persisted state. The new CI job pins the same action SHAs as existing
  jobs and routes no untrusted expressions into shell (Art. XXVI).
- **Operational:** Adds one `macos-latest` CI job that builds the XCFramework + `dl-score` (~2–3
  min, cargo-cached). A genuine toolchain/SDK outage on the runner now HARD-FAILS (not a silent
  skip), so a vacuous green is impossible on Darwin; non-Darwin remains an advisory skip.
- **Migration:** None. Existing iOS build (`make xcframework` → xcodebuild) is unaffected; the
  macOS leg builds via `swift build --product dl-score` (never a bare `swift build`, which would
  try to compile the iOS-only targets for macOS).
- **Cost:** One added macOS CI job per PR (cargo-cached); negligible.
- **Follow-ups:** (a) full-game sequential scoring mode (confirm/resolve each play) for
  state-dependent Reisner cells + the SC-003-under-prior-pending-state path; (b) wire the gold
  game's `narration.txt` → `dl-score` into `accuracy.sh` for SC-001/SC-002 once the human gold
  scorecard lands (h3_ready); (c) grammar ambiguity on "single to left field" (parses ambiguous) —
  a separate Parse issue; (d) headless confirm/resolve/finalize verbs for full write-side parity;
  (e) adversarial wrong-role corpus cases + the other three judgment kinds + double-play.

---

## ADR-0014 — Retrosheet Grammar Contract v1.2: Date Format Fix + H2 Export Replay Parity

- **Status:** Accepted
- **Date:** 2026-06-06
- **Owner:** Squad C (Software Factory / Retrosheet gate)
- **Implements:** DL-36 H2 export validation (SC-004 / FR-016 / I4)
- **Tickets:** DL-36

### Context

DL-36 (H2 integration) proved end-to-end that the real Rust core's `finalize_scorecard` export
passes the pinned Chadwick `cwevent` v0.10.0 STDERR-driven 3-layer gate. Code review on PR #160
surfaced two P1s and a contract-documentation gap (P2):

**P1a — Export replay parity with `project_game`:** The initial export replay in `finalize_scorecard`
used raw confirmed `PlayRecorded` facts without honoring `correction_overrides` (FR-012) or
`open_judgment_for_seqs` (SC-003/I2). This meant a game finalized with an open judgment or an applied
correction would emit stale/unwithheld facts in its official Retrosheet record — the export could
misrepresent a corrected or judgment play.

**P1b — SC-004 gate hardness:** The `h2-export-gate` CI job had `continue-on-error: true`, which
would let a genuine malformed-export failure pass CI silently. The gate script already maps
cwevent-absent → exit 2 (skip) and malformed → exit 1 (hard fail), making `continue-on-error`
unnecessary and unsafe.

**P2 — Frozen contract date format:** The `retrosheet-reduced-grammar.md` v1.1 contract specified
`info,date` as `YYYY-MM-DD` in §1 and §6 examples, but cwevent v0.10.0 segfaults on the dash format
(research.md D4, confirmed empirically). The emitter has always emitted slash format (`YYYY/MM/DD`);
the contract text was wrong.

### Decision

1. **Export replay parity (P1a):** Expose `correction_overrides` as `pub(crate)` in `rules/mod.rs`.
   In `finalize_scorecard`, build `export_overrides` + `export_withheld` using the same functions
   `project_game` uses. The export loop mirrors `apply_row` exactly: skip withheld seqs (they remain
   in `out_of_format_flags` for the caller's review), substitute corrected facts from the override
   map. Two new integration tests prove the invariant: (1) finalize with open judgment → withheld
   play excluded from export; (2) finalize after correction → export reflects corrected facts.

2. **Hard gate (P1b):** Remove `continue-on-error: true` from `h2-export-gate`. The script's exit-2
   skip logic is the correct guard; a genuine exit-1 rejection must hard-fail the PR.

3. **Contract v1.2 (P2):** Bump `retrosheet-reduced-grammar.md` to v1.2 with: date field corrected
   to `YYYY/MM/DD` in §1 and §6; `number`, `daynight`, `usedh`, `innings` promoted to MUST (not
   "optional but recommended") — cwevent segfaults without `number`. Change log entry added per §8
   protocol (Article XXXVIII).

### Consequences

- `finalize_scorecard` export is now parity-safe: the official Retrosheet record reflects the same
  facts the authoritative `project_game` projection reflects.
- SC-004 is a true hard gate: a malformed core export blocks the PR.
- The frozen contract is the single source of truth for both the emitter and fixture squads — the
  date format discrepancy is resolved.

---

## ADR-0013 — Multi-Target CI Matrix + Hard-Fail Gate Wiring + Privacy Check (T068/T069/T070)

- **Status:** Accepted
- **Date:** 2026-06-02
- **Owner:** Squad C (Software Factory)
- **Implements:** T068 (#112), T069 (#113), T070 (#115)
- **Tickets:** DL-112, DL-113, DL-115

### Context

ADR-0007 established Rust + UniFFI as the single artifact cross-compiled to iOS, Android, CLI,
and WASM (agent-native parity, Art. II). ADR-0009 wired the UniFFI surface and the
delete-before-regenerate XCFramework cache guard. Three follow-up factory tasks remained:

1. **T068**: The `core-build` job proved the host build; no CI job proved the UniFFI surface
   compiles for any non-host target triple.
2. **T069**: Several gates existed in the YAML but were either still carrying `continue-on-error`
   or had not been audited since the core landed green on main.
3. **T070**: FR-022 (process-don't-store) and FR-029 (COPPA) had no automated enforcement path;
   a developer could add a raw-PCM write with no CI signal.

### Decisions

**T068 — Multi-target build matrix:**

A `cross-compile-matrix` job (needs: `core-build`) runs `cargo build -p dl-core --features uniffi`
across five target triples in a `strategy.matrix`:

- `aarch64-linux-android` and `armv7-linux-androideabi`: ubuntu-latest runner, `cargo-ndk` v3.5.4
  (pinned, `--locked`), Android NDK from `$ANDROID_NDK_ROOT` (pre-installed on GitHub runners).
- `wasm32-unknown-unknown`: ubuntu-latest, no UniFFI feature (UniFFI proc-macros have no WASM
  surface; the goal is proving the integer-only core compiles to WASM).
- `aarch64-apple-ios` and `aarch64-apple-ios-sim`: macos-latest, `continue-on-error: true`
  (advisory). GitHub-hosted macOS runners do not ship the iOS-26 SDK (Xcode 26.x) as of
  2026-06-02. These legs prove the Rust cross-compile itself works when the SDK is available;
  promotion to hard gate requires a macOS runner with Xcode 26.x.

`fail-fast: false` is set so all matrix legs report in a single run rather than stopping on
the first advisory iOS failure.

**XCFramework cache note (ADR-0009 guard):** the full XCFramework assembly (`make xcframework`)
requires Xcode and is handled by the `ios-build` advisory job. When that job is promoted to
a hard gate, its steps must restore the XCFramework from a cache keyed on `Cargo.lock` +
`build-xcframework.sh` checksum, OR rebuild it from scratch — always deleting the output
directory first to defeat the cache pitfall (non-uniffi dylib → zero bindgen output).

**T069 — Hard-fail gate audit:**

Reviewed every job for spurious `continue-on-error`. Findings:
- `retrosheet-gate`: already hard (removed in a prior PR). No change.
- `core-build` (clippy, UniFFI surface, bindgen non-empty): hard. No change.
- `core-eval` (judgment SC-003, proof-box, parity): hard. Accuracy remains advisory by design
  (ADVISORY until gold/H3). No change.
- `ios-build`: intentionally advisory; comment updated with explicit promotion checklist.
- `cross-compile-matrix` iOS legs: advisory with `continue-on-error: true` at job level via
  `matrix.advisory` boolean. All other legs are hard-fail.
- No gates were demoted. The no-float clippy gate, determinism check, judgment gate (SC-003),
  and cwevent retrosheet gate are all confirmed hard-fails on main.

**Security hardening (Article XXVI / ADR-0002):** all `${{ matrix.* }}` and
`${{ github.head_ref }}` expressions that were previously interpolated directly into `run:`
shell text have been moved to `env:` assignments (safe indirection pattern). The
`github.head_ref` value was already safe in the prior workflow; this PR makes the pattern
consistent across all new matrix steps.

**T070 — Privacy CI check:**

A new script `scripts/check-no-raw-audio.sh` and a CI step in the `secret-scan` job enforce
FR-022 (process-don't-store) and FR-029 (COPPA) as hard-fails:

- Scans `core/`, `ios/`, `adapters/`, `android/` for raw-PCM persistence patterns across
  Swift, Kotlin, and Rust source files (8 POSIX-ERE patterns covering `pcmBuffer.write`,
  `saveAudio*`, `FileManager` copies of audio paths, `fwrite`/`write` on audio-named fds,
  SQLite/GRDB inserts of audio blobs, UserDefaults audio sets, CloudKit audio record saves).
- Comment lines are filtered to reduce false positives; any real match exits 1 with a
  `::error::` annotation giving the exact file and line.
- COPPA structural check: if `ios/Sources/Auth/` exists, at least one Swift file must contain
  a COPPA/consent/parental-gating marker — hard-fail if absent. Currently passes
  (marker present in `Auth.swift`).
- The script is also runnable locally (`bash scripts/check-no-raw-audio.sh`).

### Alternatives Considered

- **Android: cross-compilation without cargo-ndk (manual linker config):** cargo-ndk is the
  de facto standard and handles the NDK sysroot selection; rejected raw linker config as
  fragile and harder to maintain.
- **Run iOS cross-compile on ubuntu with a cross-compiler:** the iOS target triple
  (`aarch64-apple-ios`) requires Apple's SDK and linker; a Linux cross-compiler cannot
  produce a valid iOS static lib. The advisory macOS runner is the only viable path.
- **Privacy check via semgrep:** semgrep is more powerful but adds a non-trivial dependency
  and startup cost. The grep-based patterns are sufficient for the narrow FR-022 guard and
  are transparent/auditable without a separate tool.

### Consequences

- All UniFFI-targeted platform triples are now exercised in CI (Android: hard; WASM: hard;
  iOS: advisory with clear promotion path).
- The no-float determinism gate, judgment gate, retrosheet gate, and privacy gate are all
  confirmed hard-fails. No gate silently passes a bad state.
- `scripts/check-no-raw-audio.sh` is the canonical FR-022 enforcement artifact; it must be
  updated when new source directories are added to the workspace.
- The iOS advisory legs block the matrix summary until the Xcode 26 SDK is available on
  GitHub runners; track this against T068 promotion.

### Impact

- **Security (Article XXVI):** workflow expressions moved through `env:` (safe indirection).
- **Privacy (FR-022 / COPPA):** raw-audio persistence is now a CI hard-fail.
- **Reproducibility (Article XXXV):** `cargo-ndk` pinned at v3.5.4 `--locked`.
- **Agent-native (Art. II):** parity across iOS/Android/WASM/CLI is now mechanically
  verified in CI, not just asserted by design.
## ADR-0012 — correct_event (US4) Append-Only Correction + get_proof_box Historical Replay-Up-To

- **Status:** Accepted
- **Date:** 2026-06-02
- **Owner:** Squad A (Deterministic Core & Agent Parity)
- **Implements:** US4 · FR-012–014 · SC-007 · `contracts/correct_event.md` · Art. III/XII
- **Closes:** the ADR-0009 documented limitation (`get_proof_box` errored on a PAST half-inning)
- **Tickets:** DL-correct-event-proofbox

### Context

Two pieces of core work were incomplete. (1) `correct_event` (US4) was a stub returning
`InvalidArgument` — the amend-a-prior-play primitive in the contract (`contracts/correct_event.md`,
FR-012–014) was never implemented. (2) ADR-0009 §Consequences recorded a known limitation:
`get_proof_box` returned a structured error for a PAST half-inning because the live projection only
carries the *current* half's tallies; a review (correctly) made it error rather than return a
misleading all-zeros box. Historical-inning proof boxes needed replay-up-to.

### Decision

1. **Correction is APPEND-ONLY via a replay override (FR-013).** `correct_event` appends an
   `EventCorrected{corrects_seq, amended_play, idempotency_key}` row — the original `PlayRecorded`
   row is **never** mutated or deleted. Replay (`project_game`) builds a `corrected_seq → amended_play`
   override map from all `EventCorrected` rows and substitutes the amended facts for the corrected
   seq during projection. Latest correction wins (scanned in seq order). History is preserved: the
   result's `history` re-reads the untouched original row (SC-007: 100% of corrections retain prior
   versions). The log only ever GROWS.

2. **State is ACTUALLY recomputed (FR-012), not flagged.** With the override in place, the standard
   deterministic replay produces `recomputed_state` — a real `GameState`, byte-identical across reads
   (I6). The amended facts are reclassified from facts alone (I1), using the corrected play's
   half-inning error/PB context reconstructed by a per-half replay scan (parity with `record_play`).

3. **A correction that introduces a judgment opens a FRESH decision — never silent (SC-003/I2).**
   If the amended facts classify as `Judgment(kind)`, `correct_event` appends a `JudgmentOpened`
   `for_seq == corrects_seq`. It does not resolve it; the silent-resolution counter stays zero. A
   correction OUT of a judgment simply reclassifies `Deterministic`.

4. **`invalidated_downstream` is surfaced, not discarded (FR-014).** When the correction changes the
   corrected play's out-count, later confirmed plays in the SAME half-inning are returned as
   `[PlayRef]` for review — never silently dropped.

5. **Idempotent on `idempotency_key` (Art. XXXIII).** A retried key returns a byte-identical result
   and appends NO second correction (the result is rebuilt deterministically from the existing log).

6. **`get_proof_box` past half-inning = replay-up-to.** `end_half_inning` now archives each CLOSED
   half's `HalfInningCtx` into `GameProjection.completed_halves` (keyed by a half-index
   `(inning<<1)|is_bottom`) before resetting `current_half`. A past-half query replays the confirmed
   log and reads the archived context — exactly the tallies `finalize` balances (SC-011), byte-identical
   on replay (I6). The current half still reads live; a future half still returns zeros; a past half
   with no recorded 3rd out surfaces a structured `ContradictoryState` rather than fabricating zeros.

7. **`finalize_scorecard` now emits a proof box for EVERY closed half-inning** (from
   `completed_halves`, in half-index order) plus the current half — so SC-011 ("must balance for every
   completed half-inning") is enforced across all halves, and a historical `get_proof_box` query
   returns the SAME box finalize reports (replay parity). Previously finalize emitted only the current
   half's box.

8. **CLI parity (Art. II):** added a `dl correct-event <game-id> <corrects-seq> <amended-play-json>
   <owner-id>` subcommand so the correction primitive is invokable from the CLI/agent surface exactly
   as from the core/UI path.

### Alternatives Considered

- **Mutate the corrected row in place.** Rejected: violates the append-only invariant (FR-013) and
  destroys the audit history (SC-007). The override-map replay preserves both.
- **Store a recomputed snapshot on the correction event.** Rejected: snapshots drift from the
  deterministic replay (I6) and duplicate state; re-deriving from the log is the single source of truth.
- **Leave `get_proof_box` erroring on past halves (status quo).** Rejected: the data exists in the
  log; replay-up-to is the correct, deterministic answer, and the archive makes it O(replay) with no
  extra storage in the log.
- **Compute `invalidated_downstream` for the whole game.** Rejected as over-broad: only same-half
  downstream plays depend on the corrected play's out/runner state in v1; cross-inning effects are out
  of scope and would produce noisy review lists.

### Consequences / Reversibility

- US4 is shippable end-to-end (core + CLI parity + 12 contract tests); the ADR-0009 proof-box
  limitation is closed (7 proof-box tests incl. past-half-matches-finalize). `cargo test --workspace`,
  `cargo clippy --workspace --all-targets -- -D warnings` (no-float), the SC-003 judgment gate, and
  `make demo` are all green.
- **Reversibility:** high — the correction override and `completed_halves` archive are additive; the
  `EventCorrected` event already existed in the schema. Reverting restores the stub + the past-half
  error path with no data migration (no production data).

### Impact

- **Append-only / audit (FR-013/SC-007):** corrections never rewrite history; every prior version is
  retained and surfaced.
- **No-silent-judgment (SC-003/I2):** a correction that creates a judgment opens a fresh decision.
- **Determinism (I6):** correction replay and historical proof boxes are pure functions of the log.
- **Agent-native (Art. II):** the `dl correct-event` subcommand gives the CLI/agent path full parity.
## ADR-0011 — iOS Real-Core Swap (H1 consumption): module name + Swift-6 language mode

- **Status:** Accepted
- **Date:** 2026-06-02
- **Owner:** Squad F-Integration (iOS ↔ core integration)
- **Implements:** ADR-0009 (UniFFI Wiring) · T071 / T044 · DL-35 (#35) — relates #34
- **Tickets:** DL-35-h1-realcore

### Context

ADR-0009 produced the UniFFI XCFramework + Swift bindings (the A-side of H1). Swapping the iOS
`MockCore` for the real `DiamondCore` (T071) surfaced two integration facts the A-side handoff doc
(`ios/Generated/README.md`) did not anticipate. Both fail loudly at build time and are recorded
here so the next consumer (Android, or a bindings regen) does not re-discover them.

### Decision

1. **The binary/source module is `dl_coreFFI`, not `DiamondLedgerCoreFFI`.** UniFFI 0.28 bakes the
   FFI C-module name from the crate **lib name** (`dl_core` → header `dl_coreFFI.h`, module
   `dl_coreFFI`), and the generated Swift `import dl_coreFFI`. The README/`build-xcframework.sh`
   assumed it could rename the module to `DiamondLedgerCoreFFI`; the rename mismatches the generated
   `import` and the header copy (`cp libdl_coreFFI.h` fails — the file is `dl_coreFFI.h`). Resolution:
   the XCFramework exposes the modulemap module `dl_coreFFI` as-generated; `Package.swift` wires a
   `.binaryTarget` + a `DiamondLedgerCoreBindings` source target compiling the generated Swift; the
   generated `import dl_coreFFI` resolves against the binary target's baked module. No rename.
2. **The generated bindings compile in Swift 5 language mode.** UniFFI 0.28's output uses a
   nonisolated global `var initializationResult`, which Swift 6 strict-concurrency rejects
   ("not concurrency-safe ... global shared mutable state"). Resolution: the `DiamondLedgerCoreBindings`
   target alone sets `swiftSettings: [.swiftLanguageMode(.v5)]`; every hand-written target stays on
   Swift 6. Scoped to the generated file, reversible on a UniFFI upgrade that fixes the global.
3. **`DiamondCoreClient` is the adapter; `MockCore` stays.** A thin `CoreClient` conformer wraps a
   single session-lifetime `DiamondCore.ffiNew()` (the real core is stateful — it holds the
   append-only log), maps the 11 `ffi*` methods 1:1, bridges the loose `[String:String]` facts into
   the typed generated `NormalizedPlay` (the WoZ demo scripts produce the exact fact patterns the
   core's classifier keys on — never a `"script"`-string shortcut into the core), and maps
   `CoreFfiError.Core(Error)` → `CoreError` by `error.code`. `MockCore` is retained for previews/tests.

### Consequences

- **Real-core behavior parity is verified** by 6 `RealCoreIntegrationTests` driving the full loop
  (Card A → confirm → Card B → resolve → finalize) against `DiamondCoreClient`; I2/SC-003, FR-007,
  owner-as-decider, and SC-011 all hold against the real core (not the mock's canned answers).
- **One intended divergence from MockCore:** `finalizeScorecard` on the real core computes the
  half-inning proof box and enforces SC-011, so finalizing a *still-in-progress* half-inning is
  rejected with `proofBoxImbalance` (the mock always returned a canned balanced book). A completed/
  empty half-inning finalizes fine. This is the real core enforcing an invariant the mock faked —
  surfaced, not papered over (the WoZ demo's two-play half-inning is mid-inning, so a demo "Export"
  before the half completes will show the SC-011 rejection; expected).
- **`scripts/build-xcframework.sh` has a latent header-name bug** (`cp ${LIB_BASENAME}FFI.h` →
  `libdl_coreFFI.h`, but UniFFI emits `dl_coreFFI.h`) that aborts `make xcframework` at step 4. The
  XCFramework was assembled manually with the correct names for this PR (the script is Squad A's file
  lane). Tracked as a follow-up for Squad A to fix in-script; documented here so the next run isn't
  blocked silently.

### Reversibility

High. Removing the binary/bindings targets + restoring `AppState(core: MockCore())` reverts cleanly;
the generated artifacts are `.gitignore`d build outputs.

---

## ADR-0009 — UniFFI Wiring (H1) + CLI Event-Log Persistence

- **Status:** Accepted
- **Date:** 2026-06-02
- **Owner:** Squad A (Deterministic Core & Agent Parity)
- **Implements:** ADR-0007 (Rust + UniFFI) · T037 (#67) · #128 · #65 (Story A8)
- **Tickets:** DL-A8-uniffi-h1 — #67 #70 #71 #73 #74 #127 #128

### Context

ADR-0007 chose Rust + UniFFI to expose ONE deterministic core to iOS/Android/CLI/agent from a
single artifact (parity, Art. II). The boundary schema (`core/src/ffi.rs`) was authored with
`// UNIFFI-EXPORT` marker comments but the macros were intentionally not applied (handoff H1,
T037). This ADR records the actual wiring decisions, plus a small supporting change (#128) that
makes the `dl` CLI a real cross-invocation agent surface.

### Decision

1. **New dependency: `uniffi` v0.28** (pinned, Art. XXXV), `optional = true` behind a
   **`uniffi` cargo feature**. The pure deterministic core (and the no-float clippy gate, the
   adapters, `cargo test`) build with **zero FFI coupling by default**; the feature is enabled
   only for binding generation / the iOS XCFramework. All annotations are
   `#[cfg_attr(feature = "uniffi", derive(...))]`, so they vanish in the default build.
2. **Newtypes** (`GameId`/`Seq`/`RunnerId`/`Position`, all integer-only, I6) are exported via
   `uniffi::custom_newtype!` (mapped to their underlying integer) — a single-field tuple struct
   cannot be a `uniffi::Record`.
3. **`GameState.batting_index` changed `[u8; 2]` → `Vec<u8>`** at the FFI boundary only (UniFFI
   has no fixed-array type); the internal rules projection keeps `[u8; 2]`. The `Vec` is always
   length-2 `[visitor, home]`. JSON shape is unchanged for existing serde consumers in practice
   (array of two ints).
4. **Throwable error:** a `uniffi::Error` must be an enum, but the structured boundary `Error`
   is a struct (Art. I machine-readable code). Resolution: `Error` is a `uniffi::Record`; a thin
   `CoreFfiError::Core(Error)` enum is what the exported methods throw — **zero info loss**
   (`code` preserved).
5. **In-crate `uniffi-bindgen` binary** (`required-features = ["uniffi"]`) so the generator is
   ALWAYS the same UniFFI version as the proc-macros (avoids silent version skew).
6. **`scripts/build-xcframework.sh`** (`make xcframework`) builds device + simulator static libs,
   generates Swift (and optionally Kotlin) bindings, and assembles a `.xcframework`. It rebuilds
   the host dylib WITH the feature immediately before bindgen and **deletes the output dir before
   regenerating** to defeat the cache pitfall (a non-uniffi dylib makes bindgen silently emit zero
   files). Generated artifacts are `.gitignore`d; `ios/Generated/README.md` documents consumption
   (T071/T044).
7. **#128 — CLI persistence:** `EventLog`/`GameAuthority` are now `serde`-serializable;
   `DiamondCore::snapshot()/restore()` capture/rebuild the whole core. The `dl` CLI persists the
   append-only log to `$DL_STATE_FILE` (default `./.dl-state.json`) so a game is built across
   separate invocations. The log stays append-only (load → primitive appends; nothing rewritten).
8. **#127 — judgment trigger-priority reconciliation:** the classifier's trigger order was refined
   (AmbiguousAdvance before ContestedCredit/HitVsError when a misplay/overthrow/deflection enabled
   the advance; a safe multi-fielder throw chain is ContestedCredit) so all 20 corpus entries match
   their expected KIND. All entries still SURFACE as judgments, so SC-003/I2 holds regardless; this
   was an accuracy-of-kind change, NOT a silent-resolution change. No corpus edits were needed.

### Alternatives Considered

- **UDL file instead of proc-macros.** Rejected: proc-macros reuse the existing typed schema
  in-place; a UDL would duplicate it and drift.
- **Annotate types unconditionally (no feature gate).** Rejected: would couple the deterministic
  moat (and the no-float gate) to UniFFI and pull `uniffi` into every build.
- **Edit Squad C's `corpus.jsonl` to resolve #127.** Rejected: the facts justified a classifier
  refinement; touching C's H3-adjacent corpus risked a merge conflict for no benefit.

### Consequences

- The iOS `MockCore` → real-core swap (T071/T044) is unblocked: run `make xcframework`, add the
  binary target + generated Swift to `ios/Package.swift` (see `ios/Generated/README.md`).
- Determinism/parity is provable end-to-end: `evals/runners/parity.sh` asserts the CLI/agent path
  and the in-memory core path produce byte-identical `GameState` (SC-008).
- **Known limitation (documented handoff):** `get_proof_box` returns a zeroed box for a *past*
  half-inning (it projects only the current half). Historical-inning proof boxes need replay-up-to;
  finalize already balances the current half (SC-011). Tracked for a follow-up.
- **Reversibility:** high — the `uniffi` feature is off by default; removing the feature, the
  script, and the `$DL_STATE_FILE` load/save reverts cleanly.

### Impact

- **Reproducibility (Art. XXXV):** `uniffi` and the iOS targets are pinned; bindgen is in-crate.
- **No-float (I6):** the FFI surface compiles AND passes `clippy -D warnings` under the feature.
- **Agent-native (Art. II):** the `dl` CLI is now a real cross-invocation agent surface; parity is
  gated in CI.

---

## ADR-0010 — Two-Engine ASR Adapter Shape + Engine-Selection Seam (T047/T048)

- **Status:** Accepted
- **Date:** 2026-06-02
- **Owner:** Squad B (iOS Voice Client)
- **Relates to:** ADR-0007 (two-engine ASR design decision D2), Story B2 (#78), T047 (#80), T048 (#81)

### Context

ADR-0007 specified a two-engine ASR architecture: Apple `SpeechAnalyzer` (primary, iOS 26+) and
sherpa-onnx/Parakeet (fallback/portable). This ADR documents the concrete adapter design choices
made during implementation:

1. **`@available(iOS 26, *)`** on `AppleTranscriber` — the type guard is placed on the class, not
   individual methods, so callers (EngineSelector) check `#available(iOS 26, *)` once at the
   selection site rather than every call site.

2. **`SherpaTranscriber` compiled in all targets but `SHERPA_ONNX_ENABLED` gates real decode** —
   the adapter shape, protocol conformance, and selection logic compile always; the real
   sherpa-onnx XCFramework is behind a compile flag to avoid a missing-framework build error until
   the framework binary is fetched and committed to the repo.

3. **`TranscriberEngineSelector` with `nonisolated(unsafe) static var forceStub`** — the debug
   toggle needs to be mutable from test setUp (serial context) but is never written concurrently
   in production, making `nonisolated(unsafe)` the correct Swift 6 annotation. The seam is
   `#if DEBUG`-guarded so it is excluded from release builds.

4. **`SherpaStubSeam.isOverrideActive`** — same pattern, test-only mutation, also `#if DEBUG`-guarded.

5. **Integer confidence at the adapter boundary** — both adapters convert their native float
   confidence to an integer percentage via a single shared `mapConfidence` helper
   (`Int((clamp(native, 0, 1) * 100).rounded())`) before returning `Transcript`.
   This eliminates float-precision divergence between engines at the `GrammarParser` threshold.

### Decision

- Both adapters conform to `Transcriber: Sendable` (actor-based, Swift 6 strict concurrency).
- `EngineSelector.resolve()` returns `any Transcriber` (existential) so call sites remain
  engine-agnostic.
- The WoZ stub remains the default in simulator/debug builds (`forceStub = true`), preserving
  the existing WoZ demo workflow. The stub reports a distinct `.stub` engine kind (not `.apple`)
  so observability reflects reality.
- Real on-device Apple ASR accuracy (mic → `SpeechAnalyzer` → transcript) requires a physical
  device and microphone. This is a human handoff, documented in `MANUAL-TESTING.md`.
- The sherpa-onnx framework download + model asset is a human handoff (see `SherpaTranscriber.swift`
  handoff checklist); the compile-always stub path prevents blocking the build.

### Alternatives Considered

- **Dynamic library dispatch (ObjC `id<Transcriber>`)**: rejected — Swift protocols with
  `consuming` parameters require value-type dispatch.
- **Single-engine with fallback inside the engine**: rejected — would couple Apple and sherpa
  concerns; cleaner as separate conformers behind the selection seam.

### Consequences

- `AppleTranscriber` uses **legacy `SFSpeechRecognizer`** today; `preloadAssets()` only requests
  authorization. Real `SpeechAnalyzer`/`AssetInventory` preload (FR-021) is a pending on-device
  handoff, flagged with a `#warning` in the file and a follow-up issue.
- `SherpaTranscriber` is an integration skeleton until the XCFramework is fetched; tests exercise
  the selection logic and stub path without the real binary.
- The WoZ fact-mapping (`misplayed-grounder` → MockCore routing) lives in the PTT/test harness
  layer, NOT in the Speech module — the Speech module has no MockCore dependency.

### Renumbering note

This ADR was originally drafted as ADR-0009 on `feat/ios/DL-080-asr-adapters-export`. On merge with
`main`, ADR-0009 was claimed by the UniFFI Wiring decision (PR #141); this ASR ADR was renumbered to
ADR-0010 to preserve append-only numbering.

---

## ADR-0008 — Cargo Workspace Root at Repo Root; Rust Toolchain Bumped to 1.96

- **Status:** Accepted
- **Date:** 2026-06-01
- **Owner:** Project lead (zone17)
- **Amends:** ADR-0007 (Cargo workspace layout consequence)
- **Ticket:** PLAT-009

### Context

ADR-0007 established Rust + UniFFI as the core language.  When the Cargo workspace was scaffolded
the initial `Cargo.toml` was placed inside `core/`.  Cargo requires that every `[workspace]`
member be located **below** the directory that contains `Cargo.toml`; a workspace root inside `core/`
cannot reference sibling directories (`adapters/cli`, `adapters/agent`) as members without
symlinks or path hacks.  The fix is to move the workspace manifest to the **repo root**, with
`core/`, `adapters/cli/`, and `adapters/agent/` listed as members.

A related discovery: `proptest` (the adversarial fuzz library selected in ADR-0007) requires a
minimum Rust edition / MSRV of **1.96**; the toolchain had been pinned at 1.83 (the channel
available at planning time).  The toolchain pin was bumped to 1.96 in `rust-toolchain.toml`.

### Decision

1. **Cargo workspace manifest lives at repo root** (`./Cargo.toml`), not inside `core/`.
   Members: `core`, `adapters/cli`, `adapters/agent` (and `android/` when scaffolded).
2. **`cargo` commands run from repo root** against the root `Cargo.toml` — consistent with the
   CI `core-build` job (`cargo check --workspace`).
3. **`rust-analyzer`** is configured at repo root (workspace root = `.`).
4. **Rust toolchain pin bumped: 1.83 → 1.96** to satisfy `proptest`'s MSRV.  Pin is in
   `rust-toolchain.toml`; CI reads it automatically via `rustup show`.

### Alternatives Considered

- **Keep workspace root inside `core/`; use path hacks for adapters.** Rejected: non-idiomatic,
  breaks `cargo check --workspace`, complicates `rust-analyzer`.
- **Separate workspace per crate.** Rejected: defeats shared `Cargo.lock` and unified CI check.

### Consequences

- All developers and CI agents run `cargo <cmd>` from the repo root.
- The `rust-toolchain.toml` at repo root controls the compiler version for the entire workspace.
- `proptest` and other dev-dependencies compile without MSRV overrides.
- **Reversibility:** high — moving `Cargo.toml` back and updating the CI step is the full revert.

### Impact

- **Reproducibility (Art. XXXV):** single `Cargo.lock` at repo root; toolchain version is
  deterministic and version-controlled.
- **CI:** `core-build` job already targets repo-root `Cargo.toml` (`cargo check --workspace`).
- **Agent-native:** any agent or developer who runs `cargo` from repo root gets the full picture.

---

## ADR-0007 — v1 Technical Architecture: Rust Deterministic Core + UniFFI Parity, Two-Engine ASR, Pinned Chadwick `cwevent`

- **Status:** Accepted
- **Date:** 2026-06-01
- **Owner:** Project lead (zone17)
- **Review date:** 2026-09-30 (revisit after the first headless core + Phase B slice exist)
- **Relates to:** `specs/001-voice-scorebook-core/plan.md` + `research.md` (decisions D1–D8); founder
  confirmation 2026-06-01 (core language = Rust; ASR = two-engine; first slice = US1+US2+US3).

### Context

`/speckit-plan` had to settle the v1 technical architecture for the voice-scorebook core. Three forks were
surfaced to the founder for explicit decision (not silently chosen, Art. VI), grounded in four sourced
research streams (`research.md`): the shared-core implementation language, the on-device ASR strategy, and
the first shippable slice. The constitution requires the platform-independent deterministic core
(Art. VII) with agent-native parity (Art. II), byte-identical determinism (FR-003/I6), and the pinned
Retrosheet acceptance gate (FR-016/SC-004). The core-language choice is a foundational architectural
decision and therefore requires this ADR before core implementation begins.

### Decision

1. **Core language = Rust + UniFFI.** A single Rust crate (pinned toolchain, **integer/fixed-point only,
   no `f32`/`f64` — CI-linted**) implements the rules engine, the **fact-derived** judgment classifier,
   the Reisner renderer + proof-box, the reduced-Retrosheet emitter, and the append-only event log. The
   *same compiled artifact* is exposed via UniFFI to Swift (iOS, XCFramework→SwiftPM), Kotlin (Android
   fast-follow), a native CLI, and a native/WASM agent/API surface — so Art. II parity holds by
   construction. The FFI boundary is kept to the four primitives + plain owned types + a typed error enum.
2. **ASR = two-engine, behind one `Transcriber` protocol.** Apple `SpeechAnalyzer`/`DictationTranscriber`
   (iOS 26+, free, phrase-biased) primary on iOS; **sherpa-onnx/Parakeet** as the portable Android +
   fallback engine. The Android fast-follow swaps one adapter, not the app. v1 structured parse is a
   deterministic grammar-constrained parser (no LLM); FunctionGemma-270M+XGrammar is a documented v2 path.
3. **Retrosheet acceptance = pinned Chadwick `cwevent` v0.10.0**, validated by a **stderr-driven** 3-layer
   CI gate (proof-box → `cwevent` parse-success → golden diff). Exit-code-only is vacuous (`cwevent`
   returns 0 on malformed plays) — same failure class as the dead SC-003 counter the probe caught.
4. **Storage = event-sourced SQLite/GRDB on iOS; sync = CloudKit private DB, last-write-wins, NO CRDTs**
   (single-writer-per-game; CRDTs would be scale theater, Art. XXXVII).
5. **First shippable slice = US1 + US2 + US3 (export).** Founder chose to include the Retrosheet **export
   UI** in the first artifact demoed to ~20 serious scorers (stronger official-artifact story), broader
   than the planner's US1+US2 recommendation. US4 (correction UI) + sync follow; full Rule 9.16 earned-run
   reconstruction remains deferred (earned/unearned = `PENDING`).

### Alternatives Considered

- **Kotlin Multiplatform** (core language) — strong runner-up; rejected for an iOS-first product because
  determinism would span three runtimes and the Kotlin→Swift interop friction lands on the iOS side. The
  sanctioned fallback had team Rust proficiency been low.
- **TypeScript/JS core** — rejected: no integer type, byte-identity across three JS engines, runtime weight.
- **Swift-shared core** — rejected: official Swift-for-Android is preview (Swift 6.3, Mar 2026).
- **Single ASR engine everywhere** — simpler to maintain but forfeits Apple-native's free first-party iOS
  accuracy/privacy win; rejected in favor of the thin two-engine abstraction.
- **CRDT sync** — rejected as unjustified for single-writer-per-game data.

### Tradeoffs / Risks (accepted)

- **Rust learning curve** for a small team — accepted; the core is bounded, mostly-integer, pure-logic
  (no async/unsafe), near the safe end for learning Rust. UniFFI is pre-1.0 (keep the boundary small);
  Android binding uses JNA (the synchronous core sidesteps the async-crash class). Cross-compile matrix is
  larger CI but well-trodden (Mozilla `application-services` reference).
- **Min iOS = 26** (SpeechAnalyzer) — pre-26 needs the `SFSpeechRecognizer`/sherpa fallback.
- **Crowd-noise WER on short baseball phrases is unproven in public benchmarks** — must be field-tested
  before committing accuracy claims (ties to A5/SC-005). The biggest real technical risk.
- Including US3 export in the first slice adds the emitter's UI surface earlier — acceptable; the emitter
  itself is core work needed for the `cwevent` gate regardless.

### Consequences / Reversibility

Core implementation (Phase A) is unblocked. The deterministic core, the CLI/agent parity surface, and the
`evals/` gates are buildable headless before any UI. **Moderately reversible:** the language choice is the
stickiest (rewriting the core), but the small FFI surface + the deferred Android/agent adapters limit blast
radius; ASR/storage/sync choices are behind thin protocols and swappable. No production data yet.

### Impact

- **Agent-native (Art. II):** parity is structural — one artifact, four surfaces.
- **Security/privacy:** on-device, process-don't-store enforced in code; COPPA path (FR-029) preserved.
- **Reproducibility (Art. XXXV):** pinned Rust toolchain, `cwevent` v0.10.0 (SHA-pinned), pinned model assets.
- **Cost:** engineering begins (per ADR-0006 the build is authorized ahead of the A1/A3 demand instrument).

---

## ADR-0006 — Build Authorized Ahead of the A1/A3 Demand Gate (Override → Parallel Instrument + Tripwires)

- **Status:** Accepted
- **Date:** 2026-06-01
- **Owner:** Project lead (zone17)
- **Review date:** 2026-07-31 (the original A1/A3 falsification deadline — first tripwire review)
- **Relates to:** `specs/001-voice-scorebook-core/` (spec + `probe-report.md`); discovery
  (`docs/product/discovery/`); experiments (`docs/product/experiments/`)

### Context

Discovery set a falsification **gate**: building the rules engine was to wait on the A1/A3 demand
smoke-test clearing **≥8% commitment by 2026-07-31**. The riskiest assumption — serious/official
scorekeepers will *switch to and pay for* voice→Retrosheet scoring, and Retrosheet export is valued
beyond the SABR niche — is rated **importance-high / evidence-low (confidence L)**. The
spec-coherence probe (`probe-report.md`) separately de-risked **feasibility** (the deterministic
core is buildable). The project lead has decided to **build regardless of the A1/A3 outcome** — a
founder-conviction bet grounded in lived domain pain (scored own child's games tee-ball→college) and
the judgment that a fake-door landing page under-measures a novel "feel-it-to-get-it" voice product
(genuine false-negative risk).

### Decision

Authorize the v1 build to proceed **ahead of, and independent of,** the A1/A3 demand gate. The gate
is **not removed** — it is **reframed from a hard go/no-go into a parallel instrument** run alongside
the build, with **pre-committed tripwires** (defined below, before data arrives) so any
course-correction stays evidence-driven rather than goalpost-moving.

**Risk explicitly accepted (Art. VI):** engineering the rules engine + mobile app (the main upfront
investment per the PR/FAQ) may be spent before the riskiest, confidence-L assumption
(paying-beachhead adoption) is validated. A correct engine with weak adoption is the accepted
downside; building does not, by itself, move adoption.

**Mitigations adopted ("decouple, don't override"):**
1. **Run A1/A3 in parallel anyway** (cheap: ~$1–3k + ~30 hrs) — keep the demand instrument live; do
   not go blind.
2. **Sequence the build so the first shippable artifact is demoable to ~20 real serious scorers** —
   turning the build into a stronger demand signal than the fake-door (directly tests the
   false-negative hypothesis).
3. **Keep the most expensive engine work deferred** (full Rule 9.16 earned-run reconstruction —
   already out of v1 scope) until early adoption signal exists.

### Tripwires (pre-committed 2026-06-01; reviewed 2026-07-31)

- **Demand:** if by 2026-07-31 A1/A3 commitment is **<8% AND <8/20** interviewed scorers show a
  commitment signal → **pause net-new engine investment beyond the demoable slice**; re-segment or
  evaluate the discovery-named pivot (archivist score-from-video) before committing further months.
- **Distribution:** if **~20 real serious scorers cannot be put in front of the demoable slice**
  within the build window → treat as an access/GTM red flag and reassess go-to-market before scaling.
- **Usability:** if the demoable slice's per-game correction rate is high enough that test scorers
  abandon (fails the SC-005 attention bar / SC-010 retention intent) → stop and fix the loop before
  building further (the A5 concern).
- Any tripwire trip triggers an **explicit, documented continue / redirect / pause decision** — never
  silent continuation.

### Alternatives Considered

- **Honor the gate (build only if A1/A3 passes).** Rejected by the project lead: founder conviction +
  fake-door false-negative risk for a novel voice product.
- **Drop A1/A3 entirely.** Rejected: discards a cheap behavioral signal for no benefit; willful
  blindness is strictly worse than parallel measurement.
- **Build the full engine first (incl. Rule 9.16) before any demand signal.** Rejected: maximizes
  sunk cost on the least-validated bet.

### Consequences / Reversibility

Planning (`/speckit.plan`) and the v1 build are unblocked now. **Reversible at the tripwire reviews**
— the parallel instrument + tripwires preserve the ability to pivot on evidence rather than lock in
sunk cost. No code/schema impact (governance decision).

### Impact

- **Process:** converts a hard gate into a monitored, tripwired parallel instrument; preserves the
  constitution's *test-before-build* intent in spirit (the test continues; the build no longer blocks
  on it) while honoring an explicit, auditable founder-conviction override (Articles VI, IX, XXV,
  XXXVIII).
- **Honesty (Art. VI):** the accepted risk and the false-negative rationale are recorded, not hidden.
- **Cost:** engineering spend begins before demand validation — the accepted risk.

---

## ADR-0005 — Compound-Gate Recursion Backstop: Don't Resolve Volatile Context via a Racing Live Call

- **Status:** Accepted
- **Date:** 2026-06-01
- **Owner:** Project lead (zone17)
- **Review date:** 2026-09-01
- **Amends:** ADR-0004 (compound-gate recursion fix)

### Context

ADR-0004 stopped `compound-flag.sh` from arming on `docs/*` merges (so the merge of the compound
docs themselves wouldn't ask to "compound the compound step"). It resolved the merged PR's head
branch with a **live `gh pr view <n> --json headRefName`** at hook time, and on any failure fell
through and armed (safe default).

Dogfooding exposed the gap: after `gh pr merge <n> --squash --delete-branch`, that live lookup
**races the branch deletion / merge-API propagation**. In a real session the lookup returned empty
for the just-merged compound-doc PR (a `docs/*` branch), so the `docs/*` skip never fired and the
gate armed on the compound step's own merge — the exact recursion ADR-0004 set out to prevent. (The
armed flag even read `merged_at=unknown`, since the hook ran under macOS bash 3.2, which lacks
`EPOCHSECONDS`.) The general defect: **a hook that re-fetches volatile context via a network call
races the very action that triggered it.**

### Decision

`compound-flag.sh` keeps the `docs/*` skip but makes resolution authoritative and adds an
**identity** backstop, covered by 24 assertions in `test-compound-hooks.sh` and the CI `hooks-test`
job:

1. **`gh pr view` is authoritative** for the head ref (primary `docs/*` skip).
2. **Anchored no-network fallback.** Only when `gh` is unavailable/empty, parse the head ref from
   `tool_response`, anchored to gh's real success line `Deleted branch <ref> and switched to branch`
   — so a stray `Deleted branch docs/x` substring elsewhere in the payload cannot fabricate a skip.
3. **Identity backstop (not a clock).** When the ce-compound Skill clears the flag, write an
   *await* marker (`.claude/.compound-done`). The compound doc's own `gh pr create` (while the
   await marker is fresh, ≤1h) captures its **PR number** from the printed `.../pull/<n>` URL. The
   merge of **exactly that PR number** is then skipped — robust even if `gh pr view` races to empty,
   and it can never suppress a *different* (substantive) merge. Timestamps use portable `date +%s`.

**Note — the first attempt was caught by code review.** An initial version parsed `Deleted branch`
from the *whole payload* with a bare substring grep and let it override the live lookup. The
`ce-adversarial-reviewer` flagged (P2) that this **reintroduced ADR-0004's own documented pitfall #1**
(scanning the whole payload for a trigger phrase causes false matches) — a `docs/*` mention anywhere
could suppress a non-docs reminder — and that a time-window marker could suppress a legitimate
substantive merge. Both were corrected to the authoritative + anchored + identity design above
before merge. Independent verification (Article XX) earned its keep here.

### Alternatives Considered

- **Whole-payload `Deleted branch` grep overriding gh (first attempt).** Rejected after review:
  reintroduced the false-match pitfall the change set out to document.
- **Time-window suppression of the next unresolved merge.** Rejected: suppresses by clock, so a
  real substantive merge with a transiently-unresolved ref in the window loses its reminder.
  Identity (PR number) suppresses exactly the compound doc's merge and nothing else.
- **Retry the `gh` lookup with a sleep.** Rejected: latency on every merge, still probabilistic.

### Consequences / Reversibility

The compound gate stops self-triggering on its own documentation merge even under the lookup race;
ordinary `docs/*` merges and substantive merges behave as before. High reversibility — revert the
hook + test edits and delete the marker line from `.gitignore`. No data/schema impact.

### Impact

- **Operational:** removes a spurious post-merge compound reminder (the one that fired this session).
- **Agent-native:** plain bash with `COMPOUND_TEST_HEAD_REF` + a `gh` PATH stub make every branch
  exercisable offline; learning generalized in
  `docs/solutions/best-practices/hook-command-string-matching-pitfalls.md`.
- **Security:** no new authority; reads the hook payload, writes two local flag files.

---

## ADR-0004 — Hook Hardening: Branch-Discipline Defense-in-Depth + Compound-Gate Recursion Fix

- **Status:** Accepted
- **Date:** 2026-06-01
- **Owner:** Project lead (zone17)
- **Review date:** 2026-09-01

### Context

Two gaps surfaced via independent review (ADR-0002) and dogfooding (ADR-0003):

1. The vendored `auto-commit.sh` wraps `git commit`, so the command-string `branch-discipline.sh`
   hook can't see it — an auto-commit could land on `main` (Article XVIII bypass).
2. The compound-loop gate (ADR-0003) re-arms on **any** `gh pr merge`, including the merge of the
   compound docs themselves — asking to compound the compound step (a mild recursion).

### Decision

**Branch-discipline defense-in-depth (closes #1):**
- Add a branch guard at the top of `auto-commit.sh` that refuses to commit on `main`/`master`
  (zero-setup, closes the named bypass even if `core.hooksPath` is unset).
- Add a repo-managed git hook `.githooks/pre-commit` that blocks commits to the default branch from
  **any** path — the altitude-correct generalization ("put the invariant where the action happens,"
  per `docs/solutions/best-practices/hook-command-string-matching-pitfalls.md`). Enabled per clone
  with `git config core.hooksPath .githooks` (documented in `CONTRIBUTING.md`). It recovers the
  underlying branch during a rebase (detached HEAD) so a rebase *on* `main` is also caught.

**Compound-gate recursion fix (closes #2):**
- `compound-flag.sh` no longer arms when the merged PR's head branch is `docs/*` (where compound
  and other documentation land). Resolved via `gh pr view --json headRefName`; on any failure it
  falls through and arms (safe default). Test override: `COMPOUND_TEST_HEAD_REF`.

All paths covered by `.claude/hooks/test-compound-hooks.sh` (12 assertions) and the CI `hooks-test`
job, including pre-commit block/allow and the docs/* skip.

### Alternatives Considered

- **Only edit auto-commit.sh.** Rejected as sole fix: doesn't generalize to other script-wrapped
  git; the `pre-commit` hook covers all paths.
- **Only add the pre-commit hook.** Rejected as sole fix: `core.hooksPath` is per-clone and easily
  unset, so the in-script guard is the no-setup backstop.
- **Skip-arm by changed paths (docs/solutions only).** Rejected: the real compound merge also edits
  instruction files (e.g. CLAUDE.md), so a path filter misses it; the `docs/*` branch convention is
  the cleaner, more robust signal.

### Tradeoffs

`core.hooksPath` must be set per clone (documented; the in-script guard backstops it). The `docs/*`
skip may occasionally suppress a reminder for a docs branch that did contain a real learning —
acceptable, since compounding can always be run manually, and the alternative (recursion) is worse.
The editing of a vendored file (`auto-commit.sh`) must be re-applied if Spec Kit overwrites it on
upgrade (noted in an inline comment).

### Consequences

- `main` is protected from direct commits via any path on clones that ran the one-time setup, and
  the specific auto-commit bypass is closed unconditionally.
- The compound gate stops nagging after documentation merges.

### Reversibility

High. Remove `.githooks/pre-commit` + unset `core.hooksPath`; revert the two hook edits. No data or
schema impact.

### Impact

- **Security:** Strengthens branch-discipline enforcement (Articles XVIII, XXVI, XXXIX).
- **Operational:** Adds a one-time `git config core.hooksPath .githooks` to onboarding.
- **Agent-native:** All guards are plain bash with test overrides any agent can exercise.

---

## ADR-0003 — Compound-Loop Gate (Continuous Improvement Flywheel)

- **Status:** Accepted
- **Date:** 2026-05-31
- **Owner:** Project lead (zone17)
- **Review date:** 2026-08-31

### Context

The constitution mandates a Continuous Improvement Flywheel (Article XXII) and that non-obvious
knowledge be captured after work completes (Article XVI). Relying on instructions alone to "always
run ce-compound" fails the moment agent context is compacted — the exact failure mode Article XXXIX
addresses by requiring mechanical enforcement.

### Problem

Nothing in the repository ensured the compound step actually ran after a unit of work landed, so
learnings risked being lost.

### Decision

Add a project-scoped, version-controlled hook pair that ties compounding to the natural milestone of
a **merged pull request**:

- `.claude/hooks/compound-flag.sh` (PostToolUse, all tools): arms `.claude/.needs-compound` after a
  `gh pr merge`; clears it after the ce-compound skill runs.
- `.claude/hooks/compound-reminder.sh` (Stop): if the flag is set, blocks the stop **once** and
  instructs the agent to run `/ce-compound`. Loop-safe via `stop_hook_active`; bypass by deleting
  the flag for genuinely trivial merges.
- Wired in `.claude/settings.json`; flag is git-ignored (runtime state).

Trigger chosen: **merge-triggered** (not every commit) — fires at a meaningful milestone and avoids
nagging on intermediate commits. Scope: **project** — committed so it travels with every clone
(Article XXXIX repository-managed equivalent).

### Alternatives Considered

- **Soft Stop reminder only.** Rejected: on `Stop` the agent has already decided to finish, so a
  non-blocking message wouldn't reliably cause the loop to run.
- **Hard gate on every commit.** Rejected: too noisy; most commits are intermediate.
- **Global hook (~/.claude).** Rejected here: the user chose project scope so it's versioned with
  Diamond Ledger; a global variant remains possible later.
- **Instruction in CLAUDE.md.** Rejected: not mechanically enforceable (Article XXXIX).

### Tradeoffs

Blocking a stop is intrusive by design; mitigated by being one-shot per stop sequence, clearing
automatically when ce-compound runs, and a documented one-file bypass. Detection is substring-based
(no jq dependency) for portability, at the cost of theoretical false matches — acceptable for a
local developer hook.

### Consequences

- After every merge, the session cannot quietly end without either compounding or an explicit skip.
- Learnings accrue in `docs/solutions/` over time, feeding the flywheel.

### Reversibility

High. Remove the two hook entries from `.claude/settings.json` (or the scripts) to disable; downgrade
to a soft reminder by changing the Stop hook's `decision: block` to a non-blocking message.

### Impact

- **Operational:** Adds a post-merge compound ritual.
- **Agent-native:** Both hooks are plain bash any agent can read and reason about.
- **Security:** No new authority; reads hook payloads, writes a single local flag file.

### Follow-ups (deferred)

- Consider extending the trigger to debugging/non-trivial non-PR work if learnings are being missed
  (the merge-only trigger's known gap).

---

## ADR-0002 — Software Factory: CI Enforcement + Hook-Based Branch Protection

- **Status:** Accepted
- **Date:** 2026-05-31
- **Owner:** Project lead (zone17)
- **Review date:** 2026-08-31 (revisit if repo goes public or upgrades to GitHub Pro)

### Context

Immediately after ratifying the constitution (ADR-0001), the repository needed its "software
factory" — the enforcement infrastructure the constitution mandates (Articles XXXIV, XXXIX) — before
feature work begins. The repo is **private on the GitHub free plan**, and the Spec Kit toolchain
(extensions, git skills, scripts, workflows) was sitting uncommitted.

### Problem

1. Constitutional rules (branch discipline, no secrets, governance integrity) were enforced only by
   local hooks on one machine, with nothing in the repository itself.
2. GitHub server-side rulesets/branch protection returned `403 — Upgrade to GitHub Pro or make this
   repository public` on the private free plan, so the planned `main` ruleset could not be created.
3. The Spec Kit scaffolding was untracked, making the environment non-reproducible (Article XXXV).

### Decision

- **Commit the Spec Kit scaffolding** (`.specify/extensions*`, `.specify/workflows/`,
  `.specify/init-options.json`, `.claude/skills/speckit-git-*`, executable-bit changes on
  `.specify/scripts/*.sh`) so the toolchain is reproducible and version-controlled.
- **Add `.github/workflows/ci.yml`** — an advisory CI pipeline whose jobs map directly to the
  Enforcement Matrix: `governance` (constitution + DECISIONS integrity), `branch-name` (Article
  XVIII naming), `secret-scan` (gitleaks, full history).
- **Adopt hook-based branch protection** as the Article XXXIX "repository-managed equivalent":
  local `branch-discipline.sh` + `security-gate-bash.sh` hard-block direct/force pushes to `main`.
  Document the PR-only convention in `CONTRIBUTING.md`.
- **Add a root `.gitignore`** (OS junk, secrets, local agent memory, forward-looking build
  artifacts).

### Alternatives Considered

- **Make the repo public to unlock free rulesets.** Rejected by owner: keep private for now.
- **Upgrade to GitHub Pro for private rulesets.** Rejected for now: not worth the cost at this
  stage; revisit at the review date.
- **Use the GitHub Actions `gitleaks-action`.** Rejected: it requests a license key for
  organizations; the pinned `zricethezav/gitleaks` CLI image is free and reproducible.

### Tradeoffs

CI is **advisory, not blocking** — without server-side required status checks, a determined local
actor could merge a red PR. Mitigated by: local hooks (the real hard gate today), `/watch-ci`
discipline, and a documented upgrade path. Accepted as proportionate for a solo, pre-product repo.

### Consequences

- The toolchain and enforcement live in the repo and travel with every clone.
- Every PR runs governance, branch-name, and secret-scan checks.
- Future work: if the repo goes public or Pro, add a `main` ruleset and mark the CI checks
  **required**.

### Reversibility

High. CI and `.gitignore` are editable; hook-only protection swaps cleanly to a server-side ruleset
when the plan allows.

### Impact

- **Security:** Adds secret scanning and codifies destructive-op / branch hard-blocks.
- **Operational:** Establishes `/watch-ci` as the post-push ritual.
- **Reproducibility:** Scaffolding is now version-controlled.
- **Agent-native:** CI checks are plain bash any agent can read, run, and reason about.

### Follow-ups (deferred, not blocking)

- Pin GitHub Actions to commit SHAs (currently major-version tags) — Article XXXVI.
- Add markdown structural linting once a noise-free config is tuned.
- Add a `DECISIONS.md`-changed-when-architectural-files-change check in CI (today enforced by the
  local `decision-gate.sh` hook).
- Promote CI checks to **required status checks** if the repo becomes public or Pro.

---

## ADR-0001 — Ratify the Diamond Ledger Engineering Constitution

- **Status:** Accepted
- **Date:** 2026-05-31
- **Owner:** Project lead (cryptozone1723@gmail.com)
- **Review date:** 2026-11-30 (6-month review)

### Context

Diamond Ledger is being built as an agent-native capability system — a composable graph of small,
permissioned, discoverable primitives usable by humans, agents, CLIs, APIs, and future interfaces —
rather than a traditional UI-first application with AI bolted on. Before any code lands, the project
needs a single binding engineering authority governing architecture, agent behavior, security,
testing, evaluation, documentation, branch discipline, CI/CD, observability, and the definition of
done.

### Problem

Without a ratified, enforceable standard, agent-generated work drifts: UI-only features bypass
agent parity, critical invariants get enforced only by prompts, knowledge fails to compound, and
branch/security discipline depends on willpower that context compaction erodes.

### Decision

Ratify the constitution at `.specify/memory/constitution.md` (v1.0.0) as the highest-level durable
engineering authority for the repository. It defines 40 articles, an enforcement matrix, 20
pull-request review questions, a 25-point definition of done, and governance with semantic
versioning.

### Alternatives Considered

- **No formal constitution; rely on global CLAUDE.md + ad-hoc review.** Rejected: not project-scoped,
  not versioned, no enforcement matrix, weak under context loss.
- **A short principles list (5–7 bullets).** Rejected: insufficient for an agent-native system where
  tool contracts, deterministic policy boundaries, memory safety, and harness engineering each need
  explicit, testable rules.
- **Defer until first code exists.** Rejected: the constitution's value is shaping the first
  capability, not retrofitting after patterns set.

### Tradeoffs

A comprehensive 40-article document carries process overhead and a learning curve. Mitigated by the
constitution's own "depth is the only variable" rule (Article IX) — lightweight loops for low-risk
work — and by the enforcement matrix distinguishing hard blocks from soft reminders.

### Consequences

- All non-trivial work passes Brainstorm → Plan → Work → Review → Compound (Article IX).
- New tools require contract-first design and contract tests (Articles I, XI).
- Agent-native parity, deterministic policy at tool boundaries, and risk-tiered autonomy become
  review gates (Articles II, VII, XXV, XXVIII).
- This DECISIONS.md must be updated for every future architectural change.

### Reversibility

High at this stage (no dependent code). Amending or relaxing articles follows the constitution's
own governance + semantic-versioning procedure.

### Impact

- **Migration:** None (greenfield).
- **Security:** Establishes hard gates for destructive ops, secrets, branch discipline, untrusted
  content, and tool-call policy.
- **Operational:** Introduces CI gates, CI-watch, and observability expectations before broad
  release.
- **Agent-native:** Core intent — agents are first-class users with full parity.
- **Cost:** Adds planning/review overhead, scoped by loop depth.

### Follow-ups (deferred, not blocking)

- Seed `PROJECT_CONTEXT.md` when the first capability/architecture lands.
- Seed `docs/solutions/patterns/critical-patterns.md` and `common-solutions.md` on first compounded
  learning.
- Stand up CI enforcement (branch protection, secret/dependency scanning, contract-test + eval
  gates) per the Enforcement Matrix.
