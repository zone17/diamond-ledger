# Interaction Spec — Judgment-Play Confirm/Correct Loop

*The behavior the prototype must implement. Tech-agnostic; the design prompt turns this into a UI.*

## Screen anatomy (single mobile screen, iOS-first, portrait)

1. **Glanceable game-state HUD** (top, always visible): inning + half (▲/▼), outs (0–2 dots),
   bases (a diamond with occupied bases filled), count (B-S), line score (R-H-E per side), and the
   due-up batter. Must be readable in a <1s glance — this is what lets the scorer keep eyes on the
   field.
2. **Push-to-talk control** (bottom, thumb-reachable): a large hold-to-talk button. States: idle →
   listening (while held) → processing → result. No continuous listening.
3. **The result card** (center, appears after a play): one of the two types below.

## Card type A — Deterministic play (read-verify; the ~85%)

The engine is confident. Show what it recorded so the scorer can confirm in one tap and look back up.

- Big, plain-language restatement: *"Ground out, short to first. 6-3."*
- The Reisner notation token shown but secondary.
- Resulting state delta surfaced subtly (e.g. "1 out → 2 outs", "runner to 3rd").
- **One primary action: Confirm** (large, thumb-reachable). Secondary: **Correct** (opens the
  correction affordance). Auto-advances on confirm.
- Tone: settled, low-attention. This should be dismissable almost without reading.

## Card type B — Scorer-judgment play (the ~15%; the make-or-break)

The engine **refuses to decide**. This is the one moment that legitimately asks for the scorer's
attention, and it must be unmistakably different from card A.

- A clear "**Your call**" signal — visually distinct (not just a different color; a different posture).
- The question, stated plainly: e.g. **Hit or error?** / **Earned or unearned?**
- The engine's **recommendation** with one line of *why* (e.g. "Looked like a clean single — *Hit*"),
  presented as a suggestion, **not** a pre-made decision.
- The **alternatives** as equally-tappable choices (Hit / Error; Earned / Unearned / leave PENDING).
- **One tap resolves it.** Target: ≤5s. After the tap, it collapses into a confirmed card-A-style
  entry showing the chosen call + notation.
- **Earned/unearned may be left PENDING** (deferred) explicitly — a first-class, honest "decide later"
  (spec FR-010a). Never auto-tagged.
- It must be impossible to advance to the next play while a judgment is unresolved *without* an
  explicit choice (including the explicit "leave PENDING").

## Selected judgment-card variant — V3 (glance) *(decided 2026-06-01)*

The project lead selected **V3 (glance)** as the canonical Card-B pattern: the most minimal,
largest-target, ≤5s-eyes-down version — the most faithful to the core thesis (eyes on the field,
glanceable, one tap). **V3 is the pattern `/speckit.plan` and the v1 build carry forward.** V1
(decision sheet) and V2 (inline toggle) remain in the prototype as references / A5 comparison arms
but are not the build target.

## Correction flow (`correct_event`)

- From any recorded card, **Correct** opens a quick amend: change the play, or step back to a prior
  play in the inning.
- On correction, downstream state visibly **recomputes** (outs, bases, line score) — show that it
  re-derived, don't silently swap.
- Prior version is preserved (a small "edited" affordance / history peek). No silent rewrite.

## Ambiguity / low-confidence path (FR-008)

- If the "engine" isn't sure what was said (facilitator can trigger this), the card asks a **single
  clarifying question** or offers **quick manual entry** — it never guesses. Distinct from a judgment
  card (missing facts vs. a ruling).

## Wizard-of-Oz control surface (hidden from the test subject)

- A facilitator-only panel (e.g. swipe-in drawer, long-press a hidden corner, or `?woz` mode) listing
  the scripted plays from `scripted-plays.json`.
- The facilitator taps the play the scorer just spoke → the subject's screen renders the matching
  card (A or B). This simulates the engine with zero real ASR/parsing.
- Also expose: "trigger ambiguous re-prompt", and a per-session timer/tap log if cheap to include.

## Motion & attention rules

- Cards arrive with a quick, calm transition — enough to notice without demanding focus.
- The judgment card may use a slightly stronger entrance (it's the one that *should* pull the eye).
- Nothing animates on a loop or pulses for attention except an unresolved judgment.
- Everything one-handed/thumb-reachable. Large hit targets (the scorer isn't looking).
