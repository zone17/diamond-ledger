/// CardAView.swift — T053 (Squad B, Story B5)
///
/// Card A — Deterministic play: plain-language restatement + secondary Reisner token +
/// state delta + one-tap Confirm/Correct.
///
/// Spec coverage:
///   - FR-007: state does not advance until "Confirm" is tapped.
///   - interaction-spec.md §Card A: big restatement, secondary Reisner, one primary action.
///   - SC-005: dismissable almost without reading (≤1 phrase + ≤1 tap for ~85% of plays).
///   - MVP correction scope (remediation I1): "Correct" amends only the *pending unconfirmed*
///     entry (re-record before confirm). Prior-play amend via `correct_event` is US4/post-MVP
///     and is NOT surfaced here.
///
/// Layout (portrait, bottom sheet):
///   ┌─────────────────────────────────────┐
///   │   ▸ Ground out, short to first      │  ← big plain-language restatement
///   │     6-3                             │  ← secondary Reisner token
///   │     1 out → 2 outs   (delta)        │  ← state delta
///   ├─────────────────────────────────────┤
///   │  [  Correct  ]   [     Confirm     ]│  ← one-tap confirm (large), Correct secondary
///   └─────────────────────────────────────┘
///
/// Auto-advance: Confirm tap → `AppState.confirmPlay()` → sheet dismisses, HUD updates.

import SwiftUI
import Core

struct CardAView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let result: RecordPlayResult

    @State private var isConfirming: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                playCard
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                Spacer()

                actionRow
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Label("Play recorded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .presentationBackground(.regularMaterial)
        .presentationDragIndicator(.visible)
    }

    // MARK: - Play card

    private var playCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Plain-language restatement — big, primary.
            Text(plainLanguageDescription)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.primary)
                .accessibilityLabel("Play: \(plainLanguageDescription)")

            HStack(spacing: 16) {
                // Secondary Reisner token.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result.reisner.catalystSymbols)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                Divider()
                    .frame(height: 40)

                // State delta.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(stateDelta)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Situation diamond (before play).
            HStack(spacing: 8) {
                Text(result.reisner.situationDiamond)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(pitchMarkString)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 16) {
            // Correct — secondary, smaller.
            Button("Correct") {
                appState.correctPendingEntry()
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Correct this play — re-record before confirming")

            // Confirm — primary, large, thumb-reachable.
            Button {
                Task { await confirm() }
            } label: {
                if isConfirming {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                } else {
                    Text("Confirm")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConfirming)
            .accessibilityLabel("Confirm play")
            .accessibilityHint("Advances the game to the next at-bat")
        }
    }

    // MARK: - Actions

    private func confirm() async {
        isConfirming = true
        defer { isConfirming = false }
        await appState.confirmPlay()
    }

    // MARK: - Display helpers

    /// Plain-language restatement derived from the Reisner cell and classification.
    private var plainLanguageDescription: String {
        plainLanguage(
            catalystSymbols: result.reisner.catalystSymbols,
            fate: result.reisner.runnerFate
        )
    }

    private func plainLanguage(catalystSymbols: String, fate: RunnerFate) -> String {
        // Map common Reisner tokens to plain language.
        let token = catalystSymbols.uppercased()

        if token.hasPrefix("K") { return "Struck out" }
        if token == "BB"        { return "Walk — batter takes first" }
        if token == "HBP"       { return "Hit by pitch" }
        if token == "HR"        { return "Home run!" }
        if token.hasPrefix("S") && !token.hasPrefix("SF") && !token.hasPrefix("SH") {
            return "Single"
        }
        if token.hasPrefix("D") && !token.hasPrefix("DP") { return "Double" }
        if token.hasPrefix("T")  { return "Triple" }
        if token.hasPrefix("SF") { return "Sacrifice fly" }
        if token.hasPrefix("SH") { return "Sacrifice bunt" }
        if token.hasPrefix("DP") { return "Double play — \(token)" }
        if token.hasPrefix("E")  { return "Reached on error (\(token))" }

        // Generic fielder notation (e.g. "6-3")
        if token.contains("-") || (token.count >= 2 && token.allSatisfy({ $0.isNumber })) {
            return "Ground out — \(token)"
        }
        if token.hasPrefix("F") { return "Fly out — \(token)" }

        return token
    }

    private var stateDelta: String {
        let preview = result.statePreview
        switch result.reisner.runnerFate {
        case .putOut(let n):
            return "\(n == 1 ? "1 out" : "\(n) outs")"
        case .scored:
            return "Run scores"
        case .leftOnBase:
            return "Inning \(preview.inning), \(preview.isTopHalf ? "top" : "bottom")"
        }
    }

    private var pitchMarkString: String {
        result.reisner.pitchMarks.joined(separator: " ")
    }
}
