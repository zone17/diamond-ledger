---
title: A push-to-talk hold ends through paths that do not look like a release
date: 2026-09-27
category: ui-bugs
module: ios/Sources/UI/PushToTalk
problem_type: ui_bug
component: frontend_stimulus
symptoms:
  - "Backgrounding mid-hold scored the partial utterance instead of discarding it"
  - "Exit without saving mid-press left the microphone capture running behind a closed game"
  - "A transcript that finished after the game closed was silently dropped while diagnostics recorded it as scored"
  - "The speech-recognition system prompt appeared on app activation, before New Game"
root_cause: missing_workflow_step
resolution_type: code_fix
severity: high
related_components: [ios/Sources/Speech, ios/Sources/UI/App]
tags: [push-to-talk, swiftui, gesturestate, scenephase, avaudioengine, permissions, test-fakes, state-machine, ios]
---

# A push-to-talk hold ends through paths that do not look like a release

## Problem
Wiring real microphone capture into push-to-talk (#176, PR #186) passed 353 simulator tests, yet a nine-lens review found three P1 defects. Each one was an exit from a hold that the code did not treat as an exit. Two came from iOS delivering events in an order the tests never used. One came from a fake that hid a real side effect.

## Symptoms
- The partial utterance was scored when the app went to the background mid-hold. Requirement R3 says it must be discarded.
- Leaving a game without saving, or signing out, while holding the button left the capture running. A transcript that finished afterwards went into a closed game.
- The system speech prompt appeared on an ordinary app activation, where the readiness check promises never to prompt.

## What Didn't Work
- **Handling `.background` for a held press only.** The first version cancelled the press when the scene reached `.background`, but skipped any press already marked released. On a device, iOS can cancel the touch before the scene phase changes. SwiftUI resets a `@GestureState` on a cancelled gesture exactly as on a real lift, so the view saw a release first. By the time `.background` arrived, the press was already released, and it got scored.
- **Guarding the release on `currentPress` alone.** The release task checks that its press is still current before scoring. It then clears `currentPress` before transcribing, so resets that happen during transcription could not stop it. `recordPlay` then returned early on its missing-game guard, and nothing told the user.
- **Testing readiness with a silent fake preloader.** Every readiness test injected a `FakePreloader` that only succeeds, fails, or holds. The real `AppleTranscriber.preloadAssets()` calls `SpeechAuthorization.request()` before downloading. A preload started while speech was `.notDetermined` therefore showed the system prompt, and no test could see it.

## Solution
The review-fix commit in PR #186 (squash-merged as 6d5e172) fixed all three, with regression tests in `ios/Tests/T176ReviewFixTests.swift`. Each of those tests fails when its fix is reverted.

1. **Either event order discards.** On `.inactive` or `.background`, a held press is cancelled. A press that is released but still inside `stop()`, the 250 ms tail, is flagged instead. The release task then discards the audio when `stop()` returns:
   ```swift
   case .background, .inactive:
       guard let press = appState.currentPress else { return nil }
       guard press.released else {
           return cancel(press, message: AppState.interruptionMessage(for: .background), appState: appState)
       }
       press.discardOnRelease = true
   ```
2. **Every reset ends the live press.** `PushToTalkPipeline.endLivePress(appState:)` stops a held capture and forgets the press. `exitGameWithoutFinalizing()` and `signOut()` call it before they reset `pttState`. Each press also records its `gameId`, and scoring checks it again after transcription. A transcript whose game has closed is dropped and recorded as `interrupted`, not `scored`.
3. **Preload only once access is granted.** `SpeechReadiness.evaluate()` starts the preload only when speech is `.granted`, so it can never be the thing that prompts. A failed preload now waits out a cooldown before retrying. `live()` sets that cooldown to 30 s.

## Why This Works
A hold is state that exists between two events, and each fix names another way that state can end. The sheet bug in `swiftui-sheet-ondismiss-state-reconciliation.md` was the same class: state reset only by explicit handlers, and a dismissal path that bypassed them. The capture made the class wider. Besides UI dismissals, the operating system can end a hold, as can app-level resets written before the capture existed. So can platform APIs that do more than their name says.

## Prevention
- For any state that lives between two gestures, list every way it can end before writing the first test. Cover every end the OS can deliver, including a cancelled gesture, `.inactive` and `.background` in either order, and interruptions. Also cover every existing method that resets related state. Write a test for each order, not just the order the simulator happens to produce.
- When a new invariant such as "a live capture has an owner" is added, search for every existing method that resets neighbouring state, like `pttState` or `activeGame`. Route each one through the new cleanup.
- Before injecting a fake for a platform call, read the real call for side effects such as prompts, network access, or persistence. Then either reproduce them in the fake or gate the call so the side effect cannot happen. A fake that silently succeeds hides exactly those side effects.

## Related Issues
- `docs/solutions/ui-bugs/swiftui-sheet-ondismiss-state-reconciliation.md` covers the same class through a sheet dismissal.
- `docs/solutions/integration-issues/mock-to-real-stateful-core-swap.md` covers bugs that surface only when a real implementation replaces a mock.
- Device-only risks the review could not settle are listed in `docs/evaluations/2026-09-device-voice-checklist.md` and in `.specify/reviews/PR-186.md`. They include a second press while the previous capture is still releasing the audio session, and a Bluetooth route change right after start.
