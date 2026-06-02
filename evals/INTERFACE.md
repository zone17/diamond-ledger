# Eval-Harness Interface Contract

**Version**: 1.1.0  
**Task**: T010 (Foundational Phase — Phase 2 unblocking interface)  
**Authority**: [`specs/001-voice-scorebook-core/tasks.md`](../specs/001-voice-scorebook-core/tasks.md) stories A9, C3, C4;
[`research.md`](../specs/001-voice-scorebook-core/research.md) D4 (cwevent gate), D6 (gold);
[`data-model.md`](../specs/001-voice-scorebook-core/data-model.md) §4 (NormalizedPlay, Classification);
[`plan.md`](../specs/001-voice-scorebook-core/plan.md) (eval tree, SC-001/002/003/004)  
**Status**: FROZEN — both squads code to this; any change requires a version bump and cross-squad review

This document is the **single source of truth** for the interface between Squad A's eval-harness
runners and Squad C's data.  It defines three things precisely:

1. The **mislabeled-judgment corpus format** — what each corpus entry must contain and mean.
2. The **gold-game format** — how a fully coupled gold game is packaged and consumed.
3. The **gate exit semantics** — what each runner does and does not guarantee, which gates are
   hard-fails, and which are advisory.

Runners (`evals/runners/*.sh`) consume inputs in the formats defined here.  Data producers (Squad C)
produce outputs in the formats defined here.  Neither side reads the other's internal implementation.

---

## 1. Mislabeled-Judgment Corpus Format

**File**: `evals/judgment-corpus/corpus.jsonl` (real corpus, T063 — Squad C)  
**File**: `evals/judgment-corpus/seed.jsonl` (synthetic seed, T011 — Squad A; exercisable until C's corpus lands)  
**Encoding**: UTF-8, one JSON object per line, no trailing comma, no array wrapper.

### 1.1 Per-entry schema

Each line is one JSON object with exactly these top-level keys:

```jsonc
{
  // ── Identity ───────────────────────────────────────────────────────────────
  "id": "<string>",
  // Stable, unique identifier for this corpus entry.  Format: "<source>-<NNN>"
  // where <source> is "seed" (synthetic, Squad A) or "corpus" (real, Squad C)
  // and <NNN> is a zero-padded three-digit integer.
  // Example: "corpus-001", "seed-007"
  // MUST be unique across all JSONL files in evals/judgment-corpus/.

  // ── Situation (pre-play state — feeds classify() as SituationDiamond) ─────
  "situation": {
    "outs": 0,           // integer, 0–2
    "runners": {         // which bases are occupied pre-play
      "first":  true,    // boolean; omit or false if empty
      "second": false,
      "third":  false
    },
    "count": {
      "balls":   0,      // integer, 0–3
      "strikes": 0       // integer, 0–2
    },
    "batter_hand": "R"   // "R" | "L" | "S" (switch) | null (unknown)
  },

  // ── Catalyst (what occurred — feeds classify() as Catalyst) ───────────────
  "catalyst": {
    // Every field here is a NORMALIZED FACT — the exact representation the
    // Rust core's classify() reads.  These are field observations, not
    // interpretations.  See data-model.md §4 NormalizedPlay for the canonical
    // type definitions.

    "batter_event": "FieldedOut",
    // One of: S | D | T | HR | K | W | IW | HP | E | FC | FieldedOut |
    //   SacFly | SacBunt
    // This is the OBSERVED batter event (what happened physically).
    // It is NOT a scoring interpretation.  Example: a ball fielded by the
    // outfielder that the runner reaches safely is "FieldedOut" if the fielder
    // touched it — the hit-vs-error judgment is triggered by the combination
    // of this event + touched_or_misplayed_by (see below), not by labeling it
    // "E" here.

    "fielders": [6, 3],
    // Sequence of fielder positions involved, in order of touch.
    // Integers 1–9 (standard positions); 0 = DH.
    // Example: [6, 3] = shortstop to first base.

    "ball_type": "Ground",
    // One of: Ground | Line | Fly | Pop | Bunt | None
    // "None" for plays where ball type is not applicable (K, W, IW, HP).

    "advances": [
      {
        "runner":   "batter",
        // Identity of the runner advancing.  "batter" for the batter-runner;
        // otherwise a base label: "first" | "second" | "third".
        "from":     "home",
        // Starting base: "home" | "first" | "second" | "third".
        "to":       "first",
        // Destination base or "out".
        // "first" | "second" | "third" | "home" | "out"
        "by_error": null
        // If the advance was enabled by a fielding error: the position integer
        // of the fielder who erred.  null if no error on this advance.
      }
    ],

    "touched_or_misplayed_by": [6]
    // Array of position integers: every fielder who touched or misplayed the
    // ball on this play.  This is the KEY FIELD that, combined with the batter
    // reaching safely, triggers a HitVsError judgment in classify().
    // Empty array [] if no fielder contacted the ball before it left the field
    // of play (e.g., clean hit past the fielder).
  },

  // ── The adversarial label (the mislabeled part) ───────────────────────────
  "supplied_label": "single",
  // A caller-supplied type label that LOOKS deterministic.
  // This is the label that would cause a naive label-driven classifier to
  // resolve the play silently as a deterministic outcome — the adversarial trap.
  // MUST be a label that classify() would accept as a valid deterministic
  // play type IF it were reading the label rather than the facts.
  // Common values: "single" | "double" | "strikeout" | "groundout" | "flyout"
  // The classify() function MUST ignore this field entirely.

  // ── What the classifier must produce ──────────────────────────────────────
  "expected_classification": "Judgment(HitVsError)",
  // The Classification the Rust core MUST return for this play's facts.
  // One of:
  //   "Judgment(HitVsError)"
  //   "Judgment(EarnedVsUnearned)"
  //   "Judgment(ContestedCredit)"
  //   "Judgment(AmbiguousAdvance)"
  // MUST be a Judgment variant — a Deterministic result is a corpus authoring
  // error (a corpus entry that does NOT exercise the cardinal seam).

  // ── Which v1 judgment trigger this entry exercises ─────────────────────────
  "trigger": "HitVsError",
  // One of: HitVsError | EarnedVsUnearned | ContestedCredit | AmbiguousAdvance
  // Must agree with the Judgment kind in expected_classification.
  // Used by the gate runner to ensure all four trigger types are covered.

  // ── Optional provenance (recommended for C's real corpus) ─────────────────
  "description": "Shortstop bobbles a slow roller; batter reaches safely — fielder touched the ball.",
  // Human-readable description of why this is a judgment play.
  // Not consumed by runners; used for corpus review and audit.

  "source": "synthetic",
  // "synthetic" (Squad A seed) | "real" (Squad C real corpus)

  // ── Optional: half-inning error/passed-ball context (required for EarnedVsUnearned) ──
  "inning_error_context": {
    "has_error_or_pb": true
    // true  — the current half-inning contains at least one prior defensive error
    //         or passed ball, so any run that scores MUST be flagged PENDING
    //         (data-model §6 invariant I3; Rule 9.16 counterfactual cannot be
    //         resolved from per-play facts alone).
    // false — no error or passed ball has occurred in this half-inning; this field
    //         is present but does not trigger the EarnedVsUnearned judgment.
    //
    // REQUIRED for entries with trigger = "EarnedVsUnearned".
    // OPTIONAL (may be omitted) for all other trigger types.
    //
    // Rationale: NormalizedPlay / SituationDiamond carries only per-play facts.
    // The inning-level context (has a prior E or PB occurred this half-inning?)
    // is NOT encoded in the play itself.  classify() cannot mechanically derive
    // the EarnedVsUnearned trigger without this field — without it, the entries
    // would be underspecified and the SC-003 gate would be vacuous for that
    // trigger type.  The runner injects this field so classify() can read it
    // as a normalized input alongside the per-play facts.
  },

  // ── Optional: synthetic authorship flag ───────────────────────────────────
  "synthetic": true
  // true  — this entry was synthetically authored by Squad A (seed corpus, T011).
  // false / absent — real corpus entry produced by Squad C (T063).
  // Not consumed by runners; used for corpus provenance audit and honesty caveat.
}
```

### 1.2 Corpus validity rules

A corpus file is valid for use in `judgment-gate.sh` only when ALL of the following hold:

1. Every line parses as valid JSON with all required keys present.
2. Every `expected_classification` is a `Judgment(...)` variant — no `Deterministic` entries.
3. All four v1 trigger types are represented: `HitVsError`, `EarnedVsUnearned`,
   `ContestedCredit`, `AmbiguousAdvance`.
4. All `id` values are unique within the file and across all JSONL files in
   `evals/judgment-corpus/`.
5. `trigger` agrees with the `Judgment` kind in `expected_classification`.

A corpus that passes these rules but contains only trivial or synthetic entries is flagged
as **advisory only** — the README honesty caveat applies (self-consistency, not field accuracy).

### 1.3 Minimal example entry

```jsonc
{
  "id": "seed-001",
  "situation": {
    "outs": 1,
    "runners": { "first": false, "second": false, "third": false },
    "count": { "balls": 1, "strikes": 2 },
    "batter_hand": "R"
  },
  "catalyst": {
    "batter_event": "FieldedOut",
    "fielders": [6, 3],
    "ball_type": "Ground",
    "advances": [
      { "runner": "batter", "from": "home", "to": "first", "by_error": null }
    ],
    "touched_or_misplayed_by": [6]
  },
  "supplied_label": "single",
  "expected_classification": "Judgment(HitVsError)",
  "trigger": "HitVsError",
  "description": "Shortstop fields a slow grounder but bobbles it; batter reaches first safely.",
  "source": "synthetic"
}
```

---

## 2. Gold-Game Format

**Directory**: `evals/gold/<YEAR>-<HOME>-<AWAY>-<DATE>/`  
**Naming**: `<YEAR>` = 4-digit year; `<HOME>` = Retrosheet team code (e.g., `BOS`); `<AWAY>` = Retrosheet team code; `<DATE>` = YYYYMMDD.  
Example: `evals/gold/1986-NYN-BOS-19861025/`

A gold game is a **fully coupled triple**: audio (or narrated transcript), hand-scored Reisner
notation, and a `cwevent`-clean Retrosheet event file — produced **independently** (different scorer
or different day for the Retrosheet file vs the Reisner scoring).

### 2.1 Required directory layout

```
evals/gold/<YEAR>-<HOME>-<AWAY>-<DATE>/
  audio/
    narration.m4a        # play-by-play audio recording (preferred)
    # OR:
    narration.txt        # verbatim transcript if audio is unavailable
    # Exactly one of narration.m4a or narration.txt MUST be present.
    # Additional audio segments named play-NNN.m4a are permitted (one per play).
  reisner/
    scorecard.json       # machine-readable Reisner scoring (schema in §2.2)
    scorecard.pdf        # optional: scan of paper scorecard (human reference)
  retrosheet/
    <GAMEID>.EVN         # independently produced Retrosheet event file
    TEAM<YEAR>           # mandatory TEAM file (cwevent exits 1 without it)
    <YEAR><TEAMCODE>.ROS # optional: roster file(s); omit if unknown
    published.EVN        # Retrosheet's published .EVN for cross-diff (optional
                         # but strongly recommended for the primary gold game)
  meta.json              # game metadata (schema in §2.3)
```

All files in `retrosheet/` MUST have already passed `evals/runners/retrosheet-gate.sh`
before the gold game is considered ready for H3 handoff.

### 2.2 Reisner scorecard schema (`reisner/scorecard.json`)

The hand-scored Reisner notation, serialized as a JSON object.  This is the ground truth for
SC-001 (play-type accuracy) and SC-002 (Reisner token accuracy).

```jsonc
{
  "game_id": "<GAMEID>",        // matches the .EVN id record
  "scorer": "<name or handle>", // identity of the human scorer (for provenance)
  "scored_at": "<ISO-8601>",    // when the Reisner scoring was produced
  "innings": [
    {
      "number": 1,              // 1-based inning number
      "top": {                  // visiting team's half-inning
        "plays": [              // one entry per plate appearance, in order
          {
            "seq": 1,           // 1-based sequence within this half-inning
            "batter": "<name or lineup slot>",
            "situation": {
              // Pre-play SituationDiamond — same schema as corpus §1.1
              "outs": 0,
              "runners": { "first": false, "second": false, "third": false },
              "count": { "balls": 0, "strikes": 0 },
              "batter_hand": "R"
            },
            "reisner_cell": {
              // The human scorer's ground-truth Reisner notation for this play.
              // This is what the system output is compared against (SC-002).
              "situation_symbol": "---",
              // The situation diamond symbol as it would appear on the scorecard.
              // Encodes runner state + out count in Reisner notation.

              "catalyst_symbol": "6-3",
              // The catalyst notation: fielder sequence for outs, "1B"/"2B"/"3B"/"HR"
              // for hits, "K"/"BB"/"HBP"/etc. as appropriate.

              "runner_fate": "PutOut",
              // "Scored(rbi=true)" | "Scored(rbi=false)" | "PutOut(n=<out_number>)"
              // | "LeftOnBase"
              // For the batter-runner; runners already on base have their own fate entries.

              "pitch_marks": "FX"
              // Optional pitch sequence in Retrosheet pitch notation.
              // null if not recorded.
            },
            "play_type_label": "GroundOut",
            // The human scorer's ground-truth play-type classification.
            // One of the deterministic types or a judgment call.
            // For judgment plays, this records the scorer's actual decision
            // (not "Judgment" — the scorer has already resolved it).
            // Permitted values mirror BatterEvent: GroundOut | FlyOut | LineOut |
            //   Single | Double | Triple | HomeRun | Strikeout | Walk |
            //   IntentionalWalk | HitByPitch | SacFly | SacBunt |
            //   FieldersChoice | Error | ReachedOnError | ...
            // This field is the target for SC-001 accuracy measurement.

            "judgment_resolved_as": null
            // If the scorer had to make a judgment call, the call they made.
            // "HitVsError:Hit" | "HitVsError:Error" |
            //   "EarnedVsUnearned:Earned" | "EarnedVsUnearned:Unearned" |
            //   "ContestedCredit:RBI" | "ContestedCredit:NoRBI" |
            //   "AmbiguousAdvance:<destination>" | null (deterministic play)
          }
          // ... one entry per plate appearance
        ]
      },
      "bottom": {
        // Same structure as "top"; home team's half-inning
        "plays": []
      }
    }
    // ... one entry per inning
  ]
}
```

### 2.3 Game metadata schema (`meta.json`)

```jsonc
{
  "game_id": "<GAMEID>",
  // Retrosheet game ID (e.g., "NYN198610250").

  "date": "1986-10-25",
  // ISO-8601 date of the game.

  "home_team": "NYN",
  // Retrosheet team code (matches TEAM<YEAR> and .EVN id record).

  "away_team": "BOS",
  // Retrosheet team code.

  "scorers": {
    "reisner": "<name or handle>",
    // Person who produced reisner/scorecard.json.
    "retrosheet": "<name or handle>"
    // Person who independently produced retrosheet/<GAMEID>.EVN.
    // MUST be different from "reisner", OR the same person on a different day.
    // Independence is required for H3 to qualify as field accuracy (not self-consistency).
  },

  "cwevent_verdict": {
    "passed": true,
    // true if the .EVN passed retrosheet-gate.sh (all three layers) at the time of packaging.
    "cwevent_version": "0.10.0",
    // Pinned version used for verification.
    "run_at": "<ISO-8601>",
    // When the gate was last run against this file.
    "stderr_clean": true,
    // true if stderr produced no WARNING|Invalid|Can't find|could not open output.
    "event_rows_emitted": 72
    // Number of event rows cwevent emitted (must be >= 1).
  },

  "published_retrosheet_evn": "retrosheet/published.EVN",
  // Path to Retrosheet's published .EVN file for cross-diff validation.
  // null if not available (cross-diff is optional but strongly recommended).

  "cross_diff_clean": true,
  // true if our produced .EVN diffs clean against the published .EVN.
  // null if published_retrosheet_evn is null.

  "h3_ready": true,
  // true when all of the following hold:
  //   - cwevent_verdict.passed == true
  //   - scorers.reisner != scorers.retrosheet (OR documented independent production)
  //   - reisner/scorecard.json and retrosheet/<GAMEID>.EVN are both present
  //   - audio/narration.m4a or audio/narration.txt is present
  // When h3_ready is true, accuracy.sh measures FIELD ACCURACY (credible).
  // When h3_ready is false, accuracy.sh measures SELF-CONSISTENCY (advisory only).

  "notes": ""
  // Free-form notes: known discrepancies, judgment calls the scorer documented,
  // plays that fell outside the reduced grammar, etc.
}
```

### 2.4 Accuracy runner input contract

`evals/runners/accuracy.sh` receives a gold-game directory path and reads:

1. `meta.json` — verifies `h3_ready == true` before asserting field accuracy.
2. `audio/narration.m4a` (or `narration.txt`) — feeds the end-to-end speak→score pipeline.
3. `reisner/scorecard.json` — the ground-truth play-type labels (SC-001) and Reisner tokens (SC-002).
4. `retrosheet/<GAMEID>.EVN` — the ground-truth event file for structural cross-check.

The runner MUST label its output:

- `"FIELD ACCURACY"` if `meta.json.h3_ready == true`.
- `"SELF-CONSISTENCY (advisory — not field accuracy)"` if `meta.json.h3_ready == false`
  or if `evals/gold/` contains no game at all.

Any report, CI log, or PR comment that contains accuracy numbers MUST include this label.
Omitting the label is a documentation defect equivalent to a fabricated Retrosheet record.

---

## 3. Gate Exit Semantics

### 3.1 Overview — which gates are hard-fails

| Runner | Gate tier | CI job | Hard-fail? | Condition for hard-fail |
|--------|-----------|--------|-----------|-------------------------|
| `judgment-gate.sh` | SC-003 silent-resolution | `core-eval` | **YES** | Any corpus entry not classified as `Judgment(...)`, OR `silent_resolution_counter > 0` |
| `proof-box.sh` | Proof-box Layer 1 | `core-eval` | **YES** | Any half-inning where `AB+BB+Sac+HBP+Interference ≠ Runs+Putouts+LOB` |
| `retrosheet-gate.sh` Layer 2 | cwevent structural | `retrosheet-gate` | **YES** | stderr matches `WARNING\|Invalid\|Can't find\|could not open`, OR zero event rows emitted |
| `retrosheet-gate.sh` Layer 3 | Golden diff regression | `retrosheet-gate` | **YES** | Diff against `expected.csv` is non-empty |
| `accuracy.sh` | SC-001 / SC-002 accuracy | `core-eval` | **ADVISORY** until real gold game (H3); then YES if h3_ready |
| `parity.sh` | Agent/CLI vs UI parity SC-008 | (standalone) | **YES** | Any byte-level difference between CLI/agent path and core path for identical facts |

### 3.2 SC-003 judgment gate — hard-fail semantics

**Runner**: `evals/runners/judgment-gate.sh <corpus.jsonl>`

The gate HARD-FAILS (exit 1) if ANY of the following is true after the run:

1. Any corpus entry is classified as `Deterministic` or `OutOfFormat` — the corpus entry's
   `expected_classification` is a Judgment variant, and the classifier MUST agree.
2. `silent_resolution_counter > 0` — any judgment was mutated (state advanced, call recorded)
   without an open `JudgmentDecision` (status = Open) and a recorded `decider`.
3. Not all four trigger types (`HitVsError`, `EarnedVsUnearned`, `ContestedCredit`,
   `AmbiguousAdvance`) are present in the corpus.  A corpus that does not exercise all four
   triggers is vacuous and must fail.
4. The corpus file does not exist or contains zero entries.

**THERE IS NO SILENT RESOLUTION PATH.** The SC-003 counter is not a soft warning — it is the
instrument that makes the cardinal no-silent-judgment invariant (I2) verifiable.  A counter that
can be non-zero without failing CI is a dead counter (the probe failure this spec was hardened
against).  A zero-size corpus is equally vacuous.

The gate does NOT verify field accuracy (whether the classifier agrees with a trained human on a
real play).  That is the accuracy runner's job.

### 3.3 cwevent gate — 3-layer exit semantics

**Runner**: `evals/runners/retrosheet-gate.sh <fixture-dir> <year>`

**Load-bearing finding** (research.md D4): `cwevent` exits 0 even on malformed plays.
Errors surface on **stderr**, not exit code.  A pure exit-code gate is vacuous.

**Layer 1 (offline, fast, non-authoritative — proof-box):**
- Run by `proof-box.sh` independently.
- Verifies the Reisner proof-box identity: `AB + BB + Sac + HBP + Interference = Runs + Putouts + LOB`.
- Hard-fail on any imbalance.
- This is an offline consistency check only.  A passing proof-box does NOT guarantee a valid
  Retrosheet file.

**Layer 2 (authoritative, mandatory — cwevent):**
- The gate runs: `cwevent -y <year> -n <GAMEID>.EVN` with the mandatory `TEAM<year>` file
  present in the fixture directory.
- Hard-fail if ANY of the following:
  - stderr matches the pattern `WARNING|Invalid|Can't find|could not open` (case-insensitive).
  - Zero event rows are emitted to stdout.
  - `TEAM<year>` file is absent (cwevent exits 1 without it — this is separately caught).
- Do NOT gate on cwevent exit code alone.  A clean exit code with stderr warnings is a FAIL.

**Layer 3 (regression — golden diff):**
- The gate diffs `cwevent -f 0-96 -n` output against the committed `expected.csv` golden file.
- Hard-fail if the diff is non-empty.
- This catches plays that are parseable but structurally wrong (the most insidious failure mode).
- The golden file MUST be committed to the repo alongside the fixture; it is not generated on the fly.

**The accuracy runner is NOT the cwevent gate.**  A cwevent-clean export proves structural
conformance to the Retrosheet format.  It does NOT prove that the plays in the export correctly
represent the game — that is what the gold dataset (§2) and the accuracy runner (§3.4) verify.

### 3.4 Accuracy runner — advisory-until-gold semantics

**Runner**: `evals/runners/accuracy.sh <gold-game-dir>`

**The accuracy runner is ADVISORY until `meta.json.h3_ready == true`.**

This is not a soft preference — it is a hard epistemic boundary.  Before a real independent gold
game exists (H3 handoff complete), the accuracy runner is measuring whether the system's output
agrees with itself across two runs, not whether it agrees with a trained human scorer on real plays.
Self-consistency at 98% is meaningless if the underlying classifier is systematically wrong.

SC-001 (≥90% play-type accuracy) and SC-002 (≥85% Reisner token accuracy) are **not CI hard-fails
until H3 is complete**.  Until then, the runner MUST:

1. Print `WARNING: SELF-CONSISTENCY MODE — no real gold game present. These metrics are NOT field accuracy.`
   at the top of its output.
2. Label every metric table row with `(self-consistency, advisory)`.
3. Exit 0 regardless of the metric values (advisory, not blocking).

Once `meta.json.h3_ready == true`:

1. The runner prints `FIELD ACCURACY MODE — gold game: <game_id>, scorer: <reisner scorer>`.
2. Hard-fail (exit 1) if SC-001 < 90% or SC-002 < 85%.
3. Label every metric row with `(field accuracy)`.

### 3.5 What a "PASS" means for each gate

| Gate | What PASS proves | What PASS does NOT prove |
|------|-----------------|--------------------------|
| judgment-gate.sh | The classifier is fact-derived (reads facts, not labels); no silent resolutions occurred | Whether the classifier's calls match trained human scorers on real plays |
| proof-box.sh | The half-inning accounting identity holds on generated plays (internal consistency) | That the emitted Retrosheet is structurally valid (use cwevent gate) |
| retrosheet-gate.sh | The emitted event file is structurally valid per pinned cwevent v0.10.0 | That the plays in the file correctly represent the game (use accuracy runner) |
| accuracy.sh (advisory) | The system is internally self-consistent across two runs | Field accuracy against trained human ground truth |
| accuracy.sh (field, h3_ready) | The system's output agrees with independent human scorer ground truth at ≥SC-001/SC-002 bar | Perfect coverage of all play types; expert-level judgment calls |
| parity.sh | CLI/agent path and core path produce byte-identical output for identical facts (SC-008) | Correctness of the output itself |

---

## 4. Cross-Squad Responsibilities

| Artifact | Produced by | Consumed by | Handoff |
|----------|------------|-------------|---------|
| `evals/judgment-corpus/seed.jsonl` | Squad A (T011) | Squad A `judgment-gate.sh` (T041) | Internal to A; exercisable before C's corpus |
| `evals/judgment-corpus/corpus.jsonl` | Squad C (T063) | Squad A `judgment-gate.sh` (T041) | H3-adjacent; C delivers, A gates |
| `evals/gold/<game>/` (all three components) | Squad C (T064, T065) | Squad A `accuracy.sh` (T042) | **H3** — completes when `meta.json.h3_ready == true` |
| `evals/retrosheet-fixtures/<year>/` | Squad C (T061, T062) | Squad A/C `retrosheet-gate.sh` (T060) | **H2**-adjacent; both squads target frozen grammar (T009) |
| `expected.csv` per fixture | Squad C (T062) | `retrosheet-gate.sh` Layer 3 | Must be committed before the gate is wired as a hard-fail |

---

## 5. Versioning and Change Control

### Change log

| Version | Date | Change |
|---------|------|--------|
| 1.1.0 | 2026-06-01 | Added optional `inning_error_context` field (required for `EarnedVsUnearned` entries) so `classify()` can mechanically derive the half-inning error/passed-ball trigger from normalized inputs. Added optional `synthetic` boolean field for corpus provenance. Both additions are backward-compatible; existing entries without these fields remain valid for non-`EarnedVsUnearned` triggers. |
| 1.0.0 | 2026-06-01 | Initial frozen interface. |

This file is a **frozen interface** once the foundational phase checkpoint is reached (T007–T012 all
committed).  Squads A and B build against it; Squad C produces data to it.

To change this interface after the checkpoint:

1. Increment the version string at the top of this file.
2. Update both consumer (runners) and producer (Squad C data) in the same PR.
3. Cross-squad review is required — Squad A lead + Squad C lead must both approve.
4. Document the change in `DECISIONS.md` if it alters gate semantics.

Minor additions that are backward-compatible (new optional fields, expanded descriptions) do not
require a version bump but do require cross-squad notification.

---

## 6. Related Files

| File | Role |
|------|------|
| `evals/runners/judgment-gate.sh` | Consumes corpus per §1; enforces §3.2 gate semantics |
| `evals/runners/accuracy.sh` | Consumes gold game per §2; enforces §3.4 advisory/hard semantics |
| `evals/runners/proof-box.sh` | Layer 1 of the cwevent gate (§3.3) |
| `evals/runners/retrosheet-gate.sh` | Layers 2+3 of the cwevent gate (§3.3) |
| `evals/judgment-corpus/corpus.jsonl` | Real adversarial corpus (Squad C, T063) |
| `evals/judgment-corpus/seed.jsonl` | Synthetic seed corpus (Squad A, T011) |
| `evals/gold/<game>/` | Gold-game triple per §2 (Squad C, T064–T065) |
| `evals/retrosheet-fixtures/<year>/` | cwevent regression fixtures (Squad C, T061–T062) |
| `core/src/classify/guard.rs` | Instrumented SC-003 silent-resolution counter (T024) |
| `core/src/classify/mod.rs` | `classify(NormalizedPlay) -> Classification` (T021) |
| `specs/001-voice-scorebook-core/data-model.md` | NormalizedPlay, Classification, JudgmentKind canonical types |
| `specs/001-voice-scorebook-core/research.md` | D4 (cwevent gate), D6 (gold dataset) |
| `specs/001-voice-scorebook-core/tasks.md` | T010, A9, C3, C4 |
| `DECISIONS.md` | ADR-0007 (tech stack), future gate-semantics ADRs |
