<div align="center">

# ⚾ Diamond Ledger

### Speak the game. Capture every play.

**An agent-native voice scorebook** — say what you saw, and a deterministic engine keeps a
complete, *official* baseball scorebook in [Reisner](https://www.reisnerscorekeeping.com/how)
notation and exports a [Retrosheet](https://www.retrosheet.org/)-compatible event file.
You watch the game; the book keeps itself.

<br/>

[![CI](https://github.com/zone17/diamond-ledger/actions/workflows/ci.yml/badge.svg)](https://github.com/zone17/diamond-ledger/actions/workflows/ci.yml)
![Stage](https://img.shields.io/badge/stage-pre--build%20(spec)-yellow)
![Method](https://img.shields.io/badge/method-Spec--Kit%20%2B%20Compound%20Engineering-blue)
![Scoring](https://img.shields.io/badge/notation-Reisner-brightgreen)
![Export](https://img.shields.io/badge/export-Retrosheet-brightgreen)
![Governed by](https://img.shields.io/badge/governed%20by-constitution%20v1.0.0-purple)

<sub>Private repository · greenfield · agents and humans are equal first-class users</sub>

</div>

---

> [!IMPORTANT]
> **Status: pre-build.** No app or engine exists yet. The thinking is done and sharp; the build
> is deliberately **gated on a demand experiment** (the A1/A3 smoke-test must clear **≥8% commitment
> by 2026-07-31** — see [discovery](docs/product/discovery/00-discovery-brief.md)). This repo is
> currently a *specification and governance* artifact. We write the spec before the code on purpose.
> Estimates in the product docs are labeled as estimates; nothing here is a shipped metric.

## The one-minute version

For over a century, keeping score has cost the scorekeeper the one thing they came for — the game
itself. Tap-based apps replaced the pencil but not the problem: eyes still glued to a screen, every
pitch. Diamond Ledger removes the screen from the moment.

You watch the play, then describe it the way you'd tell a friend:

> *"Ground ball to short, threw him out at first."*

A **deterministic scoring engine** — not a guess — applies the official rules: it assigns the hit or
error, advances the runners, charges the runs, and renders the play in standard Reisner notation.
It shows you the result for a one-tap confirm or correction, and exports a file that drops straight
into the tools professional scorers and SABR researchers already use.

The same engine produces a tee-ball parent's keepsake book **and** a college statistician's official
record — *the same kind of artifact*, at different levels of formality.

## Why this is hard — and why now

Two capabilities became deployable only in **late 2024 → 2025**, and did not exist in 2021:

- **On-device speech recognition** at usable accuracy in noise (WhisperKit, Apple SpeechAnalyzer) —
  low power, runs offline.
- **On-device, grammar-constrained function calling** — turns a freely-spoken sentence into a
  *structured, schema-valid* scoring event with no malformed output.

Pair them with a **push-to-talk** design (speak *after* each play, not continuous listening) and the
hardest problems — crowd noise, battery, and minors'-audio privacy — are solved by architecture, not
hope. The 5-year feasibility gap is categorical, not marginal.

## The architecture in one diagram

```
            ┌─────────────────────────────────────────────────────────────┐
  spoken    │   PROBABILISTIC INTERPRETER         DETERMINISTIC ENGINE      │   official
  play  ──► │   (on-device ASR + grammar-    ──►   (rules · runner advance · │ ─► scorebook
  "6-3"     │    constrained NL→event)             earned runs · notation)   │   + Retrosheet
            │            │                               │                    │
            │            └────────── read · verify · correct ◄────────┐      │
            └─────────────────────────────────│──────────────────────│──────┘
                                               ▼                      ▼
                            human one-tap confirm/correct   agent / API / CLI
                            (the ~15% scorer-judgment        (identical effect,
                             plays are NEVER auto-resolved)    same primitives)
```

The interpreter is allowed to be probabilistic; **the rules engine is the source of truth.** Anything
genuinely ambiguous — hit vs. error, earned vs. unearned — is surfaced for a human (or authorized
agent) decision and is *never silently auto-resolved*. That discipline is what makes the book
trustworthy enough to call "official."

## Agent-native by construction

Diamond Ledger is **not a UI-first app with AI bolted on.** It is a graph of small, permissioned,
discoverable primitives where **humans and agents are equal first-class users**. Every action a
human can take in the app, an agent can take through the same contract:

| Primitive | What it does |
|---|---|
| `record_play` | Interpret a spoken/structured play → rules-correct event + Reisner notation |
| `advance_runner` | Deterministic runner advancement; surfaces ambiguous advances |
| `correct_event` | Amend a prior play; recompute downstream state; **preserve history** |
| `finalize_scorecard` | Close the game → human scorebook + Retrosheet export |

This is mandated by the [engineering constitution](.specify/memory/constitution.md), Article II
(agent-native parity).

## Who it's for

The **beachhead is the serious / official scorekeeper** — travel/select, high-school, and college
statisticians, and Retrosheet/SABR archivists. They already pay for scoring tools, are badly served
(frustrating UX, no industry-standard export), and are the exact user the dominant incumbent
structurally ignores. The rec/tee-ball parent is the *expansion* market and the product's emotional
origin — not the launch wedge. The reasoning is in
[discovery](docs/product/discovery/00-discovery-brief.md).

## How we build — Spec-driven, inside a compound loop

Roughly **80% planning / review, 20% code.** Non-trivial work flows through versioned artifacts,
never ad-hoc prompting:

```
constitution → /speckit.specify → /speckit.plan → /speckit.tasks → /speckit.implement
        └──────────────  Brainstorm → Plan → Work → Review → Compound  ──────────────┘
                            (knowledge compounds back into the next loop)
```

- **[Spec Kit](https://github.com/github/spec-kit)** gives the spec → plan → tasks → implement spine.
- **Compound Engineering** captures every non-obvious learning into `docs/solutions/` so the team
  (human + agent) gets faster over time.
- The whole thing is governed by a **40-article [constitution](.specify/memory/constitution.md)** —
  architecture, agent behavior, security, testing, evaluation, branch discipline, and a 25-point
  definition of done. It is the highest authority in the repo.

## Project map

| Path | What lives there |
|---|---|
| **[`.specify/memory/constitution.md`](.specify/memory/constitution.md)** | The binding constitution — **start here.** Governs all work. |
| [`docs/product/PR-FAQ.md`](docs/product/PR-FAQ.md) | Working-backwards PR/FAQ (the vision, future-dated) |
| [`docs/product/discovery/`](docs/product/discovery/) | Research synthesis, opportunity map, assumption tests, the sharp bet |
| [`docs/product/experiments/`](docs/product/experiments/) | Pre-registered falsification experiments (the build gate) |
| [`specs/001-voice-scorebook-core/`](specs/001-voice-scorebook-core/) | The first feature spec — the voice-to-scorebook core |
| [`DECISIONS.md`](DECISIONS.md) | Architectural decision records (ADRs) |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Workflow, branch discipline, CI, one-time hook setup |
| [`docs/solutions/`](docs/solutions/) | Documented solutions & patterns (the compounding knowledge base) |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | CI: governance · branch-name · secret-scan · hooks-test |

## Roadmap (honest scope)

**v1 — prove one hard thing:** *a spoken sentence can become an official scorebook a serious
scorekeeper would trust.* Full consumer mobile app, **iOS first** (Android fast-follow), on-device &
offline, push-to-talk, one-tap confirm/correct, reduced-but-valid Retrosheet export.

**Deliberately *not* in v1:** live video streaming · recruiting/social · camera/computer-vision
scoring · sports other than baseball · full league/tournament management · wearables · full earned-run
counterfactual reconstruction (MLB Rule 9.16). The system's job is to *know which ~15% of plays it
must ask about*, not to fake certainty.

**Later:** softball (the planned second sport), full Rule 9.16 reconstruction, the parent/keepsake
expansion tier.

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) and the [constitution](.specify/memory/constitution.md)
first. The non-negotiables:

- **Branch discipline (Article XVIII):** never commit or push to `main`. Branch as
  `{type}/{squad}/{ticket}-{slug}` (or the Spec Kit `NNN-feature` form) and land via PR.
- **First clone, one-time setup:**
  ```sh
  git config core.hooksPath .githooks   # ADR-0004: blocks commits to the default branch
  ```
- **After any push / PR / merge:** run `/watch-ci`.
- **Architectural change?** Append an ADR to [`DECISIONS.md`](DECISIONS.md) (Article XXXVIII).

## License

No license is set yet — **all rights reserved** until one is chosen. Note that the *Retrosheet*
format is openly licensed and implemented to spec; we license nothing to read or write it.

---

<div align="center">
<sub>Built spec-first. Governed by a constitution. Designed so an agent can keep the book as well as you can.</sub>
</div>
