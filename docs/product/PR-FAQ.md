# Diamond Ledger — PR/FAQ

> Working-backwards document. Future-dated and written as if already launched. Its job is
> to expose weak thinking before code is written, not to market a decided idea. Per the
> constitution's North Star: *can someone use this for something we never imagined?*
>
> **Revised 2026-06-01 after discovery** (`docs/product/discovery/`): verdict was REFINE. The
> product and problem held; the *beachhead* moved from the tee-ball parent (low willingness-to-pay,
> owned by the incumbent) to the under-served **serious/official scorekeeper**. TAM corrected down,
> rivals named (Pocket Blue), "why now" dated, and v1 scope locked. The riskiest assumption and its
> falsification condition live in `discovery/00-discovery-brief.md`; experiments to run it are in
> `docs/product/experiments/`.

## Assumptions I made

The idea was well-specified; these are the concrete details I invented so the draft is
real enough to argue with. Correct anything that's off.

- **Name & tagline:** the product is **Diamond Ledger** — *"Speak the game. Capture every play."*
  The paid tier for leagues, schools, tournaments, and professional organizations is
  **Diamond Ledger Pro**.
- **Launch date / place:** Opening Day window, **March 26, 2027**, datelined Cooperstown, NY.
- **Pricing:** **Diamond Ledger** is free for individuals/parents and a single team (with
  low-cost personal and team add-ons); **Diamond Ledger Pro** is the paid tier for *multi-team*
  organizations only — leagues/districts, school athletic departments, tournament operators, and
  professional organizations (site-license). Freemium is the adoption wedge.
- **Incumbent comparison:** GameChanger / iScore as the tap-on-every-pitch status quo.
- **TAM math, unit economics, and risk estimates** in the Internal FAQ are my own
  back-of-envelope figures, clearly framed as estimates.
- **Notation:** I treat the **Reisner** scoring notation and the **Retrosheet** event-file
  format as the two industry standards you named, used respectively for the human-readable
  scorebook and the machine-readable official record.

---

## Press Release

**Diamond Ledger Announces the Voice Scorebook That Lets Anyone Keep an Official Baseball
Scorebook Just by Talking**

**Speak the game. Capture every play.**

*Speak naturally, and Diamond Ledger turns the game into a complete, accurate scorebook
automatically — for everyone from a parent at a tee-ball game to a professional official scorer,
so you can watch the game instead of scoring it.*

COOPERSTOWN, NY — March 26, 2027 — Today Diamond Ledger launched a mobile app that turns
spoken play-by-play into a complete, accurate baseball scorebook automatically. You say what
you saw — *"ground ball to short, threw him out at first"* — and Diamond Ledger records it in
proper Reisner notation, keeps the running line score, tracks every runner, batter, count,
and pitch, and exports the game as a Retrosheet-compatible event file that meets the same
standard professional scorers and analysts use. It works for a grandparent at a tee-ball game
and for a college statistician keeping the official book, and the parent tier is free.

For more than a century, keeping score by hand has cost the scorekeeper the very thing they
came for: the game itself. Scoring a single game means learning an arcane notation, tracking
a dozen moving facts at once, and keeping your eyes and pencil on the page during the exact
moments your kid is at the plate. A scorer who looks up to watch a play risks an error or a
gap in the book; a scorer who keeps the book misses watching their child play. The finished
scorebook is then trapped on paper — it can't be shared with the family that couldn't attend,
checked against the official record, or turned into the season stats a coach or recruiter
needs. The leading scoring apps replaced the pencil with a screen but not the problem: they
still demand a tap on every pitch and every play, so the scorekeeper is still staring at a
device instead of the field.

Diamond Ledger removes the screen from the moment. You watch the play, then describe it in
plain language the way you'd tell a friend. A deterministic scoring engine — not a guess —
applies the official rules: it assigns hits and errors, advances runners, charges earned and
unearned runs, and renders the play in standard notation, then shows you the result so you can
confirm or correct it in one tap. Because the same engine produces both the human scorebook
and the Retrosheet event file, a tee-ball parent and a professional scorer are keeping the
*same* book at different levels of formality — the casual scorer gets a clean, shareable
record, and the official scorer gets a file that drops straight into the industry's standard
tools. Mishear a play? Say *"correction"* and fix it; the book preserves the history rather
than silently rewriting it.

"I built Diamond Ledger because I spent my son's entire baseball life — tee-ball through
college — with my head down in a paper scorebook, scoring the game instead of watching him
play it," said the founder of Diamond Ledger. "We made one engine that's correct enough for a
professional official scorer and simple enough for a first-time tee-ball parent, so the same
spoken sentence becomes a real, official scorebook no matter who's holding the phone. The
standard is Retrosheet; the notation is Reisner; the work is done for you."

Getting started is easy. Download the app, tap **New Game**, set the lineups (or just the two
team names for a casual book), and start talking after each play. You can keep your first
scorebook in under a minute, free.

"I keep the official book for our high-school program, and I've used every app — they all want my
thumbs on the screen for every pitch, and none of them give me a file I can actually hand to a
college coach or the league," said Dave Russo, a varsity baseball official scorer in Columbus, OH.
"Now I just say the play. The book is right, the judgment calls stop and ask me, and I export a
clean Retrosheet file in one tap. For the first time I'm watching the game I'm scoring."

To keep your first scorebook free, visit diamondledger.app.

\# # #

---

## Frequently Asked Questions

### External FAQ (customer- & press-facing)

**Q: What is Diamond Ledger and how does it work?**
A mobile app that turns spoken play-by-play into a complete baseball scorebook. After each
play you describe what happened in natural language. The app transcribes your speech, a
scoring engine interprets it against the official rules of baseball scoring, and it records
the result in standard Reisner notation while maintaining the full game state — count, base
runners, outs, line score, batting order, pitch sequence. It shows you what it recorded so you
can confirm or correct before the next play. At any point you can export the game as a
Retrosheet-compatible event file.

**Q: Do I have to know how to keep score?**
No. That's the point of the free parent tier — you describe plays in plain English and the app
handles the notation. If you *do* know how to score, the official tiers expose the full
notation, scorer's-judgment controls (hit vs. error, earned vs. unearned), and the Retrosheet
export.

**Q: What does it cost?**
**Diamond Ledger** is free for individuals — keep a complete scorebook for your own viewing and
sharing, the parent/keepsake wedge. A low-cost **personal upgrade** adds season stats and
multi-game history; a low-cost **team add-on** lets a single travel/select or high-school team
share rosters and a season book without stepping up to an organizational plan.
**Diamond Ledger Pro** is the paid tier for *multi-team organizations* — leagues and districts,
school athletic departments, tournament operators, and professional organizations. It adds
official-scorer controls (hit/error and earned/unearned judgment), verified Retrosheet export,
bulk roster and multi-team management across an org, and priority support, sold as a site
license. All pricing is an initial estimate and will be validated before launch.

**Q: What is "Retrosheet-compatible" and why does it matter?**
Retrosheet is the open, industry-standard event-file format used by professional analysts, SABR
researchers, and official scorers to record play-by-play. Producing a valid Retrosheet file means
a Diamond Ledger game is not a proprietary scribble — it can be checked, archived, and analyzed
with the same tools the pros use. It's what makes a tee-ball parent's book and a college official
book the *same kind of artifact*.

**Q: What platforms does it support?**
iOS and Android at launch. The scorebook syncs to a web view for sharing. Voice scoring is
designed to work offline for a full game (ballparks have poor connectivity) and sync when a
connection returns.

**Q: Does it record audio? How is my data and my child's data handled?**
Voice is processed to extract the play and is not retained as a stored recording by default.
Scorebooks belong to the account that created them and are shared only when you choose to share.
Youth data is handled under a children's-privacy policy (COPPA-aligned) with parental
consent — see the Internal FAQ risk on regulatory compliance.

**Q: How do I get support, and what if it scores a play wrong?**
Every recorded play is shown for one-tap confirmation or correction before the next play, and any
prior play can be corrected after the fact with the history preserved. In-app help and email
support are included on all tiers; official tiers add priority support.

### Internal FAQ (the hard questions)

**Customer & demand**

**Q: Who exactly is the customer — and where do we START?**
The long-term vision serves one ladder from tee-ball to pro, but discovery (see
`docs/product/discovery/`) corrected the **beachhead**. We start with the **serious/official
scorekeeper** — travel/select and high-school/college statisticians, and Retrosheet/SABR
archivists — because they *already pay* for scoring tools (iScore), are badly served (frustrating
UX, no industry-standard export), and are a user the dominant incumbent structurally ignores.
That segment scores highest on the under-served opportunities — accuracy/officialness and
Retrosheet portability — and validates that the engine is genuinely correct.

The **youth/recreational parent** remains the largest segment and the emotional origin of the
product, but is the *expansion* market, not the entry wedge: they have the lowest willingness to
pay and are owned today by GameChanger's free tier plus DICK'S retail distribution. We earn the
parent *after* the engine is proven by the people who keep the strictest books. Buyer by tier:
official scorer / statistician (beachhead) → travel-team manager → athletic department/league →
parent (expansion).

**Q: What proof do we have they have this problem, and would they change behavior to adopt?**
Three independently-sourced signals (discovery research, confidence H): (1) the attention pain is
*competitor-validated* — Pocket Blue, a funded camera-based scorer, names it verbatim: *"a parent
pulls out their phone, opens a scorekeeping app, and stops watching"*; (2) the serious-scorer pain
is real and monetized — iScore is described by users as *"incredibly deep but insanely
frustrating,"* volunteer-kept youth stats are so unreliable that *"college coaches take them with a
huge dollop of salt,"* and no tool exports the industry-standard Retrosheet format; (3) demand for
paid scoring is proven at scale — GameChanger crossed ~$100M revenue in 2024. **The nuance
discovery added:** that proven willingness-to-pay lives mostly with *serious* users, not the free
parent. So we ask the smaller behavior change (talk instead of tap) of the segment that *already
pays and is under-served*. Open question still to test: whether Retrosheet/official export is
valued beyond the small SABR niche (our riskiest assumption — see `docs/product/discovery/`).

**Q: How will we test and measure success?**
Pre-launch: a scoring-accuracy eval suite — spoken plays (clean and adversarial: accents, noise,
ambiguous plays) measured against a gold-standard human-scored Retrosheet file, with hit/error
and earned-run judgment graded separately. Launch metrics: games completed without abandonment,
correction rate per game (lower is better), free→Pro conversion, and at least a handful of
official scorers willing to keep a real official book on it.

**Market & economics**

**Q: What is the TAM? (corrected by discovery — show the math)**
The honest market anchor: **GameChanger crossed ~$100M revenue in 2024** (9M+ users, 750K+
baseball/softball teams) — that figure ≈ the *entire current US monetized* youth scorekeeping +
streaming market, and the incumbent owns most of it. So:
- **US category TAM** (all $ spent today): **~$100–130M/yr** (GameChanger ~$100M + iScore/others
  ~$10–20M + TeamSnap overlap). Baseball participation that backs it: 16.7M total US (2023),
  ~4.5–5M organized youth, 472,598 HS players (~16,000 programs), ~1,600 college programs.
- **US + softball:** ~$110–160M/yr (fast-pitch adds ~344,952 HS girls + youth).
- **Global:** real but heavily discounted (non-US payment/app-store economics are 60–80% weaker) —
  a defensible **~$200–250M/yr**, *not* the $300–500M my first draft guessed.

Crucial distinction discovery forced: our near-term target is **not** the category TAM but the
**serviceable serious-scorer SAM** — ~16,000 HS + ~1,600 college + tens of thousands of serious
travel teams + the Retrosheet/archivist community. Smaller, but monetizable and defensible because
the incumbent ignores it. Big enough to matter; not a winner-take-all giant — and we are not
trying to out-distribute GameChanger for free parents.

**Q: What are the unit economics and gross margin?**
This is SaaS with one real variable cost: speech-to-text plus the inference that parses a
spoken play into a structured event. A 2–3 hour game is on the order of 80–300 plays; at an
estimated $0.20–$1.00 of inference per game and ~40–60 games/active scorer/year, variable cost is
roughly **$10–40/year** against subscription prices anchored by the market (iScore ~$20/yr;
GameChanger Team Pass $239–$449/season; our serious-scorer/Pro pricing in between) — a target
**gross margin near 80%**, typical for SaaS. Critically, the **push-to-talk + on-device**
architecture discovery validated does most transcription on-device, pushing margin higher and
supporting the offline requirement. Upfront investment is the scoring-rules engine and the parsing/eval harness
(the core IP), not infrastructure scale.

**Competition & approach**

**Q: What do customers use today and why are we meaningfully better?**
- **GameChanger** (DICK'S) — dominant, but **tap-based by deliberate design** (its 2024 redesign
  optimizes "fewer taps"), **closed** (no public API, **no Retrosheet export** — data gravity is
  its business model), and its voice feature is **basketball-only** by choice because baseball's
  50+ event codes are hard. Its moat is retail distribution + streaming + parent network, *not*
  scoring depth.
- **iScore** — power-user tap scoring, *"incredibly deep but insanely frustrating,"* and has
  shipped **no Retrosheet export in ~8 years** despite community requests.
- **Pocket Blue** — a funded **camera/computer-vision** scorer (different modality); validates the
  attention problem but is mount-dependent, produces counts not a full book, and has no Retrosheet.
- **Paper** — free, error-prone, trapped on the page.

Discovery confirmed (confidence H) that **no voice-driven baseball scoring that yields an official,
Retrosheet-exportable book exists anywhere** — app store, funded startups, or open source. Our
differentiation is therefore *not "voice" alone* but **official-grade accuracy + open Retrosheet
export, delivered attention-free** — precisely the combination the incumbent has chosen not to
build for a user it doesn't serve. We deliberately do *not* compete on streaming/network/recruiting
(GameChanger's moat) — see scope below.

**Q: Should we build, buy, or partner?**
**Build** the two things that are the moat: the deterministic baseball-scoring rules engine and
the natural-language-to-event parser plus its eval harness. **Buy/partner** commodity
speech-to-text (use a best-in-class ASR rather than train our own). **Implement to an open
standard** for Retrosheet (the format is public) rather than license anything.

**Feasibility & dependencies**

**Q: What new capability must we create that hasn't been done reliably before?**
Conversational, official-grade scoring: mapping a freely-spoken sentence to a structured,
rules-correct scoring event, in a noisy live environment, accurately enough that a professional
would trust the book. The defensible architecture is exactly the one this repo's constitution
already mandates — a **deterministic scoring engine** (rules, runner advancement, earned-run
logic, notation) wrapped around a **probabilistic interpreter** (speech → candidate event), with
a **read-verify-correct loop** so the human confirms anything ambiguous. The agent is the
interpreter; the rules engine is the source of truth. Atomic primitives (`record_pitch`,
`advance_runner`, `correct_event`, `finalize_scorecard`) compose into the game. That alignment
is why the feasibility risk is in the *parsing accuracy*, not the scoring correctness.

**Why now (discovery-confirmed, confidence H).** This stack became deployable only in **late
2024–early 2025** and did not exist in 2021: on-device ASR at <15% WER in noise (WhisperKit, ICML
2025, ~0.3W per inference on the Apple Neural Engine; Apple's native SpeechAnalyzer at WWDC 2025)
*plus* on-device, grammar-constrained function calling (e.g. FunctionGemma 270M, Dec 2025;
Outlines/XGrammar constrained decoding that eliminates malformed output). A **push-to-talk**
design — speak after each play, not continuous listening — sidesteps the hardest crowd-noise case
and resolves the battery and privacy/COPPA concerns by architecture. The 5-year gap is categorical,
not marginal.

**Q: What does it depend on?**
A reliable ASR provider; a complete, tested encoding of the official scoring rules and the
Retrosheet spec; mobile offline storage and sync; and a gold-standard scored-game dataset to
evaluate against (partnering with a few real scorers/SABR-adjacent volunteers is the cheapest way
to get one).

**Risk & scope**

**Q: What are the top three reasons this could fail?**
1. **Accuracy of judgment calls erodes trust.** Baseball scoring contains genuine
   scorer's-judgment decisions (hit vs. error, earned vs. unearned, who gets the putout). If the
   app silently gets these wrong, the "official, Retrosheet-compatible" promise — the whole value
   ladder — collapses for the very segment that validates it. Mitigation: deterministic rules
   engine, explicit human confirmation on judgment plays, never auto-resolve ambiguity silently.
2. **Voice doesn't survive the ballpark.** Crowd noise, wind, accents, and natural (non-scripted)
   phrasing may push transcription/parse accuracy below the threshold where talking beats tapping.
   Mitigation: constrained grammar + clarifying re-prompts, the one-tap confirm loop, and an
   honest fallback to quick manual entry. This must be proven in real stands before launch.
3. **Incumbent lock-in and single-keeper economics.** GameChanger's value is partly network
   effects (the whole league is on it, families watch there). A better *book* may not overcome a
   better *network*. Mitigation: win on the wedge incumbents can't easily copy (attention-free
   voice + true official export), start with the keepsake parent who has no network to leave.

**Q: What legal/regulatory concerns exist?**
**Children's privacy (COPPA)** is the material one: youth-sports data involves minors and
requires verified parental consent, data-minimization, and careful handling — non-negotiable and
designed in from the start (it's a hard gate, not a feature). Audio capture in public venues and
recording-of-minors norms must be respected (process-don't-store by default). Standard SaaS
privacy/ToS otherwise.

**Q: What are we explicitly NOT doing in v1?**
- **No live video streaming** to family (the incumbent's core network feature).
- **No recruiting marketplace or social network.**
- **No automatic camera/computer-vision scoring** — voice is the input; auto-tracking from video
  is a different, much harder product (and Pocket Blue's lane).
- **No sports other than baseball** at launch — softball is the planned second sport, not v1.
- **No full league/tournament management** (scheduling, brackets, umpire assignment).
- **No wearables or sensor hardware.**

**Scope locks discovery added (the part that keeps v1 shippable):**
- **Score the deterministic ~85% automatically; surface the ~15% scorer-judgment plays (hit vs.
  error, earned vs. unearned) as one-tap confirmations.** Never silently auto-resolve a judgment
  call — that's the failure mode that destroys trust. The system's job is to *know which plays it
  must ask about*, not to pretend certainty.
- **Ship a reduced-but-valid event format first** (play type + fielder sequence + result, covering
  ~95% of amateur plays); defer full **earned-run counterfactual reconstruction** (Rule 9.16,
  ~3–6 months of engine work) and the most exotic Retrosheet modifiers to a later release.
- **Push-to-talk, on-device, offline-first** — not continuous listening.

The point of v1 is to prove one hard thing: *a spoken sentence can become an official scorebook
a serious scorekeeper would trust.* Everything above is deferred until that is true.

---

*Next step in the methodology: discovery says **REFINE, then test before build.** Run the two cheap
experiments first (`docs/product/experiments/`): the A5 Wizard-of-Oz usability test (~2 wks) and the
A1/A3 demand smoke-test (~6–8 wks), in parallel. Only if the riskiest assumption clears its
falsification threshold (≥8% commitment by 2026-07-31) does the first capability go through
`/speckit.specify` — the smallest missing primitive (likely `record_play` → `advance_runner` →
`finalize_scorecard`) shaped by the constitution's contract-first and agent-native rules. If it
fails, pivot (e.g. an archivist score-from-video tool) or kill.*
