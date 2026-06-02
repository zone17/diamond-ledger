---
title: SwiftUI swipe-dismissible .sheet must reconcile owner state in onDismiss
date: 2026-06-02
category: ui-bugs
module: ios/Sources/UI/App
problem_type: ui_bug
component: frontend_stimulus
symptoms:
  - "Push-to-talk mic button goes permanently disabled (green 'Ready') with no way to record the next play"
  - "Bug only reproduces on Card A (confirm), never on Card B (judgment)"
  - "App appears responsive but the primary input is dead until relaunch"
root_cause: missing_workflow_step
resolution_type: code_fix
severity: medium
tags: [swiftui, sheet, ondismiss, state-machine, ios, interactive-dismiss, push-to-talk]
---

# SwiftUI swipe-dismissible .sheet must reconcile owner state in onDismiss

## Problem
A SwiftUI `.sheet` that the user can dismiss by swiping down does **not** call the
sheet's in-content button handlers when dismissed that way. The push-to-talk state
machine (`AppState.pttState`) was only ever returned to `.idle` by the Confirm/Correct
buttons inside Card A — so swiping the card away left `pttState == .result`, which
disables the mic button with no recovery path short of relaunching the app.

## Symptoms
- Mic button stuck disabled showing the green "Ready" state after dismissing a card by swipe.
- Reproduces on **Card A only** (it is freely dismissible); never on Card B, which sets
  `interactiveDismissDisabled` to enforce the I2 no-silent-judgment invariant.
- No error, no log — the app looks healthy; only the primary input is dead.

## What Didn't Work
- Looking for a bug in the mic button's `.disabled(...)` predicate — the predicate was
  correct (`pttState == .processing || pttState == .result`). The defect was that nothing
  reset `pttState` on the swipe-dismiss path, so the predicate was correctly reporting a
  state that should never have persisted.
- Treating it as a button/gesture issue — the button was fine; the *state owner* was stale.

## Solution
Attach an `onDismiss` closure to the `.sheet` and reconcile the owner state machine there,
so the swipe-dismiss path converges to the same state the explicit buttons produce:

```swift
// MainView.swift
.sheet(item: $state.presentedSheet, onDismiss: { appState.handleSheetDismiss() }) { sheet in
    sheetContent(for: sheet)
}
```

```swift
// AppState.swift
/// onDismiss unsticks the PTT loop if a card (e.g. Card A) is swiped away instead of being
/// Confirmed/Corrected — otherwise pttState stays `.result` and the mic button is left disabled.
func handleSheetDismiss() {
    if pttState == .result {
        pttState = .idle
    }
    activeGame?.pendingResult = nil   // safe per FR-007: state never advanced on an unconfirmed play
}
```

Clearing `pendingResult` is safe because the deterministic core never advances game state on
an unconfirmed play — the pending result is a UI-side staging value, so dropping it on dismiss
simply discards an un-acted entry. The handler is a no-op after an explicit Confirm/Correct/
Resolve (those already set `pttState = .idle` and cleared the pending), so it cannot double-fire
into a bad state.

## Why This Works
SwiftUI's interactive dismissal (swipe-down, tap-outside) bypasses any logic wired to the
controls *inside* the sheet. The only dismissal callback the framework guarantees to run for
**every** dismissal path — swipe, programmatic, or button-driven — is the `onDismiss:` argument
of `.sheet`. Putting the state-reconciliation there makes it the single convergence point for
all exit paths, so a state machine driven by a dismissible sheet can never be left mid-transition.

The asymmetry that hid the bug is itself instructive: Card B couldn't trigger it because
`interactiveDismissDisabled` removes the swipe path entirely (you *must* pick Hit/Error/Leave
PENDING). A sheet that is dismissible by gesture is exactly the one that needs `onDismiss`
reconciliation; a sheet that disables interactive dismiss has already constrained its exits.

## Prevention
- **Rule:** any `@Observable`/owner state machine whose transitions are driven from *inside* a
  swipe-dismissible SwiftUI `.sheet` (or `.fullScreenCover`/`.popover`) MUST reconcile that state
  in the `.sheet(..., onDismiss:)` closure. Button handlers alone are insufficient — they don't
  run on gesture dismissal.
- **Decision shortcut:** if a sheet should be exit-able only through explicit choices, use
  `interactiveDismissDisabled()` and skip `onDismiss`. If it's freely dismissible, you owe it an
  `onDismiss` that returns the owner to a safe resting state. Pick one deliberately per sheet.
- **Test:** add a UI/unit test that presents the sheet, simulates a dismiss without invoking the
  in-content actions, and asserts the owner state returned to its idle/resting value (e.g.,
  `pttState == .idle` and `pendingResult == nil`).
- **Verification method (reusable):** this fix was built, installed, and screenshot-verified
  headlessly against the iOS 26 simulator without a round-trip to the user, via:
  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -project ios/DiamondLedger.xcodeproj -scheme DiamondLedger \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  xcrun simctl install booted <app.app> && xcrun simctl launch booted app.diamondledger.DiamondLedger
  xcrun simctl io booted screenshot /tmp/out.png
  ```
  iOS UI state bugs are reproducible and verifiable locally — prefer a build+install+screenshot
  loop over asking the user to re-shoot the screen. (Note: `DEVELOPER_DIR` must point at the full
  Xcode for `xcodebuild`/iOS SDK; CommandLineTools is only enough for `git`/`cc`.)

## Related Issues
- DL-134 (PR #134) — the fix.
- The I2 / SC-003 cardinal invariant (Card B `interactiveDismissDisabled`) — the reason Card B
  was immune and Card A was not; see `.specify/memory/constitution.md` and the judgment-card
  interaction spec.
- `docs/solutions/best-practices/verify-generated-code-with-real-toolchain.md` — sibling learning
  on verifying against the real toolchain rather than by inspection.
