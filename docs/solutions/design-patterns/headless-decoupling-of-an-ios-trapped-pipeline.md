---
module: ios + scripts/build-xcframework
date: 2026-06-09
problem_type: design_pattern
component: cross_platform_packaging
applies_when:
  - "A deterministic pipeline (parse/score/transform) is only reachable from inside the iOS app"
  - "You need that pipeline invokable headlessly — from a CLI, CI, the eval harness, or an agent"
  - "The logic is platform-independent but its SwiftPM target transitively pulls iOS-only frameworks"
  - "Restoring agent/CLI parity (Art. II / FR-018) for a capability trapped behind the UI"
tags: [agent-native-parity, swiftpm, uniffi, xcframework, macos-slice, cross-platform, headless, cli, dl-37, decoupling, article-ii]
---

# Un-trapping an iOS-only pipeline so it runs headless (CLI / CI / agent)

## Context
Diamond Ledger's scoring pipeline (`transcript → GrammarParser → real Rust core → result`) was
logically platform-independent but could only be invoked from inside the SwiftUI app. That broke
agent/CLI parity (Art. II / FR-018) for the product's most important capability **and** made the
accuracy story unmeasurable headlessly (the eval harness had no scorer binary to call). The blocker
was twofold: the core UniFFI XCFramework shipped **iOS-only** slices, and the parser's SwiftPM
target (`Parse`) transitively depended on the iOS-26-only ASR engines (`DiamondSpeech`).

## Guidance
A three-move pattern un-traps the pipeline without rewriting it:

1. **Extract the pure value types into a platform-agnostic target.** The parser only needed the
   `Transcript` *value*, not the ASR engines. Move `Transcript` / enums / pure helpers into a new
   Foundation-only target (`SpeechTypes`); have the iOS engine target `@_exported import` it so
   existing `import DiamondSpeech` consumers are unchanged; repoint the parser at the pure target.

   ```swift
   // DiamondSpeech (iOS-only) keeps the engines but re-exports the value layer:
   @_exported import SpeechTypes
   // Parse now depends on SpeechTypes (Foundation-only), NOT the SpeechAnalyzer engines.
   ```

2. **Add the host platform as a slice of the binary artifact.** The Rust core is platform-
   independent, so building it for `aarch64/x86_64-apple-darwin` and adding a `macos-arm64_x86_64`
   slice to the XCFramework is nearly free (lipo same-platform arches; keep distinct platforms as
   separate `-library` slices):

   ```bash
   xcodebuild -create-xcframework \
     -library "$ios_device" -headers "$H" \
     -library "$ios_sim_fat" -headers "$H" \
     -library "$macos_fat"   -headers "$H" -output "$XCF"
   ```

3. **Build only the product's dependency closure, never the whole package.** Add the host platform
   to `Package.swift` and a thin `executableTarget`, then build with
   `swift build --product <cli>` — which compiles only that product's closure. The iOS-only targets
   (UI, the ASR engines, etc.) stay out of the closure and are never compiled for the host. Document
   that a **bare** `swift build`/`swift test` will fail on the host (it tries every target); the iOS
   app + tests still build via `xcodebuild` for the iOS destination.

## Why This Matters
The capability becomes a first-class primitive any human *or* agent can invoke (Art. II), and CI
gains real headless coverage of a seam that previously only ran behind the UI. The decoupling is a
**clean structural win**, not a workaround: the parser never should have depended on the audio
engine — it only needed the transcript value. The platform boundary that remains (audio→transcript
ASR is still device-bound) is a *named, tracked* parity exception, not an accidental one.

## When to Apply
Whenever a deterministic, platform-independent capability is reachable only from the app target and
you want it in CLI/CI/agent reach. The tell: a "core logic" target whose transitive deps include a
platform-only framework (AVFoundation, Speech, UIKit) it doesn't actually use. Split the pure value
layer out first; the rest follows.

## Examples
- DL-37 / ADR-0015: `SpeechTypes` extraction + macOS XCFramework slice + `dl-score` CLI +
  `swift build --product dl-score`. Restored parity and unblocked the eval harness in one PR.
- Forward-compat note (agent-native review): when exposing a detect-style result (e.g.
  "judgment required"), also emit the IDs/alternatives an agent needs to *act* on it
  (`decision_id`, `alternatives`) — parity means an agent can resolve, not just observe.

## Related
- DL-37 (ADR-0015) — the implementation + alternatives considered.
- [[mock-to-real-stateful-core-swap]] — testing the real input path this pattern now exposes headlessly.
- [[uniffi-integration-gotchas]] — the XCFramework/bindgen build the macOS slice extends.
