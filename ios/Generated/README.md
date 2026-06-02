# iOS consumption of the Rust core (H1 / T037 → T071)

This directory holds the **generated** UniFFI artifacts produced by
`scripts/build-xcframework.sh` (a.k.a. `make xcframework`). It is the A-side of handoff
**H1**: the real Rust core, compiled for iOS and wrapped in Swift bindings. Squad B's
job (**T071 / T044**) is to swap `MockCore` for these bindings — **no `CoreClient`
protocol changes required**.

> The artifacts themselves (`DiamondLedgerCore.xcframework/`, `DiamondLedgerCore.swift`)
> are build outputs and are `.gitignore`d. Run `make xcframework` to produce them.

## What the build emits

```
ios/Generated/
  DiamondLedgerCore.xcframework/   # static-lib slices: ios-arm64 (device) + ios-arm64_x86_64-simulator
  DiamondLedgerCore.swift          # the generated Swift bindings (≈7.5k lines)
  kotlin/                          # only if built with --kotlin (android fast-follow)
```

The Swift file `import`s a C module named **`DiamondLedgerCoreFFI`** — that module is the
header + modulemap baked into the `.xcframework`.

## Build it

```bash
# From the repo root. Requires Xcode (not just CommandLineTools), rustup.
make xcframework
# or, with options:
bash scripts/build-xcframework.sh [--debug] [--out ios/Generated] [--kotlin]
```

`cargo` auto-installs the three iOS Rust targets via rustup the first time
(`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`).

> **Cache pitfall (do not skip):** a plain host `cargo build` overwrites
> `target/debug/libdl_core.dylib` with a **non-UniFFI** dylib, after which
> `uniffi-bindgen --library` silently emits **zero files**. The script rebuilds the host
> dylib *with* `--features uniffi` right before generating and **deletes the output dir
> before regenerating**. Don't hand-run bindgen against a stale dylib.

## Wire it into the SwiftPM package (T071)

1. **Add a binary target** for the XCFramework in `ios/Package.swift`:

   ```swift
   .binaryTarget(
       name: "DiamondLedgerCoreFFI",
       path: "Generated/DiamondLedgerCore.xcframework"
   ),
   ```

2. **Add the generated Swift bindings as a source target** that depends on the binary
   target, then make `Core` depend on it:

   ```swift
   .target(
       name: "DiamondLedgerCoreBindings",
       dependencies: ["DiamondLedgerCoreFFI"],
       path: "Generated",
       sources: ["DiamondLedgerCore.swift"]
   ),
   // ...
   .target(name: "Core", dependencies: ["DiamondLedgerCoreBindings"], path: "Sources/Core"),
   ```

   (Equivalently, in the XcodeGen app: add the `.xcframework` to the
   `DiamondLedger` target's `dependencies:` and add `DiamondLedgerCore.swift` to its
   sources. The SwiftPM route above is preferred — it matches `Package.swift`'s existing
   note "wraps the UniFFI-generated XCFramework".)

## Map `MockCore` → the real core

The generated Swift exposes an `open class DiamondCore` with a static constructor and the
**11 methods** that mirror `CoreApi` 1:1. They take the same request records and return the
same result records the boundary defines in `core/src/ffi.rs`:

| `CoreClient` protocol method (Swift) | Generated `DiamondCore` method | Rust `CoreApi` |
|---|---|---|
| `createGame`        | `ffiCreateGame(req:)`        | `create_game`        |
| `recordPlay`        | `ffiRecordPlay(req:)`        | `record_play`        |
| `confirmPlay`       | `ffiConfirmPlay(req:)`       | `confirm_play`       |
| `advanceRunner`     | `ffiAdvanceRunner(req:)`     | `advance_runner`     |
| `resolveJudgment`   | `ffiResolveJudgment(req:)`   | `resolve_judgment`   |
| `correctEvent`      | `ffiCorrectEvent(req:)`      | `correct_event`      |
| `finalizeScorecard` | `ffiFinalizeScorecard(req:)` | `finalize_scorecard` |
| (read) game state   | `ffiGetGameState(gameId:)`   | `get_game_state`     |
| (read) event log    | `ffiListGameEvents(gameId:)` | `list_game_events`   |
| (read) one play     | `ffiGetPlay(gameId:seq:)`    | `get_play`           |
| (read) proof box    | `ffiGetProofBox(gameId:inning:half:)` | `get_proof_box` |

Construct it with `DiamondCore()` (generated from `#[uniffi::constructor] ffi_new`).

### Errors

Every method `throws` a Swift `enum CoreFfiError`. It has a single case `.core(Error)`
carrying the **structured boundary error** — read `error.code` (an `ErrorCode` enum: the
stable machine signal, Art. I), plus `error.message`, `error.retryable`, `error.details`.
Map `ErrorCode` → the existing Swift `CoreError` cases in `CoreClient.swift`:

| `ErrorCode` (Rust)      | suggested `CoreError` (Swift)     |
|-------------------------|-----------------------------------|
| `unauthorized`          | `.unauthorized`                   |
| `judgmentRequired`      | `.judgmentRequired`               |
| `pendingConfirmation`   | `.invalidState`                   |
| `contradictoryState`    | `.invalidState` / `.proofBoxImbalance` (finalize) |
| `notFound`              | `.notFound`                       |
| others                  | `.internalError` / `.invalidState`|

### The `MockCore` adapter contract still holds

`MockCore` (T008) and the real `DiamondCore` both implement the same **shape**. The
adapter you write at T071 builds the `RecordPlayRequest` / `ConfirmPlayRequest` / etc.
records (now generated UniFFI structs) from the same inputs `CoreClient`'s `[String:String]`
placeholders carried — see the `TODO: T044` markers in `CoreClient.swift`. Replace those
`[String:String]` placeholders with the generated record types as you wire each method.

## Determinism / parity guarantee (SC-008)

The Swift surface is byte-for-byte the same boundary the CLI/agent adapters call (Rust
`DiamondCore`), proven by `evals/runners/parity.sh`. Same confirmed facts in → identical
results out, regardless of caller (iOS / CLI / agent). The integer-only core has **no
`f32`/`f64`**, so projections are bit-identical across architectures (device vs simulator
vs host).
