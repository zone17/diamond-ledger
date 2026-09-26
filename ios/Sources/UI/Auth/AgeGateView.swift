/// AgeGateView.swift — T081 (Squad B, Story B0 / FR-029 / ADR-0016 §4)
///
/// The minimal COPPA age gate, shown once after sign-in and before any game can be recorded.
/// 13+ proceeds; under-13 is routed to `Under13BlockedView` (v1 does not collect their data;
/// verified parental consent is deferred to the backend).

import SwiftUI

struct AgeGateView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Before you start")
                .font(.title2.weight(.semibold))
            Text("Diamond Ledger is built for scorekeepers 13 and older. We don't knowingly collect data from children under 13.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Button("I'm 13 or older") {
                    appState.recordAgeResponse(isUnder13: false)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("age-gate-adult")

                Button("I'm under 13") {
                    appState.recordAgeResponse(isUnder13: true)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("age-gate-under13")
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }
}

/// Shown when a signed-in user has indicated they are under 13. Recording is blocked in v1.
struct Under13BlockedView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Thanks for your honesty")
                .font(.title3.weight(.semibold))
            Text("Diamond Ledger isn't available for scorekeepers under 13 yet. Verified parental consent is coming in a future update.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Sign out") { appState.signOut() }
                .buttonStyle(.bordered)
            Spacer()
        }
    }
}
