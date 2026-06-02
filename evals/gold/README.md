# evals/gold

Gold-standard game dataset for field-accuracy evaluation (T005, T064, T065 — Squad C).

## Purpose

This directory holds one or more **fully coupled gold games**: a real baseball game
for which we have all three of:

1. **Audio** — narrated play-by-play recording.
2. **Hand-scored Reisner** — produced independently by a trained scorer.
3. **cwevent-clean Retrosheet event file** — independently hand-produced and
   verified against the pinned Chadwick `cwevent` v0.10.0 gate.

When all three are present for a game, running evals/runners/accuracy.sh against
it measures **field accuracy** (SC-001 >= 90% play-type accuracy, SC-002 >= 85%
Reisner token accuracy) — not self-consistency.

## Honesty caveat

> **Self-consistency vs. field accuracy — a hard distinction.**
>
> Until at least one real gold game is present in this directory AND wired into
> evals/runners/accuracy.sh (H3 handoff complete), every accuracy metric produced
> by the eval harness is **self-consistency (advisory)** — the system scoring its
> own output against itself.
>
> Self-consistency results MUST be labeled "(self-consistency, advisory — not field
> accuracy)" in any report, dashboard, or PR comment.  They become credible only
> once this directory contains a game with independent human ground truth.
>
> Published Retrosheet .EVN files are used as **export-conformance / cwevent
> regression fixtures only** (evals/retrosheet-fixtures/).  They are NOT gold games:
> they have no audio source and represent professional play, not the amateur/serious-
> scorer beachhead this system targets.

## Primary path (D6 — fully in our control)

Pick an MLB game with a published Retrosheet .EVN:

1. Capture or obtain a narrated play-by-play audio recording.
2. Hand-score the game in Reisner notation (one scorer).
3. Independently hand-produce a Retrosheet event file (second scorer or same scorer
   on a different day — must be independent of step 2).
4. Verify the produced file with `cwevent -y <yr> -n game.EVN` against the
   mandatory TEAM<yr> file; confirm zero stderr warnings.
5. Cross-diff the produced file against the published Retrosheet .EVN — this is a
   free third independent check.
6. Package into the eval format per evals/INTERFACE.md (T065).

## Directory layout (per game)

```
evals/gold/
  <YEAR>-<HOME>-<AWAY>-<DATE>/
    audio/          # play-by-play recording (or transcript if audio unavailable)
    reisner/        # hand-scored Reisner notation
    retrosheet/     # independently produced .EVN + mandatory TEAM<yr>
    meta.json       # game metadata (date, teams, scorer identity, cwevent verdict)
```

## Related

- `evals/runners/accuracy.sh` — accuracy runner (T042); advisory until this dir is populated
- `evals/INTERFACE.md` — gold-game format contract (T010)
- `evals/retrosheet-fixtures/` — conformance fixtures (separate from gold)
- `specs/001-voice-scorebook-core/research.md` D6 — sourcing strategy
- `specs/001-voice-scorebook-core/tasks.md` T064, T065 — Squad C work items
- SC-001 (>= 90% play-type accuracy), SC-002 (>= 85% Reisner token accuracy)
