# Retrosheet Reduced Grammar — v1 FROZEN Contract

**Feature:** `001-voice-scorebook-core`
**Status:** FROZEN — v1 contract (do not change without a revision note and new version tag)
**Version:** v1.1 (2026-06-01 — see §8 change log)
**Authority:** [`spec.md`](../spec.md) (FR-016 / FR-017) · [`research.md`](../research.md) (D4)
**Reference:** [retrosheet.org/eventfile.htm](https://www.retrosheet.org/eventfile.htm)
**Acceptance gate:** Chadwick `cwevent` v0.10.0 (pinned, SHA256-pinned — see plan.md D4)

This document is the **shared contract** between:
- **Squad A's emitter** (T029 — `core/src/retrosheet/`) which produces `.EVN` / `.EVA` files, and
- **Squad C's fixtures** (T061 — `evals/retrosheet-fixtures/`) which build the `cwevent` regression corpus.

Both squads target exactly the record types, field grammar, and event-string subset defined here.
Anything outside this contract is **flag-for-manual** (see Section 5). Neither squad may silently
fabricate or emit a construct not listed in this document.

---

## 1. Record Types (all 8 mandatory / supported in v1)

The v1 emitter MUST produce exactly these eight record types and MUST NOT produce any other top-level
record type (e.g., `badj`, `ladj`, `presadj` are out of scope and must not be emitted).

| Record type | Format | v1 requirement |
|-------------|--------|---------------|
| `id` | `id,<game-id>` | Required; first record of every game file. Game ID format: `<hometeam><YYYYMMDD><seq>` (e.g. `NYA2024091401`). |
| `version` | `version,<n>` | Required; immediately follows `id`; always `version,2` for standard Retrosheet event files. |
| `info` | `info,<type>,<value>` | Required; one line per field. **v1 MUST include at minimum:** `visteam`, `hometeam`, `date` (YYYY-MM-DD). Optional but recommended: `number` (game number in doubleheader, default 0), `starttime`, `daynight`, `usedh`, `innings`. |
| `start` | `start,<player-id>,<player-name>,<side>,<batting-order>,<fielding-position>` | Required for every starting player. `side`: 0 = visitor, 1 = home. `batting-order`: 1–9. `fielding-position`: 1–9 (P/C/1B…RF), 10 = DH (see note below). |
| `play` | `play,<inning>,<side>,<batter>,<count>,<pitches>,<event>` | One line per plate appearance outcome. The load-bearing record — see Section 2 for full field grammar. |
| `sub` | `sub,<player-id>,<player-name>,<side>,<batting-order>,<fielding-position>` | One line per substitution. Same field schema as `start`. |
| `com` | `com,<free-text>` | Commentary / annotation. Free text; `cwevent` parses but ignores. Use for flags-for-manual notes (Section 5). |
| `data` | `data,er,<player-id>,<earned-runs>` | Earned-run data. In v1 all entries are `data,er,<id>,0` or omitted when earned/unearned is PENDING (FR-010a / FR-017); emit a `com` record documenting the PENDING status rather than fabricating a value. |

**DH position note:** Retrosheet encodes the DH as fielding-position `10` in `start`/`sub` records.
The Reisner system uses position number `0` for the DH (D5 / FR-005). The emitter MUST map Reisner `0`
→ Retrosheet `10` at the boundary; the inverse mapping applies in any import path.

---

## 2. The `play` Record Field Grammar

```
play,<inning>,<side>,<batter-id>,<count>,<pitches>,<event-string>
```

| Field | Type | Values / format |
|-------|------|-----------------|
| `inning` | integer | 1–19 (extra innings allowed; top = side 0, bottom = side 1) |
| `side` | integer | 0 = visiting team batting, 1 = home team batting |
| `batter-id` | string | Retrosheet player ID (8 chars: `<last4><first2><seq2>`, e.g. `ruthb101`); use placeholder `unknXX01` when lineup not provided |
| `count` | string | Two digits: balls then strikes, e.g. `32`, `00`, `23`; use `??` when count not tracked |
| `pitches` | string | Pitch-sequence string (see pitch codes below); use empty string `""` or `?` when not tracked |
| `event-string` | string | The play event — see Section 3 for the reduced v1 grammar |

### 2a. Pitch sequence codes (v1 subset)

Only the following pitch codes are emitted by the v1 core; others are out of scope.

| Code | Meaning |
|------|---------|
| `B` | Ball |
| `C` | Called strike |
| `S` | Swinging strike |
| `F` | Foul |
| `X` | Ball put in play |
| `I` | Intentional ball (part of IBB sequence) |
| `+` | Preceding pitch with pickoff attempt |
| `.` | Play not involving the batter (e.g. SB, CS, PO between pitches) |
| `*` | Ball blocked by catcher |
| `H` | Hit batter (on pitch) |
| `K` | Strike (unknown type — use only when type not determinable) |

When pitch sequence is not tracked (e.g. the scorekeeper did not record it), emit an empty string `""`.

---

## 3. Reduced Event-String Grammar (v1 scope)

This is the **complete** set of event-string constructs the v1 emitter MUST handle. The notation below
uses:
- `$` = a single fielding position digit (1–9)
- `%` = a base letter: `1` (first), `2` (second), `3` (third), `H` (home)
- `(R)` = a runner identifier: `B` (batter), `1`, `2`, `3`

### 3a. Basic hit types

| Event string | Meaning |
|-------------|---------|
| `S$` | Single; `$` = fielder who fielded it (e.g. `S7` = single to left) |
| `S` | Single; fielder unknown or not tracked |
| `D$` | Double; `$` = fielder (e.g. `D8` = double to center) |
| `D` | Double; fielder unknown |
| `T$` | Triple; `$` = fielder (e.g. `T9` = triple to right) |
| `T` | Triple; fielder unknown |
| `H` | Home run (inside the park or over the fence — see modifier `/F` below for distinction) |
| `HR` | Home run (alternate; both `H` and `HR` are accepted by `cwevent`; emit `HR` for clarity) |

**Note:** the fielder digit on hits is the primary fielder, not the fielding sequence. A hit that
glances off a fielder still records the fielder's position.

### 3b. Strikeout

| Event string | Meaning |
|-------------|---------|
| `K` | Strikeout (called or swinging; distinction is in the pitch sequence) |
| `K+WP` | Strikeout; batter reaches on wild pitch |
| `K+PB` | Strikeout; batter reaches on passed ball |

### 3c. Walks and hit-by-pitch

| Event string | Meaning |
|-------------|---------|
| `W` | Walk (base on balls) |
| `IW` | Intentional walk |
| `HP` | Hit by pitch |

### 3d. Fielded outs — single fielder and clean chains

The v1 emitter supports **single-fielder outs** and a defined set of **clean double-play chains**.
Multi-fielder sequences not in this list are flag-for-manual (Section 5).

**Single-fielder putout:**
```
$           (e.g. "8" = flyout to center fielder)
```

**Common two-fielder putout sequences (clean):**
```
$-$         (e.g. "6-3" = shortstop to first base)
```

**Common three-fielder putout sequence (clean):**
```
$-$-$       (e.g. "6-4-3" = shortstop to second to first, double play)
```

**Specifically named clean sequences in v1 scope** (both squads must include these as fixture cases):

| Event string | Play |
|-------------|------|
| `8` | Flyout to center field |
| `6-3` | Ground ball, shortstop to first |
| `4-3` | Ground ball, second base to first |
| `5-3` | Ground ball, third base to first |
| `1-3` | Ground ball, pitcher to first |
| `3` | Groundout, first baseman unassisted |
| `2-3` | Catcher to first (e.g. on a dropped third strike) |
| `63` | Shortstop to first (alternate no-hyphen notation; `cwevent` accepts both; emit hyphenated) |
| `643` | 6-4-3 double play (alternate no-hyphen; emit hyphenated `6-4-3`) |
| `6-4-3` | Double play, shortstop to second to first |
| `4-6-3` | Double play, second to shortstop to first |
| `5-4-3` | Double play, third to second to first |
| `3-6` | First baseman to shortstop |

**Canonical form:** the v1 emitter MUST emit **hyphenated** sequences (`6-3`, `6-4-3`) even though
`cwevent` accepts both forms. The non-hyphenated form (`63`, `643`) is accepted by the parser and
MAY appear in fixtures for conformance testing, but the emitter always outputs the hyphenated form.

### 3e. Errors

| Event string | Meaning |
|-------------|---------|
| `E$` | Error on fielder `$`; batter reaches base (e.g. `E6` = error by shortstop) |

**Note on advances:** when a runner takes extra bases on an error, the error is noted in the advance
section — see Section 3g. The main event string records only the initial reaching event.

### 3f. Stolen bases, caught stealing, and defensive indifference

| Event string | Meaning |
|-------------|---------|
| `SB%` | Stolen base; `%` = base reached (e.g. `SB2` = steal of second, `SB3` = steal of third, `SBH` = steal of home) |
| `CS%($)` | Caught stealing; `%` = base attempted; `$` = fielder recording putout (e.g. `CS2(26)` = caught at second, catcher to shortstop). In v1, `$` is a **single fielder digit** when the putout is unambiguous. Multi-fielder CS is flag-for-manual. |
| `DI` | Defensive indifference (no attempt to retire runner advancing) |

### 3g. Advance strings (base running)

Advances are appended after the main event string, separated by `.` when multiple advances are present:

```
<event>.<advance1>.<advance2>...
```

Each advance has the form:

```
<from><arrow><to>
```

| Element | Values |
|---------|--------|
| `<from>` | `B` (batter), `1`, `2`, `3` (runner's starting base) |
| `<arrow>` | `-` = advance without a putout; `X` = runner retired |
| `<to>` | `1`, `2`, `3`, `H` (destination base or plate) |

**Examples:**
```
S7.1-3          # Single to left; runner on first advances to third
S8.1-H          # Single to center; runner scores from first
HR.1-H.2-H     # Home run; both runners score
W.1-2           # Walk; runner advances from first to second
E6.B-2          # Error by shortstop; batter reaches second on the error
```

**Simple error-in-advance notation (v1 scope):**

When a runner takes an extra base because of an error during an advance:
```
<from>-<to>(E$)     (e.g. "1-H(E9)" = runner scored from first on an error by right fielder)
```

Only single-fielder error-in-advance is in v1 scope. Multi-fielder or throwing-error-reclassification
advances are flag-for-manual (Section 5).

**Out on base (retired):**
```
<from>X<to>($)      (e.g. "1X3(5)" = runner from first out at third, tagged by third baseman)
                    (e.g. "2X3(24)" = runner from second out at third, catcher to second baseman)
```

In v1, the putout fielder sequence in the `(...)` annotation is:
- A **single fielder digit** for a tag play.
- A simple **two-fielder sequence** (e.g. `24`) when the relay is straightforward.
- Multi-out plays involving `(runner)` annotations or ambiguous fielder credit are **flag-for-manual**.

### 3h. Event modifiers

Modifiers are appended to the main event string with `/`:

```
<event>/<modifier>
```

Multiple modifiers: `<event>/<mod1>/<mod2>` (ordered by convention: trajectory before direction).

| Modifier | Meaning | Applies to |
|---------|---------|------------|
| `/G` | Ground ball | Hits, fielded outs |
| `/L` | Line drive | Hits, fielded outs |
| `/F` | Fly ball | Hits, fielded outs, `HR` (distinguishes inside-the-park from over-the-fence) |
| `/P` | Pop-up / infield fly | Fielded outs |
| `/SF` | Sacrifice fly | `S`, `D`, `T` — batter out, runner scores |
| `/SH` | Sacrifice bunt | Bunt where batter is out, runner(s) advance |

**v1 modifier rules:**
- `/SF` and `/SH` affect scoring: `/SF` credits an RBI; `/SH` does not count as an at-bat. The emitter
  MUST apply these when the play facts confirm them (FR-005 catalyst field).
- `/F` on a home run denotes an inside-the-park home run.
- Modifiers are **informational** from `cwevent`'s perspective for the reduced grammar; the acceptance
  gate does not reject absent modifiers, but the emitter SHOULD include them when the play facts
  provide the data.

---

## 4. Complete Event-String BNF (v1 scope)

The following grammar is normative for what the v1 emitter MAY produce. Anything not derivable from
this grammar is either flag-for-manual (Section 5) or an emitter bug.

```
event-string  ::= primary-event advance-section?

primary-event ::= hit | strikeout | walk | ibw | hbp | fielded-out | error | stolen-base
                | caught-stealing | defensive-indifference

hit           ::= ("S" | "D" | "T") position-digit?
                | "HR"
                | "H"

strikeout     ::= "K" strikeout-suffix?
strikeout-suffix ::= "+WP" | "+PB"

walk          ::= "W"
ibw           ::= "IW"
hbp           ::= "HP"

fielded-out   ::= position-digit ("-" position-digit)*

error         ::= "E" position-digit

stolen-base   ::= "SB" base

caught-stealing ::= "CS" base "(" position-digit+ ")"

defensive-indifference ::= "DI"

modifier-section ::= ("/" modifier)*
modifier      ::= "G" | "L" | "F" | "P" | "SF" | "SH"

advance-section ::= "." advance ("." advance)*

advance       ::= from ("-" | "X") to advance-annotation?
advance-annotation ::= "(" advance-annotation-body ")"
advance-annotation-body ::= error-in-advance | putout-fielders
error-in-advance ::= "E" position-digit
putout-fielders  ::= position-digit+   (* one or two digits for v1 *)

from          ::= "B" | "1" | "2" | "3"
to            ::= "1" | "2" | "3" | "H"
base          ::= "2" | "3" | "H"
position-digit ::= "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"
```

**Note:** `primary-event` is followed by the optional modifier-section before the advance-section:
```
event-string ::= primary-event modifier-section? advance-section?
```

---

## 5. Flag-for-Manual List (the Hard ~5%)

The following play types are **outside v1 scope**. When the emitter encounters any of these, it MUST:
1. Emit a `com` record describing the play (including the available facts).
2. NOT emit a fabricated `play` record for that plate appearance, OR emit a `play` record with event
   string `NP` (no play — `cwevent`-accepted placeholder) and flag it clearly in a following `com`.
3. Set `earned_unearned = PENDING` on any affected runs (FR-010a / FR-017).
4. Record the play in the judgment/review queue for the human scorer.

| Category | Description | Why out of scope |
|----------|-------------|-----------------|
| **Multi-out plays with runner annotations** | Double plays and triple plays where the textual `(runner)` notation is required to identify which runner is retired (e.g. `4(1)3` = second baseman tags runner from first, throws to first for DP; `1(B)3(1)` = pitcher tags batter-runner, throw to first retires runner from first for TP) | Requires resolving runner identity mid-string in the advance section; annotation grammar overlaps with error-in-advance; correct mapping requires unambiguous runner tracking that is not in v1 event model |
| **Throwing-error reclassification mid-string** | A play that starts as a fielded out but the throw is errant, allowing runners to advance beyond what the error alone accounts for — requiring reclassification of the primary event (e.g. a fielder's choice where an errant throw turns a FC into a hit-with-error compound) | Mid-string error reclassification requires rewriting the primary event after the fact; v1 emitter writes events linearly from the confirmed facts |
| **Fielder's choice (FC) — all cases** | Any play where the fielder elected to retire a runner other than the batter-runner, resulting in the batter-runner reaching base safely | FC is a **ContestedCredit / scorer-judgment play** (per spec.md Play classification reference): determining which runner was the intended target and whether the batter-runner reached on a true FC or an error requires scorer judgment. FC is therefore **always flag-for-manual** in v1; the emitter MUST NOT emit an `FC` event string — it emits a `com` record and an `NP` placeholder instead. `FC` is absent from the Section 4 BNF `primary-event` production for this reason. |
| **Interference and obstruction** | Batter interference (`C/INT`), catcher obstruction (`C/OBS`), fielder obstruction — especially when they result in automatic bases or reversed outs | Small edge-case frequency in amateur play; correct event-string encoding requires additional state not tracked in v1 |
| **Combined / rare baserunning events** | Two-runner steals (e.g. `SB3;SB2`), pickoff + advance combinations (e.g. `POCS2(1e2/TH)`), balk-plus-advance (`BK`), wild-pitch-plus-advance (`WP`), passed-ball-plus-advance (`PB`) where the primary event is a non-plate-appearance baserunning event (not a strikeout+WP handled above) | Low frequency; encoding requires semicolon-separated multi-event strings and additional runner-state tracking beyond the v1 event model |
| **Earned/unearned requiring Rule 9.16 reconstruction** | Any run that scores in a half-inning with a defensive error or passed ball, where determining earned vs. unearned requires the counterfactual "what would have happened without the error" — i.e. `data,er` entries that cannot be filled in as 0 | Full MLB Rule 9.16 counterfactual reconstruction is deferred (FR-017); v1 always sets `earned_unearned = PENDING` for affected runs |

**Frequency guidance:** the combined flag-for-manual categories constitute approximately 5% of plays
in typical amateur/college games (the v1 beachhead). The emitter's ~95% coverage is validated by the
`cwevent` 3-layer CI gate against real Retrosheet fixtures (D4 / SC-004).

---

## 6. Minimal Valid Input File Structure

`cwevent` requires the following structure to avoid exit(1) or stderr errors (D4):

```
# File: GAME.EVN  (or .EVA — extension is conventional, not enforced)
id,<game-id>
version,2
info,visteam,<team>
info,hometeam,<team>
info,date,YYYY-MM-DD
start,<player-id>,<player-name>,0,1,8   # one per starter, both sides
start,...
play,1,0,<batter-id>,00,,<event>
...
data,er,<player-id>,0
```

Additionally, a `TEAM<YYYY>` file MUST exist in the same directory as the `.EVN` file when invoking
`cwevent`. The file format is one team per line: `<team-code>,<league>,<city>,<nickname>`. The `cwevent`
binary exits with code 1 ("Can't find teamfile") without this file.

Roster files (`.ROS`) are optional. `cwevent` emits a warning but continues without them.

---

## 7. Attribution

All Retrosheet event files produced by Diamond Ledger — whether in tests, fixtures, or exports —
MUST include the following attribution in a `com` record at the top of the file (after `version`):

```
com,"Data based on the Retrosheet event-file format (retrosheet.org). Use of Retrosheet data is subject to the terms at retrosheet.org/notice.txt."
```

The export UI (US3) MUST display this attribution string to the user before or at the time of export,
and MUST include it verbatim in the exported file (D6 / Retrosheet notice.txt requirement).

---

## 8. Contract Versioning and Change Protocol

**Non-breaking additions** (new event types in v1 scope, new modifiers): bump minor version.
**Breaking changes** (removing a construct, changing canonical form): bump major version, notify both squads.

Any change requires:
1. A new version tag in the header.
2. A revision note in the change log below.
3. An ADR entry if the change affects the emitter/fixture boundary (Art. XXXVIII).
4. Re-validation of the `cwevent` fixture corpus (Squad C must update fixtures to match).

### Change log

| Version | Date | Change |
|---------|------|--------|
| v1.1 | 2026-06-01 | Section 5: FC (fielder's choice) clarified as **always flag-for-manual** in v1 — the emitter MUST NOT emit an `FC` event string. Previous wording ("the emitter can emit FC for a clean fielder's choice") contradicted the Section 4 BNF, which has no FC production in `primary-event`. Resolved in favour of the BNF: FC is a scorer-judgment play (ContestedCredit) per the spec, so it is flag-for-manual regardless of whether the individual case appears "clean". |
| v1.0 | 2026-06-01 | Initial frozen contract. |

---

*v1.0 frozen 2026-06-01; v1.1 revised 2026-06-01 · Feature `001-voice-scorebook-core` · Reference: [retrosheet.org/eventfile.htm](https://www.retrosheet.org/eventfile.htm)*
