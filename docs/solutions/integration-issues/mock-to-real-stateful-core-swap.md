---
title: Swapping a real stateful core in for a stateless mock surfaces a whole class of bugs
date: 2026-06-02
category: integration-issues
module: ios/Sources/Core + core/src
problem_type: integration_issue
component: service_object
symptoms:
  - "Play recording failed: Core.CoreError error 4 (invalidState) on the first real mic press"
  - "A prior play is unconfirmed (FR-007) after swiping a card away"
  - "Export failed / 'Something went wrong' on End Game of an in-progress game"
  - "xcodebuild: Could not resolve package dependencies (gitignored XCFramework absent)"
root_cause: incomplete_setup
resolution_type: code_fix
severity: high
tags: [h1, mock-vs-real, stateful, ffi, uniffi, ios, verification-gap, fact-schema, interactive-dismiss]
---

# Swapping a real stateful core in for a stateless mock surfaces a whole class of bugs

## Problem
The iOS app was built and tested for weeks against a **stateless** `MockCore` (canned results, ignores
its inputs, holds no state). When the real **stateful** Rust core (`DiamondCoreClient` over UniFFI,
handoff H1) was dropped in at the single injection point, a *coherent class* of failures appeared at
once — none caught by CI, unit tests, or the integration agent's own test pass; every one surfaced on
the first live human tap-through.

## Symptoms
- `Play recording failed: Core.CoreError error 4` (`invalidState`) on the very first real mic press.
- `A prior play is unconfirmed (FR-007)` on the next mic press after a card was swiped away.
- `Export failed` (generic "Something went wrong") on **End Game** of an in-progress game.
- `xcodebuild: Could not resolve package dependencies` on a fresh `main` checkout.

## What Didn't Work
- **The integration agent's headless tests passed** while the live path failed. They called the adapter
  with **idealized facts** (the WoZ format `"6-3"`) rather than the facts the **real UI path** produces
  (`StubTranscriber → GrammarParser → FactBridge` emits the concatenated `"63"`). Testing a *proxy* of
  the input, not the real input — the same "assert the real signal, not a proxy" failure as
  [[verify-generated-code-with-real-toolchain]], recurring at the integration layer.
- **Trusting "MockCore was built to mirror the contract."** It mirrored the *shapes* and the *happy
  path*, but not the real core's **statefulness** or its **stricter invariants** — which is exactly
  where the bugs lived.

## Solution
Each failure was the same root cause wearing a different hat: **iOS flows assumed statelessness; the
real core is stateful and stricter.** The fixes, by flow:

1. **Fact-schema mismatch → `CoreError 4`.** The grammar parser emits a *concatenated* fielder chain
   (`"63"`), but the FFI fact-bridge dash-split it (`"6-3"`), yielding `Position(63)` — out of range —
   which the real core rejected. Fielders are single digits; parse digit-wise:
   ```swift
   // before: parts split on "-"/" " → "63" stays one token → Position(63) ❌
   // after:  each digit is one fielder — handles "6-3", "63", "643", "6-4-3"
   let positions = s.compactMap { $0.wholeNumberValue }.filter { (0...9).contains($0) }.map { Position(UInt8($0)) }
   ```
2. **Pending-play orphaning → FR-007.** Swiping a card away reset the *UI* (`pttState`) but the real
   core still held the unconfirmed play; the next record hit `PendingConfirmation`. The real core has
   **no discard/cancel primitive** (append-only) — the only forward move is Confirm. So dismissal must
   be **prevented**, not silently cleared: `CardAView.interactiveDismissDisabled(true)`, `onDismiss`
   keeps the pending, and a mic press with a pending play **reopens the card** (routed A/B by `needs`).
3. **End Game finalized an incomplete game.** The real `finalize_scorecard` enforces SC-011 (proof box
   must balance); MockCore returned a canned balanced book. `endGame()` now pre-checks the blocker and
   surfaces the **real** reason ("the half-inning isn't complete… or exit without saving") instead of a
   generic failure.
4. **Card B resolve-without-confirm.** `resolve_judgment` resolves the decision but does *not* confirm
   the play (the row stays `confirmed=false`). `AppState.resolveJudgment` now calls `confirmPlay` after
   a successful resolve (capturing `recordedSeq` first), so Card B → next-play works.
5. **Surface the real error.** `CoreError` gained `LocalizedError` so the core's message reaches the UI
   instead of Foundation's opaque "operation couldn't be completed (error 4)".
6. **Gitignored XCFramework.** `Package.swift`'s `.binaryTarget` points at a gitignored build artifact,
   so a fresh checkout can't resolve dependencies until `make xcframework` runs. (Documented; CI's iOS
   job and any fresh setup must run it first.)

## Why This Works
A stateless mock can only ever exercise the parts of a contract that don't depend on accumulated state
or strict invariant enforcement — which is precisely the part the real implementation gets *strict*
about. The swap is therefore not a drop-in: it's an integration event that re-validates every flow
against behavior the mock never had. The cardinal point: **the real core's invariants (FR-007 pending
gate, SC-011 balance, no-silent-judgment, append-only/no-discard) are features**, and the UI must be
reconciled with each, not paper over them.

## Prevention
- **Test the REAL input path, not an idealized proxy.** Write integration/regression tests that drive
  the *actual* production pipeline end-to-end (here: `StubTranscriber → GrammarParser → FactBridge →
  real core`), with the exact shapes production emits (`"63"`, not `"6-3"`). A test that constructs the
  downstream struct by hand will pass while the upstream producer feeds something different.
- **Budget a reconciliation pass for any real-for-mock swap.** Treat it as its own task: enumerate the
  flows the mock made trivial (dismiss, cancel, finalize, retry, re-record) and re-verify each against
  the real implementation's state machine and invariants. Read the real implementation's capabilities
  *first* (e.g. "is there a discard primitive?") before designing the UI's escape hatches.
- **A "never silently X" gate is only as strong as its instrumentation** — see
  [[parallel-squad-integration]] §4: the same round had a P0 where the silent-resolution counter was
  never fired on a projection path, so the gate passed vacuously. Close such gaps *architecturally*
  (withhold the state), and make the gate actually exercise the path.
- **The live human tap-test is the highest-fidelity signal** for a UI-over-real-backend swap, and it's
  what surfaced every bug here. Get a real build in a human's hands early.
- **`DEVELOPER_DIR` gotcha:** `xcrun simctl` returns *empty* (no sims/runtimes) under
  `CommandLineTools` — point it at `/Applications/Xcode.app/Contents/Developer`.

## Related Issues
- H1 / DL-35 (PR #148) — the swap + this reconciliation. Follow-ups #150 (core pending/defer token),
  #151 (grammar: route "misplayed" transcripts to the reached-on-error/Card-B path).
- [[parallel-squad-integration]] — §4 green-CI≠correct (this round added the strongest evidence yet:
  the review gate caught a real blocker in **all four** PRs).
- [[verify-generated-code-with-real-toolchain]] — the sibling "verify against reality, not a proxy".
