# Human Handoff Protocol — Gold Game LAN2024091601

**Game**: Los Angeles Dodgers vs New York Mets  
**Date**: 2024-09-16  
**Retrosheet game ID**: LAN2024091601  
**Directory**: `evals/gold/2024-LAN-NYN-20240916/`  
**Authority**: `evals/INTERFACE.md` §2 · `evals/gold/BUILD.md` · `specs/001-voice-scorebook-core/research.md` D6

---

## Why this game

This package is the **primary gold-game candidate** (T064/T065, Story C4 #105). It was selected because:

1. **Complete, standard 9-inning game** — no extra innings, no suspended game complexity.  
2. **2024 season** — aligns with the existing `retrosheet-fixtures/2024` corpus; same `TEAM2024` format exercised end-to-end.  
3. **Retrosheet EVN is publicly available** — download from [retrosheet.org/game.htm](https://www.retrosheet.org/game.htm) → 2024 season → LAN home games.  
4. **Grammar coverage** — the harness EVN exercises all reduced-grammar constructs: hits `S/D/T/HR`, strikeout, walk, HP, error `E$`, stolen base `SB`, caught stealing `CS`, advance strings, modifiers `/F /L`, multi-fielder chains. A human scoring this game from audio will exercise every play type the eval suite targets.  
5. **Narration-friendly** — 2024 Mets/Dodgers is well-documented in box scores and broadcast records; easy to narrate from public sources.
6. **Cross-diff available** — once the published Retrosheet `.EVN` is downloaded, our independently-produced EVN can be diffed against it as a free third independent check.

**Status of the harness EVN** (`retrosheet/LAN2024091601.EVN`): this is a grammar-correct scaffold built to exercise all reduced-grammar constructs. It has passed `cwevent` Layer 2+3 (61 event rows, zero stderr). It is **not** the independently-produced EVN — the human must produce that in step H-3.

---

## What "independent" means (why it matters)

`meta.json.h3_ready` becomes `true` — and `accuracy.sh` switches from advisory to hard-fail CI — **only** when the Reisner hand-scoring and the Retrosheet EVN are produced **independently**:

- **Independent** = different scorer, OR the same scorer on a different day (minimum 24 hours apart).  
- The scorer in step H-2 (Reisner) must not have produced the EVN in step H-3 on the same sitting.  
- This independence is what makes SC-001/SC-002 measure **field accuracy** (agreement with a trained human) rather than **self-consistency** (the system scoring its own output).

An accuracy number without independence is meaningless for the ADR-0006 demand-validation tripwire.

---

## Human steps

### H-1 — Capture / narrate the audio

**Owner**: human scorer A (or the project lead)  
**Output**: `audio/narration.m4a` OR `audio/narration.txt`  
**Estimated time**: 45–90 minutes

1. Obtain the play-by-play for LAN2024091601:  
   - Baseball Reference: https://www.baseball-reference.com/boxes/LAN/LAN202409160.shtml  
   - Or use the harness EVN (`retrosheet/LAN2024091601.EVN`) as a cheat sheet for play sequence.

2. Narrate each plate appearance aloud, one at a time, exactly as you would at the ballpark:  
   - "Ground ball to shortstop, threw him out at first."  
   - "Line drive single to left."  
   - "Fly ball to center, caught for the out."  
   - For judgment plays, narrate the ambiguity: "Ground ball to second, he bobbled it — batter reached first, could be a hit or an error."

3. Record as a single continuous file OR one file per play (see `audio/NARRATION_PLACEHOLDER.txt` for full format spec).

4. Save as `audio/narration.m4a` (preferred) or `audio/narration.txt`.  
   Delete `audio/NARRATION_PLACEHOLDER.txt` once the narration file is in place.

**Gate**: `meta.json.h3_ready` requires this file present before it can be set `true`.

---

### H-2 — Hand-score the game in Reisner notation

**Owner**: human scorer A (or B, as long as independent from H-3)  
**Output**: `reisner/scorecard.json`  
**Estimated time**: 2–4 hours  
**Prerequisite**: ideally done **after** H-1 narration is captured; score FROM the audio

1. Use the Reisner scoring schema at `evals/INTERFACE.md` §2.2.  
   The `reisner/scorecard.json` file has the required structure; fill in the `innings` array.

2. Score every plate appearance in order (9 innings × top + bottom), producing:  
   - `situation` (pre-play state)  
   - `reisner_cell` (situation_symbol, catalyst_symbol, runner_fate, pitch_marks)  
   - `play_type_label` (your ground-truth call)  
   - `judgment_resolved_as` (non-null if you had to make a judgment call)

3. For judgment plays — plays where you, as scorer, must decide between outcomes:  
   - **HitVsError**: ball touched by a fielder but batter reached safely — your call: Hit or Error?  
   - **EarnedVsUnearned**: run scored in an inning with a prior error — deferred to `PENDING` in v1, but note it  
   - **ContestedCredit**: RBI vs. not (e.g., runner scored on a fielder's choice)  
   - **AmbiguousAdvance**: runner advancement on a play with multiple fielding touches  
   Record your actual decision in `judgment_resolved_as`.

4. Validate the file parses:
   ```bash
   python3 -c "import json; d=json.load(open('reisner/scorecard.json')); print('OK:', d['game_id'], '| innings:', len(d.get('innings', [])))"
   ```

5. Update `meta.json.scorers.reisner` with your name or handle.

**Independence note**: if you are also doing H-3, wait at least 24 hours between H-2 and H-3.

---

### H-3 — Independently produce the Retrosheet event file

**Owner**: human scorer B (different from A, OR scorer A at least 24 hours after H-2)  
**Output**: `retrosheet/LAN2024091601.EVN` (replaces the harness scaffold)  
**Estimated time**: 2–4 hours  
**Prerequisite**: access to the published Retrosheet 2024 season data

**CRITICAL**: Start from the blank template below. Do NOT copy the harness scaffold — produce from your own scoring of the play-by-play.

```
id,LAN2024091601
version,2
com,"Data based on the Retrosheet event-file format (retrosheet.org). Use of Retrosheet data is subject to the terms at retrosheet.org/notice.txt."
info,visteam,NYN
info,hometeam,LAN
info,date,2024/09/16
info,number,1
info,daynight,N
info,usedh,false
info,innings,9
start,<player-id>,<name>,<side>,<batting-order>,<fielding-position>
...
play,<inning>,<side>,<batter-id>,<count>,<pitches>,<event-string>
...
data,er,<pitcher-id>,<earned-runs>
```

See `specs/001-voice-scorebook-core/contracts/retrosheet-reduced-grammar.md` for the full event-string grammar.  
See `evals/gold/BUILD.md` §Step 5 for a worked example.

After producing the EVN:

1. Verify with the pinned gate:
   ```bash
   bash evals/runners/retrosheet-gate.sh evals/gold/2024-LAN-NYN-20240916/retrosheet 2024
   ```
   Gate must exit 0 with zero stderr warnings.

2. Regenerate `expected.csv` (Layer 3 golden diff) from the new file:
   ```bash
   cd evals/gold/2024-LAN-NYN-20240916/retrosheet
   cwevent -n -f 0-96 -y 2024 -q LAN2024091601.EVN > expected.csv
   ```

3. Update `meta.json`:
   - `scorers.retrosheet` = your name/handle
   - `cwevent_verdict.passed = true`
   - `cwevent_verdict.run_at` = ISO-8601 timestamp of the gate run
   - `cwevent_verdict.stderr_clean = true`
   - `cwevent_verdict.event_rows_emitted` = number from gate output

---

### H-4 — Cross-diff against the published Retrosheet file

**Owner**: either scorer  
**Output**: `meta.json.cross_diff_clean` updated; `retrosheet/published.EVN` added  
**Estimated time**: 30 minutes

1. Download the published Retrosheet `.EVN` for 2024:
   - Go to https://www.retrosheet.org/game.htm
   - Download the 2024 NL season event files
   - Extract the LAN2024091601 game record and save as `retrosheet/published.EVN`

2. Run the cross-diff:
   ```bash
   cd evals/gold/2024-LAN-NYN-20240916/retrosheet
   cwevent -n -f 0-96 -y 2024 -q LAN2024091601.EVN > /tmp/ours.csv
   cwevent -n -f 0-96 -y 2024 -q published.EVN > /tmp/pub.csv
   diff /tmp/ours.csv /tmp/pub.csv
   ```

3. A clean diff = free third independent check. Document any discrepancies in `meta.json.notes`.
4. Set `meta.json.cross_diff_clean = true` (or `false` with notes on discrepancies).

---

### H-5 — Set h3_ready and run accuracy.sh

**Owner**: project lead  
**Prerequisite**: H-1 through H-4 all complete

1. Verify all checklist items:
   - [ ] `audio/narration.m4a` or `audio/narration.txt` present
   - [ ] `reisner/scorecard.json` present with all innings scored
   - [ ] `retrosheet/LAN2024091601.EVN` is the HUMAN-produced file (not the scaffold)
   - [ ] `retrosheet-gate.sh` exits 0 for the retrosheet directory
   - [ ] `meta.json.scorers.reisner != meta.json.scorers.retrosheet` (or independence documented in notes)
   - [ ] `meta.json.cwevent_verdict.passed == true`

2. Set `meta.json.h3_ready = true`.

3. Run the accuracy runner (Squad A T042, not yet present; when present):
   ```bash
   bash evals/runners/accuracy.sh evals/gold/2024-LAN-NYN-20240916
   ```
   With `h3_ready: true`, this outputs `FIELD ACCURACY MODE` and SC-001/SC-002 are CI hard-fails.

---

## Summary checklist

| Step | Owner | Output | Status |
|------|-------|--------|--------|
| H-1 | Human scorer A | `audio/narration.m4a` or `audio/narration.txt` | PENDING |
| H-2 | Human scorer A (independent from H-3) | `reisner/scorecard.json` (fully scored) | PENDING |
| H-3 | Human scorer B (or A + 24h) | `retrosheet/LAN2024091601.EVN` (human-produced, NOT scaffold) | PENDING |
| H-4 | Either scorer | `retrosheet/published.EVN` + `meta.json.cross_diff_clean` | PENDING |
| H-5 | Project lead | `meta.json.h3_ready = true` | PENDING |

Once H-5 is complete, the accuracy runner (Squad A T042) runs in **FIELD ACCURACY MODE** and SC-001/SC-002 become CI hard-fails. Until then, all accuracy metrics are `SELF-CONSISTENCY (advisory)`.
