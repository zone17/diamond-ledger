# Device voice checklist — push-to-talk on a physical iPhone (#176)

**Status:** pending — a human step for the product owner. This file is the *procedure*; the run
itself produces a new dated record, `YYYY-MM-device-voice-run.md`, in this directory.
**Label for the run's numbers:** `FIELD ACCURACY` only for utterances spoken live into the device
microphone by a person; anything else carries its advisory label (see `README.md`).
**Why it matters:** hands-free scoring stays closed (ADR-0017, silent-scoring switch OFF) until
this run measures the biased recognizer leg's confidence on real speech. The numbers here are the
input for that decision, and for nothing else.

## What you need

- An iPhone on iOS 26 or later, with Apple Intelligence languages including English (US).
- A Mac with Xcode 26, this repo at the commit you are testing, and the phone connected by cable.
- A quiet room for Part B, and a noisy one (a field, a gym, or crowd audio from a speaker) for Part C.
- About 30 minutes.

## Part A — Build and permissions (5 min)

1. Run `make ios-test` on the Mac. It must print `PASS`. Write down the commit (`git rev-parse --short HEAD`).
2. Open `ios/DiamondLedger.xcodeproj` in Xcode, choose the **DiamondLedger** scheme, pick your phone,
   and press Run. Use the **Debug** configuration: the diagnostics export lives only in Debug builds.
3. Tap **New Game**. The app asks for **Microphone** and then **Speech Recognition** access.
   Allow both. The game must start right away, even if the speech model is still downloading.
4. Denied-path check: in the iOS Settings app, turn **Microphone** off for Diamond Ledger, return to
   the app, and press the mic button. Expect a message saying microphone access is off, with a link to
   Settings, and **no** play scored. Turn Microphone back on, return, and press again: the mic works
   without starting a new game.
5. If the first press says the speech model is still preparing, wait a minute and press again.

## Part B — Twenty scripted utterances, quiet room (15 min)

Enter a lineup with at least three real player names first; they bias the recognizer. Hold the
mic button, say the line, release. For each row, record what the app did: **Clarify** (list the
candidates), **manual entry**, **scored** (which play), or **error** (the message).

On iOS 26 the speech engine reports no confidence, so every play it recognizes goes to the Clarify
sheet for one tap (ADR-0017). "Expected" names the candidate that must appear there. The phrasings
come from the transcript regression corpus, so the parser is known to understand them as text; what
this run measures is whether the phone hears them.

| # | Say exactly | Expected |
|---|-------------|----------|
| 1 | ground ball to short, threw him out at first | Clarify with groundout 6-3 |
| 2 | strikeout swinging | Clarify with strikeout swinging |
| 3 | fly ball to center caught for the out | Clarify with flyout 8 |
| 4 | single to left | Clarify with single to left |
| 5 | walk | Clarify with walk |
| 6 | line drive to center, caught | Clarify with lineout 8 |
| 7 | double to center field | Clarify with double to center |
| 8 | pop up to the catcher | Clarify with popout 2 |
| 9 | ground ball to third, threw him out at first | Clarify with groundout 5-3 |
| 10 | home run to center | Clarify with home run |
| 11 | strikeout looking | Clarify with strikeout looking |
| 12 | sacrifice fly to right | Clarify with sacrifice fly 9 |
| 13 | double play short to second to first | Clarify with double play 6-4-3 |
| 14 | hit by pitch | Clarify with hit by pitch |
| 15 | reached on error by the shortstop | Clarify with reached on error E6 |
| 16 | ground ball to *\<lineup player 1\>*, threw him out at first | Clarify or manual entry. Never a play with a guessed fielder |
| 17 | *\<lineup player 2\>* struck out looking | Clarify with strikeout looking, or manual entry |
| 18 | triple to right | Clarify with triple to right |
| 19 | *(say nothing, release after one second)* | a "too short" or no-speech message; nothing scored |
| 20 | *(keep talking for more than 15 seconds)* | capture stops by itself at 15 s and proceeds as a release |

**Never acceptable:** a play scored that you did not say. Record any such case first, verbatim,
with the row number. That is an Article VII defect and blocks everything else.

## Part C — Noise and interruptions (5 min)

1. Repeat rows 1–10 in the noisy environment.
2. While holding the button, have someone call the phone. Expect the listening state to end with a
   message and nothing scored. After the call, a fresh press works.
3. While holding, connect or disconnect Bluetooth headphones. Expect the same clean stop.
4. While holding, swipe to the home screen. Expect the same clean stop when you return.

## Part D — Export the diagnostics (5 min)

1. In the app, press and hold the status label above the mic button for 1.5 seconds to open the
   facilitator panel (Debug builds only).
2. Tap **Export voice diagnostics**. It copies the last 50 voice records to the clipboard as JSON.
   With Universal Clipboard (same Apple Account, Wi-Fi and Bluetooth on), paste it on the Mac into
   a new file. Otherwise paste it into a note and send it to yourself.
3. The records hold numbers only. There are two kinds. A `capture` record has the capture
   duration, the release-to-transcript latency, and the outcome. A `transcription` record has the
   base leg's confidence (`unreported` on iOS 26, which is expected), the biased leg's measured
   confidence, and the biasing reason. Records are in time order, and each spoken play produces
   its `transcription` record right before its `capture` record, so pair them in order.
   Interrupted captures show 0 seconds. There is no audio and no transcript text in the export.
   If you see either, stop and file a privacy defect (FR-022).

## Part E — Write the record

Create `docs/evaluations/YYYY-MM-device-voice-run.md` with the header block `README.md` requires
(date, commit, device model, iOS build, engine `AppleTranscriber`, environment), then:

- the Part B and Part C result tables, each labeled `FIELD ACCURACY`;
- the biased-leg confidence distribution from the export: count, min, median, 90th percentile, max,
  split by whether the play was right (match each record pair to its Part B or Part C row in order);
- release-to-transcript latency: median and worst;
- every error message seen, and every Part A or Part C step that did not behave as written.

Open a PR with the record. The decision on the silent-scoring switch is made in a separate ADR that
cites it; this checklist never flips the switch.
