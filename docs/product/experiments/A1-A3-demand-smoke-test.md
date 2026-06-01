# Experiment A1/A3 — Demand Smoke-Test + Interviews

*Tests the single riskiest assumption. Pre-registered 2026-06-01. Status: NOT YET RUN.*

**Assumption:** Serious/official scorekeepers will switch to and *pay for* voice-driven,
Retrosheet-grade scoring — and Retrosheet/official export is valued beyond the small SABR niche.

**XYZ hypothesis (registered before running):** *At least **8%** of targeted serious-scorer
visitors will give a real commitment signal — a paid pre-order deposit, a signed LOI, or an intro
to their league/program — and **≥8 of 20** interviewed scorers will show a commitment signal.*

---

## Part 1 — Landing page + paid fake-door (behavioral signal)

**Asset:** `landing-page.html` (host on `diamondledger.app` or a Carrd/Vercel page). Wire:
- An analytics tag (Plausible/GA) for unique visitors + funnel events.
- The primary CTA → a **Stripe payment link** for a **$10 refundable "founding scorer" deposit**
  (real money = strong evidence; refundable keeps it ethical). Fallback CTA → email capture +
  a one-question "what do you score?" field.
- A secondary CTA for orgs: **"Request a league pilot"** → a short form (this captures the
  intro/LOI signal).

**Traffic (target ~1,000 targeted visitors over 4 weeks), seeded into serious-scorer channels:**
- Reddit: r/Homeplate (scorekeepers/coaches), r/baseball (scoring threads), r/Sabermetrics.
- Retrosheet / SABR mailing lists + SABR Slack (the archivist segment for the A3 export signal).
- High-school & travel coaching Facebook groups; state HS baseball coaches associations.
- Perfect Game / USSSA scorer communities; PrestoSports/DakStats user forums.
- A small paid test ($1–3k) on Meta/Reddit targeting "baseball coach / statistician" interests.

**Pre-registered metrics & thresholds (do not change after launch):**

| Metric | Definition | PASS threshold |
|---|---|---|
| **Primary — commitment rate** | (paid deposits + signed LOIs + league-pilot requests) ÷ unique visitors | **≥ 8%** |
| Secondary — email capture | emails ÷ unique visitors | ≥ 20% (context, not gating) |
| Secondary — paid-deposit rate | $10 deposits ÷ unique visitors | ≥ 3% (strongest single signal) |
| Guardrail — A3 export pull | % of commitments that cite Retrosheet/official export as a reason | report (tells us if export is the draw or the SABR niche only) |

**Cost:** ~$1–3k ads + ~10 hrs setup. **Duration:** 4 weeks traffic.
**Evidence strength:** Strong (real money / real commitment).

---

## Part 2 — Mom-Test interviews (qualitative, runs in parallel)

**Sample:** 20 serious scorekeepers — mix of HS/college official scorers, travel-team scorers, and
Retrosheet/SABR archivists. Recruit from the same channels + the email captures.

**Rules (Fitzpatrick):** talk about *their* life, not our idea; ask about *past specifics*, never
hypotheticals; never pitch; let them talk ~80%. A compliment is not a commitment.

**Interview guide — ask these (good questions):**
1. "Walk me through the last game you scored. What did you actually do, step by step?"
2. "When was the last time scoring made you miss something on the field? What happened?"
3. "What do you use today? What did it cost you — money, and time?"
4. "Tell me about the last time your scorebook had an error or someone disputed it."
5. "Have you ever needed to hand your data to someone else (coach, league, recruiter, archive)?
   What format? What broke?" *(the A3 export probe — listen for real past pain, not enthusiasm)*
6. "What have you already tried or paid for to fix any of this?"

**Banned questions (they only fish for validation):** "Would you use this?" "Do you like this
idea?" "How much would you pay?"

**Commitment signals to record (the real output):** agrees to a paid deposit; signs an LOI; gives
an intro to their league/AD; sends you their current scorebook/data; books a follow-up. Count an
interview as a "commitment" only if the person **gave up something they value** (time, reputation,
or money) — not if they merely praised it.

**PASS threshold:** **≥ 8 of 20** interviews produce a real commitment signal, AND the A3 export
pain shows up *unprompted* in at least a third of the export-relevant interviews.

---

## Decision rule (combined, pre-registered)

- **PROCEED to build** if commitment rate **≥8%** OR (paid-deposit ≥3% AND interviews ≥8/20).
- **PIVOT** (e.g. to the archivist score-from-video tool, or a different beachhead) if demand is
  weak but a specific *sub-segment* over-indexes (e.g. archivists love export, coaches don't).
- **KILL / rework the PR/FAQ** if commitment **<8%** AND interviews **<8/20** by **2026-07-31**.

Record outcomes in `results-tracker.md`. No fabricated entries (Article VI).
