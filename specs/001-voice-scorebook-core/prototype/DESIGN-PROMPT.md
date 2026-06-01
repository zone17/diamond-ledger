# Design Prompt — paste this into Claude Design

*Self-contained. Produces the interactive Wizard-of-Oz prototype of the judgment-play loop.*

---

You are designing a **high-fidelity, interactive mobile prototype** for **Diamond Ledger**, a
voice-driven baseball scorekeeping app. Build it as a **single self-contained React artifact**
(mobile viewport, portrait, no backend, no external assets) that I can click through immediately.

## The product, in one breath
A serious baseball scorekeeper watches the game and, after each play, **speaks** what happened
("ground ball to short, threw him out at first"). The app records it in proper scorebook notation
and keeps the official book — so the scorer can **watch the game instead of staring at a screen.**

## What you are prototyping (and ONLY this)
The **capture → read-verify → confirm/correct loop for one half-inning**, including the handful of
**scorer-judgment plays** the app must NOT decide on its own. This is a **Wizard-of-Oz** rig: there
is no real speech engine — a hidden facilitator control drives what the "engine understood." Do not
build ASR, accounts, or anything else.

## The ONE design problem to solve
**The scorer's eyes belong on the field, not the phone.** Every screen must be *glanceable* — read
in under a second, operated with one thumb without looking. Success is measured as: **median
eyes-on-screen ≤ 3 seconds per play**, ≥80% of plays handled in **one tap**, judgment calls
resolved in **≤5 seconds**. Design for the glance, not the gaze.

## The two moments that must look and feel DIFFERENT
1. **Deterministic play (~85%) — "here's what I got."** The engine is confident. Show a calm,
   dismissable confirmation: a big plain-language restatement ("Ground out, short to first — 6-3"),
   the state change ("1 out → 2"), and **one primary tap: Confirm** (Correct is secondary).
   It should be confirmable almost without reading.
2. **Scorer-judgment play (~15%) — "this one's your call."** The engine **refuses to decide** (hit
   vs. error; earned vs. unearned). This is the *only* moment that legitimately asks for attention,
   so make it **unmistakably different in posture** — not merely a different color. Show: the
   question ("Hit or error?"), the engine's **recommendation with one line of why** (a *suggestion*,
   never a pre-made choice), and the **alternatives as equally tappable options**, resolvable in one
   tap. Earned/unearned must allow an explicit **"Leave pending — decide later."** This honest
   "I won't guess this" is the soul of the product — make it feel trustworthy, not naggy.

## Screen anatomy
- **Glanceable game-state HUD** (top, persistent): inning ▲/▼, outs as filled dots, a **bases
  diamond** (occupied bases filled), the count (B–S), a compact line score, due-up batter. One-second
  legibility is the whole point.
- **Hold-to-talk button** (bottom, thumb zone): idle → listening (held) → processing → result.
- **Result card** (center): renders card A or card B per above; collapses into the running book.
- A subtle **scorebook strip** (the plays so far in this half-inning, in notation) so the scorer
  trusts the book is accruing.

## Produce THREE variants of the judgment moment (card B)
Because it's the make-or-break interaction, show it **three ways** on a variant switcher:
- **V1 — Decision sheet:** a bottom sheet with the question + two big choices + recommendation.
- **V2 — Inline two-tap toggle:** the call resolves in-line on the card with a prominent recommended
  default that still requires a deliberate tap.
- **V3 — Glance card:** the most minimal, largest-target version optimized purely for ≤5s eyes-down.
Keep card A (deterministic) consistent across all three.

## Wizard-of-Oz facilitator control (hidden from the test subject)
Add a discreet facilitator drawer (e.g. a long-press on the HUD, or a `?woz` toggle) listing the
scripted plays below. The facilitator taps the play the scorer just spoke → the subject's screen
renders the matching card. Include a "didn't catch that" trigger that shows a **clarify/re-prompt**
(never a guess). If trivial, log taps + a per-play timer for the A5 metrics.

## The scripted plays to wire in (real, rules-valid — use verbatim, invent no stats)
Top 1st: **6-3 ground out** (det) · **K swinging** (det) · **S7 single to left** (det) · **bobbled
grounder, safe at first → HIT vs ERROR judgment**, recommend *Error (E6)* (judgment) · **flyout to
center, 8** (det, side retired). Bottom 1st: **walk** (det) · **double, runner to 3rd, D7.1-3** (det)
· **throwing error scores a run → EARNED vs UNEARNED judgment**, recommend *Leave pending* (judgment)
· **fielder's choice, out at home → contested credit, confirm fielders** (judgment). Plus one
**ambiguous/"mumbled"** trigger → clarify card.

## Design-quality bar (this is the part most AI UIs fail)
- **Earn every element.** No decorative gradients, no generic SaaS card-shadow soup, no emoji as
  icons, no filler. Restraint is the aesthetic.
- **Real typographic hierarchy** — the glance reads in one fixation; notation is secondary, never
  competing with the plain-language line.
- **A considered, sporty-but-serious palette** — this is an *official* book a college scorer trusts,
  not a toy. Dark-field-friendly (people score outdoors/at dusk); ensure AA contrast.
- **Purposeful motion only** — calm entrances; nothing pulses except an unresolved judgment.
- **Big thumb targets, one-handed** — assume the user is not looking at the screen.
- **No fabricated numbers anywhere** — only the scripted content above.
- Aim for "a serious scorekeeper's tool, designed with restraint," not "an AI demo."

## Output
A single runnable React artifact: the live scoring screen, the hold-to-talk flow, cards A and B with
the **three V1/V2/V3 judgment variants** behind a switcher, the correction affordance, and the hidden
Wizard-of-Oz drawer driving the scripted plays. Start on the top of the 1st, due-up batter, 0 out.
