# Prototype — Judgment-Play Confirm/Correct Loop

*Design input that LEADS the plan. Created 2026-06-01. Branch home: TBD (kept out of the spec PR #12).*

## What this is — and its three jobs

A high-fidelity, interactive **mobile prototype** of the single riskiest interaction in Diamond
Ledger: the **push-to-talk → read-verify → one-tap confirm/correct** loop, including the **~15%
scorer-judgment plays** (hit vs. error, earned vs. unearned) that must be *surfaced, never silently
resolved*. It is deliberately a **Wizard-of-Oz** rig — a human facilitator plays the "engine," so we
can test the *interaction* with real scorers **before any engine exists**.

It does triple duty:

1. **Design input to `/speckit.plan`.** Per 2026 practice, the interaction prototype of the risky flow
   must precede the technical plan — you can't plan screens you haven't designed. This is that input.
2. **The A5 Wizard-of-Oz usability test rig** (`../../../docs/product/experiments/A5-wizard-of-oz-usability.md`).
   Same artifact validates the loop against the A5 thresholds.
3. **The demoable slice** the build-authorization decision (ADR-0006) requires — the thing we put in
   front of **~20 real serious scorers** so the parallel A1/A3 demand instrument has something real to
   react to.

## The bar it must clear (from A5 / spec SC-005)

| Metric | Threshold |
|---|---|
| Plays captured with ≤1 spoken phrase + ≤1 tap | ≥ 80% |
| Median **eyes-on-screen per play** | ≤ 3 s |
| Median **judgment-prompt resolve** time | ≤ 5 s |
| Scorers reporting more misses than paper | 0 |
| Abandonments | 0 |

The whole design tension: **the scorer's eyes belong on the field.** The screen must be *glanceable*,
big-tap-target, and never demand reading. The judgment moment is the one place we *do* ask for
attention — so it must be unmistakable and resolvable in one tap.

## The non-negotiable principle the UI must make visible

**Never silently resolve a judgment call** (spec FR-010 / SC-003; the cardinal invariant the
spec-coherence probe broke). The UI must have two visibly different moments:
- **deterministic play** → "here's what I recorded, tap to confirm" (the engine is sure);
- **judgment play** → "**this one's your call**" with a recommendation + alternatives (the engine
  refuses to decide). The difference must be felt at a glance.

## Files

- `interaction-spec.md` — the states, the two card types, the Wizard-of-Oz control surface.
- `scripted-plays.json` — the stimulus: a real half-inning the facilitator feeds, labeled
  deterministic vs. judgment, with the expected card for each. Demo script + A5 stimulus.
- `DESIGN-PROMPT.md` — the paste-ready prompt for Claude Design to generate the prototype.
- `app/` — **the realized prototype** from Claude Design (handoff bundle). Open
  `app/Diamond Ledger.html` to click through it. Self-contained React + Babel (CDN) over local
  `data.js` / `*.jsx` / `app.css` / `fonts/`; needs a network connection only for the React/Babel
  CDN scripts. `app/HANDOFF-README.md` and `app/chat1.md` preserve the design's own notes +
  the full design conversation (provenance). *(Named `app/` not `build/` — the latter is
  `.gitignore`d for compiled artifacts.)*

## Run it

Open `app/Diamond Ledger.html` in a browser (or serve the `app/` folder, e.g.
`python3 -m http.server` from inside it). It opens on the **top of the 1st, due-up batter, 0 out**.
Hold the talk button to walk the scripted half-inning; use the right-edge handle (or long-press the
HUD) to open the facilitator drawer and switch the three Card-B judgment variants.

## How a session runs (Wizard of Oz)

1. Facilitator holds the device (or screen-shares); the scorer watches a real or recorded game.
2. After each play the scorer **speaks it naturally**. The facilitator (hidden control) selects what
   the "engine understood" from `scripted-plays.json`.
3. The UI shows the read-verify card (deterministic) or the judgment card (the ~15%). The scorer
   confirms/corrects/decides in one tap.
4. Capture the A5 metrics above. Debrief: "did you miss plays you'd have caught on paper?"
