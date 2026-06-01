# Discovery — Assumption Tests

*Diamond Ledger · names the riskiest assumption + defines falsification · 2026-06-01*

Every assumption the (refined) bet depends on, classified by risk type (Cagan's four + ethical),
mapped on the **2×2** (Y = importance: if wrong, does the idea fail?; X = evidence: do we have
observable evidence, not opinion?). Top-right (important + no evidence) = **test now**. Each gets a
directional **estimated resolution** from the research, with an explicit confidence flag — the
estimate *prioritizes* the test, it never replaces it.

## Assumptions ledger

| ID | Type | Assumption | Importance | Evidence | Quadrant |
|---|---|---|---|---|---|
| A1 | Desirability/Viability | Serious/official scorekeepers will **switch to and pay for** voice-driven scoring | High | Low–Med | **Top-right** |
| A3 | Desirability | Retrosheet/official export is valued **beyond the SABR niche** (by travel/HS/college buyers) | High | **Low** | **Top-right** |
| A5 | Usability | The confirm/correct loop for the ~15% judgment plays stays fast enough to **not recreate** the attention problem | High | Low | **Top-right** |
| A2 | Desirability | The rec parent will actually **use voice** (vs. tap, vs. not scoring) | Med (v1) / High (TAM) | Low | Top-right (TAM) |
| A6 | Feasibility | ASR + on-device NLU parses freely-spoken plays to rules-correct events at trustworthy accuracy in ballpark noise | High | **Med–High** | Top-left (have evidence) |
| A7 | Feasibility | A deterministic engine produces trustworthy official/Retrosheet output incl. earned runs | High | Med | Top-right→left (scope-dependent) |
| A8 | Viability | A beachhead exists that GameChanger won't **neutralize via distribution/voice** before traction | High | Med | Top-right |
| A9 | Viability | WTP at a price yielding a viable business for the *monetizable* segment | High | Med | Top-left-ish (iScore/GC pricing) |
| A11 | Ethical | COPPA / minors' audio handled (push-to-talk, process-don't-store) | High | Med–High | Top-left (architecture solves it) |

## 2×2 (text)

```
IMPORTANCE ↑
  (fatal) │  A2(TAM) · A8        │  A6 · A9 · A11
          │  ┌────TEST NOW────┐  │  (have evidence → monitor)
          │  │ A1 · A3 · A5   │  │  A7 (scope to de-risk)
          │  │ A2(v1)         │  │
          │  └────────────────┘  │
  (minor) │                      │
          └──────────────────────┴──────────────────────→ EVIDENCE
             (no evidence)              (have evidence)
```

## The single riskiest assumption

**A1 + A3 (fused): "Enough serious/official scorekeepers will switch to and pay for voice-driven,
Retrosheet-grade scoring to form a viable beachhead — i.e. official, exportable, attention-free
scoring is something the paying segment actively wants, not a niche GameChanger can ignore us into."**

Why this one: feasibility (A6/A7) is largely de-risked by the research, and the consumer attention
pain (A2) is real but low-WTP and incumbent-owned. The whole *viability* of the refined bet
therefore rests on whether the underserved paying scorer will actually adopt and pay. If they
won't, you are left fighting GameChanger for free parents — the losing position.

## Experiment cards (top-right, cheapest-first)

```
EXPERIMENT CARD — A1/A3  (riskiest)
─────────────────────────────────────────────
Type: ☒Desirability ☒Viability
Assumption: Serious/official scorekeepers will switch to & pay for voice→Retrosheet scoring.
Hypothesis (XYZ): At least 8% of targeted serious-scorer visitors will give a real commitment
                  signal (email + paid pre-order/deposit OR written LOI OR an intro to their league).
Test: Smoke-test landing page (voice → official Retrosheet book) + fake-door "Reserve early
      access — $X deposit", seeded into travel-ball/HS-coach/SABR-Retrosheet/r/Homeplate channels;
      paired with 15–20 Mom-Test interviews of official/serious scorers (past specifics, no pitch).
Setup: ~1,000 targeted visitors over 4 weeks; deposit via Stripe; interviews recruited from forums.
Metric: (a) visitor→deposit/LOI rate; (b) # of 20 interviewees showing a commitment signal.
Success: PASS if deposit/LOI ≥ 8% AND ≥ 8/20 interviews show commitment. FAIL below either.
Cost: ~$1–3k ads + ~30 person-hours.   Time: ~6–8 weeks.
Evidence strength: ☒Strong (money/commitment, not "says").
Estimated resolution: UNCERTAIN, confidence M — serious scorers demonstrably pay (iScore) and are
  underserved (no Retrosheet anywhere), but whether *voice* + *export* clears their switching bar
  is unproven; A3 (export valued beyond SABR) is the weakest link (research confidence L).
─────────────────────────────────────────────

EXPERIMENT CARD — A5  (usability — does the fix recreate the pain?)
─────────────────────────────────────────────
Type: ☒Usability ☒Desirability
Assumption: The ~15% judgment-play confirm/correct loop stays fast enough to keep attention free.
Hypothesis (XYZ): At least 80% of plays are recorded with ≤1 spoken phrase + ≤1 tap, and median
                  eyes-on-screen time per play ≤ 3s, in a Wizard-of-Oz test.
Test: Wizard of Oz — human "engine" behind a phone UI; 5–8 scorers score a real or video game by
      voice; measure taps, time-on-screen, abandonment, and "did you miss plays?" debrief.
Metric: % plays ≤1 phrase+1 tap; median seconds eyes-on-screen; self-reported missed plays.
Success: PASS if ≥80% one-shot AND median ≤3s AND no scorer reports missing more than paper would.
Cost: low (no engine).   Time: ~2 weeks.   Evidence strength: ☒Strong (observed behavior).
Estimated resolution: LIKELY TRUE, confidence M — push-to-talk + one-tap confirm is structurally
  light, but the judgment-play UX is unproven and is the part that can quietly recreate O1.
─────────────────────────────────────────────

EXPERIMENT CARD — A6/A7  (feasibility spike — already partly de-risked)
─────────────────────────────────────────────
Type: ☒Feasibility
Assumption: Voice→rules-correct event is trustworthy on a real noisy game (scoped v1, no earned-run
            counterfactual).
Hypothesis (XYZ): On one recorded real amateur game, ≥90% of *unambiguous* plays are parsed
                  structurally correct, and ≥85% end-to-end correct after the confirm loop, vs. a
                  hand-scored gold Retrosheet file.
Test: Engineering spike — WhisperKit/on-device ASR + grammar-constrained NLU over a Pydantic play
      schema + partial deterministic engine; score one real game from field audio.
Metric: structural accuracy on unambiguous plays; end-to-end accuracy post-confirm.
Success: PASS at the thresholds above; FAIL if unambiguous-play accuracy <90%.
Cost: med (engineering).   Time: ~3–4 weeks.   Evidence strength: ☒Strong (measured).
Estimated resolution: LIKELY TRUE, confidence M–H — research shows the stack is viable; risk is
  ballpark ASR WER and parser coverage, both mitigable (push-to-talk, fine-tune, scope).
─────────────────────────────────────────────
```

## Other assumptions — directional estimates (test later / monitor)

- **A2 (rec parent uses voice):** UNCERTAIN, confidence L. Validates the *expansion* TAM, not the
  beachhead — defer; Pocket Blue proves the pain, not voice adoption.
- **A8 (GC won't neutralize first):** LIKELY TRUE *for the beachhead*, confidence M — GC ignores
  the serious-scorer/archivist user and chose not to extend voice to baseball; watch for a feature
  announcement if traction becomes visible.
- **A9 (viable WTP):** LIKELY TRUE, confidence M — iScore ($20/yr) and GC Team Pass ($239–449/season)
  bound a real price; tested directly by the A1/A3 deposit experiment.
- **A11 (COPPA/audio):** LIKELY TRUE, confidence M–H — solved by push-to-talk + process-don't-store;
  a viability gate to design in, not a discovery blocker.

## Ordering

Run **A5 (Wizard of Oz, ~2 wks, cheap)** and the **A1/A3 smoke-test (6–8 wks)** first and in
parallel; they de-risk demand+usability before spending engineering on the **A6/A7 spike**. If
A1/A3 fails its threshold, stop before the spike.
