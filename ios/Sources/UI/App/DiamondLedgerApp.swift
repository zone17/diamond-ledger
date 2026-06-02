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
import Core

// MARK: - App entry

@main
struct DiamondLedgerApp: App {

    @State private var appState = AppState(core: MockCore())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}

// MARK: - RootView

/// Gating router: shows SignInView when unauthenticated, MainView when signed in.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.session != nil {
                MainView()
            } else {
                SignInView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.session != nil)
    }
}
