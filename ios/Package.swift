// swift-tools-version: 6.0
// Diamond Ledger — iOS app-logic library package (T003)
//
// Min platform: iOS 26 — required by SpeechAnalyzer / DictationTranscriber (T046, ADR-0007).
// This package wraps the UniFFI-generated XCFramework (Squad A / H1) plus the four thin
// Swift-side modules: Core, Speech, Parse, Persistence, UI, Auth.
//
// Note: The real UniFFI XCFramework target (DiamondLedgerCore) is added in Phase B (H1).
// Until H1 lands, ios/Sources/Core/MockCore.swift provides canned results (T008).

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
        // MARK: - Core
        // Swift mirror of the Rust CoreApi (UniFFI boundary).
        // Backed by MockCore until H1; swapped to the real XCFramework at H1 (T071).
        .target(
            name: "Core",
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
        .target(
            name: "UI",
            dependencies: ["Core", "DiamondSpeech", "Parse", "Persistence"],
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
