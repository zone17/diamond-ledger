/// SignInView.swift — T081 (Squad B, Story B0)
///
/// Minimal sign-in that establishes a real `ownerId` (not anonymous) before any
/// `CoreClient` primitive can be called (FR-020 / I5 / G1/G2).
///
/// MVP implementation: email + password form (primary path). Apple Sign-In is
/// required for App Store distribution (T081 full implementation); the button is
/// present and routes to the TODO Apple Sign-In path.
///
/// **Why real sign-in matters at MVP (analysis remediation G1/G2):**
/// The Rust core's owner-as-decider authority assertion (T036/FR-020/I5) binds to
/// an authenticated `ownerId`. A device-generated UUID does NOT satisfy the
/// authority or privacy claims — a real sign-in is required.
///
/// **Dev mode**: in `#if DEBUG` builds a "Dev Sign-In" button short-circuits to a
/// stub session for faster iteration against MockCore. This path MUST NOT ship.

import SwiftUI
import Auth

struct SignInView: View {
    @Environment(AppState.self) private var appState

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSigningIn: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                logo

                VStack(spacing: 16) {
                    emailField
                    passwordField
                    signInButton

                    divider

                    appleSignInButton
                }
                .padding(.horizontal, 32)

                #if DEBUG
                devSignInButton
                #endif

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

    private var emailField: some View {
        TextField("Email", text: $email)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
    }

    private var passwordField: some View {
        SecureField("Password", text: $password)
            .textFieldStyle(.roundedBorder)
    }

    private var signInButton: some View {
        Button {
            Task { await signInWithEmail() }
        } label: {
            if isSigningIn {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            } else {
                Text("Sign In")
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(email.isEmpty || password.isEmpty || isSigningIn)
    }

    private var divider: some View {
        HStack {
            VStack { Divider() }
            Text("or")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
    }

    private var appleSignInButton: some View {
        // TODO: T081 — replace with `SignInWithAppleButton` + AuthenticationServices.
        Button {
            errorMessage = "Apple Sign-In — coming in T081 full implementation."
        } label: {
            Label("Sign in with Apple", systemImage: "apple.logo")
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.bordered)
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

    private func signInWithEmail() async {
        guard !email.isEmpty, !password.isEmpty else { return }
        isSigningIn = true
        defer { isSigningIn = false }

        do {
            let session = try await AuthStore.shared.signIn(email: email, password: password)
            appState.session = session
        } catch AuthError.invalidCredentials(let msg) {
            errorMessage = msg
        } catch {
            // TODO: T081 — for MVP against MockCore, fall through to dev stub so the demo works.
            // This produces a stable ownerId from the email address.
            #if DEBUG
            appState.devSignIn(displayName: email.components(separatedBy: "@").first ?? email)
            #else
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
            #endif
        }
    }
}
