# Voice-accuracy baseline — fixture robustness (2026-09-27)

**Label:** FIXTURE ROBUSTNESS (advisory — not field accuracy). Every number below measures the deterministic transcript→score pipeline (`GrammarParser` → `FactBridge` → Rust core via `dl-score`) on frozen text fixtures and hypothesis pairs. No audio, no ASR, no field conditions. It says nothing about field accuracy (SC-001/SC-002), which needs the human-scored gold game (`evals/gold/`, `h3_ready`).

| | |
|---|---|
| Commit measured | branch `feat/ios/DL-157-voice-accuracy-harness`, parser at U9 (post-416f3f2 working tree; frozen in the U9 commit) |
| Runner | `evals/runners/voice-accuracy.sh` (`make voice-accuracy-gate`), two identical runs |
| Corpus | 56 canonical rows, 228 variant rows (12 text-layer undetectable), 40 biasing pairs |
| Gate verdict | PASS |
| Tripwire | `tools/tests/voice-accuracy-tripwire.sh` 24/24 (gate demonstrably goes red on a known-bad corpus, a wrong fielder on a judgment base, a silent score at confidence 60, and a non-deterministic run) |

## Hard signal (Article VII / FR-008)

- confident-wrong rows: **0**
- canonical regressions: **0**
- biasing-pair mismatches: **0**
- rows scoring silently at confidence 60: **0** (FR-008 low-confidence route intact)
- advisory expectation mismatches: 4 (keyword-named roster players over-clarify; corpus README finding F13, open, safe direction)
- determinism: identical raw `dl-score`/`dl-bias` output across two runs

## What the harness found before the parser fix (same corpus, parser at commit fc670d5)

The corpus was authored from play semantics, not from the pipeline's output, and the first run was red: **25 confident-wrong variants and 2 pair mismatches**. Root causes, all fixed in this branch (details in `evals/voice-accuracy/README.md`, findings F1–F12, B0–B2):

- Hard-coded default fielders (groundout 6-3, flyout 8, sac fly 9, misplay 6, double play 6-4-3, strikeout swinging) fired whenever the position word was lost or mis-heard, producing a confident wrong play. Rule now: a production that would need a default surfaces clarify with the partial chain it actually heard (never an invented one).
- Substring keyword matching absorbed filler ("alright," → right field; "first of all," → first base). Keywords now match whole tokens, and bare position words count only in a fielding slot (after to/at/by/in/from/into/toward or as the head of an "X to Y" chain), never as a destination.
- Roster masking left a wrong explicit chain when a masked name was one of the fielders. A masked name in a fielding slot now forces clarify for every fielder-requiring production.
- The biasing decision allowed the biased hypothesis to *insert* a play word ("…, double play"). Biasing is now substitution-only (`insertion_or_deletion` guard, ADR-0017).
- `dl-bias` rejected literal `0`/`1` confidences as booleans.

Twenty-one variant labels were corrected during the fix: 15 `same_as_base` → `safe_surface` where the transcript does not state the fielder (the old label was only satisfiable by a guess), 6 `safe_surface` → `same_as_base` where new grammar synonyms (flied out, flyball, centre, strike-out, …) now score the correct play. No canonical row changed; the transcript-score gate stayed green at 56/56 throughout.

## Advisory metrics

| kind | same as base | safe miss | undetectable |
|---|---|---|---|
| filler | 53 | 0 | 0 |
| mishear | 25 | 36 (18 clarify, 18 out-of-grammar) | 12 |
| numeral | 0 | 32 (18 clarify, 14 out-of-grammar) | 0 |
| roster | 40 | 8 (clarify) | 0 |
| roster_collision | 8 | 14 (clarify) | 0 |

- Clarify rate at confidence 100: **23.8%** of parseable rows (59/248). Before the parser fix it was 7.4%; the difference is the former silent guesses now surfacing as a tap.
- Clarify rate at the production default confidence 60: **100.0%** (248/248). This is today's on-device reality: iOS 26 reports no scalar confidence, the adapter substitutes 60, the parser threshold is 70, so every parseable play goes through the Clarify sheet. Hands-free scoring is closed (Key Decision 4 / R20) and SC-005's one-tap bar cannot be met until that changes on device evidence after T046.
- Numerals are deliberately not treated as positions (too overloaded in narration: counts, outs, runs), so every spoken-number variant surfaces rather than scores.
- Text-layer undetectable rows (a mis-hearing that is itself a valid different play, e.g. "to second" for "to short"): 12, of which 10 score the other play confidently. No text-only harness can catch these; they are the case for the ASR leg (T076) and for the roster/lexicon biasing to keep those words right at the source.
- Biasing pairs: 12 override, 28 keep_base, all as expected.
- Independent corpus review (Article XX, 2026-09-27): 224/228 variant and 39/39 pair expectations confirmed; 4 collision rows relabeled to play semantics.
- Transcript WER: not measured (no ASR leg in this harness).

## Open items this baseline does not cover

- On-device behavior: push-to-talk has no microphone capture (T046); the Apple engine surfaces `audioTooShort` on device today.
- Whether on-device `SFSpeechRecognizer` reports a usable per-segment confidence (plan Assumption A7). The first device run must log the biased-leg confidence distribution here.
- Field accuracy (SC-001/SC-002): human gold game.
- Synthetic-speech leg (plan U8): not started; deferred to a follow-up.

## Code-review fixes folded in before merge

The multi-lens review (run 20260927-013633-0198784d) found and reproduced three gate holes, all closed here and each pinned by a tripwire fixture: a wrong fielder on a judgment base counted as a safe miss; the confidence-60 leg had no hard signal; the parser read "runner scored from third" as a fielder. Also fixed: "left center" gap words, hyphenated roster names, roster tokens that were grammar words, the unlabeled staged-corpus line, padded transcripts, and the dl-bias 0/1 boundary now pinned by two pairs.
