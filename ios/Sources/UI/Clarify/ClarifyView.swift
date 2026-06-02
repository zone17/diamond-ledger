/// ClarifyView.swift — T050 (Squad B, Story B3)
///
/// Ambiguity path (FR-008): when the grammar parse produces multiple candidate mappings
/// or low-confidence, this view surfaces a **single clarifying question** — never a guess.
///
/// The scorer taps one candidate → it is forwarded to `CoreClient.recordPlay` as a
/// pre-selected normalized play.
///
/// Design invariant (Art. VI / I1): a silent guess is NEVER made. If no candidates are
/// available, the view falls back to manual entry.

import SwiftUI
import Core

struct ClarifyView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let candidates: [ClarifyCandidate]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding()

                if candidates.isEmpty {
                    // No candidates: fall directly to manual entry.
                    manualEntryPrompt
                } else {
                    candidateList
                }
            }
            .navigationTitle("What was that play?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Manual Entry") {
                        appState.presentedSheet = .manualEntry(prefilledTranscript: "")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        appState.correctPendingEntry()
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("I wasn't sure — pick the play:")
                .font(.headline)
            Text("Tap the correct play below or enter it manually. I'll never guess.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var candidateList: some View {
        List(candidates) { candidate in
            Button {
                Task {
                    await appState.recordPlay(facts: candidate.facts)
                }
            } label: {
                HStack {
                    Text(candidate.label)
                        .font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .foregroundStyle(.primary)
        }
        .listStyle(.insetGrouped)
    }

    private var manualEntryPrompt: some View {
        VStack(spacing: 16) {
            Text("Couldn't understand the play. Enter it manually.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Manual Entry") {
                appState.presentedSheet = .manualEntry(prefilledTranscript: "")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - ManualEntryView

/// Fallback manual text entry for out-of-grammar or rejected transcripts (FR-017).
/// Never fabricates — the scorer types the play directly.
struct ManualEntryView: View {
    @Environment(AppState.self) private var appState

    let prefilledTranscript: String
    @State private var text: String = ""
    @State private var isSubmitting: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Enter the play") {
                    TextField("e.g. 6-3 ground out", text: $text, axis: .vertical)
                        .lineLimit(3)
                        .autocorrectionDisabled()
                }

                Section {
                    Button("Submit") {
                        Task { await submit() }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
            }
            .navigationTitle("Manual Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { appState.correctPendingEntry() }
                }
            }
            .onAppear {
                text = prefilledTranscript
            }
        }
    }

    private func submit() async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSubmitting = true
        // For MVP: forward as a raw transcript so MockCore routes appropriately.
        // The real adapter normalizes first (parse layer); here we pass as a script
        // marker if the text is a known token, else as-is.
        var facts: [String: String] = ["manual_entry": trimmed]

        // Recognise the WoZ misplayed-grounder shorthand for demo purposes.
        if trimmed.lowercased().contains("error") || trimmed.lowercased().contains("misplay") {
            facts["script"] = "misplayed-grounder"
        }

        await appState.recordPlay(facts: facts)
        isSubmitting = false
    }
}
