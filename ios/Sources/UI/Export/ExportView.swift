/// ExportView.swift — T057 (Squad B, Story B8)
///
/// Retrosheet export UI: invoke `finalize_scorecard` via `CoreClient`, render the human
/// Reisner scorebook, and share the `cwevent`-gated Retrosheet event file with attribution.
///
/// ## Spec coverage
///   - US3 / FR-015: close the game, emit both the human Reisner book and the Retrosheet file.
///   - FR-016 / I4: the Retrosheet file is `cwevent`-gated in CI; the UI trusts the core's output.
///   - FR-020 / I5: owner-as-decider authority check; empty `ownerId` → error.
///   - FR-005a / SC-011: the core rejects a finalization with an unbalanced proof-box.
///   - SC-006 / T056: the scorecard must survive a session with no connectivity.
///
/// ## Attribution requirement
///   Per Retrosheet's data use policy, any export shared from this app must include:
///   "The information used here was obtained free of charge from and is copyrighted by
///    Retrosheet. Interested parties may contact Retrosheet at www.retrosheet.org."
///   This attribution is embedded in the share sheet as body text and in the exported file
///   header comment.
///
/// ## Layout (modal sheet, bottom card)
///
///   ┌─────────────────────────────────────────┐
///   │  Scorebook Complete                     │  ← title
///   │  ─────────────────────────────────────  │
///   │  [Human Reisner Book — scrollable]      │  ← monospaced text
///   │  ─────────────────────────────────────  │
///   │  Retrosheet export                      │  ← section header
///   │  [cwevent-gated file preview]           │
///   │  ─────────────────────────────────────  │
///   │  Attribution notice                     │
///   │  ─────────────────────────────────────  │
///   │  [Share]  [Done]                        │  ← action row
///   └─────────────────────────────────────────┘
///
/// - SeeAlso: `ios/Sources/Core/CoreClient.swift` — `finalizeScorecard` primitive
/// - SeeAlso: `ios/Sources/Core/MockCore.swift` — canned export (until H1)
/// - SeeAlso: `specs/001-voice-scorebook-core/contracts/finalize_scorecard.md`

import SwiftUI
import Core

// MARK: - ExportView

/// Main export/finalize sheet. Invoked from the game toolbar when the scorer wants to end the game.
public struct ExportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    enum ExportPhase {
        case idle
        case finalizing
        case ready(FinalizedScorebook)
        /// `reason` is the underlying `CoreError` (nil for unexpected non-core errors) so the view
        /// can decide whether "Try again" makes sense and whether to offer "Exit without saving".
        case failed(message: String, reason: CoreError?)
    }

    @State private var phase: ExportPhase = .idle
    @State private var showShareSheet: Bool = false
    @State private var shareItems: [Any] = []
    /// Temp `.evn` file backing the current share, if any. Deleted when the share completes.
    @State private var sharedTempFileURL: URL?
    @State private var showRetrosheetPreview: Bool = false
    @State private var showReisnerPreview: Bool = false

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .idle:
                    finalizePromptView
                case .finalizing:
                    finalizingSpinner
                case .ready(let book):
                    scorebookReadyView(book: book)
                case .failed(let message, let reason):
                    errorView(message: message, reason: reason)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .presentationBackground(.regularMaterial)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .sheet(isPresented: $showShareSheet) {
            ActivityView(activityItems: shareItems) {
                // Share finished (completed or cancelled): clean up the temp .evn file so we
                // don't leak files into the temporary directory across exports.
                cleanupSharedTempFile()
            }
        }
        .task {
            // Auto-trigger finalization when the sheet opens.
            await finalizeScorecard()
        }
    }

    // MARK: - Navigation

    private var navigationTitle: String {
        switch phase {
        case .idle, .finalizing: return "Finalizing…"
        case .ready:             return "Scorebook Complete"
        case .failed:            return "Export Error"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
                .font(.body.weight(.semibold))
        }
    }

    // MARK: - Subviews

    private var finalizePromptView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Finalizing your scorecard…")
                .font(.title3.weight(.semibold))
            Text("Verifying the proof-box balance and generating the Retrosheet export.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var finalizingSpinner: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Generating scorebook…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func scorebookReadyView(book: FinalizedScorebook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Reisner Book
                reisnerSection(book: book)

                Divider()

                // MARK: Retrosheet Export
                retrosheetSection(book: book)

                Divider()

                // MARK: Attribution
                attributionSection

                Divider()

                // MARK: Action Row
                actionRow(book: book)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
    }

    private func reisnerSection(book: FinalizedScorebook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Human Scorebook (Reisner)", systemImage: "pencil.and.list.clipboard")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Your official hand-scored game record:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Expandable Reisner book preview.
            VStack(alignment: .leading, spacing: 0) {
                let lines = book.reisnerBook.components(separatedBy: .newlines)
                let preview = lines.prefix(6).joined(separator: "\n")
                let hasMore = lines.count > 6

                Text(preview)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if hasMore && !showReisnerPreview {
                    Button("Show full scorebook (\(lines.count) lines)…") {
                        showReisnerPreview = true
                    }
                    .font(.subheadline)
                    .padding(.top, 8)
                }

                if showReisnerPreview {
                    let remaining = lines.dropFirst(6).joined(separator: "\n")
                    Text(remaining)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    private func retrosheetSection(book: FinalizedScorebook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Retrosheet Event File", systemImage: "doc.badge.gearshape")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("cwevent-gated format (Chadwick v0.10.0)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("Machine-readable play-by-play compatible with Retrosheet, SABR, and stat tools:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Collapsible preview of the .evn file.
            VStack(alignment: .leading, spacing: 0) {
                let lines = book.retrosheetEvents.components(separatedBy: .newlines)
                let preview = lines.prefix(8).joined(separator: "\n")
                let hasMore = lines.count > 8

                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if hasMore && !showRetrosheetPreview {
                    Button("Show full event file (\(lines.count) lines)…") {
                        showRetrosheetPreview = true
                    }
                    .font(.subheadline)
                    .padding(.top, 8)
                }

                if showRetrosheetPreview {
                    let remaining = lines.dropFirst(8).joined(separator: "\n")
                    Text(remaining)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    private var attributionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Attribution", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(RetroAttribution.shortNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link("www.retrosheet.org", destination: RetroAttribution.retrosheetURL)
                .font(.caption.weight(.medium))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.tertiarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
        )
    }

    private func actionRow(book: FinalizedScorebook) -> some View {
        HStack(spacing: 16) {
            // Share the Retrosheet .evn file.
            Button {
                prepareShareItems(book: book)
                showShareSheet = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Share Retrosheet export file and Reisner scorebook")

            // Done — dismiss the sheet.
            Button("Done") {
                dismiss()
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.primary)
            .accessibilityLabel("Done — close the export view")
        }
        .padding(.bottom, 16)
    }

    /// The game can't be finalized yet because there are outstanding scoring items (an in-progress
    /// half-inning, an open judgment, or an unconfirmed play). For these, "Try again" alone is a
    /// dead end — the user must go back and resolve the item, or exit without saving. We detect that
    /// class from the carried `CoreError` and offer the right choices.
    private func isIncompleteGame(_ reason: CoreError?) -> Bool {
        switch reason {
        case .proofBoxImbalance, .judgmentRequired, .invalidState: return true
        default: return false
        }
    }

    private func errorView(message: String, reason: CoreError?) -> some View {
        let incomplete = isIncompleteGame(reason)
        return VStack(spacing: 20) {
            Image(systemName: incomplete ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(incomplete ? .orange : .red)

            Text(incomplete ? "Game not finished" : "Export failed")
                .font(.title3.weight(.bold))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                if incomplete {
                    // Primary: go back and resolve the outstanding item (the card / next play).
                    Button("Back to game") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Back to the game to resolve the outstanding play")

                    // Secondary, destructive: leave without producing an official record.
                    Button(role: .destructive) {
                        appState.exitGameWithoutFinalizing()
                        dismiss()
                    } label: {
                        Text("Exit without saving")
                    }
                    .accessibilityLabel("Exit the game without finalizing or exporting")
                } else {
                    // Transient/auth/internal failures: retrying may succeed.
                    Button("Try again") {
                        Task { await finalizeScorecard() }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Back to game") { dismiss() }
                        .accessibilityLabel("Close the export view")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func finalizeScorecard() async {
        guard let game = appState.activeGame,
              let ownerId = appState.session?.ownerId, !ownerId.isEmpty else {
            phase = .failed(message: "Sign in before exporting the scorecard.", reason: nil)
            return
        }

        phase = .finalizing

        do {
            let book = try await appState.core.finalizeScorecard(
                gameId: game.gameId,
                ownerId: ownerId,
                correlationId: UUID().uuidString
            )
            phase = .ready(book)
        } catch let coreError as CoreError {
            // Map each real-core reason to a clear, actionable message — never a generic
            // "something went wrong" that hides the cause (DL-35). The carried message is the
            // real core's own text (CoreError: LocalizedError), so the reason is always legible.
            phase = .failed(message: Self.finalizeFailureMessage(for: coreError), reason: coreError)
        } catch {
            // Truly unexpected (non-CoreError) — still surface the real description, not a placeholder.
            phase = .failed(message: "Couldn't finalize the scorecard: \(error.localizedDescription)", reason: nil)
        }
    }

    /// Map a `CoreError` from finalize to a clear, actionable scorer-facing message. Each carries the
    /// real core reason; the user is told exactly what to do (resolve, finish the inning, or exit).
    static func finalizeFailureMessage(for error: CoreError) -> String {
        switch error {
        case .proofBoxImbalance(let detail):
            return "The current half-inning isn't complete yet, so the scorebook can't be balanced and finalized.\n\nFinish the half-inning (3 outs) before ending the game — or exit without saving.\n\nDetails: \(detail)"
        case .judgmentRequired(let detail):
            return "One or more judgment calls are still open. Resolve every open call (Hit vs Error, etc.) before ending the game.\n\nDetails: \(detail)"
        case .invalidState(let detail):
            // FR-007: a recorded-but-unconfirmed play blocks finalize.
            return "There's a play that hasn't been confirmed yet. Confirm (or resolve) it, then end the game.\n\nDetails: \(detail)"
        case .unauthorized(let detail):
            return "You're not authorized to finalize this game.\n\nDetails: \(detail)"
        case .notFound(let detail):
            return "This game couldn't be found in the scoring core.\n\nDetails: \(detail)"
        case .internalError(let detail):
            return "The scoring core hit an unexpected error finalizing the game.\n\nDetails: \(detail)"
        }
    }

    private func prepareShareItems(book: FinalizedScorebook) {
        // Build the file to share: a .evn (Retrosheet event) file.
        // The file includes the full attribution header and the event records.
        let fileContent = """
        \(RetroAttribution.fileHeader)
        \(book.retrosheetEvents)
        """

        // Clean up any temp file from a previous share before creating a new one.
        cleanupSharedTempFile()

        // Write to a temporary file so the share sheet can offer "Save to Files".
        let tmpURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("scorebook-\(Date().timeIntervalSince1970).evn")

        do {
            try fileContent.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            // Fallback: share as plain text (no temp file to track).
            sharedTempFileURL = nil
            shareItems = [fileContent, RetroAttribution.shortNotice]
            return
        }

        // Track the temp file so it can be deleted when the share completes.
        sharedTempFileURL = tmpURL
        // Share: the .evn file + human Reisner book as text + attribution.
        shareItems = [tmpURL, book.reisnerBook, RetroAttribution.shortNotice]
    }

    /// Deletes the temp `.evn` file backing the most recent share, if present. Idempotent.
    private func cleanupSharedTempFile() {
        guard let url = sharedTempFileURL else { return }
        sharedTempFileURL = nil
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - ActivityView (UIActivityViewController wrapper)

/// SwiftUI wrapper for `UIActivityViewController` (the iOS share sheet).
///
/// Invokes `onComplete` once the share finishes (whether the user completed an activity or
/// cancelled) so the caller can clean up any temp file backing the share.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    /// Called when the activity sheet completes or is dismissed. Always fires exactly once.
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - RetroAttribution

/// Retrosheet attribution constants, required by Retrosheet data use policy.
enum RetroAttribution {
    static let retrosheetURL = URL(string: "https://www.retrosheet.org")!

    /// Short attribution notice for display in the share sheet body and UI.
    static let shortNotice: String = """
    The information used here was obtained free of charge from and is copyrighted by \
    Retrosheet. Interested parties may contact Retrosheet at www.retrosheet.org.
    """

    /// File header comment block embedded at the top of every exported .evn file.
    static let fileHeader: String = """
    # Diamond Ledger — Retrosheet Event File
    # Generated by Diamond Ledger (https://diamondledger.app)
    # \(shortNotice)
    #
    """
}
