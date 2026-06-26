/// DiamondLedgerApp.swift — T045 (Squad B, Story B1)
///
/// App entry point + root environment injection.
///
/// Owns:
///   - `@main` entry via SwiftUI lifecycle
///   - Singleton `AppState` (authenticated session, active game, navigation)
///   - `MockCore` injection (real UniFFI core replaces at H1 — no caller changes)
///   - `AuthStore.shared` — session gate before any CoreClient call
///
/// Architecture:
///   AppState is an `@Observable` class held at the app root and passed
///   into the environment. All child views read it via `@Environment(AppState.self)`.
///   No view owns mutable game/auth state directly — it all flows through AppState.
///
/// - SeeAlso: `ios/Sources/UI/NewGame/NewGameView.swift` (T045)
/// - SeeAlso: `ios/Sources/UI/HUD/HUDView.swift` (T051)
/// - SeeAlso: `ios/Sources/UI/PushToTalk/PushToTalkView.swift` (T052)

import SwiftUI
import Auth

// MARK: - RootView
//
// The `@main` app entry lives in the app target (App/DiamondLedgerApp.swift), which wraps
// this library. `RootView` is the public root the app target renders.

/// Gating router (ADR-0016): unauthenticated → SignInView; signed-in but age gate unanswered →
/// AgeGateView; under-13 → Under13BlockedView; otherwise → MainView. Restores a persisted owner
/// session on launch.
public struct RootView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        Group {
            if appState.session == nil {
                SignInView()
            } else if appState.consentStatus == .blockedUnder13 {
                Under13BlockedView()           // FR-029 — under-13 cannot record in v1.
            } else if !appState.consentResolved {
                AgeGateView()                  // FR-029 — ask once before any recording.
            } else {
                MainView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.session != nil)
        .animation(.easeInOut(duration: 0.25), value: appState.consentStatus)
        // Restore a persisted owner session on launch (ADR-0016); revoked Apple credential → nil.
        .task { await appState.restoreSession() }
    }
}
