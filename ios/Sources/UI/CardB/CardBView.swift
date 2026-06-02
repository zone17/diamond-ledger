/// CardBView.swift — T054 (Squad B, Story B6)
///
/// Card B — "Your call" judgment posture.
///
/// This is the make-or-break interaction (interaction-spec.md §Card B / V3 glance):
/// the core **refuses to decide**; the scorer's tap is the resolution.
///
/// Spec coverage:
///   - US2 / FR-010 / FR-011 / I2: judgment play surfaced open; never auto-resolved.
///   - interaction-spec.md §V3 (glance): visually DISTINCT from Card A, largest targets,
///     ≤5s one-tap resolve, equals-tappable alternatives, unresolved → cannot advance.
///   - FR-010a: "Leave PENDING" is envisioned as a first-class explicit choice — but it is HIDDEN
///     against the real core (DL-35), which has no pending/defer token in `resolve_judgment`
///     (showing it could only orphan the open judgment). Re-enable when issue #150 lands the path.
///   - I2 invariant: it is IMPOSSIBLE to advance state without an explicit tap — even
///     dismissing the sheet (swipe down) does not advance. The pending judgment blocks
///     the PTT button via AppState.pttState / activeGame.pendingResult guard.
///   - NEVER auto-resolve: `AppState.resolveJudgment(...)` is called only on an explicit
///     tap. There is no timer, no default, no "pick the recommendation if untouched".
///
/// Layout (portrait, modal sheet — medium/large):
///   ┌──────────────────────────────────────┐
///   │  🟡  YOUR CALL                       │  ← visually distinct badge / header
///   │  Hit or Error?                       │  ← judgment question
///   ├──────────────────────────────────────┤
///   │  💡 "Looked like a clean single"     │  ← recommendation + one-line why
///   ├──────────────────────────────────────┤
///   │  [      Hit       ]                  │  ← equally-tappable alternatives
///   │  [    Error (SS)  ]                  │
///   │  [  Leave PENDING ]                  │  ← explicit deferred (FR-010a)
///   └──────────────────────────────────────┘
///
/// Guard: swipe-to-dismiss is DISABLED — the scorer must make an explicit choice.
/// AppState also guards PTT: if `pendingResult != nil`, starting a new play is blocked.

import SwiftUI
import Core

struct CardBView: View {
    @Environment(AppState.self) private var appState

    let result: RecordPlayResult

    @State private var isResolving: Bool = false
    @State private var chosenToken: String?

    private var judgment: RecordPlayJudgment? { result.judgment }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    yourCallBadge
                    judgmentQuestion
                    recommendationCard
                    alternativeButtons
                    // "Leave PENDING" is HIDDEN against the real core (DL-35): the core's
                    // resolve_judgment has no pending/defer token, so the button could only orphan
                    // the open judgment. Re-enable when issue #150 lands the pending-token path. The
                    // `pendingOption` view + `AppState.deferJudgment` are retained (guarded) so the
                    // wiring is ready, but not shown.
                    blockadeNote
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    yourCallBadgeInline
                }
            }
        }
        .presentationBackground(.regularMaterial)
        .presentationDragIndicator(.hidden)  // Hide drag indicator to discourage swipe-dismiss.
        // Guard: interactiveDismissDisabled so the scorer cannot swipe away without choosing.
        .interactiveDismissDisabled(true)
        .accessibilityLabel("Your call required")
    }

    // MARK: - Your Call badge

    private var yourCallBadge: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.yellow)
            Text("YOUR CALL")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
                .tracking(1.5)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var yourCallBadgeInline: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.yellow)
            Text("Your Call")
                .fontWeight(.semibold)
        }
        .font(.subheadline)
    }

    // MARK: - Judgment question

    private var judgmentQuestion: some View {
        Text(judgmentQuestionText)
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.primary)
    }

    private var judgmentQuestionText: String {
        guard let j = judgment else { return "Your call" }
        switch j.kind {
        case .hitVsError:        return "Hit or Error?"
        case .earnedVsUnearned:  return "Earned or Unearned?"
        case .contestedCredit:   return "Who gets credit?"
        case .ambiguousAdvance:  return "Where does the runner go?"
        }
    }

    // MARK: - Recommendation card

    private var recommendationCard: some View {
        Group {
            if let j = judgment {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                        Text("Engine suggests:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("\"\(j.recommendation.call.label)\"")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(j.recommendation.oneLineReason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This is a suggestion, not a decision — your tap is the call.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.yellow.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.yellow.opacity(0.25), lineWidth: 1)
                        )
                )
            }
        }
    }

    // MARK: - Alternative buttons (equally-tappable)

    private var alternativeButtons: some View {
        VStack(spacing: 12) {
            if let j = judgment {
                // Show recommendation first so it's prominent but NOT pre-selected.
                // All buttons have equal visual weight (V3 spec: equally-tappable).
                let allCalls = deduplicated(
                    [j.recommendation.call] + j.alternatives
                )
                ForEach(allCalls, id: \.token) { call in
                    callButton(call: call, isRecommendation: call.token == j.recommendation.call.token)
                }
            }
        }
    }

    private func callButton(call: ScoringCall, isRecommendation: Bool) -> some View {
        let isChosen = chosenToken == call.token

        return Button {
            Task { await resolve(chosen: call) }
        } label: {
            HStack {
                Text(call.label)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                if isRecommendation {
                    Text("suggested")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if isChosen {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isChosen ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isChosen ? Color.accentColor : Color.clear, lineWidth: 2)
                )
        )
        .disabled(isResolving)
        .accessibilityLabel("\(call.label)\(isRecommendation ? " — engine suggestion" : "")")
        .accessibilityHint("Tap to record this as your call")
    }

    // MARK: - Leave PENDING (FR-010a) — retained but NOT shown against the real core (DL-35)
    //
    // Hidden from the body (see the call site): the real core has no pending/defer token in
    // resolve_judgment, so showing this could only orphan the open judgment. Kept so the wiring is
    // ready to re-enable when issue #150 lands the pending-token path; intentionally unreferenced today.
    private var pendingOption: some View {
        VStack(spacing: 8) {
            Divider()
            Button {
                appState.deferJudgment()
            } label: {
                HStack {
                    Image(systemName: "clock.badge.questionmark")
                        .foregroundStyle(.secondary)
                    Text("Leave PENDING — decide later")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .disabled(isResolving)
            .accessibilityLabel("Leave this judgment pending — decide later")
            .accessibilityHint("This is an explicit deferred call. The play is still recorded.")
        }
    }

    // MARK: - Guard note

    private var blockadeNote: some View {
        Text("You cannot record the next play until you make a call.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Actions

    private func resolve(chosen: ScoringCall) async {
        guard let j = judgment, !isResolving else { return }
        isResolving = true
        chosenToken = chosen.token
        await appState.resolveJudgment(decisionId: j.id, chosen: chosen)
        // AppState.resolveJudgment dismisses the sheet on success.
        isResolving = false
        chosenToken = nil
    }

    // MARK: - Helpers

    /// Deduplicate calls by token (recommendation may appear again in alternatives).
    private func deduplicated(_ calls: [ScoringCall]) -> [ScoringCall] {
        var seen = Set<String>()
        return calls.filter { seen.insert($0.token).inserted }
    }
}
