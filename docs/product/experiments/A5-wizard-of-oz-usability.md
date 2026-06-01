# Experiment A5 — Wizard-of-Oz Usability Test

*Tests whether the confirm/correct loop recreates the very attention problem it's meant to solve.
Pre-registered 2026-06-01. Status: NOT YET RUN. No engine required.*

**Assumption:** The ~15% scorer-judgment plays (hit vs. error, earned vs. unearned) can be
confirmed/corrected fast enough that the scorer keeps their eyes on the field — i.e. voice scoring
stays *attention-free* in practice, not just in theory.

**XYZ hypothesis (registered before running):** *At least **80%** of plays are recorded with ≤1
spoken phrase + ≤1 tap; **median eyes-on-screen time ≤ 3s per play**; and no participant reports
missing more plays than they would with paper.*

---

## Setup — the "wizard"

No real ASR/engine. A hidden human operator ("the wizard") listens to the participant's spoken
plays and drives a simple phone UI (even a clickable Figma/Keynote prototype or a shared screen),
returning: (a) the recorded play in notation, and (b) for ~15% of plays, a **judgment prompt**
("Hit or error on the shortstop?") the participant must resolve by voice or one tap.

- **Participants:** 5–8 scorekeepers (skew to the serious-scorer beachhead; include 1–2 novices).
- **Stimulus:** one real game OR a broadcast/video of a game with a known gold scorebook, so the
  wizard injects realistic judgment-call moments at the right rate (~15%).
- **Mode:** push-to-talk. Participant says the play, glances only to confirm.

## What we measure (observed, not asked)

| Metric | How | PASS threshold |
|---|---|---|
| One-shot capture rate | % plays recorded with ≤1 phrase + ≤1 tap | **≥ 80%** |
| Eyes-on-screen per play | stopwatch / screen-recording review, median seconds | **median ≤ 3s** |
| Judgment-prompt handling | median seconds to resolve a hit/error prompt | ≤ 5s (report) |
| Missed-play self-report | post-game: "did you miss plays you'd have caught on paper?" | **no participant reports more misses than paper** |
| Abandonment | did anyone quit mid-game / revert to manual? | 0 abandonments |

## Facilitator script (keep it Mom-Test clean)

- Before: "Score this game however feels natural. Talk to the app like you'd tell a friend what
  happened. I'm watching how it *feels*, not testing you." (Do **not** explain features or sell.)
- During: stay silent; record taps + time-on-screen via screen capture; note hesitations.
- After (debrief, ask about specifics): "Where did you have to look down longest? Tell me about the
  play that was hardest to record. Did you miss anything on the field? Compared to how you score
  today, what was better or worse?"

## Pre-registered decision rule

- **PASS** → the attention promise holds; the confirm-loop design is safe to build.
- **FAIL** (one-shot <80% OR median eyes-on-screen >3s OR anyone reports missing more than paper)
  → the judgment-call UX is the problem, not the concept. Redesign the loop (e.g. batch judgment
  prompts to inning breaks, smarter defaults) and re-test **before** building the engine.

Record outcomes in `results-tracker.md`. No fabricated entries (Article VI).
