# Demo Cohort Tracker — ~20 Serious Scorers (ADR-0006 First-Slice Demo)

**Task**: T067 (Story C5 #108 / issues #109, #110)  
**Authority**: ADR-0006 · `specs/001-voice-scorebook-core/research.md` D6  
**Tripwire review date**: 2026-07-31  
**Status**: PLANNING — cohort not yet assembled; this document is the tracker  
**Last updated**: 2026-06-02

---

## Purpose

ADR-0006 mitigation #2 requires:

> **Sequence the build so the first shippable artifact is demoable to ~20 real serious scorers.**

The ~20 serious scorers are not a beta group — they are the **demand-signal instrument** that
tests the foundational assumption: will a serious/official scorekeeper switch to and pay for a
voice→Retrosheet scoring workflow? Their adoption signal feeds the ADR-0006 tripwire review
on **2026-07-31**.

The demo requires:
1. A **demoable slice** — US1 + US2 + US3 (speak→score→export) running on a real device.
2. **~20 real serious scorers** who can react to it.
3. **A session structure** that captures the SC-005 attention bar (≥80% plays ≤1 phrase + ≤1 tap;
   median eyes-on-screen ≤3s) and a commitment signal (would they use/pay for this?).

This document tracks the cohort recruitment and the ADR-0006 distribution tripwire risk.

---

## Who counts as a "serious scorer"

For this cohort, "serious scorer" means:

- **Official/credentialed scorers**: MLB-credentialed official scorers (a small rotating pool, ~2-3 per club), state
  high school association scorers, MiLB official scorers.
- **High-frequency amateur scorers**: travel baseball statisticians (frequent game scoring),
  college or high school athletic scorekeeping staff, Retrosheet volunteer contributors.
- **SABR members with active scoring practice**: SABR members who actively score games rather
  than primarily doing archival research.

**Explicitly NOT in scope**: casual rec league parents, fans who score occasionally, sportswriters.
The beachhead is people for whom scoring is a skill they practice deliberately.

---

## Recruitment channels

| Channel | Type | Priority | Capacity | Notes |
|---------|------|----------|----------|-------|
| SABR Official Scoring Research Committee | National org | HIGH | 10–30 members | See `sabr-retrosheet-outreach.md` Track 1B |
| Local SABR chapters (LA, NY, other) | Local | MEDIUM | 5–15 per chapter | See `sabr-retrosheet-outreach.md` Track 1C |
| Retrosheet contributor network | Archive volunteers | MEDIUM | 20–50 active | Via Tom Thress intro — see Track 1A |
| Travel baseball association stats coordinators | Amateur operators | MEDIUM | Hard to reach cold | Via regional travel ball associations |
| College baseball SIDs / statisticians | College ops | MEDIUM | Hard to reach cold | Via CoSIDA (College Sports Information Directors of America) or direct outreach to sports info directors |
| Direct personal network | Warm contacts | HIGH | Low ceiling | Start here; fastest path to first 5 |
| Twitter/X baseball scoring community | Social | LOW | Noisy | Use only if warm channels are exhausted |

**Recommended sequence**: Personal network → SABR Committee (warm intro) → Retrosheet network →
local chapters → cold athletic associations.

---

## Cohort tracker

Target: **≥20 confirmed, ≥15 completing the session** (ADR-0006 tripwire threshold)

| # | Name / Handle | Channel | Scorer type | Status | Notes |
|---|--------------|---------|-------------|--------|-------|
| 1 | PLACEHOLDER | — | — | — | — |
| 2 | PLACEHOLDER | — | — | — | — |
| 3–20 | ... | — | — | — | — |

**Status values**: `identified` → `contacted` → `confirmed` → `session-complete` → `signal-captured`

**Human action**: fill in this table as recruitments progress. Update status after each touchpoint.

---

## Demo session structure

Each session is approximately **45–60 minutes**, conducted **in person or remote (video call)**
with the real demoable slice on device.

### Session flow

**Part 1 — Orientation (5 min)**

> "I'm building a voice-driven scorebook. You'll score 5–8 plays of a real game by speaking,
> and the app will produce Reisner notation and a Retrosheet event file. I want to measure
> whether the recognition and scoring are accurate, and whether the workflow feels natural."

- Brief app walkthrough (no coaching on how to speak plays — let them use their natural idiom)
- Confirm they are comfortable scoring the v1 play types (standard plays, a few judgment calls)

**Part 2 — Scoring session (20–30 min)**

- Scorer speaks 5–8 real plays from the LAN2024091601 gold game (or equivalent)
- App produces Reisner notation and judgment prompts
- Scorer resolves any judgment calls with one tap
- Facilitator observes and notes:
  - Misrecognitions (how many? what patterns?)
  - Judgment resolution: did the card make the options clear?
  - Time on screen: was the scorer eyes-up as expected?
  - Any plays that tripped the flag-for-manual path

**Part 3 — Feedback (10–15 min)**

- Structured questions (see below)
- Open-ended: "What would need to be true for you to use this for a real game?"
- Commitment probe: "On a scale of 1–10, how likely are you to use this for your next game?
  What would move that number higher?"

**Part 4 — SC-005 measurement capture**

Facilitator records:
- `plays_one_phrase_one_tap_count`: plays that required ≤1 narration attempt AND ≤1 UI tap
- `total_plays`: total plays in the session
- `median_eyes_on_screen_seconds`: estimated (log during session with a stopwatch if possible)

SC-005 bar: ≥80% of plays one-phrase-one-tap; median eyes-on-screen ≤3s.

### Structured feedback questions

1. "Does the Reisner notation match what you would have written?" (per play, yes/no/modified)
2. "For judgment plays: did the app identify the right judgment? Did the 'your call' card give
   you enough information to decide quickly?"
3. "How does this compare to your current scoring workflow?" (paper / spreadsheet / app)
4. "Would you export the Retrosheet file and submit it to a database or archive?"
5. Commitment probe: "If this app existed today at $X/month, would you use it for your
   next game?" (test at $0, $5/mo, $15/mo, $29/mo)

---

## ADR-0006 tripwire calculation (review: 2026-07-31)

The ADR-0006 distribution tripwire fires if:

> "~20 real serious scorers cannot be put in front of the demoable slice within the build window"

**Operational definition**: if by **2026-07-31** fewer than **15 sessions** are complete with
a committed scorer, the tripwire fires.

### Risk log

| Date | Risk | Severity | Status | Notes |
|------|------|----------|--------|-------|
| 2026-06-02 | Cohort recruitment not started | HIGH | OPEN | First outreach drafts committed in this PR; actual sends are human task |
| 2026-06-02 | Access to SABR/serious-scorer network unknown | MEDIUM | OPEN | SABR outreach drafted; warm contacts not yet identified |
| 2026-06-02 | Demoable slice not yet built | MEDIUM | OPEN | Build proceeding; T071–T074 on critical path; target: before 2026-07-31 |

### Tripwire outcomes

If by 2026-07-31:

- **<8% commitment signal AND <8/20 scorers show commitment** → pause net-new engine investment;
  re-segment or evaluate the archivist score-from-video pivot before committing further months.
- **<15 sessions complete** → log as the distribution/GTM red flag; explicit documented
  continue/redirect/pause decision required before scaling.

Any tripwire trip is documented in `DECISIONS.md` as an ADR amending ADR-0006. **Never silent
continuation.**

---

## Immediate next actions (human tasks)

1. **Identify 5 warm contacts** in personal network who score travel/HS/college games.  
   → Send brief personal messages this week (not the formal email above — informal first contact).

2. **Join SABR and post to the Official Scoring Research Committee list**.  
   → Use the Track 1B draft email in `sabr-retrosheet-outreach.md` as the basis.

3. **Contact Retrosheet (Tom Thress)** via retrosheet.org/contact.htm.  
   → Use the Track 1A draft in `sabr-retrosheet-outreach.md`.

4. **Update this tracker** after each contact. Keep the risk log current.

5. **Set a 2026-06-30 checkpoint**: if fewer than 5 confirmed by then, escalate recruitment strategy
   (consider attending a SABR event, reaching out to regional travel ball associations, etc.).

---

## What to tell recruits

**One-sentence pitch**: "I'm building a voice scorebook that turns spoken play-by-play into Reisner
notation and a Retrosheet-compatible event file — I need 20 serious scorers to demo it and tell me
if it works."

**Key points to include**:
- The session is 45–60 minutes, on their schedule
- No technical setup required (they just speak plays normally)
- Credit and early access in return; no equity or ongoing commitment
- The app is designed for *them* — serious scorers, not rec parents

**Key points NOT to overpromise**:
- Do not promise the accuracy will be good (that's what we're measuring)
- Do not promise a ship date
- Do not promise free forever (monetization decision is post-tripwire-review)
