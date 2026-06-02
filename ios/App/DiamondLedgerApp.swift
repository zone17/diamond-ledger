// DiamondLedgerApp.swift — the runnable iOS app target entry (DL-133).
//
// This thin @main wraps the DiamondLedgerLib package (Core/UI/Speech/Parse/Persistence/Auth).
// The app logic + views live in the library (testable as a package); this target produces the
// launchable .app. The real UniFFI core (DiamondCoreClient) is injected as of H1 (T071 / DL-35);
// MockCore remains available for previews/tests.

import SwiftUI
import UI
import Core

@main
struct DiamondLedgerApp: App {

    @State private var appState = AppState(core: DiamondCoreClient())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}
