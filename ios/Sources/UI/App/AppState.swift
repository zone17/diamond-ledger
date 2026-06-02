/// AppState.swift — T045 (Squad B, Story B1)
///
/// Single source of truth for the running app: auth session, active game, pending card state,
/// and the CoreClient handle. Passed into the SwiftUI environment at the app root.
///
/// **Threading**: `@Observable` + `@MainActor` — all mutations happen on the main actor so
/// SwiftUI view updates are safe. Async CoreClient calls are `await`ed inside Task blocks
/// dispatched from view actions.
///
/// **Ownership**: AppState owns the `CoreClient`; it does not own `AuthStore` (singleton).
///
/// - SeeAlso: `DiamondLedgerApp.swift` — injection point
/// - SeeAlso: `ios/Sources/Core/CoreClient.swift` — protocol
/// - SeeAlso: `ios/Sources/Core/MockCore.swift` — current conformer (T008)

import Foundation
import SwiftUI
import Core
import Auth

// MARK: - Active Game

/// Live scorable game — everything the HUD and cards need.
@MainActor
final class ActiveGame: ObservableObject {
    let gameId: String
    let homeTeamName: String
    let visitorTeamName: String
    var state: GameState

    /// The pending record-play result waiting for confirm/judgment.
    var pendingResult: RecordPlayResult?

    init(gameId: String, homeTeamName: String, visitorTeamName: String, state: GameState) {
        self.gameId = gameId
        self.homeTeamName = homeTeamName
        self.visitorTeamName = visitorTeamName
        self.state = state
    }
}

// MARK: - App-level Navigation

enum AppSheet: Identifiable {
    case newGame
    case cardA(RecordPlayResult)
    case cardB(RecordPlayResult)
    case clarify(candidatePlays: [ClarifyCandidate])
    case manualEntry(prefilledTranscript: String)
    /// T057 — Retrosheet export / finalize scorecard (Story B8).
    case export

    var id: String {
        switch self {
        case .newGame:      return "newGame"
        case .cardA:        return "cardA"
        case .cardB:        return "cardB"
        case .clarify:      return "clarify"
        case .manualEntry:  return "manualEntry"
        case .export:       return "export"
        }
    }
}

struct ClarifyCandidate: Sendable, Identifiable {
    let id: UUID = UUID()
    let label: String
    let facts: [String: String]
}

// MARK: - AppState

@MainActor
@Observable
public final class AppState {

    // MARK: Auth

    /// The currently signed-in session (`nil` → shows SignInView).
    var session: AuthSession?

    // MARK: Game

    /// The in-progress game, or `nil` when no game is active.
    var activeGame: ActiveGame?

    // MARK: Navigation

    /// The currently presented sheet (card A/B, new-game, clarify, etc.)
    var presentedSheet: AppSheet?

    // MARK: Push-to-talk

    enum PTTState: Equatable {
        /// Thumb-resting idle.
        case idle
        /// Microphone open, capturing.
        case listening
        /// ASR/parse in flight.
        case processing
        /// Result ready — card will appear.
        case result
    }

    var pttState: PTTState = .idle

    // MARK: Error banner

    struct AppError: Identifiable {
        let id: UUID = UUID()
        let message: String
    }
    var presentedError: AppError?

    // MARK: Core

    let core: any CoreClient

    // MARK: Init

    public init(core: any CoreClient) {
        self.core = core
    }

    /// Called when a presented sheet is dismissed. Unsticks the push-to-talk loop so the mic
    /// button is never left disabled after a sheet closes.
    ///
    /// ## H1 reconciliation (DL-35): do NOT blindly drop `pendingResult` here.
    ///
    /// Against the **stateful real core** a recorded-but-unconfirmed play lives in the append-only
    /// event log; the core has **no discard/cancel primitive** (verified — see ADR / MANUAL-TESTING).
    /// The ONLY way to clear it is `confirmPlay` (or resolving its open judgment then confirming).
    /// The old behaviour — `activeGame?.pendingResult = nil` on every dismiss — orphaned the play:
    /// the UI forgot it while the core still held it, so the next mic press hit the real core's
    /// FR-007 `PendingConfirmation` guard with no way for the user to recover.
    ///
    /// Card A and Card B are now non-dismissible by swipe (`interactiveDismissDisabled`), so this
    /// runs only for sheets that legitimately have no pending play (newGame / export / clarify /
    /// manualEntry) — for those it is correct to return to idle. If a `pendingResult` somehow
    /// survives (defensive), we KEEP it and surface a banner rather than silently orphaning it.
    func handleSheetDismiss() {
        if pttState == .result {
            pttState = .idle
        }
        // Backstop only: a pending play should not reach here (cards block interactive dismissal).
        // If one does, keep it and tell the user how to clear it — never silently drop it.
        if activeGame?.pendingResult != nil {
            presentedError = AppError(
                message: "There's still an unconfirmed play. Press the mic to reopen it, then Confirm it."
            )
        }
    }

    // MARK: - Auth actions

    /// Sign in with a development stub (dev only; real sign-in is T081).
    func devSignIn(displayName: String = "Demo Scorer") {
        // Development-only: creates a stub session. This is NOT acceptable production auth —
        // T081 replaces this with Keychain-backed Apple/email sign-in.
        // ownerId uses a stable UUID so MockCore authority checks pass.
        let ownerId = "dev-owner-\(displayName.lowercased().replacingOccurrences(of: " ", with: "-"))"
        session = AuthSession(ownerId: ownerId, displayName: displayName, signInMethod: .email)
    }

    func signOut() {
        session = nil
        activeGame = nil
        pttState = .idle
    }

    // MARK: - Game actions

    /// Called by NewGameView on "Start game".
    func createGame(homeTeam: String, visitorTeam: String) async {
        guard let ownerId = session?.ownerId, !ownerId.isEmpty else {
            presentedError = AppError(message: "Sign in before starting a game.")
            return
        }
        do {
            let result = try await core.createGame(
                homeTeam: homeTeam,
                visitorTeam: visitorTeam,
                ownerId: ownerId,
                correlationId: UUID().uuidString
            )
            activeGame = ActiveGame(
                gameId: result.gameId,
                homeTeamName: homeTeam,
                visitorTeamName: visitorTeam,
                state: result.state
            )
            presentedSheet = nil
        } catch {
            presentedError = AppError(message: "Could not start game: \(error.localizedDescription)")
        }
    }

    /// Re-present the card for the still-pending play (Card A or Card B), so a user who dismissed it
    /// can get back to the Confirm / Resolve action. The real core still holds this unconfirmed play
    /// (it has no discard primitive), so reopening the card is the ONLY way to clear it forward.
    func reopenPendingCard() {
        guard let pending = activeGame?.pendingResult else { return }
        pttState = .result
        switch pending.needs {
        case .judgment: presentedSheet = .cardB(pending)
        default:        presentedSheet = .cardA(pending)
        }
    }

    /// Called by PushToTalk after parse produces normalized facts.
    func recordPlay(facts: [String: String]) async {
        guard let game = activeGame,
              let ownerId = session?.ownerId, !ownerId.isEmpty else { return }

        // Guard: a play is already pending in the (stateful) core. Don't try to record a new one —
        // the real core would reject it (FR-007 PendingConfirmation). Instead REOPEN the pending
        // card so the user can Confirm / Resolve it; that's the only way to clear it forward.
        if game.pendingResult != nil {
            reopenPendingCard()
            return
        }

        pttState = .processing
        do {
            let result = try await core.recordPlay(
                gameId: game.gameId,
                ownerId: ownerId,
                normalizedFacts: facts,
                correlationId: UUID().uuidString
            )
            game.pendingResult = result
            pttState = .result

            // Route to Card A or Card B based on `needs`.
            switch result.needs {
            case .confirm:
                presentedSheet = .cardA(result)
            case .judgment:
                presentedSheet = .cardB(result)
            case .clarify:
                // Surface a single clarifying question — never guess.
                presentedSheet = .clarify(candidatePlays: [])
            case .none:
                // Auto-applied (edge case); update state preview.
                game.state = result.statePreview
                game.pendingResult = nil
                pttState = .idle
            }
        } catch {
            pttState = .idle
            presentedError = AppError(message: "Play recording failed: \(error.localizedDescription)")
        }
    }

    /// Called by Card A "Confirm" tap.
    func confirmPlay() async {
        guard let game = activeGame,
              let pending = game.pendingResult,
              let ownerId = session?.ownerId, !ownerId.isEmpty else { return }

        do {
            let result = try await core.confirmPlay(
                gameId: game.gameId,
                confirmsSeq: pending.recordedSeq,
                ownerId: ownerId,
                correlationId: UUID().uuidString
            )
            game.state = result.state
            game.pendingResult = nil
            presentedSheet = nil
            pttState = .idle
        } catch {
            presentedError = AppError(message: "Confirm failed: \(error.localizedDescription)")
        }
    }

    /// Called by Card A "Correct" tap.
    ///
    /// ## H1 reconciliation (DL-35): "Correct" cannot replace a pending play's facts.
    ///
    /// The real core has **no discard/replace primitive** for a recorded-but-unconfirmed play
    /// (verified — append-only log, only `confirm_play` transitions it). The old behaviour cleared
    /// `pendingResult` and dropped the sheet, which orphaned the core's row (UI forgot it, core kept
    /// it) — the exact bug this pass fixes. Amending a play is `correct_event`, which the core only
    /// allows AFTER confirm and which is post-MVP (US4, gated off).
    ///
    /// So "Correct" keeps the pending play and the card intact, and surfaces a clear explanation:
    /// confirm the play first; amending lands post-MVP. This keeps the UI and the core consistent —
    /// no orphaned pending. Returns `false` (no state change) so callers/tests can assert it.
    @discardableResult
    func correctPendingEntry() -> Bool {
        guard activeGame?.pendingResult != nil else { return false }
        presentedError = AppError(
            message: "Confirm this play to record it. Editing a recorded play comes in a later update — for now the facts can't be changed before confirming."
        )
        // Keep pendingResult + the card up: do NOT orphan the core's unconfirmed play.
        return false
    }

    /// Called by Card B tap (one of the alternatives / recommendation).
    func resolveJudgment(decisionId: UInt64, chosen: ScoringCall) async {
        guard let game = activeGame,
              let ownerId = session?.ownerId, !ownerId.isEmpty else { return }

        do {
            let result = try await core.resolveJudgment(
                gameId: game.gameId,
                decisionId: decisionId,
                chosen: chosen,
                ownerId: ownerId,
                correlationId: UUID().uuidString
            )
            game.state = result.state
            game.pendingResult = nil
            presentedSheet = nil
            pttState = .idle
        } catch {
            presentedError = AppError(message: "Could not record your call: \(error.localizedDescription)")
        }
    }

    // MARK: - End Game

    /// Whether a play is recorded-but-unconfirmed in the (stateful) core. End Game must not try to
    /// finalize while this holds — the real core rejects finalize with FR-007 PendingConfirmation.
    var hasPendingPlay: Bool { activeGame?.pendingResult != nil }

    /// Called by the toolbar "End Game" button.
    ///
    /// ## H1 reconciliation (DL-35): don't blind-call finalize on an incomplete game.
    ///
    /// The real core refuses to finalize a game that still has an unconfirmed play (FR-007) or an
    /// unbalanced / in-progress half-inning (SC-011). Pre-check the cheap, known-locally condition
    /// (a pending play) and surface a clear, actionable message + reopen the pending card rather than
    /// dropping the user into the export sheet only to fail. Anything the core alone knows (proof-box
    /// balance, open judgments) is surfaced by `ExportView` from the real `CoreError` message — never
    /// a generic "something went wrong".
    func endGame() {
        guard activeGame != nil else { return }
        if hasPendingPlay {
            presentedError = AppError(
                message: "Finish the current play first — Confirm or resolve it, then End Game."
            )
            reopenPendingCard()
            return
        }
        // No locally-known blocker: open Export, which calls finalize and surfaces the real core
        // reason (proof-box / open judgment) if the core still refuses.
        presentedSheet = .export
    }

    /// Exit the game without finalizing/exporting (the "discard / leave" choice on an incomplete
    /// game). The real core keeps its append-only log, but the iOS session forgets the game — the
    /// user explicitly chose not to produce an official record. No finalize is attempted.
    func exitGameWithoutFinalizing() {
        activeGame = nil
        presentedSheet = nil
        pttState = .idle
    }

    /// Called by Card B "Leave PENDING" tap (FR-010a — explicit deferred, first-class).
    /// Resolves the judgment as deferred without auto-picking a call.
    func deferJudgment() {
        // For MVP against MockCore: mark pending as deferred by clearing it + dismissing the card.
        // The real core (H1) will accept a PENDING token via resolve_judgment.
        guard let game = activeGame else { return }
        game.pendingResult = nil
        presentedSheet = nil
        pttState = .idle
    }
}
