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

    /// COPPA age-gate status (FR-029 / ADR-0016 §4). Stored (not computed) so SwiftUI observes
    /// changes when the user answers the gate.
    private(set) var consentStatus: ConsentGate.Status

    /// The age-gate backing store (`UserDefaults`).
    private let consentGate = ConsentGate()

    /// Whether the signed-in user has answered the age gate (any answer).
    var consentResolved: Bool { consentStatus != .unknown }

    /// Whether recording is permitted — requires a signed-in owner AND a 13+ age-gate answer.
    var recordingAllowed: Bool { session != nil && consentStatus == .allowed }

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
        self.consentStatus = ConsentGate().status   // same UserDefaults as `consentGate`
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

    /// Restore a persisted owner session on launch (ADR-0016). For an Apple session this also
    /// verifies the credential is still valid; a revoked credential leaves `session == nil`.
    func restoreSession() async {
        if let restored = await AuthStore.shared.restoreSession() {
            session = restored
        }
    }

    /// Complete Sign in with Apple (T081 / FR-020 / I5): derive + persist the owner identity.
    func completeAppleSignIn(appleUserID: String, fullName: PersonNameComponents?) {
        do {
            session = try AuthStore.shared.establishAppleSession(appleUserID: appleUserID,
                                                                 fullName: fullName)
        } catch {
            presentedError = AppError(message: "Could not save your sign-in. Please try again.")
        }
    }

    /// Record the one-time COPPA age-gate answer (FR-029). Mutating `consentStatus` republishes so
    /// `RootView` re-routes (adult → app, under-13 → blocked).
    func recordAgeResponse(isUnder13: Bool) {
        consentGate.record(isUnder13: isUnder13)
        consentStatus = consentGate.status
    }

    #if DEBUG
    /// Sign in with a development stub (DEBUG only — a release build cannot mint this identity).
    /// The `dev-owner-*` id satisfies the core's non-trivial-identity guard for MockCore demos; it
    /// is NOT persisted to the Keychain, so it never survives a relaunch. It also clears the age
    /// gate in-memory (the dev shortcut bypasses sign-in *and* consent friction); the real Apple
    /// path does not, so it still routes through `AgeGateView`.
    func devSignIn(displayName: String = "Demo Scorer") {
        let ownerId = "dev-owner-\(displayName.lowercased().replacingOccurrences(of: " ", with: "-"))"
        session = AuthSession(ownerId: ownerId, displayName: displayName, signInMethod: .email)
        consentStatus = .allowed   // in-memory only; not persisted to UserDefaults
    }
    #endif

    func signOut() {
        AuthStore.shared.signOut()
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
        // Defense-in-depth: routing also blocks the UI, but never start recording a game without a
        // satisfied age gate (FR-029). `recordingAllowed` requires a 13+ answer.
        guard recordingAllowed else {
            presentedError = AppError(message: "Confirm your age before starting a game.")
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
    ///
    /// ## H1 reconciliation (DL-35): resolve does NOT confirm — must confirm afterward.
    ///
    /// The real core's `resolve_judgment` only records the decision (`JudgmentResolved`); it does
    /// **not** confirm the underlying play, so the `PlayRecorded` row stays `confirmed == false` and
    /// `pending_play()` is still `Some`. If we cleared `pendingResult` here (as the old code did),
    /// the next mic press would hit the core's FR-007 `PendingConfirmation` guard with no recovery
    /// (the card can't reopen because `pendingResult` is gone). So after resolve we **confirm the
    /// same play** (the sequence proven by `test_fullLoop_createConfirmJudgeResolveConfirm`), and
    /// only clear/dismiss on confirm success. On confirm failure we KEEP `pendingResult` (so the
    /// card can reopen) and surface the real reason — never orphan the play.
    func resolveJudgment(decisionId: UInt64, chosen: ScoringCall) async {
        guard let game = activeGame,
              let pending = game.pendingResult,
              let ownerId = session?.ownerId, !ownerId.isEmpty else { return }

        // Capture the recorded seq BEFORE any clearing — we need it to confirm the play.
        let confirmsSeq = pending.recordedSeq

        do {
            let resolved = try await core.resolveJudgment(
                gameId: game.gameId,
                decisionId: decisionId,
                chosen: chosen,
                ownerId: ownerId,
                correlationId: UUID().uuidString
            )
            game.state = resolved.state

            // Confirm the now-resolved play so it leaves the pending state (FR-007). Until this
            // succeeds the play is still unconfirmed in the core — keep `pendingResult` intact.
            let confirmed = try await core.confirmPlay(
                gameId: game.gameId,
                confirmsSeq: confirmsSeq,
                ownerId: ownerId,
                correlationId: UUID().uuidString
            )
            game.state = confirmed.state
            game.pendingResult = nil
            presentedSheet = nil
            pttState = .idle
        } catch {
            // Keep the pending play + let the card reopen; surface the real core reason.
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

    /// Called by Card B "Leave PENDING" — DISABLED against the real core (DL-35).
    ///
    /// ## Why this is a no-op (the deferred-pending path is not implemented in the core)
    ///
    /// FR-010a envisions "Leave PENDING" as a first-class explicit defer, but the real core's
    /// `resolve_judgment` REQUIRES a `chosen` Call — there is **no** pending/defer token and no
    /// other primitive that clears an open judgment without a recorded decision. The old MockCore
    /// behaviour (clear `pendingResult` + dismiss) was the SAME orphan bug this PR fixes elsewhere:
    /// it dropped the UI's pending while the real core kept the play unconfirmed AND the judgment
    /// open, so the next mic press dead-ended on `PendingConfirmation`.
    ///
    /// Until the core gains a pending-token path (follow-up: issue #150 — `resolve_judgment` PENDING
    /// token + `EarnedUnearned::Pending` plumbing), the "Leave PENDING" button is hidden on the
    /// real-core build (see `CardBView.pendingOption`). This method is kept only as a guarded no-op
    /// so any stray caller can't orphan a play: it surfaces an explanation and leaves the card up.
    func deferJudgment() {
        guard activeGame?.pendingResult != nil else { return }
        presentedError = AppError(
            message: "Leaving a call pending isn't available yet. Make a call to continue — you can correct it in a later update."
        )
        // Do NOT clear pendingResult or dismiss: never orphan the core's open judgment.
    }
}
