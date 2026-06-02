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

    var id: String {
        switch self {
        case .newGame:      return "newGame"
        case .cardA:        return "cardA"
        case .cardB:        return "cardB"
        case .clarify:      return "clarify"
        case .manualEntry:  return "manualEntry"
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

    /// Called when a presented sheet is dismissed (including a Card A swipe-away). Unsticks the
    /// push-to-talk loop: if a result card was dismissed without an explicit Confirm/Correct/
    /// Resolve, return to idle and discard the unconfirmed entry (safe — FR-007: state is never
    /// advanced on an unconfirmed play). No-op when already idle (e.g. right after a confirm/resolve).
    func handleSheetDismiss() {
        if pttState == .result {
            pttState = .idle
        }
        activeGame?.pendingResult = nil
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

    /// Called by PushToTalk after parse produces normalized facts.
    func recordPlay(facts: [String: String]) async {
        guard let game = activeGame,
              let ownerId = session?.ownerId, !ownerId.isEmpty else { return }

        // Guard: do not record a new play while a pending entry awaits confirm/judgment.
        if game.pendingResult != nil {
            presentedError = AppError(
                message: "Confirm or correct the previous play before recording a new one."
            )
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

    /// Called by Card A "Correct" tap — re-opens PTT for re-entry of the pending play only.
    /// MVP scope: amends only the *pending unconfirmed* entry (re-record before confirm).
    /// Prior-play amend requires correct_event (US4/post-MVP) and is gated OFF here.
    func correctPendingEntry() {
        guard let game = activeGame else { return }
        // Clear the pending result so the next PTT invocation re-records.
        game.pendingResult = nil
        presentedSheet = nil
        pttState = .idle
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
