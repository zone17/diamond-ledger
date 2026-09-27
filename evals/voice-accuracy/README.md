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

Rows deliberately NOT added because today's output is wrong (see findings F8–F10):
"ground ball, first baseman made the play unassisted", "dropped fly ball in center, runner scored
safely", "bobbled the grounder, safe at first", "dropped it, batter reaches first".

## Row counts

`variants.jsonl` (228 rows, 21 distinct bases):

| kind | same_as_base | safe_surface | text_layer_undetectable | total |
|------|---:|---:|---:|---:|
| mishear | 29 | 32 | 12 | 73 |
| numeral | 7 | 25 | 0 | 32 |
| filler | 52 | 1 | 0 | 53 |
| roster | 39 | 9 | 0 | 48 |
| roster_collision | 8 | 14 | 0 | 22 |
| **total** | 135 | 81 | 12 | 228 |

`biasing-pairs.jsonl`: 39 rows, 27 `keep_base`, 12 `override`.

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

The 25 confident-wrong rows are the rows whose `expect` the pipeline does not meet today. They
are the findings below, not authoring errors: each was checked against play semantics and the
expectation is what is correct. **The gate is expected to be red on this corpus until the
findings are fixed or explicitly waived by the reviewer.**

`dl-bias`: 37 of 39 pairs match; the 2 mismatches are finding B1 (both `bp-adversarial-insert-*`
rows override where a correct policy keeps the base).

## Pipeline findings

Everything observed today that is wrong or that hides a defect. Row ids are the evidence.

### Text→score leg (`GrammarParser` / core)

- **F1. Groundout default `63` fires when only one position word survives.** A 4-3 or 5-3
  whose "second"/"third" or "first" is mis-heard is scored as a confident 6-3.
  Rows: `va-mishear-43-sickened`, `va-mishear-43-thirst`, `va-mishear-53-thud`,
  `va-mishear-53-fist`, `va-numeral-43-ground-four-three`, `va-numeral-43-groundout-digits`,
  `va-numeral-43-ground-4-to-3`, `va-numeral-53-ground-five-three`. The same default makes
  `va-mishear-63-sean/shore/firth`, `va-numeral-63-ground-six-three`,
  `va-numeral-63-groundout-digits` pass *by coincidence* (the base is 6-3).
- **F2. Flyout default `8` fires when the outfield word is mis-heard.** F7/F9 become F8.
  Rows: `va-mishear-f7-loft`, `va-mishear-f7-lift`, `va-mishear-f9-write`, `va-mishear-f9-rite`,
  `va-numeral-f7-seven`, `va-numeral-f7-fly-ball-7`. `va-mishear-f8-centre` and
  `va-numeral-f8-eight` pass by coincidence.
- **F3. Sac-fly default `9`.** "sacrifice fly to centre" / "to enter" become SF9.
  Rows: `va-mishear-sf-centre`, `va-mishear-sf-enter`.
- **F4. Strikeout defaults to swinging.** "strikeout cooking/booking" (a mis-heard "looking")
  is scored as a swinging K. Rows: `va-mishear-kl-cooking`, `va-mishear-kl-booking`.
  Lower severity (the Reisner catalyst is `K` either way) but the fact differs.
- **F5. Substring keyword matching absorbs filler words.** "right," / "alright," prepends
  fielder 9 (`963`); "first of all," reverses the chain (`36`). Rows: `va-filler-63-right`,
  `va-filler-63-alright`, `va-filler-63-first-of-all`, `va-filler-43-right`. Note "alright"
  matches because `positionKeywords` are substring-matched, not whole-word.
- **F6. Roster masking with a partial chain scores a wrong explicit chain (DL-157 gap).** The
  clarify invariant fires only when a production *defaulted*. When a masked name removes one
  fielder but two position words remain, the production builds a wrong explicit chain and
  returns it silently: "double play short to second to first" with roster `["Short"]` → a
  deterministic 4-3 double play (the 6-4-3 contested-credit judgment disappears);
  "double play Wright to second to first" → `43`; "ground ball, Wright to second to first" → a
  4-3 groundout. Rows: `va-collision-dp643-short-name`, `va-roster-dp643-wright-partial-chain`,
  `va-roster-63-wright-partial-chain`. Suggested rule: masked-name AND any fielder-chain
  production → clarify, regardless of default.
- **F7. `error_position` is taken from the batter's destination when the fielder word is
  lost.** "error on the turd baseman, batter reached first" → E3 (from "reached first"), as
  does "error on Garcia, batter reached first" (roster), "first of all, error on the third
  baseman …", and roster `["Third"]`. Surfaces as Card B of the right kind (safe miss under the
  comparator), but the card shows the wrong fielder. Rows: `va-mishear-e3b-turd`,
  `va-roster-e3b-garcia-no-position`, `va-filler-e3b-first-of-all`,
  `va-collision-e3b-third-name`, `va-numeral-e3b-error-five`, `va-numeral-e3b-error-on-5`.
  Same root cause in the canonical candidates "bobbled the grounder, safe at first" and
  "dropped it, batter reaches first" (both E3 today) — not added to the canonical set.
- **F8. Unassisted groundout scored as 6-3.** "ground ball, first baseman made the play
  unassisted" → `63`. Not added to the canonical set. (The DL-151 test accepts this as v1
  behaviour; from play semantics it is a silent wrong play.)
- **F9. "dropped fly ball in center, runner scored safely" scores a confident F8.** The
  `tryMisplay` fly-ball guard's comment says the case is left out-of-grammar for manual entry,
  but the transcript falls through to `tryFlyout` and records the batter out. Not added to the
  canonical set.
- **F10. Grammar gaps that surface safely (recorded, not failures):** "flied out to center",
  "flyball to left field", "fly out to 8", "Martinez flies out to center", "strike-out swinging",
  "F7"/"F8"/"E6"/"E5" notation, bare numerals. All out-of-grammar today. `BaseballLexicon` primes
  the biased engine with "fly out"/"flyout" but the grammar only accepts "fly ball"/"flyout".
- **F11. Double-play numerals pass by coincidence:** "six four three double play" and "6-4-3
  double play" match the base only because the DP default is `643`; the 4-6-3 siblings
  (`va-numeral-dp463-*`) surface as the same judgment kind with the wrong chain on the card.
- **F12. Bare "sacrifice bunt" renders `SH1-3`** with no fielders in the facts (core default
  rendering). The canonical row `tr-sacbunt` therefore carries no `expect_reisner_catalyst`.

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
