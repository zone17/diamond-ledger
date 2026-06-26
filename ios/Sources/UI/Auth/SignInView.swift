/// SignInView.swift — T081 (Squad B, Story B0 / ADR-0016)
///
/// Establishes a real `ownerId` via **Sign in with Apple** before any `CoreClient` primitive can
/// be called (FR-020 / I5 / FR-023). The Apple credential's stable `user` id becomes the owner
/// identity the Rust core's authority assertion (T036) validates against.
///
/// Email/password + Google are deferred to the sync/backend milestone (ADR-0016 §3) — an offline
/// app has nothing to verify a password against, so we do not ship a fake email form.
///
/// **Dev mode**: in `#if DEBUG` builds a "Dev Sign-In" button short-circuits to a stub session for
/// faster iteration against MockCore. `AppState.devSignIn` is itself `#if DEBUG`, so a release build
/// cannot mint a stub identity.

import SwiftUI
import AuthenticationServices
import Auth

struct SignInView: View {
    @Environment(AppState.self) private var appState

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                logo
                Spacer()

                VStack(spacing: 16) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName]
                    } onCompletion: { result in
                        handleAppleResult(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)
                    .accessibilityIdentifier("sign-in-apple")

                    #if DEBUG
                    devSignInButton
                    #endif
                }
                .padding(.horizontal, 32)

                Spacer()
                privacyNote
            }
            .navigationTitle("Diamond Ledger")
            .navigationBarTitleDisplayMode(.large)
            .alert("Sign In Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                if let msg = errorMessage { Text(msg) }
            }
        }
    }

    // MARK: - Subviews

    private var logo: some View {
        VStack(spacing: 8) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 40)
            Text("Score by voice.\nKeep eyes on the field.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    #if DEBUG
    private var devSignInButton: some View {
        Button("Dev Sign-In (debug only)") {
            appState.devSignIn(displayName: "Dev Scorer")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    #endif

    private var privacyNote: some View {
        Text("Your scorebooks are private to you until you share them explicitly.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
    }

    // MARK: - Actions

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Unexpected credential type from Sign in with Apple."
                return
            }
            appState.completeAppleSignIn(appleUserID: credential.user, fullName: credential.fullName)
        case .failure(let error):
            // User dismissing the sheet is not an error to surface.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }
}
