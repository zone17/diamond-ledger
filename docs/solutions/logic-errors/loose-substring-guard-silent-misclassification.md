---
title: A loose multi-signal guard in a safety-critical classifier produces silent wrong judgments
date: 2026-06-02
last_updated: 2026-06-02
category: logic-errors
module: ios/Sources/Parse/GrammarParser
problem_type: logic_error
component: service_object
symptoms:
  - "A dropped THIRD strike ('dropped third strike, batter reached first') surfaced a false Card B (Hit-or-Error)"
  - "A dropped FLY ball where the RUNNER was safe ('runner scored safely') surfaced a false Card B — the batter was actually out"
  - "An outfield misplay credited the shortstop (default '6') instead of the outfield position"
root_cause: logic_error
resolution_type: code_fix
severity: high
tags: [grammar, nlp, classification, substring-matching, fr-008, silent-judgment, adversarial-tests, parsing, asr, confidence, fail-safe-default, article-vii]
---

# A loose multi-signal guard in a safety-critical classifier produces silent wrong judgments

## Problem
A deterministic grammar production (`tryMisplay`) classified a play as a fielding misplay — which
surfaces the cardinal "Hit or Error?" judgment card — using two **bare substring** signals: a misplay
verb (`"dropped"`/`"booted"`/…) plus a bare reached word (`"safe"`/`"reached"`). Because both checks
were unanchored `String.contains`, transcripts that contained those substrings *in an unrelated role*
produced a **confident, silent, wrong judgment** — exactly the no-silent-judgment invariant (FR-008 /
Article VII) the system exists to protect.

## Symptoms
- `"dropped third strike, batter reached first"` → false Card B. (It's K + wild-pitch/passed-ball, not a
  fielding error on the batter — and out-of-grammar in v1.)
- `"dropped fly ball in center, runner scored safely"` → false Card B. `"safely"` satisfied the bare
  `"safe"` check even though it described the **runner**; the **batter was out** on the catch.
- Outfield misplay defaulted the error fielder to shortstop (`"6"`) because only infield positions were
  consulted.

## What Didn't Work
- **Two independent signals felt sufficient.** "Require a misplay verb AND a reached word" sounds robust,
  but bare substring matching means each signal fires on unrelated tokens (`"dropped"` in *dropped third
  strike*, `"safe"` in *runner safe*). Conjunction of two loose matches is still loose.
- **The green test suite hid it.** The original tests covered the happy path and one negative ("dropped
  the throw, out at first" — no reached word), but never the adversarial transcripts where *both* signals
  appear in the wrong role. CI passed while two silent-wrong-judgment paths were live.

## Solution
Tighten the guard with **exclusion contexts** + **subject-anchored patterns**, and prove it with
**adversarial tests**:
```swift
// exclusion: dropped-third-strike is out-of-grammar in v1, not a fielding error
if s.contains("third strike") || s.contains("strike three") || s.contains("strike 3") { return nil }
// exclusion: a dropped FLY ball where someone reached is a different judgment → manual entry
if s.contains("fly ball") || s.contains("flyout") || s.contains("fly out") { return nil }
// the BATTER must specifically have reached — anchored patterns, NOT a bare "safe"/"reached"
let batterReachedAnchors = ["batter safe", "batter reached", "safe at first", "reached first", …]
guard batterReachedAnchors.contains(where: s.contains) else { return nil }
let pos = parseInfieldPosition(s) ?? parseOutfieldPosition(s) ?? "6"   // outfield fallback
```
Excluded transcripts fall through to `ParseError.outOfGrammar` (manual entry) — a *surfaced* gap, never
a silent guess.

## Why This Works
The bug was that a *bare keyword* conflates the token with its semantic role. `"safe"` can describe a
batter or a runner; `"dropped"` can mean a fielding misplay or a dropped third strike. The fix
re-introduces the missing context: subject-anchored phrases (`"batter safe"`, `"reached first"`) bind
the keyword to the batter, and exclusion guards remove the play families v1 doesn't model. The output
for an excluded case is `outOfGrammar` → the human decides, satisfying FR-008.

## Prevention
- **For any classifier whose output triggers a human judgment or an irreversible action, match on
  anchored/subject-specific patterns, not bare substrings.** A bare `contains("safe")` in a path that
  raises a scoring decision is a latent silent-wrong-judgment.
- **Write adversarial tests, not just happy-path + one negative.** The review persona that caught this
  did it by *constructing* transcripts where both signals appear in the wrong role
  (`dropped third strike … reached`, `dropped fly ball … runner safe`). Make that a standing habit:
  for each "X triggers a judgment" production, add a test where the X-tokens appear but the play is NOT X.
- **Prefer `outOfGrammar` (surface to the human) over a confident guess** whenever the signal is
  ambiguous — the cost of a manual-entry prompt is far below the cost of a silently mis-scored play.

## Generalization — fail-safe defaults at the probabilistic→deterministic seam (added 2026-06-02, DL-80)

The real-ASR work (PR #156) produced the **same failure in a different layer**, which generalizes the
rule. The transcript confidence is the FR-008 gate (`GrammarParser` surfaces a clarify only when
`confidence < 70`). iOS 26's `SpeechAnalyzer` has **no confidence API**, so confidence is *always
unmeasured* in production — and the adapter defaulted the unmeasured case to `0.80` (→ 80 ≥ 70), so
**every** transcript was stamped "confident" and parsed as a clean play. A second leg: an
`SFSpeechRecognizer` biasing pass *unconditionally overrode* the transcript (its "conservative" branch
was dead code because base confidence was always nil), able to snap audio to a lexicon/roster phrase
the speaker never said. Both are the identical bug: **the boundary's default/unmeasured case failed
*confident* instead of failing *safe*.** Fix: default the unmeasured confidence **below** the gate
threshold (0.60 → 60 < 70), so an unmeasured/uncertain signal surfaces a confirm; and don't let an
over-eager enhancement (biasing) replace the signal without a positive measurement + an agreement guard
(deferred to #157).

**The rule (this is how you implement Art. VII — "deterministic shell around probabilistic
intelligence" — correctly):** wherever an uncertain/probabilistic signal feeds a deterministic safety
gate, the **default, unmeasured, or ambiguous case must fail toward surfacing-to-the-human, never
toward confident-and-silent.** A default confidence at/above a clarify threshold, a bare-substring
match, or an unconditional "enhancement" override all violate it the same way. Pin the safe default
with a structural test (e.g. `assert defaultConfidence < clarifyThreshold`) so a future tweak can't
silently drift it back across the line.

## Related Issues
- DL-151 (PR #153) — the grammar hardening + this fix. Caught by the `/ce:review` gate's adversarial
  pass before merge. Follow-up #154 (FactBridge must map all play types, not collapse to ground-out).
- [[mock-to-real-stateful-core-swap]] and [[parallel-squad-integration]] §4 — the broader
  "green CI + unit tests ≠ correct; the review gate catches the cardinal cases" theme.
