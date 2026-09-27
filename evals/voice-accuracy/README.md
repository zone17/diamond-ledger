# evals/voice-accuracy

**FIXTURE ROBUSTNESS (advisory — not field accuracy)**

Corpus for the voice-accuracy harness (DL-157, plan
`docs/plans/2026-09-26-0919-feat-voice-accuracy-harness-plan.md`, U4). One command must give a
labeled answer to a single question:

> Does the deterministic pipeline (`GrammarParser → FactBridge → real core`) ever score a
> plausibly mis-heard transcript as a **wrong play, silently**, for mis-hearings that are
> detectable at the text layer?

and, for issue #157's roster biasing: does the biasing policy ever turn a plausibly mis-heard
transcript into a confidently-scored wrong play? #157's biasing ships only if every adversarial
pair keeps the base.

Authority order: Article VII / FR-008 (never a silent wrong play) > `evals/INTERFACE.md` §2.4
labels > the plan's Requirements > its Key Technical Decisions.

## Status

| | |
|---|---|
| Authored against commit | `a0f2220184bdae8b48f6d521ec9d4311684b3a68` (branch `feat/ios/DL-157-voice-accuracy-harness`) |
| Base-staleness preflight | `git merge-base --is-ancestor origin/main HEAD` → ok (2026-09-27) |
| Binaries used | `dl-score`, `dl-bias` from `ios/.build/arm64-apple-macosx/debug` (built from the commit above) |
| Expectations authored from | play semantics first, then every row run through `dl-score --confidence 100` / `dl-bias` and compared (see checklist) |
| **reviewed_by** | **PENDING** — expectations are NOT frozen until a reviewer other than the author has read the pipeline output row by row against this corpus and recorded their name and the commit here |

## The three tiers, and what each can and cannot prove

| Tier | Input | Status | Proves | Cannot prove |
|------|-------|--------|--------|--------------|
| 1. Fixture variants (`variants.jsonl`, `biasing-pairs.jsonl`) | Hand-authored text perturbations of canonical transcripts; hand-authored (base, biased) hypothesis pairs | **Now — merge gate** | For the enumerated mis-hearings, whether the *text→score* leg scores a wrong play silently, and whether the biasing *decision* refuses the enumerated adversarial pairs. Determinism of both. | Anything about real ASR: which mis-hearings actually occur, how often, at what confidence. That a mis-hearing outside the enumerated set is safe. Field accuracy of any kind. |
| 2. Synthetic speech | TTS audio of the same transcripts through the real ASR engines | **Later — advisory only** (`SYNTHETIC SPEECH` label) | Whether the audio→text leg reproduces the enumerated words on a host; word error rate under one synthetic voice | Human speech, ballpark noise, dialect; anything about a scorer's real utterances |
| 3. Gold game (`evals/gold/`) | A human-scored game with narration audio and a Retrosheet/Reisner ground truth | **Human** (`FIELD ACCURACY` only when `meta.json.h3_ready == true`) | End-to-end accuracy against a ground truth | Generalisation beyond that game |

Every report that carries numbers from tier 1 MUST carry the label
`FIXTURE ROBUSTNESS (advisory — not field accuracy)`. Omitting it is a documentation defect
equivalent to a fabricated Retrosheet record (`evals/INTERFACE.md` §2.4).

## Files

### `variants.jsonl` — text-layer perturbations of canonical transcripts

Plain JSON Lines. One object per line, keys:

| Field | Meaning |
|-------|---------|
| `id` | Stable row id, `va-<kind>-<base>-<slug>` |
| `base_id` | An existing id in `evals/transcript-regression/cases.jsonl` (the canonical set). The base's facts at confidence 100 are the reference. |
| `kind` | `mishear` \| `numeral` \| `filler` \| `roster` \| `roster_collision` (fixed set, reported per kind) |
| `transcript` | The perturbed transcript fed to `dl-score --confidence 100` |
| `expect` | `same_as_base` \| `safe_surface` \| `text_layer_undetectable` (below) |
| `roster` | Array of player names passed as `--roster`. **Required** for `roster` / `roster_collision`, **absent** otherwise. Rows are grouped by roster and run once per group. |

Kinds:

- `mishear` — homophones and near-words a speech engine plausibly emits ("sean" for "short",
  "flied" for "fly", "centre", "thirst" for "first").
- `numeral` — spoken or digit fielder notation ("six three", "6 3", "4-3 groundout", "F7").
  The v1 grammar has no numeral support, so the correct outcome today is a safe surface; if
  numeral support is added, the `safe_surface` numeral rows flip to `same_as_base` and the
  same-by-coincidence rows (see findings) become real coverage.
- `filler` — disfluencies and lead-ins ("uh", "um, okay", "so … yeah", "right,", "alright",
  "first of all").
- `roster` — a roster name inserted where a scorer would say it, with that roster in force.
- `roster_collision` — roster names that equal or contain a position keyword ("Wright",
  "Short", "Center", "Third", "First", "Pitcher", "Lefty", "Center Fielder Jones") with that
  roster in force. Expected `safe_surface` when masking leaves the production without a fielder,
  `same_as_base` when a position word remains.

Expectations (authored from play semantics, never from today's output):

- `same_as_base` — the facts `dl-score` emits must be identical to the base's facts at
  confidence 100.
- `safe_surface` — the pipeline must NOT score confidently: `classification == "parse_error"`
  with `error` starting `ambiguous(` or equal to `out_of_grammar`, or a judgment of the same
  kind the base expects (Card B reaches the scorer).
- `text_layer_undetectable` — the perturbed text is itself a *different valid play*
  ("ground ball to second …" for "… to short", "single to left" for "double to left",
  "strikeout looking" for "strikeout swinging"). No text-layer pipeline can catch these; they are
  counted and reported under their own label and excluded from the hard fail. They exist so the
  report says how much of the mis-hearing space this tier cannot see.

The comparator (U5) applies, from `dl-score`'s actual output fields:

- **confident-wrong (hard fail):** `ok == true`, `needs` in {`none`, `confirm`} and `facts`
  differ from the base's facts; or the variant surfaces `judgment` when the base is
  deterministic; or the judgment kind differs from the base's expected kind. Any canonical row
  regressing is also a hard fail.
- **safe miss:** `parse_error` with `ambiguous(`/`out_of_grammar`, or same judgment kind as the
  base expects.

A variant scoring differently from its base is the signal (KTD6).

### `biasing-pairs.jsonl` — (base, biased) hypothesis pairs for `dl-bias`

Plain JSON Lines, keys:

| Field | Meaning |
|-------|---------|
| `id` | Stable row id, `bp-<guard>-<slug>` |
| `base` | Base-leg text (kept verbatim whenever it is kept) |
| `base_confidence` | `null` unless the row tests R19 (a known base confidence); otherwise 0…1 |
| `biased` | Biased-leg text, or `null` when that leg produced nothing |
| `biased_confidence` | 0…1 (see finding B0: use `0.01`/`0.99`, never a literal `0`/`1`) |
| `contextual_set` | Phrases the biased leg was told about: lexicon terms plus roster names in force |
| `expect_decision` | `override` \| `keep_base` |
| `expect_text` | The exact text `dl-bias` must return (the biased text verbatim on override, the base verbatim otherwise) |
| `note` | Optional: which guard the row exercises and why the expectation is what it is |

The `contextual_set` is a representative subset of `BaseballLexicon.terms`
(`ios/Sources/Speech/AppleTranscriber.swift`) plus the roster names `Wright`, `O'Neil`,
`Garcia`, `Jones`, `Martinez`. The set in force on device is what `RosterContextBuilder` would
produce (full lexicon first, roster phrases after, under the phrase budget); membership is judged
on normalized whitespace tokens, so `"third baseman"` contributes `third` and `baseman`, and
`"o'neil"` contributes `o` and `neil`.

Coverage: every `BiasingReason` gets at least two rows (`no_biased_hypothesis` 2, `empty_base` 2,
`biased_confidence_below_threshold` 3, `divergent` 6, `token_not_contextual` 4,
`replaced_token_in_vocabulary` 6, `base_more_confident` 2, `agreed` 12), including the
0.69/0.70 threshold boundary, the strictly-greater R19 boundary, the casing-only distance-0
case, and the adversarial set: in-vocabulary play-word swaps (single→double, short→second,
out→safe, fly→ground, pitch→pitcher), a divergent rewrite, an out rewritten as a home run at
0.99, insertions of non-contextual words, a biased hypothesis that deletes a lexicon word, and
insertions of contextual play/position phrases (finding B1).

## Authoring checklist (run before adding or changing any row)

1. **Semantics first.** Write the transcript and decide from the rules of scoring what the
   correct outcome is: the same facts as the base, a safe surface, or a genuinely different valid
   play. Do this before running anything.
2. **Base-staleness preflight.** `git merge-base --is-ancestor origin/main HEAD && echo ok`.
   Record the HEAD sha in *Status* above.
3. **Run the row.** `dl-score --confidence 100 [--roster a,b]` for a variant (group roster rows
   by roster, one invocation per group); `dl-bias <file>` for a pair.
   ```bash
   DLSCORE="$(cd ios && swift build --product dl-score --show-bin-path)/dl-score"
   printf '%s\n' "ground ball to sickened, threw him out at first" | "$DLSCORE" --confidence 100
   ```
4. **Compare, never bless blind.** If the output matches the semantics, record the expectation.
   If the output is wrong, the expectation stays what is *correct*; the row goes red and the
   defect goes under *Pipeline findings* below. Do not tune an expectation to make today's
   output pass. Mark `safe_surface` only when the pipeline truly surfaces (clarify / out-of-grammar
   / same-kind judgment).
5. **Same-by-coincidence check.** If a row is `same_as_base` only because a hard-coded default
   happened to equal the base (6-3 groundout, F8, E6, 6-4-3), say so in *Pipeline findings* and
   add the sibling row on a base where the default is wrong.
6. **Independent reviewer before freeze.** A reviewer other than the author reads the pipeline
   output row by row against the corpus and records `reviewed_by: <name> @ <commit>` in *Status*.
   Until then the corpus is authored, not frozen.
7. **Never change an existing canonical row** in `evals/transcript-regression/cases.jsonl`;
   append only.

## Canonical set expansion (this unit)

`evals/transcript-regression/cases.jsonl` grew from 17 to 56 rows (39 appended, all verified with
`dl-score` before adding, none of the original 17 changed). New coverage: intentional walk, base
on balls, 5-3 / 1-3 / 3-6 groundouts, "over to first", F7 / F9, line drive, pop-up to the
catcher, "caught by center fielder", "struck out" (swinging, looking, called third strike, with a
runner clause), "homer", singles with fielders (1B-7, 1B-9), doubles (right, center field,
stand-up), triple to center, "plunked", SF9 / SF7, sacrifice bunt (bare and to the pitcher),
"reached on error by short", three double plays (6-4-3, 4-6-3, 5-4-3 → `contestedCredit`
judgment), four misplay-verb judgment rows (booted / misplayed / dropped in left field / muffed
by the third baseman), and three guards (misplay verb with batter out → out-of-grammar, two
plays in one utterance → `ambiguous(`, narrative → out-of-grammar).

Rows deliberately NOT added at authoring time because the output then was wrong (findings
F7–F9): "ground ball, first baseman made the play unassisted", "dropped fly ball in center,
runner scored safely", "bobbled the grounder, safe at first", "dropped it, batter reaches first".
U9 fixed all four (now `3` unassisted, out-of-grammar, clarify, clarify — pinned by
`DL157NeverGuessAFielderTests`); they can be appended to the canonical set by the reviewer.

## Row counts

`variants.jsonl` (228 rows, 21 distinct bases):

| kind | same_as_base | safe_surface | text_layer_undetectable | total |
|------|---:|---:|---:|---:|
| mishear | 25 | 36 | 12 | 73 |
| numeral | 0 | 32 | 0 | 32 |
| filler | 53 | 0 | 0 | 53 |
| roster | 40 | 8 | 0 | 48 |
| roster_collision | 8 | 14 | 0 | 22 |
| **total** | 126 | 90 | 12 | 228 |

`biasing-pairs.jsonl`: 39 rows, 27 `keep_base`, 12 `override`.

### Expectation relabels by U9 (21 rows; no transcript changed, no row removed)

U9 changed the parser so that no production resolves a fielder / chain / strikeout variant from
a default (KTD-U9, see *Pipeline findings*). Twenty-one `expect` labels were then wrong for one
of two provable reasons — never to make the gate pass (the hard gate was already green before
the relabel; the relabel took the advisory expectation-mismatch count from 21 to 0):

- **15 rows `same_as_base` → `safe_surface`: the transcript does not state the fielder / variant,
  so `same_as_base` could only ever be met by a guess** (the "pass by coincidence" rows the
  findings already flagged under authoring rule 5). Under Article VII the correct outcome is a
  clarify. `va-mishear-63-sean`, `va-mishear-63-shore`, `va-mishear-63-firth` (only "at first"
  survives → chain `3` heard, 6-3 not stated); `va-mishear-f9-wright` ("wright" is not "right"
  under whole-word matching — the DL-157 motivating bug); `va-mishear-ks-singing`,
  `va-mishear-kl-cooking`, `va-mishear-kl-booking` (an unknown word in the strikeout modifier
  slot — the text says neither swinging nor looking; recovering "looking" from "cooking" is
  fuzzy matching, which KTD7 forbids in the parser and which belongs to the biasing layer);
  `va-mishear-ess-sean` (no fielder stated); `va-numeral-63-ground-six-three`,
  `va-numeral-63-groundout-digits`, `va-numeral-f8-eight`, `va-numeral-dp643-six-four-three`,
  `va-numeral-dp643-digits`, `va-numeral-ess-error-six`, `va-numeral-ess-error-on-6` (numerals
  are not positions in v1 — a number word in play narration is a count / out / run / inning as
  often as a fielder, so reading it as a fielder would be a guess; every numeral row now
  surfaces, which is the label their non-coincidence siblings already carried).
- **6 rows `safe_surface` → `same_as_base`: the grammar now scores the correct play, so the
  weaker label under-stated what the pipeline must do.** `va-mishear-f8-flied-out` ("flied
  out"), `va-mishear-f7-flyball-left` ("flyball"), `va-roster-f8-martinez-flies` ("flies out"),
  `va-mishear-ks-hyphen` ("strike-out" tokenizes to "strike out") — F10 synonyms, each an
  unambiguous spelling of a play the grammar already accepts; `va-mishear-sf-centre` ("centre" is
  the same word as "center"; the sibling rows `va-mishear-f8-centre` / `va-mishear-hr-centre`
  already expected `same_as_base`); `va-filler-e3b-first-of-all` ("first of all" is filler, the
  play is E5 as stated; every other filler row expects `same_as_base`).

## What today's pipeline does with this corpus (commit a0f2220)

Measured with the scratch mirror of the U5 rules; U5's comparator is the authority.

| kind | same as base | safe miss | text-layer undetectable | **confident-wrong** |
|------|---:|---:|---:|---:|
| mishear | 27 | 22 | 12 | **12** |
| numeral | 7 | 19 | 0 | **6** |
| filler | 48 | 1 | 0 | **4** |
| roster | 39 | 7 | 0 | **2** |
| roster_collision | 8 | 13 | 0 | **1** |
| **total** | 129 | 62 | 12 | **25** |

The 25 confident-wrong rows were the rows whose `expect` the pipeline did not meet at a0f2220.
They were the findings below, not authoring errors: each was checked against play semantics and
the expectation is what is correct. The gate was red on this corpus until U9 fixed them.

`dl-bias` at a0f2220: 37 of 39 pairs matched; the 2 mismatches were finding B1 (both
`bp-adversarial-insert-*` rows overrode where a correct policy keeps the base).

## What the pipeline does with this corpus after U9 (`bash evals/runners/voice-accuracy.sh`)

Measured by the real gate (U5's comparator), two identical runs, after the U9 parser change and
the 21-row relabel above:

| kind | same as base | safe miss (clarify / out-of-grammar) | text-layer undetectable | **confident-wrong** |
|------|---:|---:|---:|---:|
| mishear | 25 | 36 (18 / 18) | 12 | **0** |
| numeral | 0 | 32 (18 / 14) | 0 | **0** |
| filler | 53 | 0 | 0 | **0** |
| roster | 40 | 8 (8 / 0) | 0 | **0** |
| roster_collision | 8 | 14 (14 / 0) | 0 | **0** |
| **total** | 126 | 90 | 12 | **0** |

Hard signal: **0 confident-wrong rows, 0 canonical regressions (56/56 `transcript-score.sh`,
no canonical row changed), 0 pair mismatches, deterministic across two runs — PASS.**
Advisory: expectation mismatches 0; clarify rate @100 = 59/248 = 23.8% of parseable rows
(was 7.4% at a0f2220 — the difference is exactly the former silent defaults now surfacing).
The 12 `text_layer_undetectable` rows still score the wrong play with confidence, as designed
(a substituted position word is a valid play; only the ASR leg can catch it).

## Pipeline findings

Everything observed at a0f2220 that was wrong or that hid a defect. Row ids are the evidence.
Each finding carries its U9 status: **FIXED** (with the rule now in `GrammarParser.swift`,
pinned by `DL157NeverGuessAFielderTests` in `ios/Tests/DL151GrammarHardeningTests.swift`) or
**OPEN** (with why).

The U9 rule (KTD-U9): a production resolves a fielder, a fielder chain, or a strikeout variant
ONLY from what the utterance explicitly says; when it cannot, it still matches (the play TYPE is
known) but `parse` throws `ParseError.ambiguous(candidates: [thatPlay])` — a single-candidate
clarify — so the Clarify sheet offers the play and the scorer supplies the fielder. No hard-coded
default chain / position remains in the parser. Keywords match whole words only.

### Text→score leg (`GrammarParser` / core)

- **F1. Groundout default `63` fires when only one position word survives.** **FIXED.** A
  groundout is complete only with two explicit positions (or one plus "unassisted"); otherwise
  it is a clarify whose candidate carries the partial chain actually heard (`3` for "… at
  first"), never an invented one. At a0f2220 a 4-3 or 5-3 whose "second"/"third" or "first"
  was mis-heard was scored as a confident 6-3.
  Rows: `va-mishear-43-sickened`, `va-mishear-43-thirst`, `va-mishear-53-thud`,
  `va-mishear-53-fist`, `va-numeral-43-ground-four-three`, `va-numeral-43-groundout-digits`,
  `va-numeral-43-ground-4-to-3`, `va-numeral-53-ground-five-three`. The same default made
  `va-mishear-63-sean/shore/firth`, `va-numeral-63-ground-six-three`,
  `va-numeral-63-groundout-digits` pass *by coincidence* (the base is 6-3); those five are
  relabelled `safe_surface` (see *Expectation relabels by U9*).
- **F2. Flyout default `8` fires when the outfield word is mis-heard.** **FIXED** — no
  explicit position → clarify with no fielder. F7/F9 became F8.
  Rows: `va-mishear-f7-loft`, `va-mishear-f7-lift`, `va-mishear-f9-write`, `va-mishear-f9-rite`,
  `va-numeral-f7-seven`, `va-numeral-f7-fly-ball-7`. `va-mishear-f8-centre` and
  `va-numeral-f8-eight` passed by coincidence (the first now scores F8 because "centre" is a
  synonym; the second is relabelled `safe_surface`).
- **F3. Sac-fly default `9`.** **FIXED** — same rule; "centre" / "centre field" added as the
  British spelling of the same word (not a mis-hearing), so `va-mishear-sf-centre` is SF8.
  "to enter" is a clarify. Rows: `va-mishear-sf-centre`, `va-mishear-sf-enter`.
- **F4. Strikeout defaults to swinging.** **FIXED (narrowest rule).** "looking"/"called"/
  "watching" → Kl; "swinging"/"swings"/"swung" → K; a BARE strikeout — nothing after the
  phrase, a new clause ("struck out, runner safe at third"), a masked name, or a function /
  filler word — keeps the ONE documented default (K), because the canonical rows `struck out`
  and DL-154 pin a bare strikeout as swinging. Any OTHER content word in the modifier slot
  ("strikeout cooking / booking / singing") is a mis-heard modifier → clarify offering BOTH
  variants as candidates. The two rows are relabelled `safe_surface`: the text does not say
  "looking", and recovering it is fuzzy matching (KTD7 forbids it in the parser; it is the
  biasing layer's job). Rows: `va-mishear-kl-cooking`, `va-mishear-kl-booking`.
- **F5. Substring keyword matching absorbs filler words.** **FIXED** — the transcript is
  tokenized and every keyword / phrase matches whole tokens only ("alright" ≠ "right",
  "wright" ≠ "right", "terror" ≠ "error"); a BARE direction / ordinal word ("right", "left",
  "center", "first", "second", "third", "short") is a fielder only in a fielding slot (after
  "to / at / by / in / from / into / toward(s)", articles skipped, or as the head of an "X to Y"
  chain); phrase forms ("right field", "third baseman", "shortstop", "pitcher") always count; a
  base named as a destination ("safe at first", "reached first", "advanced to third", "runner on
  third") is never a fielder. Rows: `va-filler-63-right`, `va-filler-63-alright`,
  `va-filler-63-first-of-all`, `va-filler-43-right` (all 6-3 / 4-3 now).
- **F6. Roster masking with a partial chain scores a wrong explicit chain (DL-157 gap).**
  **FIXED** — a masked name that sits in a FIELDING SLOT ("to Wright", "by Jones", "Wright to
  second to first") is a lost fielder: every fielder-requiring production (groundout, flyout,
  sac fly, error / misplay, double play) surfaces a clarify even when the remaining explicit
  positions would form a complete chain. A masked name qualified by its position ("Wright at
  short", "Jones in center") or outside a fielding slot ("Wright threw him out at first",
  "Garcia grounds to short", "single to Wright") never forces a clarify on its own — this is
  narrower than the suggested "masked-name AND any chain production" rule, which would have
  turned the six `va-roster-*-threw / -at-short / -grounds` rows (all `same_as_base`) into
  clarifies. Rows: `va-collision-dp643-short-name`, `va-roster-dp643-wright-partial-chain`,
  `va-roster-63-wright-partial-chain`.
- **F7. `error_position` is taken from the batter's destination when the fielder word is
  lost.** **FIXED** — the error / misplay position is the earliest explicit fielder mention;
  destinations are excluded (F5 rule); no mention → clarify with no `error_position`. The four
  "not added" canonical candidates now clarify (see *Canonical set expansion*); the DL-151
  tests 1c / 1d / 1e that blessed the E3 / E6 guess now assert the clarify shape. Rows:
  `va-mishear-e3b-turd`, `va-roster-e3b-garcia-no-position`, `va-filler-e3b-first-of-all`
  (now E5, relabelled `same_as_base`), `va-collision-e3b-third-name`,
  `va-numeral-e3b-error-five`, `va-numeral-e3b-error-on-5`.
- **F8. Unassisted groundout scored as 6-3.** **FIXED** — one explicit position plus
  "unassisted" is a complete chain (`3`); the core accepts it and renders catalyst `3`. The
  DL-151 test now asserts `3`.
- **F9. "dropped fly ball in center, runner scored safely" scores a confident F8.** **FIXED** —
  `tryFlyout` declines when a misplay verb is present; the utterance is out-of-grammar (manual
  entry), which is what the `tryMisplay` guard comment always claimed.
- **F10. Grammar gaps that surface safely.** **PARTLY FIXED.** Added where the meaning is
  unambiguous: "fly out", "flied out", "flies out", "flyball", "lined out", "pop out",
  "ground out"/"grounds"/"grounded"/"groundball", "homers"/"homered"/"homerun", "walks",
  "singled"/"singles", "doubled"/"doubles", "tripled"/"triples", "strike-out" (hyphens split
  into words), "sack fly/bunt", "short stop", "centre". **OPEN by design:** "F7"/"E6" notation
  and bare / embedded numerals ("fly out to 8", "6-3 groundout", "error five") stay out of
  grammar or clarify — a number word is too overloaded in play narration (counts, outs, runs,
  innings) to be read as a fielder without guessing.
- **F11. Double-play numerals pass by coincidence.** **FIXED** — no default `643`; fewer than
  two explicit positions → clarify with no chain. `va-numeral-dp643-*` relabelled
  `safe_surface`; the 4-6-3 siblings clarify instead of showing a wrong chain on the card.
- **F12. Bare "sacrifice bunt" renders `SH1-3`** with no fielders in the facts (core default
  rendering). **OPEN** — this default lives in `FactBridge` / the core (`ios/Sources/Core`,
  outside U9's parser-only lane), not in the grammar; the parser emits no fielders for a bare
  sac bunt, so the fix is a core / bridge change. The canonical row `tr-sacbunt` still carries
  no `expect_reisner_catalyst`. Note the same bridge defaults exist for a confirmed clarify
  candidate without a fielder (groundout → 6-3, flyout → 8, sac fly → 9, error → 6, DP →
  6-4-3): after the scorer confirms a fielder-less candidate on the Clarify sheet, the bridge
  fills the conventional chain. That is a human-confirmed play, not a silent one, but the
  sheet should let the scorer set the fielder — UI follow-up, not parser.

### Biasing decision (`dl-bias` / `BiasingDecision`)

- **B0. `dl-bias` rejects a literal `0` or `1` confidence** as "must be a number or null"
  (Swift `NSNumber is Bool` bridging for 0/1 in `decodeRow`). `biased_confidence: 1.0`,
  `1`, and `0.0` all error; `0.5` works. The corpus uses `0.01` for the guard-3 zero row. The
  harness bug is in `ios/Sources/DLBias/main.swift`, not the policy.
- **B1. The policy overrides on insertion of contextual play/position phrases.** Under the
  guard order, an insertion only has to be contextual (guard 5) and has no replaced token
  (guard 6), so "ground ball to short, threw him out at first" → "…, double play" (distance
  0.18) and "fly ball to Wright, caught" → "fly ball to Wright center field, caught" (0.29)
  both override. The R20 cap keeps the result in Clarify today (confidence 69), so it is not a
  silent wrong play under the default policy, but the biased engine is adding a play, not
  correcting a word. Rows `bp-adversarial-insert-play-word` and
  `bp-adversarial-insert-position-phrase` carry the semantic expectation (`keep_base`) and go
  red. `bp-adversarial-insert-position` ("in center") keeps the base only because "in" is not in
  the set. Decision needed: refuse insertions (or insertions of play-type / position tokens), or
  document contextual insertion as intended and flip these two rows.
- **B2. Policy limits worth knowing (not bugs):** a three-token utterance can never be corrected
  (1/3 > 0.30 — `bp-guard6-pitch-to-pitcher`, and why the roster-spelling rows use six-token
  utterances); an OOV word can be "corrected" to the wrong contextual word
  (`bp-agree-oov-to-wrong-position`: "sean" → "second") — the text layer cannot know, R20 is the
  protection.

## What this corpus does NOT cover

- Real ASR behaviour (tiers 2 and 3). Nothing here measures what a speech engine emits.
- State-dependent scoring: every row is scored in a fresh game (top 1st, bases empty), like
  `transcript-regression`.
- The clarify rate at confidence 60 is reported by U5, not authored here.
- Variants that merely drop an optional field (e.g. "double to lift" → a double with no fielder)
  were not authored: under the facts-identical rule they would read as confident-wrong although
  the play is correct and merely less specific. Flag for U5 if that class matters.
