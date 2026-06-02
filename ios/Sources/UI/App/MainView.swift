/// MainView.swift — T045/T051/T052 (Squad B)
///
/// The root signed-in layout: persistent HUD at top, push-to-talk at bottom,
/// active card sheet in the center. All surfaces wired to AppState.

import SwiftUI
import Core
import DiamondSpeech
import Parse

struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Glanceable HUD — always present when a game is active.
                    if let game = appState.activeGame {
                        HUDView(game: game)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        noGameBanner
                    }
                    Spacer()
                }

                // Push-to-talk — thumb-reachable at bottom.
                PushToTalkView()
                    .padding(.bottom, 32)
            }
            .background(Color(.systemBackground))
            // --- Sheets ---
            // onDismiss unsticks the PTT loop if a card (e.g. Card A) is swiped away
            // instead of being Confirmed/Corrected — otherwise pttState stays `.result`
            // and the mic button is left disabled.
            .sheet(item: $state.presentedSheet, onDismiss: { appState.handleSheetDismiss() }) { sheet in
                sheetContent(for: sheet)
            }
            // --- Toolbar ---
            .toolbar {
                // T057: End Game → export sheet (only visible when a game is active).
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.activeGame != nil {
                        Button("End Game") {
                            appState.presentedSheet = .export
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    } else {
                        Button("New Game") {
                            appState.presentedSheet = .newGame
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if let name = appState.session?.displayName {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Diamond Ledger")
            .navigationBarTitleDisplayMode(.inline)
            // --- Error banner ---
            .alert("Error", isPresented: Binding(
                get: { appState.presentedError != nil },
                set: { if !$0 { appState.presentedError = nil } }
            )) {
                Button("OK", role: .cancel) { appState.presentedError = nil }
            } message: {
                if let err = appState.presentedError {
                    Text(err.message)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: appState.activeGame != nil)
        }
    }

    // MARK: - Helpers

    private var noGameBanner: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "figure.baseball")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No game in progress")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Start a Game") {
                appState.presentedSheet = .newGame
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: AppSheet) -> some View {
        switch sheet {
        case .newGame:
            NewGameView()
                .environment(appState)
        case .cardA(let result):
            CardAView(result: result)
                .environment(appState)
                .presentationDetents([.medium, .large])
        case .cardB(let result):
            CardBView(result: result)
                .environment(appState)
                .presentationDetents([.medium, .large])
        case .clarify(let candidates):
            ClarifyView(candidates: candidates)
                .environment(appState)
                .presentationDetents([.medium])
        case .manualEntry(let transcript):
            ManualEntryView(prefilledTranscript: transcript)
                .environment(appState)
                .presentationDetents([.medium])
        case .export:
            // T057 — Retrosheet export / finalize scorecard (Story B8).
            ExportView()
                .environment(appState)
                .presentationDetents([.large])
        }
    }
}
