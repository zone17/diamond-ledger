// DiamondLedgerApp.swift — the runnable iOS app target entry (DL-133).
//
// This thin @main wraps the DiamondLedgerLib package (Core/UI/Speech/Parse/Persistence/Auth).
// The app logic + views live in the library (testable as a package); this target produces the
// launchable .app. MockCore is injected until the real UniFFI core lands at H1.

import SwiftUI
import UI
import Core

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
