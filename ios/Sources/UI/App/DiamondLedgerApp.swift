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

/// Gating router (ADR-0016): restoring → neutral splash; under-13 → Under13BlockedView;
/// unauthenticated → SignInView; signed-in but age gate unanswered → AgeGateView; otherwise →
/// MainView. Restores a persisted owner session on launch.
///
/// **Order matters.** The under-13 branch is tested *before* the session branch: answering
/// "under 13" purges the persisted session (FR-029, see `AppState.refreshConsentStatus`), and if
/// the session check came first the child would be bounced to a sign-in screen instead of the
/// screen that explains why they cannot record.
public struct RootView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        Group {
            if appState.isRestoringSession {
                restoringPlaceholder           // avoids flashing sign-in at a signed-in owner.
            } else if appState.consentStatus == .blockedUnder13 {
                Under13BlockedView()           // FR-029 — under-13 cannot record in v1.
            } else if appState.session == nil {
                SignInView()
            } else if !appState.consentResolved {
                AgeGateView()                  // FR-029 — ask once before any recording.
            } else {
                MainView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.session != nil)
        .animation(.easeInOut(duration: 0.25), value: appState.consentStatus)
        .animation(.easeInOut(duration: 0.25), value: appState.isRestoringSession)
        // Restore a persisted owner session on launch (ADR-0016); revoked Apple credential → nil.
        .task { await appState.restoreSession() }
    }

    /// Shown only for the length of the launch-time Keychain read + Apple credential-state check.
    private var restoringPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            ProgressView()
        }
        .accessibilityIdentifier("session-restoring")
    }
}
