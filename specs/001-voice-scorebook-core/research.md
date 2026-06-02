# Phase 0 Research — Voice-to-Scorebook Core

**Feature:** `001-voice-scorebook-core` · **Plan:** [`plan.md`](./plan.md) · **Date:** 2026-06-01

This consolidates four parallel research streams into the decisions the plan depends on. Every
decision is **recommended pending founder confirmation** where flagged; the three the user asked to
surface explicitly (core language, ASR, first-slice scope) are marked **⟨DECISION FOR REVIEW⟩**.
Sources are inline; the deciding trade-off is stated for each.

---

## D1 ⟨DECISION FOR REVIEW⟩ — Shared deterministic-core language: **Rust + UniFFI** (recommended)

**Decision (recommended):** Write the platform-independent deterministic core as a **single Rust
crate**, integer/fixed-point only, exposed via **UniFFI**-generated bindings to Swift (iOS,
XCFramework→SwiftPM), Kotlin (Android, same crate), a native **CLI**, and a native/WASM **agent/API**
surface. The *same compiled artifact* powers all four surfaces → agent-native parity (Art. II) holds
by construction, not by re-implementation.

**Rationale (deciding axis = determinism, I6/FR-003):**
- IEEE-754 basic arithmetic is reproducible; **transcendental functions are not** (vary by platform/
  libm/version) — true on the JVM too (`strictfp` doesn't pin `Math.sin`). Baseball scoring is
  **overwhelmingly integer/discrete**, so the core can **forbid floating point entirely** (CI-linted
  `#![deny]`/no-`f32`/`f64` audit); ratios (AVG/OBP) compute at the adapter/UI layer. Rust makes that
  rule mechanically enforceable and runs one binary in CI, on-device, and on the server — byte-identity
  provable in one place. ([Rust #150323](https://github.com/rust-lang/rust/issues/150323),
  [Gaffer On Games](https://gafferongames.com/post/floating_point_determinism/),
  [Rapier determinism](https://rapier.rs/docs/user_guides/rust/determinism/))
- Parity is structural: UniFFI is Mozilla-proven in Firefox mobile to hundreds of millions of users;
  the same crate generates Swift **and** Kotlin, and links directly into a CLI/server/WASM.
  ([UniFFI](https://github.com/mozilla/uniffi-rs),
  [application-services](https://mozilla.github.io/application-services/book/android-faqs.html))
- Eval ergonomics: `proptest` (generate adversarial play sequences), `insta` (golden Reisner/Retrosheet
  snapshots), trivial subprocess call to the pinned `cwevent` gate.

**Alternatives considered:**
- **Kotlin Multiplatform (KMP)** — *strong runner-up*, production-ready 2025 (Compose MP iOS Stable
  1.8.0, May 2025). Loses on two axes for an **iOS-first** product: the Kotlin→Swift Obj-C bridge is the
  weak side (erases generics, `Result`, value classes — needs SKIE workarounds), i.e. friction lands on
  iOS; and determinism spans three runtimes (JVM JIT / Kotlin-Native / ART) instead of one binary.
  ([JetBrains 1.8.0](https://blog.jetbrains.com/kotlin/2025/05/compose-multiplatform-1-8-0-released-compose-multiplatform-for-ios-is-stable-and-production-ready/))
- **TypeScript + embedded JS engine** — *rejected.* No integer type (all f64); would reconcile
  byte-identity across JSC (iOS) / V8 (server) / QuickJS (device); ships a 1–4.5 MB runtime per app.
- **Swift core, share to Android later** — *rejected for the core.* Official Swift-for-Android SDK is
  **preview** (first Apple-maintained SDK lands Swift 6.3, Mar 2026, still preview). Too risky for a
  constitutionally mandated Android fast-follow. (Swift remains right for the iOS **adapter/UI** on top
  of the Rust core.)

**The one variable that flips this:** **current team Rust proficiency.** Rust's learning curve is the
real cost for a small team; the core is a bounded, mostly-integer, pure-logic domain (no async/unsafe/
lifetime-heavy APIs) — near the safe end for learning Rust — but if the team is Kotlin-deep and the
timeline is tight, **KMP is the defensible alternative**. On every other axis (determinism, iOS-first
binding quality, single-artifact parity, on-device footprint) Rust wins.

**Risks/mitigations:** UniFFI is pre-1.0 → keep the FFI surface to the four primitives + plain owned
types (strings/JSON/ints/enums), serialize events across the boundary. Android binding currently uses
JNA (async-crash reports) → the core is **synchronous**, sidestepping that class. Cross-compile matrix
(iOS device+sim, Android ABIs, host CLI, WASM) is more CI but well-trodden (`application-services` is a
public reference). **This decision warrants an ADR (Article XXXVIII) once the language is confirmed.**

---

## D2 ⟨DECISION FOR REVIEW⟩ — On-device ASR: **Apple SpeechAnalyzer (iOS) + sherpa-onnx/Parakeet (portable)** (recommended)

**Decision (recommended):** A **two-engine strategy behind one thin `Transcriber` protocol**:
- **iOS v1 primary:** Apple **`SpeechAnalyzer` + `DictationTranscriber`** (iOS 26), with phrase biasing
  via `AnalysisContext.contextualStrings` loaded with the baseball lexicon + per-game roster names.
- **Portable engine (Android fast-follow + iOS fallback):** **sherpa-onnx** running **NVIDIA Parakeet
  (TDT)** or a Zipformer transducer — one codebase across iOS + Android, hotword/fixed-vocab support.

**Rationale:**
- `DictationTranscriber` is purpose-built for **short push-to-talk utterances** and is the *only*
  module exposing **`contextualStrings` phrase biasing** (~100 phrases) — the single biggest accuracy
  lever for jargon ("6-4-3", "caught looking") and roster names. Fully offline, **system-provided
  (no license fee)**, best COPPA posture (audio never leaves device, you control the buffer), lowest iOS
  integration cost. Apple reports ~2× Whisper-Large-v3-Turbo speed at competitive accuracy.
  ([SpeechAnalyzer docs](https://developer.apple.com/documentation/speech/speechanalyzer),
  [iOS 26 guide](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide),
  [Callstack](https://www.callstack.com/blog/on-device-speech-transcription-with-apple-speechanalyzer))
- **The load-bearing trade-off:** Apple's framework is **iOS-only and does not travel to Android.**
  Standardizing the *portable fallback* on sherpa-onnx/Parakeet means the Android fast-follow swaps **one
  ASR adapter**, not a whole-app rewrite. Parakeet leads 2025 OpenASR English accuracy, handles short
  clips well (transducer, not Whisper's fixed-30s encoder), free/Apache-MIT, no per-device fee.
  ([sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx))

**Alternatives considered:**
- **WhisperKit (Argmax)** — excellent accuracy (2.2% WER, ICML 2025) but production tier is **~$0.42/
  device/mo, 1,000-device minimum**, and is **Apple-silicon-only** (nothing for Android). Keep as a
  *buy-instead-of-build* backup if Apple-native accuracy on noisy domain phrases proves insufficient.
  ([pricing](https://www.argmaxinc.com/pricing))
- **whisper.cpp** — portable + MIT, but **documented poor Android latency** (~30 s short clips) and a
  fixed-30 s encoder that wastes compute / risks hallucination on 2–4 s plays. Viable iOS fallback;
  transducers are the better portable pick. ([#1070](https://github.com/ggml-org/whisper.cpp/issues/1070))
- **Vosk** — tiny, good for constrained grammars, but accuracy below the bar; emergency low-end fallback.

**Structured-parse layer (transcript → typed scoring event):** **v1 = a deterministic
grammar-constrained parser (NO LLM)** — a baseball play is a bounded grammar (finite positions ×
outcomes × base/runner slots); a CFG/PEG/normalizer pipeline is faster, lower-power, fully offline,
deterministic, and **cannot hallucinate an invalid event**. Keep **FunctionGemma-270M + XGrammar/GBNF
constrained decoding** as a documented **v2 upgrade** for the messy-utterance tail (fine-tune required;
benchmark on-device iPhone latency before adopting in the hot loop).
([FunctionGemma](https://blog.google/technology/developers/functiongemma/),
[XGrammar](https://arxiv.org/pdf/2411.15100))

**Risks/caveats:** `SpeechAnalyzer` requires **iOS 26+** (set a min-iOS floor; pre-26 falls back to
`SFSpeechRecognizer` or sherpa-onnx). Models download via `AssetInventory` → **preload over Wi-Fi before
the field** (handle "supported-but-not-downloaded"). **Crowd-noise WER on short baseball phrases is
unproven in public benchmarks — field-test before committing** (budget an in-situ eval set; ties to A5/
SC-005). "No raw audio retained" is a **code-enforced rule** (release the held-clip PCM immediately;
never write to disk/telemetry), not a free property.

---

## D3 ⟨CONFIRMED⟩ — First shippable slice: **US1 + US2 + US3 (export)** (founder-confirmed 2026-06-01)

**Decision (confirmed, ADR-0007):** The first shippable, **demoable-to-~20-scorers** artifact is the
vertical slice **US1 (speak a play → deterministic scoring → Reisner notation → game-state advance →
one-tap confirm)** + **US2 (fact-derived judgment loop, V3 "glance" card, never silent)** + **US3
(`finalize_scorecard` + Retrosheet export UI)**. The founder chose to include export in the first slice
for a stronger official-artifact story for the archivist/serious-scorer beachhead (the planner's
recommendation had been US1+US2 only, deferring US3). This satisfies ADR-0006's binding sequencing.

**Deferred (not in the first demo):** US4 (correction UI + downstream recompute + sync). **Out of v1
entirely:** full Rule 9.16 earned-run reconstruction (the most expensive engine work; earned/unearned
stays `PENDING`).

**Note:** the reduced-Retrosheet emitter was already core work (needed for the `cwevent` gate +
gold-dataset validation); US3 surfaces it through an export UI rather than adding new engine scope.

**Important nuance:** the **reduced-Retrosheet emitter lives in the core from Phase A** (it is required
for the `cwevent` CI gate and gold-dataset validation, I4/SC-004) — only the export *UI* (US3) is
deferred. So the core can emit + validate Retrosheet before the app surfaces an export button.

**Rationale:** ADR-0006 mitigation #2 makes "first artifact demoable to ~20 real serious scorers"
binding; that dictates a thin **vertical** slice that proves the spoken-sentence→trustworthy-book thesis,
not a horizontal foundation. US1+US2 is the minimum that a serious scorer can react to. Correction (US4)
and an export button (US3) make it *relied-upon*, but the demo earns the demand signal first.

---

## D4 — Retrosheet acceptance gate: **pin Chadwick `cwevent` v0.10.0; stderr-driven 3-layer CI gate**

**Decision:** Pin **Chadwick `cwevent` v0.10.0** (latest tag, 2023-01-02; build from release tarball
`chadwick-0.10.0.tar.gz` via autotools; SHA256-pin the asset). **Re-check for a v0.11.x before locking.**

**The load-bearing finding (from reading pinned source, not prose docs):** **`cwevent` returns exit 0
even on malformed plays.** A pure exit-code gate is **vacuous** (mirrors the SC-003 dead-counter
lesson). Errors surface on **stderr** (`WARNING: ... skipping invalid record`, `Invalid integer value`,
`Can't find teamfile`, `could not open`). **Minimum valid input:** the event file **+ a mandatory
`TEAM<year>` file** (cwevent `exit(1)`s without it); `.ROS` roster files are optional. The `.EVN/.EVA`
extension is a Retrosheet convention, not enforced by the parser.
([cwevent.c](https://raw.githubusercontent.com/chadwickbureau/chadwick/v0.10.0/src/cwtools/cwevent.c),
[cwtools.c](https://raw.githubusercontent.com/chadwickbureau/chadwick/v0.10.0/src/cwtools/cwtools.c),
[eventfile.htm](https://www.retrosheet.org/eventfile.htm))

**CI gate — three layers (cwevent authoritative):**
1. **Layer 1 (offline, fast, non-authoritative):** Reisner **proof-box** reconciliation from the event
   stream (`AB + BB + Sac + HBP + Interference = Runs + Putouts + LOB`).
2. **Layer 2 (authoritative, mandatory):** pinned `cwevent -y <yr> -n game.EVN` against a fixture dir
   with `TEAM<yr>`; **fail if stderr matches `WARNING|Invalid|Can't find|could not open` OR zero event
   rows emitted.** (Not exit code.)
3. **Layer 3 (regression):** golden-file `diff` of `cwevent -f 0-96 -n` output vs committed `expected.csv`
   — catches parseable-but-*wrong* plays.

**Reduced-but-valid v1 grammar:** 8 record types (`id`, `version`, `info` incl. visteam/hometeam/date,
`start`, `play`, `sub`, `com`, `data`); play events = basic hits `S/D/T/H`+fielder, `K`, `W`, `IW`,
`HP`, single-fielder + clean chains (`8`, `63`, `643`), `E$`, `SB%`/`CS%`, modifiers `/G /L /F /P /SF
/SH`, advances (`-`, `X`, simple `(E$)`). **Flag-for-manual (the hard ~5%):** multi-out plays with
`(runner)` annotations + DP/TP, mid-string errors / throwing-error reclassification, FC disambiguation,
interference/obstruction, combined/rare baserunning.

---

## D5 — Reisner structured schema (FR-005)

Reisner renders **Project Scoresheet codes** (same family as Retrosheet → clean mapping). Model two
typed sub-structures per at-bat: **situation diamond** `{runners:{first?,second?,third?}, outs,
batterHand}` (pre-play state) and **catalyst** (batter event + advances + outcomes). Position numbers
1–9, **`0`=DH** (⚠ differs from Retrosheet `start`-record DH handling — explicit mapping table required).
Runner fate is a 3-state enum: **scored** (circled = RBI / underlined = no RBI), **put out** (out-number),
**left on base** (blank). Pitch marks map onto the Retrosheet `pitches` field. Proof-box reconciliation
is the offline content-validation layer (Layer 1 above).
([reisnerscorekeeping.com/how](https://www.reisnerscorekeeping.com/how),
[HOF "Proof on paper"](https://baseballhall.org/discover/proof-on-paper))

---

## D6 — Gold-standard dataset sourcing (parallel work-stream; ADR-0006 distribution risk)

**Primary (do now, fully in our control):** **build ONE high-quality gold game** — pick an MLB game that
already has a published Retrosheet `.EVN`; capture/narrate audio; hand-score it in Reisner; independently
hand-produce the Retrosheet file; verify with pinned `cwevent`; cross-diff against Retrosheet's published
file (a free third independent check). ~1 recorded game + ~1 day of two people + free tooling → a fully
coupled (audio + Reisner + `cwevent`-clean Retrosheet) gold game validating **SC-001 and SC-002**, plus a
repeatable recipe.

**Secondary (parallel, slower, beachhead-representative):** recruit one active college/HS/MiLB official
scorer via the **SABR Official Scoring Research Committee** (sabrgroups.org/g/official-scoring) and a
local **SABR chapter**; contact **Retrosheet (Tom Thress)** to seed the relationship — to co-produce 2–3
**amateur** games (the data the spec actually cares about). Don't gate the plan on this.

**Bulk fixtures:** published Retrosheet `.EVN` files are free for commercial use **with mandatory verbatim
attribution** — use them as **export-conformance / `cwevent` regression fixtures only** (SC-001 structural
+ I4), **never** as end-to-end accuracy evidence (no spoken source, pro not amateur). Bake the Retrosheet
attribution string into the app export + credits.
([notice.txt](https://www.retrosheet.org/notice.txt),
[SABR Official Scoring](https://sabr.org/research/official-scoring-research-committee/))

---

## D7 — iOS persistence & sync (offline-first, FR-021/FR-023)

**Persistence — SQLite via GRDB (Point-Free `SQLiteData`), event-sourced append-only.** The domain *is*
an event log (`record_play`/`advance_runner`/`correct_event` = events; `finalize_scorecard` = a replay/
fold). An immutable `events` table (monotonic seq, game_id, type, JSON payload, `corrects_event_id`) +
derived projection tables rebuilt by replay; `correct_event` appends a compensating row referencing the
original (preserves history, FR-013; never UPDATE/DELETE). SwiftData fights the append-only/replay/SQL
model and **iOS 26 silently broke SwiftData→CloudKit sync** — a "no data loss" risk. Raw GRDB is the
fallback if we don't want SQLiteData's sync layer.
([SwiftData considerations](https://fatbobman.com/en/posts/key-considerations-before-using-swiftdata/),
[SQLiteData](https://github.com/pointfreeco/sqlite-data))

**Sync — CloudKit private DB, event-log push, last-write-wins; NOT CRDTs.** FR-023 is single-owner,
private-by-default, **single-writer-per-game** → no concurrent-multi-writer problem → CRDTs are "scale
theater" (Art. XXXVII). Push immutable events by monotonic seq; local SQLite log is source of truth, cloud
is replica/backup. Persist the outbound queue (crash-survival = "no data loss"); serialize CloudKit ops
(throttling), batch ≤400. ([CloudKit lessons](https://ryanashcraft.com/what-i-learned-writing-my-own-cloudkit-sync-library/))

---

## D8 — iOS ↔ core binding (if Rust)

UniFFI → static libs for `aarch64-apple-ios` + simulator → **XCFramework** → wrapped in a **SwiftPM
package** (Xcode depends on one auto-updating artifact). Pitfalls to script in CI: rename
`<name>FFI.modulemap`→`module.modulemap`; delete XCFramework before regenerating (xcodebuild won't
overwrite); one core crate (namespace clashes); ~16 MB/lib budget; keep the boundary to the four
primitives + simple owned types + a typed error enum. Avoid the young Rust+KMP bridge generators (Gobley)
for v1. ([UniFFI guide](https://mozilla.github.io/uniffi-rs/latest/),
[Rust on iOS](https://mobilesystemdesign.substack.com/p/multiplatform-with-rust-on-ios-2c4))

---

## Decisions — founder-confirmed 2026-06-01 (ADR-0007)

| # | Decision | Confirmed choice |
|---|----------|------------------|
| D1 | Core language | **Rust + UniFFI** (ADR-0007) |
| D2 | ASR engine strategy | **Two-engine** — Apple-native (iOS) + sherpa-onnx/Parakeet (portable); min iOS = 26 |
| D3 | First-slice scope | **US1 + US2 + US3 (export)**; US4 + sync follow; Rule 9.16 deferred |

**Open verification carried to implementation** (not blockers): confirm the `cwevent` pin (**v0.10.0**)
after a final newer-tag check; **field-test crowd-noise WER** on short baseball phrases before committing
accuracy claims (the real technical risk — public benchmarks are clean/long-form; ties to A5/SC-005).
