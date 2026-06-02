// swift-tools-version: 6.0
// Diamond Ledger — iOS app-logic library package (T003)
//
// Min platform: iOS 26 — required by SpeechAnalyzer / DictationTranscriber (T046, ADR-0007).
// This package wraps the UniFFI-generated XCFramework (Squad A / H1) plus the six thin
// Swift-side modules: Core, Speech, Parse, Persistence, UI, Auth.
//
// H1 wiring (T071 / DL-35): the real Rust core ships as a binary XCFramework target
// (`DiamondLedgerCoreFFI`) plus a source target compiling the generated Swift bindings
// (`DiamondLedgerCoreBindings`). `Core` depends on the bindings; `DiamondCoreClient.swift`
// wraps the generated `DiamondCore` behind the unchanged `CoreClient` protocol. `MockCore`
// stays in `Core` for previews/tests. Build the artifacts with `make xcframework` — they
// land in `Generated/` and are `.gitignore`d (see `ios/Generated/README.md`).
//
// Note: the generated bindings `import dl_coreFFI` — the C module name UniFFI bakes from the
// crate lib name (`dl_core`). The binary target's module is therefore `dl_coreFFI`, NOT
// `DiamondLedgerCoreFFI` as the README first guessed (real-core discrepancy, see PR #).

import PackageDescription

let package = Package(
    name: "DiamondLedger",
    platforms: [
        .iOS("26")
    ],
    products: [
        // App-logic library — consumed by the Xcode app target.
        .library(
            name: "DiamondLedgerLib",
            targets: [
                "Core",
                "DiamondSpeech",
                "Parse",
                "Persistence",
                "UI",
                "Auth",
            ]
        ),
    ],
    dependencies: [
        // GRDB for SQLite / append-only event log (T055).
        // Pin to a specific version when integrating (Art. XXXV).
        // .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
    ],
    targets: [
        // MARK: - DiamondLedgerCoreFFI (binary)
        // The UniFFI-generated XCFramework: device + simulator static-lib slices wrapping the
        // real deterministic Rust core. Exposes the C module `dl_coreFFI` (named from the crate
        // lib `dl_core`) via its baked modulemap; the generated Swift bindings `import dl_coreFFI`.
        // Build with `make xcframework`; the artifact is `.gitignore`d (ios/Generated/README.md).
        .binaryTarget(
            name: "DiamondLedgerCoreFFI",
            path: "Generated/DiamondLedgerCore.xcframework"
        ),

        // MARK: - DiamondLedgerCoreBindings (generated Swift)
        // Compiles the generated `DiamondLedgerCore.swift` (the `open class DiamondCore` + all the
        // boundary records/enums). Depends on the binary target whose C module it imports. This is
        // the module `Core` imports to reach the real core (DiamondCoreClient.swift).
        .target(
            name: "DiamondLedgerCoreBindings",
            dependencies: ["DiamondLedgerCoreFFI"],
            path: "Generated",
            sources: ["DiamondLedgerCore.swift"],
            // UniFFI 0.28's generated bindings are Swift-5-shaped: they use a nonisolated global
            // `var initializationResult` that Swift 6's strict-concurrency checker rejects
            // ("not concurrency-safe ... global shared mutable state"). Compile this ONE generated
            // target in Swift 5 language mode; every hand-written target stays on Swift 6. This is
            // a real-core/H1 integration finding (the README didn't flag it) — see PR #.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - Core
        // Swift mirror of the Rust CoreApi (UniFFI boundary).
        // `MockCore` (canned, previews/tests) + `DiamondCoreClient` (real core, H1/T071) both
        // conform to the unchanged `CoreClient` protocol. `DiamondCoreClient` wraps the generated
        // bindings, so `Core` depends on `DiamondLedgerCoreBindings`.
        .target(
            name: "Core",
            dependencies: ["DiamondLedgerCoreBindings"],
            path: "Sources/Core"
        ),

        // MARK: - DiamondSpeech
        // Two-engine ASR abstraction: SpeechAnalyzer (iOS 26 primary) + sherpa-onnx (fallback).
        // Requires iOS 26 for SpeechAnalyzer / DictationTranscriber (ADR-0007, T046–T048).
        // Named "DiamondSpeech" (not "Speech") to avoid shadowing Apple's system Speech.framework,
        // which conformers in AppleTranscriber.swift (T047) must `import Speech` directly.
        .target(
            name: "DiamondSpeech",
            path: "Sources/Speech"
        ),

        // MARK: - Parse
        // Deterministic grammar-constrained transcript → NormalizedPlay parser (T049–T050).
        // v1 = no LLM; FunctionGemma-270M + XGrammar is the v2 path.
        // Depends on DiamondSpeech to receive `Transcript` values directly.
        .target(
            name: "Parse",
            dependencies: ["DiamondSpeech"],
            path: "Sources/Parse"
        ),

        // MARK: - Persistence
        // SQLite / GRDB append-only event log + CloudKit sync stub (T055, T058).
        .target(
            name: "Persistence",
            path: "Sources/Persistence"
            // dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),

        // MARK: - UI
        // V3 glance HUD, push-to-talk, Card A/B, export UI (T045, T051–T057).
        // Depends on Auth to read the authenticated ownerId for all CoreClient calls (FR-020/I5).
        .target(
            name: "UI",
            dependencies: ["Core", "DiamondSpeech", "Parse", "Persistence", "Auth"],
            path: "Sources/UI"
        ),

        // MARK: - Auth
        // Email + social sign-in; private-by-default account/owner identity (T081 / FR-028 / FR-020).
        // Provides the authenticated owner that the owner-as-decider authority assertion binds to.
        .target(
            name: "Auth",
            path: "Sources/Auth"
        ),

        // MARK: - Tests
        .testTarget(
            name: "DiamondLedgerTests",
            dependencies: ["Core", "DiamondSpeech", "Parse", "Persistence", "UI", "Auth"],
            path: "Tests"
        ),
    ]
)
