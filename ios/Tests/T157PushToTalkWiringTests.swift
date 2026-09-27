/// T157PushToTalkWiringTests.swift — DL-157 U7 (R20 / R21 / R22): push-to-talk roster wiring.
///
/// Device-independent coverage for the seam between the New Game screen, `AppState`, the ASR
/// engine and the parser:
///   - creating a game with lineups sets `activeRoster` (trimmed, empties dropped, de-duplicated,
///     order preserved) and ending the game / signing out clears it;
///   - the push-to-talk pipeline hands that roster to the engine (`setContextualStrings`) before
///     EVERY `transcribe`, and to the parser (`parse(_:roster:)`) — asserted with a recording fake;
///   - the simulator's Stub engine still plays the canned script through to Card A;
///   - the Apple engine, fed the still-empty synthesized buffer (capture T046 absent), surfaces a
///     VISIBLE error rather than silence;
///   - a real engine's out-of-grammar transcript routes to manual entry, never the WoZ canned facts.
///
/// Uses `MockCore` and injected stores (`InMemorySessionStore`, a throwaway `UserDefaults`
/// suite) — nothing here touches the Keychain, the real defaults, the mic, or a recognizer.
///
/// - SeeAlso: `ios/Sources/UI/PushToTalk/PushToTalkView.swift` — `PushToTalkPipeline`
/// - SeeAlso: `ios/Sources/UI/App/AppState.swift` — `activeRoster`, `transcriberFactory`

import XCTest
@testable import Core
@testable import UI
@testable import DiamondSpeech
import Auth
import Parse

// MARK: - Recording fake Transcriber

/// A `Transcriber` that records every call in order and returns a scripted transcript. Reports
/// itself as `.apple` so the pipeline treats it as a REAL engine (no WoZ fallbacks).
actor RecordingTranscriber: Transcriber {
    enum Event: Equatable {
        case setContextualStrings([String])
        case transcribe
    }

    nonisolated let engine: TranscriberEngine
    private(set) var events: [Event] = []
    private let text: String
    private let confidence: Int

    init(text: String = "ground ball to short, threw him out at first",
         confidence: Int = 95,
         engine: TranscriberEngine = .apple) {
        self.text = text
        self.confidence = confidence
        self.engine = engine
    }

    var isAvailable: Bool { true }

    func transcribe(buffer: consuming AudioBuffer) async throws -> Transcript {
        _ = consume buffer
        events.append(.transcribe)
        return Transcript(text: text, confidence: confidence, engine: engine, finalizedAt: Date())
    }

    func preloadAssets() async throws {}

    func setContextualStrings(_ phrases: [String]) async {
        events.append(.setContextualStrings(phrases))
    }
}

// MARK: - Tests

@MainActor
final class T157PushToTalkWiringTests: XCTestCase {

    /// Nine visitor names, clean.
    private let visitors = ["Ana Ruiz", "Ben Ortiz", "Cal Park", "Dee Wright", "Eli Shaw",
                            "Fay Long", "Gus Reed", "Hal Bly", "Ian Cole"]
    /// Nine home fields as typed: padding, blanks, a duplicate of a visitor and of a teammate.
    private let homeAsTyped = ["  Jo Vance ", "", "Kip Marsh", "   ", "ana ruiz", "Lou Diaz",
                               "\tMax Ito\n", "Kip Marsh", "Ned Fox"]
    private var expectedRoster: [String] {
        visitors + ["Jo Vance", "Kip Marsh", "Lou Diaz", "Max Ito", "Ned Fox"]
    }

    /// A fully isolated AppState. `transcriber` (if any) is what the pipeline resolves.
    private func makeAppState(transcriber: (any Transcriber)? = nil) -> AppState {
        let defaults = UserDefaults(suiteName: "test.t157.\(UUID().uuidString)")!
        let factory: (@Sendable (WoZScript) async -> any Transcriber)?
        if let transcriber {
            factory = { @Sendable _ in transcriber }
        } else {
            factory = nil
        }
        return AppState(core: MockCore(),
                        consentDefaults: defaults,
                        authStore: AuthStore(store: InMemorySessionStore()),
                        transcriberFactory: factory)
    }

    private func signIn(_ appState: AppState) throws {
        try appState.completeAppleSignIn(appleUserID: "adult-1", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)
    }

    private func startGame(_ appState: AppState, withLineups: Bool = true) async {
        await appState.createGame(
            homeTeam: "Hawks", visitorTeam: "Owls",
            homeLineup: withLineups ? homeAsTyped : [],
            visitorLineup: withLineups ? visitors : [])
        XCTAssertNotNil(appState.activeGame, "precondition: the game started")
    }

    // MARK: normalizeRoster (pure)

    func test_normalizeRoster_trimsDropsEmptiesDedupsPreservesOrder() {
        // Alone, the home list keeps "ana ruiz" (the duplicate is only against the VISITOR list,
        // which `createGame` concatenates first — see test_createGame_withNineNames_setsActiveRoster).
        XCTAssertEqual(AppState.normalizeRoster(homeAsTyped),
                       ["Jo Vance", "Kip Marsh", "ana ruiz", "Lou Diaz", "Max Ito", "Ned Fox"])
        XCTAssertEqual(AppState.normalizeRoster(visitors + homeAsTyped), expectedRoster)
        XCTAssertEqual(AppState.normalizeRoster(["Wright", "wright", "WRIGHT"]), ["Wright"],
                       "case-insensitive de-dup keeps the first spelling")
        XCTAssertEqual(AppState.normalizeRoster([]), [])
        XCTAssertEqual(AppState.normalizeRoster(["", "  ", "\n"]), [])
    }

    // MARK: activeRoster lifecycle

    func test_createGame_withNineNames_setsActiveRoster() async throws {
        let appState = makeAppState()
        try signIn(appState)
        XCTAssertEqual(appState.activeRoster, [], "no roster before a game")

        await startGame(appState)

        XCTAssertEqual(appState.activeRoster, expectedRoster,
                       "visitor lineup first, then home; trimmed, empties dropped, de-duplicated")
    }

    func test_createGame_withoutLineups_leavesRosterEmpty() async throws {
        let appState = makeAppState()
        try signIn(appState)
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls")
        XCTAssertNotNil(appState.activeGame)
        XCTAssertEqual(appState.activeRoster, [], "names-only game (FR-001) has no roster")
    }

    func test_createGame_refused_doesNotSetRoster() async throws {
        let appState = makeAppState()
        try appState.completeAppleSignIn(appleUserID: "adult-1", fullName: nil)   // gate unanswered
        await startGameExpectingRefusal(appState)
        XCTAssertNil(appState.activeGame)
        XCTAssertEqual(appState.activeRoster, [], "a refused game must not leak a roster")
    }

    private func startGameExpectingRefusal(_ appState: AppState) async {
        await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls",
                                  homeLineup: homeAsTyped, visitorLineup: visitors)
    }

    func test_signOut_clearsActiveRoster() async throws {
        let appState = makeAppState()
        try signIn(appState)
        await startGame(appState)
        XCTAssertFalse(appState.activeRoster.isEmpty)

        appState.signOut()

        XCTAssertNil(appState.activeGame)
        XCTAssertEqual(appState.activeRoster, [], "sign-out drops the roster with the game")
    }

    func test_exitGameWithoutFinalizing_clearsActiveRoster() async throws {
        let appState = makeAppState()
        try signIn(appState)
        await startGame(appState)

        appState.exitGameWithoutFinalizing()

        XCTAssertNil(appState.activeGame)
        XCTAssertEqual(appState.activeRoster, [], "ending the game drops the roster")
    }

    func test_newGame_replacesPreviousRoster() async throws {
        let appState = makeAppState()
        try signIn(appState)
        await startGame(appState)
        appState.exitGameWithoutFinalizing()

        await appState.createGame(homeTeam: "Bears", visitorTeam: "Cats",
                                  homeLineup: ["Pat Quinn"], visitorLineup: ["Rae Sun"])

        XCTAssertEqual(appState.activeRoster, ["Rae Sun", "Pat Quinn"])
    }

    // MARK: R21 — roster reaches the engine before EVERY transcribe

    func test_pipeline_setsContextualStringsWithRoster_beforeEveryTranscribe() async throws {
        let fake = RecordingTranscriber()
        let appState = makeAppState(transcriber: fake)
        try signIn(appState)
        await startGame(appState)
        let roster = appState.activeRoster

        await PushToTalkPipeline.score(script: .groundOut63, appState: appState)

        var events = await fake.events
        XCTAssertEqual(events, [.setContextualStrings(roster), .transcribe],
                       "the roster must be set immediately before transcribe")
        XCTAssertEqual(roster, expectedRoster)

        // First utterance reached Card A (MockCore: confirm). Clear it as the scorer would.
        guard case .cardA = appState.presentedSheet else {
            return XCTFail("groundout transcript must reach Card A, got \(String(describing: appState.presentedSheet))")
        }
        await appState.confirmPlay()
        XCTAssertNil(appState.activeGame?.pendingResult)

        // Second utterance: set again, before transcribe again — not once per engine.
        await PushToTalkPipeline.score(script: .groundOut63, appState: appState)
        events = await fake.events
        XCTAssertEqual(events, [.setContextualStrings(roster), .transcribe,
                                .setContextualStrings(roster), .transcribe],
                       "every transcribe is preceded by its own setContextualStrings(roster)")
    }

    func test_pipeline_emptyRoster_stillSetsContextualStrings() async throws {
        let fake = RecordingTranscriber()
        let appState = makeAppState(transcriber: fake)
        try signIn(appState)
        await startGame(appState, withLineups: false)

        await PushToTalkPipeline.score(script: .groundOut63, appState: appState)

        let events = await fake.events
        XCTAssertEqual(events, [.setContextualStrings([]), .transcribe],
                       "an empty roster is still sent (the engine keeps its lexicon-only set)")
    }

    // MARK: R22 — the same roster reaches the parser

    /// "fly ball to wright, caught": with "Wright" on the roster the surname is masked, the
    /// flyout's fielder would be a silent default, so the parser CLARIFIES; with no roster the
    /// legacy parse reads "wright" as right field and Card A follows. Same transcript, same fake —
    /// the only difference is the roster the pipeline passed to `parse(_:roster:)`.
    ///
    /// Since U9 (no-guess parser, whole-word keywords) "wright" is never read as "right" even
    /// without a roster, so both arms clarify; the roster arm additionally proves the name was
    /// masked (multi-word entries mask each token too — see `DL157RosterMaskingTests`). The
    /// invariant under test is the same either way: a surname never becomes a fielder guess.
    func test_pipeline_passesRosterToParser_surnameNeverReadAsPosition() async throws {
        let transcript = "fly ball to wright, caught"

        let withRoster = makeAppState(transcriber: RecordingTranscriber(text: transcript))
        try signIn(withRoster)
        await withRoster.createGame(homeTeam: "Hawks", visitorTeam: "Owls",
                                    homeLineup: ["Wright"], visitorLineup: ["Ana Ruiz"])
        XCTAssertEqual(withRoster.activeRoster, ["Ana Ruiz", "Wright"])
        await PushToTalkPipeline.score(script: .groundOut63, appState: withRoster)
        guard case .clarify(let candidates) = withRoster.presentedSheet else {
            return XCTFail("masked surname + defaulted fielder must clarify, got \(String(describing: withRoster.presentedSheet))")
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.facts["batter_result"], "flyout")
        XCTAssertNotEqual(candidates.first?.facts["fielder"], "9", "never right field from 'wright'")
        XCTAssertEqual(withRoster.pttState, .idle)

        let withoutRoster = makeAppState(transcriber: RecordingTranscriber(text: transcript))
        try signIn(withoutRoster)
        await startGame(withoutRoster, withLineups: false)
        await PushToTalkPipeline.score(script: .groundOut63, appState: withoutRoster)
        guard case .clarify(let legacyCandidates) = withoutRoster.presentedSheet else {
            return XCTFail("no-roster parse must clarify (no fielder stated; 'wright' is not 'right'), got \(String(describing: withoutRoster.presentedSheet))")
        }
        XCTAssertEqual(legacyCandidates.count, 1)
        XCTAssertEqual(legacyCandidates.first?.facts["batter_result"], "flyout")
        XCTAssertNil(legacyCandidates.first?.facts["fielder"], "never a guessed fielder (KTD-U9)")
    }

    // MARK: Stub engine (simulator) — canned script still reaches Card A unchanged

    func test_pipeline_stubEngine_returnsCannedScript_andReachesCardA() async throws {
        #if DEBUG
        let previous = TranscriberEngineSelector.forceStub
        defer { TranscriberEngineSelector.forceStub = previous }
        TranscriberEngineSelector.forceStub = true
        #endif
        // Default factory → TranscriberEngineSelector → StubTranscriber (forceStub).
        let appState = makeAppState()
        try signIn(appState)
        await startGame(appState)
        appState.pttState = .processing   // as stopListening() does

        await PushToTalkPipeline.score(script: .groundOut63, appState: appState)

        guard case .cardA = appState.presentedSheet else {
            return XCTFail("Stub groundOut63 must reach Card A, got \(String(describing: appState.presentedSheet))")
        }
        XCTAssertEqual(appState.pttState, .result)
        XCTAssertNil(appState.presentedError)
        XCTAssertNotNil(appState.activeGame?.pendingResult)
    }

    /// The facilitator panel path uses the Stub directly regardless of the resolved engine.
    func test_pipeline_facilitatorScripted_usesStub_evenWhenFactoryIsARealEngine() async throws {
        let fake = RecordingTranscriber(text: "the quick brown fox")   // would NOT parse
        let appState = makeAppState(transcriber: fake)
        try signIn(appState)
        await startGame(appState)

        await PushToTalkPipeline.score(script: .groundOut63, facilitatorScripted: true, appState: appState)

        let events = await fake.events
        XCTAssertEqual(events, [], "the facilitator path never touches the resolved engine")
        guard case .cardA = appState.presentedSheet else {
            return XCTFail("facilitator groundOut63 must reach Card A, got \(String(describing: appState.presentedSheet))")
        }
    }

    // MARK: Apple engine with the empty synthesized buffer → visible error, not silence

    /// Capture (T046) is still absent, so the pipeline's buffer has no bytes. On the Apple engine
    /// that is `audioTooShort` (or `permissionDenied` where speech access is restricted) — it must
    /// surface as an error banner with the PTT loop reset, never as silence or a fabricated play.
    func test_pipeline_appleEngine_emptyBuffer_surfacesVisibleError() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("AppleTranscriber needs iOS 26") }
        let appState = makeAppState(transcriber: AppleTranscriber())
        try signIn(appState)
        await startGame(appState)
        appState.pttState = .processing

        await PushToTalkPipeline.score(script: .groundOut63, appState: appState)

        let error = try XCTUnwrap(appState.presentedError, "an empty capture must be a VISIBLE error")
        XCTAssertFalse(error.message.contains("couldn’t be completed"),
                       "the reason must be spelled out, not an opaque NSError description: \(error.message)")
        XCTAssertEqual(appState.pttState, .idle, "the PTT loop is reset so the mic can be pressed again")
        XCTAssertNil(appState.presentedSheet, "no card, no clarify — nothing was recognized")
        XCTAssertNil(appState.activeGame?.pendingResult, "nothing reached the core")
    }

    func test_pipeline_message_forAudioTooShort_namesTheMissingCapture() {
        let message = PushToTalkPipeline.message(for: TranscriberError.audioTooShort)
        XCTAssertTrue(message.lowercased().contains("no audio"), message)
        XCTAssertTrue(message.lowercased().contains("capture"), message)
    }

    // MARK: Real engine + out-of-grammar → manual entry, never the WoZ canned facts

    func test_pipeline_realEngine_outOfGrammar_routesToManualEntry_notCannedFacts() async throws {
        let fake = RecordingTranscriber(text: "the quick brown fox jumps over")
        let appState = makeAppState(transcriber: fake)
        try signIn(appState)
        await startGame(appState)

        await PushToTalkPipeline.score(script: .groundOut63, appState: appState)

        guard case .manualEntry(let prefilled) = appState.presentedSheet else {
            return XCTFail("a real engine's out-of-grammar transcript must go to manual entry, got \(String(describing: appState.presentedSheet))")
        }
        XCTAssertEqual(prefilled, "the quick brown fox jumps over")
        XCTAssertNil(appState.activeGame?.pendingResult, "the WoZ canned ground out must NOT be recorded")
        XCTAssertEqual(appState.pttState, .idle)
    }
}
