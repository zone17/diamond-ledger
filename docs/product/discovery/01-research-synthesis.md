# Discovery — Research Synthesis

*Diamond Ledger · evidence behind the sharp problem · 2026-06-01*

Inputs: the PR/FAQ (`docs/product/PR-FAQ.md`) and four parallel cited web-research threads
(problem/customer, market/TAM, competition, feasibility/why-now). Every row below is tagged
**[FACT]** (cited) or **[INFERENCE]** (our interpretation) with confidence **H/M/L**.

## 1. Question & scope

Is there a real, underserved problem behind "speak the game, get an official scorebook," who
feels it most, and is the bet aimed at the sharpest version of it? Desired outcome the research
informs: **maximize complete, accurate, exportable scorebooks produced per active scorer per
season** (captures value + repeat use), and identify the **beachhead** that makes the bet viable.

## 2. Market context — size, trends, why now

- **[FACT, H]** US baseball participation ~16.7M (2023, SFIA, highest since 2008); organized
  youth 6–17 ≈ 4.5–5M; travel/select ≈ 2.8M. HS baseball **472,598** players, ~16,000 programs
  (NFHS 2024–25). College ≈ **1,600** programs (~43,000 players). Softball adds ~8.7M total US
  participants (2.3M fast-pitch) and 344,952 HS girls.
- **[FACT, H]** **GameChanger crossed ~$100M revenue in 2024** (target $150M 2025; ~40% CAGR),
  9M+ users, 750K+ baseball/softball teams, 13M athletes — owned by DICK'S since 2016.
- **[FACT, H]** Project Play: average family spends ~$1,016/yr on their primary sport (2024);
  baseball spend +68% over five years. Money is flowing into youth baseball.
- **[FACT, H] Why now is real and datable.** Offline ASR at <15% WER (WhisperKit, ICML 2025,
  0.3W/inference on Apple Neural Engine; Apple SpeechAnalyzer at WWDC 2025) **and** on-device
  grammar-constrained function calling (FunctionGemma 270M, Dec 2025, 85% fine-tuned;
  Outlines/XGrammar constrained decoding) became deployable only in **late 2024–early 2025**.
  In 2021 none of this stack existed. The 5-year gap is categorical, not marginal.

## 3. Customer segments & jobs/pains

| Segment | Job-to-be-done | Current satisfaction | WTP |
|---|---|---|---|
| Rec/tee-ball parent & grandparent | "Capture my kid's game as a keepsake without missing it" | Low — but **owned by GameChanger free** | **Low** [FACT, H] |
| Travel/select coach or team scorer | "Get accurate season stats without a dedicated scorekeeper" | Low — needs a dedicated volunteer; stats often inaccurate | Med–High [FACT, M] |
| HS/college statistician / official scorer | "Keep an accurate, exportable official book fast" | Low — iScore "incredibly deep but insanely frustrating"; no Retrosheet export | **High** (already pays) [FACT, H] |
| Retrosheet/SABR archivist | "Produce a clean Retrosheet event file (often from video)" | Very low — manual coded post-game entry by trained specialists | High (passion) [FACT, M] |

- **[FACT, H]** In youth ball the scorekeeper is a parent volunteer, *"usually the one who missed
  the parent meeting,"* separate from the coach (who can't score while coaching), inexperienced,
  producing stats so unreliable that *"college coaches take them with a huge dollop of salt."*
- **[FACT, H]** The attention pain is **named verbatim by a funded competitor**, Pocket Blue:
  *"At every game, a parent pulls out their phone, opens a scorekeeping app, and stops watching."*
- **[INFERENCE, M]** First-person "I missed my kid's hit because I was scoring" verbatim quotes
  were thin in the corpus; the pain is established structurally + competitively, not from a single
  user quote. Confidence is from triangulation, not direct voice.

## 4. Competitive / alternatives landscape

- **[FACT, H] GameChanger** — tap-based by deliberate design (2024 redesign optimizes "fewer
  taps"). Its **voice feature is basketball-only** (basketball has ~5 event types; baseball 50+).
  **No public API; no Retrosheet export** — data gravity is a feature for DICK'S. Moat = retail
  distribution + streaming + parent network, *not* scoring depth.
- **[FACT, H] iScore** — power-user tap/interview scoring; exports CSV/HTML/PDF only; **no
  Retrosheet event-file export in ~8 years** despite a community asking. iOS-only, no free tier.
- **[FACT, H] Pocket Blue** — camera/computer-vision auto-scoring (different modality), iOS-only,
  counts/score only (not a full book), no Retrosheet. Validates the *problem*, not our solution.
- **[FACT, M] EasyScore** — added "speech recognition" (Apr 2024) but undocumented; almost
  certainly iOS dictation to a text field, not semantic play parsing.
- **[FACT, H]** No voice-driven baseball scoring product exists as a shipping app, funded startup,
  or serious open-source project — confirmed across App Store, YC directory, GitHub, Product Hunt.
- **[FACT, H] Retrosheet** is openly licensed (commercial use allowed) and fully specified; the
  open-source tooling (Chadwick, pyretrosheet) **parses** event files but nothing **generates**
  them from natural language.
- **Non-consumption:** paper scorebooks (error-prone, trapped on paper) and simply not scoring.

## 5. Regulatory / technical context

- **[FACT, H] COPPA** governs minors' data — verified parental consent + data minimization. Audio
  of minors in public venues: process-don't-store. Solvable by **push-to-talk** architecture (no
  continuous listening), not a blocker but a hard design constraint.
- **[FACT, M] Scoring-rules engine is real work.** Full Retrosheet output requires inning-state,
  pitcher-responsibility, substitutions, and **counterfactual earned-run reconstruction** (MLB
  Rule 9.16) — explicitly scorer judgment, ~3–6 months of deterministic engine work. A reduced
  format covering ~95% of amateur plays is achievable much faster.

## 6. Evidence-vs-inference table (load-bearing rows)

| # | Claim | Fact/Inf | Confidence | Source |
|---|---|---|---|---|
| E1 | Attention pain is real & competitor-validated | Fact | H | Pocket Blue product copy + GC requiring dedicated scorer |
| E2 | No voice-driven official baseball scoring exists | Fact | H | App Store/YC/GitHub sweep; GC voice is basketball-only |
| E3 | No incumbent exports Retrosheet | Fact | H | GC (no API), iScore (CSV/PDF only) |
| E4 | GameChanger ≈ $100M rev (2024) = current US monetized market | Fact | H | DICK'S disclosures via YSBR |
| E5 | Rec parent = lowest WTP, owned by GC free + distribution | Fact | H | GC pricing/scale; volunteer-scorer literature |
| E6 | Serious/official scorers are underserved & already pay (iScore) | Fact | H | iScore UX reviews; official-scoring workflow |
| E7 | Core tech bet is feasible today (push-to-talk + constrained NLU) | Inference | H | WhisperKit, FunctionGemma, constrained-decoding papers |
| E8 | ~15% of plays are scorer-judgment, not auto-resolvable | Fact | H | MLB Rule 9; earned-run counterfactual |
| E9 | Global TAM $300–500M is 25–50% high; ~$200–250M defensible | Inference | M | participation × WTP, non-US discount |
| E10 | Retrosheet-export *valued beyond the SABR niche* | **Open** | **L** | not establishable from desk research |

## 7. Key insights (the decision-changers)

1. **The wedge in the PR/FAQ is real but mis-prioritized.** Attention pain is genuine, but the
   tee-ball parent who feels it is the *lowest-WTP* user and is structurally owned by GameChanger's
   free tier + DICK'S distribution. Leading there walks into the incumbent's strongest position.
2. **The defensible, monetizable beachhead is the serious/official scorekeeper.** They already pay
   (iScore), are badly served (frustrating UX, no Retrosheet), and are a user GameChanger *ignores
   by choice*. Accuracy + Retrosheet export + attention-free voice all peak for this segment.
3. **Feasibility is largely de-risked; the risk moved to demand and scope.** The tech works today
   for a scoped v1; the failure modes are (a) will the paying segment actually switch, (b) is
   Retrosheet export valued beyond a tiny niche, and (c) scope discipline on judgment calls.
4. **TAM is real but not a giant, and GC owns the consumer layer.** The business case rests on
   capturing an underserved *paying* slice, not on out-distributing GameChanger to free parents.
5. **Incumbent counter-move is the live risk.** GC demonstrated voice in basketball; if Diamond
   Ledger gains visible traction they could extend it. The defense is the part GC won't copy:
   official-grade accuracy + open Retrosheet output for a user they don't serve.

## 8. Open questions → hand off to assumption tests

- **Q1 (riskiest):** Will enough serious/official scorekeepers switch to and *pay for* voice-driven,
  Retrosheet-grade scoring to form a viable beachhead? → A1/A9 below.
- **Q2:** Is Retrosheet export valued by travel/HS/college buyers, or only by the SABR niche?
  (E10, confidence L) → A3.
- **Q3:** Does the confirm/correct loop for the ~15% judgment plays stay fast enough not to
  recreate the attention problem it's meant to solve? → A5.
- **Q4:** At what level (rec → travel) does WTP appear, and at what price? → A9.
- **Q5:** Can a scoped v1 hit play-parse accuracy a serious scorer will trust on a real, noisy
  game? → A6/A7.
