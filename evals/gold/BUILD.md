# Gold Dataset Build Runbook

**Authority**: `evals/INTERFACE.md` §2 · `specs/001-voice-scorebook-core/research.md` D6  
**Status**: Runbook only — no gold game yet (H3 handoff incomplete; accuracy runner advisory)  
**Target**: `evals/gold/<YEAR>-<HOME>-<AWAY>-<DATE>/` (one fully coupled gold game)

---

## What "Gold" Means

A gold game is a **fully coupled triple** (per INTERFACE.md §2):

1. **Audio** — narrated play-by-play of a real game (spoken exactly as a scorer would narrate)
2. **Hand-scored Reisner** — produced **independently** by a trained scorer
3. **cwevent-clean Retrosheet event file** — independently hand-produced, verified via the pinned gate

When all three are present and `meta.json.h3_ready == true`, the accuracy runner measures **field accuracy** (SC-001 ≥90%, SC-002 ≥85%). Until then, all metrics are self-consistency advisory.

> **Honesty caveat (INTERFACE.md §3.4):** Published Retrosheet .EVN files are regression fixtures only — they have no audio source and represent professional play, not the amateur/serious-scorer beachhead. They are NOT gold games.

---

## Step-by-Step Build Recipe

### Step 1 — Choose a game

Pick an MLB game from the Retrosheet database that:
- Has a published `.EVN` file at retrosheet.org (free download, all seasons)
- Is a full 9-inning game (no rainout / suspended game complexity)
- Has a manageable number of plays (~50–80 at-bats, ≤150 total events)
- Is from a season you can easily narrate from a box score

**Recommended**: any complete 9-inning game from the 1980s–2000s.  
**Example**: 1986 World Series Game 6 — NYN 6, BOS 5 (retrosheet ID `NYN198610250`)

Download the season event file from https://www.retrosheet.org/game.htm and extract the game.

### Step 2 — Set up the directory

```bash
# Replace variables with your game
YEAR=1986
HOME=NYN
AWAY=BOS
DATE=19861025
GAMEID=NYN198610250

GOLD_DIR="evals/gold/${YEAR}-${HOME}-${AWAY}-${DATE}"
mkdir -p "${GOLD_DIR}/audio"
mkdir -p "${GOLD_DIR}/reisner"
mkdir -p "${GOLD_DIR}/retrosheet"
```

### Step 3 — Capture narrated audio

**Option A (preferred):** Record yourself (or a scorer) narrating each play aloud, exactly as you would call it at the ballpark. Use a clear voice: "Ground ball to short, shortstop to first, out." Each recording should be ~2–8 seconds per play.

```bash
# Save as: evals/gold/<game>/audio/narration.m4a
# OR: one file per play: audio/play-001.m4a, audio/play-002.m4a, ...
```

**Option B:** Write a verbatim transcript if audio is unavailable:
```bash
# Save as: evals/gold/<game>/audio/narration.txt
# One play per line: "Inning 1 top, play 1: Ground ball to short, shortstop to first, out."
```

### Step 4 — Hand-score the game in Reisner notation

Using the published Retrosheet .EVN as the source of truth for play facts, score the game in Reisner notation. Produce `reisner/scorecard.json` per the schema in `evals/INTERFACE.md` §2.2.

```bash
# Validate against the schema:
python3 -c "import json; data=json.load(open('${GOLD_DIR}/reisner/scorecard.json')); print('OK:', data['game_id'])"
```

### Step 5 — Independently produce the Retrosheet event file

**CRITICAL: This must be produced INDEPENDENTLY from Step 4.** Use either:
- A different scorer on the same day
- The same scorer on a different day (minimum 24 hours later)

This independence is what makes the gold game measure field accuracy, not self-consistency (INTERFACE.md §2.3 / §3.4).

Start from a blank template (do NOT copy the published Retrosheet file):

```
id,<GAMEID>
version,2
com,"Data based on the Retrosheet event-file format (retrosheet.org). Use of Retrosheet data is subject to the terms at retrosheet.org/notice.txt."
info,visteam,<AWAY>
info,hometeam,<HOME>
info,date,<YYYY/MM/DD>
...
```

Produce each `play` record from the game facts independently.

### Step 6 — Verify with pinned cwevent

```bash
# Verify the independently produced file passes the gate
bash evals/runners/retrosheet-gate.sh "${GOLD_DIR}/retrosheet" ${YEAR}

# Exit 0 = all layers passed; exit 1 = fix the EVN file and retry
```

The `TEAM<YEAR>` file must be present in `${GOLD_DIR}/retrosheet/` — one line per team:
```
NYN,NL,New York,Mets
BOS,AL,Boston,Red Sox
```

### Step 7 — Cross-diff against the published Retrosheet file

```bash
# Copy the published Retrosheet .EVN into the gold dir
cp /path/to/downloaded/${GAMEID}.EVN "${GOLD_DIR}/retrosheet/published.EVN"

# Generate cwevent output for both files
cwevent -n -f 0-96 -y ${YEAR} -q "${GOLD_DIR}/retrosheet/${GAMEID}.EVN" > /tmp/our_output.csv
cwevent -n -f 0-96 -y ${YEAR} -q "${GOLD_DIR}/retrosheet/published.EVN" > /tmp/pub_output.csv

# Diff — a clean diff means our file matches the published ground truth
diff /tmp/our_output.csv /tmp/pub_output.csv
```

A clean diff is the **free third independent check** — it proves our hand-produced file matches what Retrosheet's professional scorers produced. Document any discrepancies in `meta.json.notes`.

### Step 8 — Package into meta.json

```json
{
  "game_id": "NYN198610250",
  "date": "1986-10-25",
  "home_team": "NYN",
  "away_team": "BOS",
  "scorers": {
    "reisner": "<name of scorer who produced scorecard.json>",
    "retrosheet": "<name of scorer who independently produced the .EVN>"
  },
  "cwevent_verdict": {
    "passed": true,
    "cwevent_version": "0.10.0",
    "run_at": "<ISO-8601 timestamp>",
    "stderr_clean": true,
    "event_rows_emitted": <count>
  },
  "published_retrosheet_evn": "retrosheet/published.EVN",
  "cross_diff_clean": true,
  "h3_ready": true,
  "notes": ""
}
```

Set `h3_ready: true` ONLY when:
- `cwevent_verdict.passed == true`
- `scorers.reisner != scorers.retrosheet` (OR documented independent production)
- `reisner/scorecard.json` and `retrosheet/<GAMEID>.EVN` are both present
- `audio/narration.m4a` or `audio/narration.txt` is present

### Step 9 — Run accuracy.sh

```bash
bash evals/runners/accuracy.sh "${GOLD_DIR}"
```

When `h3_ready: true`, the runner will output `FIELD ACCURACY MODE` and SC-001/SC-002 results become hard-fail CI gates.

---

## Directory Layout

```
evals/gold/<YEAR>-<HOME>-<AWAY>-<DATE>/
  audio/
    narration.m4a          # preferred: audio recording
    # OR narration.txt     # fallback: verbatim transcript
  reisner/
    scorecard.json         # hand-scored Reisner notation (INTERFACE.md §2.2)
    scorecard.pdf          # optional: scan of paper scorecard
  retrosheet/
    <GAMEID>.EVN           # independently produced Retrosheet event file
    TEAM<YEAR>             # mandatory (cwevent exits 1 without it)
    published.EVN          # Retrosheet's published .EVN for cross-diff (optional but strongly recommended)
  meta.json                # game metadata (INTERFACE.md §2.3)
```

---

## SABR / Retrosheet Outreach (C5 — non-code, tracked)

**T066 / T067 — tracked as non-code tasks for this PR:**

### Retrosheet
Contact: **Tom Thress** (Retrosheet founder / lead)  
Organization: retrosheet.org  
Purpose: Relationship-building + permission to use Retrosheet data as the published .EVN cross-diff source  
Note: Retrosheet data is already free for commercial use with attribution (see `NOTICE`); outreach is for the cooperative relationship and potential official scorer contacts

### SABR Official Scoring Research Committee
Contact: sabrgroups.org/g/official-scoring  
Purpose: Recruit 2–3 active college/HS/MiLB official scorers to co-produce **amateur** gold games  
Note: The beachhead is amateur/serious-scorer play, not MLB — this is why SABR outreach matters more than Retrosheet for SC-010

### Demo Cohort (~20 serious scorers) — T067
Purpose: ADR-0006 first-slice demo artifact requires ~20 real users  
Risk: Distribution/GTM risk — if cohort cannot be assembled, log against the ADR-0006 distribution tripwire (review 2026-07-31)

---

## Attribution

All Retrosheet event files (fixtures, gold games, exports) must include the attribution string per `specs/001-voice-scorebook-core/contracts/retrosheet-reduced-grammar.md` §7:

```
com,"Data based on the Retrosheet event-file format (retrosheet.org). Use of Retrosheet data is subject to the terms at retrosheet.org/notice.txt."
```

The full attribution is in the repo `NOTICE` file.
