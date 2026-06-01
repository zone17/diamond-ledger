# Discovery Brief — Diamond Ledger

*The tying-together artifact. Evidence: `01-research-synthesis.md`, `02-opportunity-map.md`,
`03-assumption-tests.md`. Date: 2026-06-01.*

> **Verdict: REFINE.** The problem is real, the product is the right solution, and feasibility is
> largely de-risked. But the PR/FAQ bets on the **wrong beachhead** — the tee-ball parent is the
> lowest-WTP user and sits on GameChanger's distribution moat. Re-aim the entry wedge at the
> **serious/official scorekeeper**, where accuracy + Retrosheet export + attention-free voice all
> peak and where the incumbent structurally won't follow. Keep the parent as expansion TAM.

## Sharp problem statement

- **WHO:** The person who keeps the official/serious book — a travel/select or high-school/college
  scorer or statistician, and the Retrosheet/SABR archivist (not, at first, the casual rec parent).
- **STRUGGLE:** When they sit down to score a live game, they are trying to **produce an accurate,
  trustworthy, exportable record of every play** — but every existing tool forces a bad trade:
  tap-based apps (GameChanger, iScore) demand eyes-on-screen for every pitch *and* still don't
  produce an official, portable (Retrosheet) record, while paper is error-prone and trapped on the
  page. (Stated as a need — it admits voice, computer-vision, faster-tap, or human-scorer solutions.)
- **CONTEXT:** Dozens of games a season, in noisy ballparks, often by an inexperienced volunteer;
  the scorer is usually *not* the coach and can't also watch the game closely.
- **ALTERNATIVES:** iScore ("incredibly deep but insanely frustrating," no Retrosheet export in
  ~8 years), GameChanger (tap-based by design, no API, no Retrosheet, voice is basketball-only),
  paper, or simply not keeping a full book. All fall short on **accuracy + portability without
  consuming attention** at the same time.
- **WHY IT MATTERS:** Inaccurate volunteer stats are discounted by college coaches (real downstream
  cost to players); archivists hand-code post-game; and no one can hand the data to industry tools.
  For us it's the wedge into a category whose incumbent ignores this exact user.
- **EVIDENCE:** Triangulated desk research (competitor product copy naming the pain; iScore UX
  reviews; GameChanger's deliberate tap/closed design; Retrosheet discrepancy program; the
  feasibility "why now"). Confidence **H** on problem/competition, **M** on the paying-beachhead,
  **L** on "Retrosheet valued beyond the SABR niche" (the open question A3).

## Sharp bet

- **THE OPPORTUNITY:** Accuracy & officialness (Opportunity Score **15**) + Retrosheet portability
  (**14**), delivered attention-free (O1/O2 also score **13**) — the under-served, monetizable,
  defensible cluster. Not O5 (speed, over-served) or O6 (streaming, the incumbent's moat).
- **TARGET CUSTOMER (beachhead):** the serious/official scorekeeper — travel/select & HS/college
  statisticians and Retrosheet/SABR archivists — who already pays (iScore) and is badly served.
- **POINT OF VIEW — why we'll win:** We're the only solution that hits attention **and** accuracy
  **and** open Retrosheet export at once, and "why now" just made it feasible (on-device Whisper +
  grammar-constrained function calling, late-2024→2025). GameChanger won't follow: it's
  deliberately closed (data gravity is its business model) and kept voice to basketball because
  baseball's 50+ event codes are hard. Our moat is the part they won't copy — official-grade
  determinism + open export — built on the constitution's deterministic-engine-around-a-
  probabilistic-interpreter architecture.
- **DESIRED OUTCOME:** Success = a proven beachhead — e.g. **≥50 serious scorers keeping real,
  exportable books across a season with a per-game correction rate low enough that they don't
  abandon** — before broadening to the parent market.
- **RISKIEST ASSUMPTION (A1+A3):** that enough serious/official scorekeepers will **switch to and
  pay for** voice-driven, Retrosheet-grade scoring to form a viable beachhead — and specifically
  that **Retrosheet/official export is valued beyond the tiny SABR niche** (the weakest-evidence
  link, confidence L).
- **FALSIFICATION:** We **pivot or kill** if, by **2026-07-31**, a smoke-test landing page + paid
  fake-door driven to ~1,000 targeted serious-scorer visitors converts **< 8%** to a real
  commitment signal (paid deposit / written LOI / league intro) **and** **fewer than 8 of 20**
  Mom-Test-interviewed scorers show a commitment signal. (Cheapest test of the riskiest belief,
  measuring real behavior before any engine is built.)

## "Is it sharp enough to exit discovery?" checklist

- [x] Problem stated as a customer **need/job**, not a solution (admits multiple solutions).
- [x] **Specific target customer** named (serious/official scorekeeper beachhead, not "users").
- [x] Problem backed by **evidence**, fact-vs-inference separated, confidence rated.
- [x] **Measurable desired outcome** tied to strategy (≥50 retained serious scorers/season).
- [x] Opportunity **prioritized with rationale** (Opportunity Scores 15/14 vs. 7/9).
- [x] Explicit **point of view** on why we win (and why the incumbent won't follow).
- [x] **Single riskiest assumption** named, in "important + no evidence" (A1+A3).
- [x] **Falsification condition** with metric (<8% commitment), threshold, and date (2026-07-31).
- [x] Riskiest assumption is **cheaply testable with real behavior** (deposit/LOI smoke test).

All nine satisfied → discovery exits.

## Verdict & handoff

**REFINE** — back to `product-idea` (`docs/product/PR-FAQ.md`) with these specific corrections:

1. **Re-aim the beachhead.** Lead the press release with the serious/official scorekeeper (accuracy
   + Retrosheet + attention-free), not the tee-ball parent. Keep the parent as the *expansion*
   story and emotional founder origin, not the launch customer.
2. **Correct the TAM.** GameChanger's ~$100M (2024) ≈ the entire current US monetized market; state
   US category total ~$100–130M and global **~$200–250M** (not $300–500M). Distinguish the smaller
   *serviceable* serious-scorer SAM (the real near-term target) from the category TAM.
3. **Name the real rivals.** Add **Pocket Blue** (camera/CV, validates the pain) and make explicit
   that GameChanger's voice is basketball-only and its closedness (no API/Retrosheet) is the
   opening — differentiation is *official-grade + open export*, not just "voice."
4. **Sharpen "why now"** with the dated on-device ASR + constrained-function-calling inflection.
5. **Lock v1 scope to the de-riskable core:** the deterministic ~85% + one-tap confirm for the ~15%
   judgment plays; a reduced-but-valid event format first, full earned-run counterfactual later.

**Then:** run the two cheap experiments (A5 Wizard-of-Oz usability ~2 wks; A1/A3 smoke-test ~6–8
wks) **in parallel before** the A6/A7 engineering spike. If A1/A3 clears its threshold, proceed to
build the first capability via `/speckit.specify` (smallest primitive: `record_play` →
`advance_runner` → `finalize_scorecard`). If it fails, pivot (e.g. archivist score-from-video tool)
or kill.
