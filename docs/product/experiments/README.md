# Diamond Ledger — Experiment Kit

*Ready-to-run assets for the discovery falsification tests. Status: **NOT YET RUN** — these are
pre-registered designs + assets; execution requires real customers (recruiting, ad spend, a hosted
page, a Stripe deposit). Pre-registration date: 2026-06-01.*

These experiments test the discovery bet (`docs/product/discovery/`). Pass/fail thresholds are
registered **here, before running** — do not move the goalposts after seeing data (the cardinal
experiment anti-pattern).

> **Status change — these are now a PARALLEL INSTRUMENT, not a hard build gate ([ADR-0006](../../../DECISIONS.md)).**
> Originally A1/A3 gated the build. The project lead overrode that gate (founder-conviction bet +
> fake-door false-negative risk): the v1 build is authorized to proceed **ahead of** these results.
> The experiments still run **in parallel** as a monitored instrument with **pre-committed tripwires**
> — a threshold miss triggers an explicit *continue / redirect / pause* decision (per ADR-0006), not an
> automatic stop. Running them remains worthwhile: willful blindness is strictly worse than parallel
> measurement, and the demoable build slice is itself a stronger demand signal than the fake-door.

## What we're testing & why

| Exp | Assumption | Risk type | Why it's first |
|---|---|---|---|
| **A1/A3** | Serious/official scorekeepers will *switch to and pay for* voice→Retrosheet scoring; Retrosheet/official export is valued beyond the SABR niche | Desirability + Viability | **The single riskiest assumption.** Feasibility is already de-risked by research; the whole bet's viability rests here. |
| **A5** | The ~15% judgment-play confirm/correct loop stays fast enough to *not recreate* the attention problem | Usability | Cheap (~2 wks, no engine); kills the product's core promise if it fails. |

A1/A3 measures **real behavior** (a paid deposit / signed LOI / a league intro) — not "would you
use this?" A5 measures **observed behavior** (taps, eyes-on-screen seconds) in a Wizard-of-Oz rig.

## The falsification condition (from `discovery/00-discovery-brief.md`)

> **Pivot or kill** if, by **2026-07-31**, the A1/A3 smoke-test driven to ~1,000 targeted
> serious-scorer visitors converts **< 8%** to a real commitment signal **AND** **fewer than 8 of
> 20** Mom-Test-interviewed scorers show a commitment signal.

## Run order (revised per ADR-0006 — instrument, not gate)

1. **Start both in parallel** *while the build proceeds*: A5 (Wizard-of-Oz, ~2 wks) and A1/A3
   (smoke-test, ~6–8 wks).
2. **A1/A3 no longer hard-gates engineering** (ADR-0006). Instead, evaluate results against the
   **tripwires**: a threshold miss (<8% commitment AND <8/20 interviews) → **pause net-new engine
   investment beyond the demoable slice** and weigh re-segmenting or the discovery-named pivot
   (archivist score-from-video) — an explicit decision, not an automatic stop.
3. The spec already exists (`specs/001-voice-scorebook-core/`); the build is authorized. Proceed to
   `/speckit.plan` and sequence the first artifact to be **demoable to ~20 real serious scorers** so
   the build doubles as a demand signal.

## Files

- `A1-A3-demand-smoke-test.md` — landing-page copy, fake-door/deposit spec, channel plan,
  pre-registered metrics, and the Mom-Test interview guide.
- `A5-wizard-of-oz-usability.md` — protocol, facilitator script, measurement sheet, thresholds.
- `landing-page.html` — a working static landing page for the smoke test (host + wire analytics
  and a Stripe payment link before driving traffic).
- `results-tracker.md` — pre-formatted, empty results sheet. Fill it as data arrives; it records
  the go/no-go decision.

## Honesty note (Article VI)

No results may be entered into `results-tracker.md` that were not actually observed with real
people. A fabricated pass is worse than no test — it manufactures false confidence the whole
discovery process exists to prevent.
