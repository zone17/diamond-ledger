/// NewGameView.swift — T045 (Squad B, Story B1)
///
/// New Game flow: two team names + optional lineups → `CoreClient.createGame`.
///
/// Spec coverage:
///   - FR-001: names-only allowed at game creation (lineup is optional).
///   - FR-020 / I5: ownerId forwarded from the authenticated session.
///   - B1 / T045 Gherkin AC: "Given signed-in owner, when they enter two team names and tap
///     Start, then createGame is called with those names and the active game is set."
///
/// MVP scope: team names + optional lineup names (no positions at this stage).
/// Full roster management (FR-001 substitutions) is a later increment.

import SwiftUI
import Core

struct NewGameView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var homeTeam: String = ""
    @State private var visitorTeam: String = ""

    // Optional lineups: up to 9 batters per team (display names only at this stage)
    @State private var showLineups: Bool = false
    @State private var homeLineup: [String] = Array(repeating: "", count: 9)
    @State private var visitorLineup: [String] = Array(repeating: "", count: 9)

    @State private var isCreating: Bool = false

    private var canStart: Bool {
        !homeTeam.trimmingCharacters(in: .whitespaces).isEmpty &&
        !visitorTeam.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                teamsSection
                lineupsSection
            }
            .navigationTitle("New Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Start") {
                        Task { await startGame() }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canStart || isCreating)
                    .overlay {
                        if isCreating { ProgressView().scaleEffect(0.7) }
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var teamsSection: some View {
        Section {
            HStack {
                Text("Visitor")
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                TextField("e.g. Hawks", text: $visitorTeam)
                    .autocorrectionDisabled()
            }
            HStack {
                Text("Home")
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                TextField("e.g. Eagles", text: $homeTeam)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Teams")
        } footer: {
            Text("Lineups are optional — you can start with just team names (FR-001).")
                .font(.caption)
        }
    }

    private var lineupsSection: some View {
        Section {
            Toggle("Enter lineups", isOn: $showLineups.animation())
            if showLineups {
                lineupRows(label: visitorTeam.isEmpty ? "Visitor" : visitorTeam,
                           lineup: $visitorLineup)
                lineupRows(label: homeTeam.isEmpty ? "Home" : homeTeam,
                           lineup: $homeLineup)
            }
        } header: {
            Text("Lineups (optional)")
        }
    }

    @ViewBuilder
    private func lineupRows(label: String, lineup: Binding<[String]>) -> some View {
        ForEach(0..<9, id: \.self) { i in
            HStack {
                Text("\(label) #\(i + 1)")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(width: 100, alignment: .leading)
                TextField("Player name", text: lineup[i])
                    .autocorrectionDisabled()
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Action

    private func startGame() async {
        let home = homeTeam.trimmingCharacters(in: .whitespaces)
        let visitor = visitorTeam.trimmingCharacters(in: .whitespaces)
        guard !home.isEmpty, !visitor.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        await appState.createGame(homeTeam: home, visitorTeam: visitor)
        // AppState.createGame dismisses the sheet on success.
    }
}
