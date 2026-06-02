/// UI.swift — T003 placeholder (Squad B, Stories B4–B8)
///
/// Module-level stub for the iOS UI layer. All sub-modules are created at their respective tasks.
///
/// **UI sub-modules (plan.md / tasks.md):**
///   - `UI/NewGame/`    — New Game flow: two team names, optional lineups (T045 / FR-001).
///   - `UI/HUD/`        — V3 glance HUD: inning, outs dots, base diamond, count, line score (T051).
///   - `UI/PushToTalk/` — Hold-to-talk states: idle → listening → processing → result (T052).
///   - `UI/CardA/`      — Card A: plain-language restatement + Reisner token + one-tap Confirm/Correct (T053).
///   - `UI/CardB/`      — Card B: "Your call" judgment posture + one-tap resolve (T054 / FR-010/011).
///   - `UI/Export/`     — Finalize + export: invoke `finalizeScorecard`, share Retrosheet file (T057).
///   - `UI/Share/`      — Explicit share-link action (T082 / FR-023, post-MVP).
///
/// **V3 glance design reference:** `specs/001-voice-scorebook-core/prototype/interaction-spec.md`
///
/// **SC-005 attention bar:** ≥80% of plays ≤1 phrase + ≤1 tap; median eyes-on-screen ≤3 s.
/// The SC-005 measurement MUST happen during the first demo (T074 remediation E1) —
/// do NOT defer to a polish phase.
///
/// - TODO: T045 — App shell + New Game flow.
/// - TODO: T051 — Glanceable HUD.
/// - TODO: T052 — Push-to-talk control.
/// - TODO: T053 — Card A (confirm / correct pending entry).
/// - TODO: T054 — Card B (judgment one-tap resolve).
/// - TODO: T057 — Export UI.
/// - TODO: T082 — Share-link action (post-MVP).

import SwiftUI

// This file provides the UI target's module-level umbrella imports.
// All real implementation lives in sub-directories:
//   UI/App/         — DiamondLedgerApp, AppState, MainView
//   UI/Auth/        — SignInView
//   UI/NewGame/     — NewGameView
//   UI/HUD/         — HUDView, OutsDotsView, BaseDiamondView
//   UI/PushToTalk/  — PushToTalkView, WoZScript
//   UI/CardA/       — CardAView
//   UI/CardB/       — CardBView
//   UI/Clarify/     — ClarifyView, ManualEntryView
