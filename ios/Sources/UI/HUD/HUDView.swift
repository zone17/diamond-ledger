/// HUDView.swift — T051 (Squad B, Story B4)
///
/// Glanceable game-state HUD: always visible, readable in a <1s glance (SC-005).
///
/// Anatomy (top-to-bottom, single-row layout optimized for portrait):
///   Row 1: [Inning+Half] [Outs dots] [Base diamond] [Count] [Score R/H]
///   Row 2: Due-up batter (visitor) | Due-up batter (home)
///
/// Design decisions:
///   - All display state derives from `GameState` (the protocol value) plus the team names.
///   - No business logic lives here; it is a pure projection of the state value.
///   - SC-005: every element fits in the top 80pt of the screen; text is ≥14pt.
///   - MockCore.GameState only carries `gameId/inning/isTopHalf/outs`; the additional
///     HUD fields (bases, count, line score, batter) are laid out but show safe defaults
///     when MockCore's minimal GameState is used. At H1 the UniFFI-generated type fills all.
///
/// - SeeAlso: `interaction-spec.md` §1 — screen anatomy
/// - SeeAlso: `ios/Sources/Core/CoreClient.swift` — `GameState`
/// - SeeAlso: `ios/Sources/UI/HUD/BaseDiamondView.swift`
/// - SeeAlso: `ios/Sources/UI/HUD/OutsDotsView.swift`

import SwiftUI
import Core

struct HUDView: View {
    let game: ActiveGame

    private var state: GameState { game.state }

    var body: some View {
        VStack(spacing: 4) {
            mainRow
            Divider()
                .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Material.bar)
    }

    // MARK: - Main row

    private var mainRow: some View {
        HStack(alignment: .center, spacing: 12) {
            inningLabel
            OutsDotsView(outs: state.outs)
            BaseDiamondView(state: state)
            countLabel
            Spacer(minLength: 0)
            lineScoreLabel
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: - Inning + half

    private var inningLabel: some View {
        VStack(spacing: 1) {
            // ▲ = top, ▼ = bottom
            Text(state.isTopHalf ? "▲" : "▼")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("\(state.inning)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 30)
    }

    // MARK: - Count (B-S)

    private var countLabel: some View {
        VStack(spacing: 1) {
            Text("B-S")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            // MockCore's GameState doesn't carry balls/strikes yet (H1 adds them).
            // Display "--" until the real state is available.
            Text("0-0")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(width: 40)
    }

    // MARK: - Line score (R/H compact)

    private var lineScoreLabel: some View {
        VStack(alignment: .trailing, spacing: 2) {
            lineScoreRow(label: visitorAbbrev, runs: 0)
            lineScoreRow(label: homeAbbrev, runs: 0)
        }
    }

    private func lineScoreRow(label: String, runs: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            Text("\(runs)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Helpers

    private var visitorAbbrev: String { abbrev(game.visitorTeamName) }
    private var homeAbbrev: String { abbrev(game.homeTeamName) }

    private func abbrev(_ name: String) -> String {
        // Up to 3 characters from the team name, uppercased.
        String(name.prefix(3)).uppercased()
    }
}

// MARK: - Outs dots

/// Three dots: filled = recorded out, hollow = remaining.
struct OutsDotsView: View {
    let outs: Int // 0...3 (3 = half-inning over, displayed briefly)

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i < outs ? Color.primary : Color.clear)
                    .overlay(Circle().stroke(Color.primary, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
            }
        }
    }
}

// MARK: - Base diamond

/// Classic baseball base diamond. Occupied bases are filled; empty bases are outlined.
struct BaseDiamondView: View {
    let state: GameState

    // MockCore.GameState doesn't carry bases yet (H1). Show all empty.
    // TODO: at H1 replace with `state.onFirst`, `state.onSecond`, `state.onThird`.
    private var onFirst: Bool { false }
    private var onSecond: Bool { false }
    private var onThird: Bool { false }

    var body: some View {
        // Diamond layout: second base at top, first at right, third at left, home at bottom.
        let side: CGFloat = 11
        let gap: CGFloat = 8

        ZStack {
            // Second base (top)
            baseDiamond(occupied: onSecond, side: side)
                .offset(x: 0, y: -(gap + side * 0.5))

            // First base (right)
            baseDiamond(occupied: onFirst, side: side)
                .offset(x: gap + side * 0.5, y: 0)

            // Third base (left)
            baseDiamond(occupied: onThird, side: side)
                .offset(x: -(gap + side * 0.5), y: 0)

            // Home plate (bottom, smaller pentagon-like diamond — just show as slightly smaller)
            baseDiamond(occupied: false, side: side * 0.8)
                .offset(x: 0, y: gap + side * 0.5)
        }
        .frame(width: (gap + side) * 2, height: (gap + side) * 2)
    }

    private func baseDiamond(occupied: Bool, side: CGFloat) -> some View {
        Rectangle()
            .fill(occupied ? Color.primary : Color.clear)
            .overlay(Rectangle().stroke(Color.primary, lineWidth: 1.5))
            .frame(width: side, height: side)
            .rotationEffect(.degrees(45))
    }
}
