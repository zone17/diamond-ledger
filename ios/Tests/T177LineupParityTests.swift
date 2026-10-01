/// T177LineupParityTests.swift — #177 U3 (R4 / R6): game lineups through the core, roster read back.
///
/// The iOS scorer's lineups now go into the core's game-started event, and the app's active roster
/// comes from what the core stored and read back (`CreateGameResult.setup`), never from the typed
/// text. Covered here:
///   - a real-core round trip through `DiamondCoreClient` (the test a stateless mock cannot fake):
///     names are trimmed by the core and kept in batting order, and `gameSetup` reads the same back;
///   - New Game rows keep their row numbers (#1, #2, #5 → 1, 2, 5); all-blank rows → no lineup;
///   - `activeRoster` follows the core's setup even when it differs from what was typed;
///   - cross-team case-insensitive de-duplication stays in the roster, not the core;
///   - the old four-argument `createGame` still compiles and creates lineup-less games;
///   - a lineup the core rejects surfaces the create-game error and starts no game.
///
/// Uses injected stores and fake speech readiness / capture; nothing here touches the Keychain,
/// the real defaults, the microphone, a permission API, or a recognizer. Every AppState call is
/// bounded (5 s) by `awaitBounded`.
///
/// - SeeAlso: `ios/Sources/Core/CoreClient.swift` — `GameSetup`, `createGame(…homeLineup:…)`
/// - SeeAlso: `ios/Sources/UI/App/AppState.swift` — `lineupEntries(fromRows:)`, `activeRoster`

import XCTest
@testable import Core
@testable import UI
@testable import DiamondSpeech
import Auth

@MainActor
final class T177LineupParityTests: XCTestCase {

    private let owner = "owner-t177"

    private func entry(_ order: UInt8, _ name: String) -> LineupEntry {
        LineupEntry(battingOrder: order, name: name)
    }

    /// A fully isolated, signed-in, 13+ AppState on the given core.
    private func makeAppState(core: any CoreClient) async throws -> AppState {
        let defaults = UserDefaults(suiteName: "test.t177.\(UUID().uuidString)")!
        let appState = AppState(core: core,
                                consentDefaults: defaults,
                                authStore: AuthStore(store: InMemorySessionStore()),
                                speechReadiness: await readySpeechReadiness(),
                                captureFactory: { FakeAudioCapture(frames: []) })
        try appState.completeAppleSignIn(appleUserID: "adult-t177", fullName: nil)
        appState.recordAgeResponse(isUnder13: false)
        return appState
    }

    /// `AppState.createGame`, bounded so a stuck call fails instead of hanging the suite.
    private func createGame(_ appState: AppState, home: [String], visitor: [String]) async {
        await awaitBounded(Task {
            await appState.createGame(homeTeam: "Hawks", visitorTeam: "Owls",
                                      homeLineup: home, visitorLineup: visitor)
        })
    }

    // MARK: Real core round trip

    func test_realCore_createGame_storesTrimmedLineup_andReadsItBack() async throws {
        let core = DiamondCoreClient()
        let result = try await core.createGame(
            homeTeam: "Hawks", visitorTeam: "Owls",
            homeLineup: [],
            visitorLineup: [entry(1, "Ana Ruiz"), entry(2, "  Ben Ortiz ")],
            ownerId: owner, correlationId: "t177-roundtrip")

        XCTAssertEqual(result.setup.visitor.lineup, [entry(1, "Ana Ruiz"), entry(2, "Ben Ortiz")],
                       "the core trims each name and keeps batting order")
        XCTAssertEqual(result.setup.home.lineup, [], "a team sent without a lineup reads back empty")
        XCTAssertEqual(result.setup.gameId, result.gameId)
        XCTAssertEqual(result.setup.visitor.name, "Owls")
        XCTAssertEqual(result.setup.home.name, "Hawks")

        let read = try await core.gameSetup(gameId: result.gameId)
        XCTAssertEqual(read, result.setup, "gameSetup reads back exactly what createGame returned")
    }

    func test_realCore_gameSetup_unknownGame_isNotFound() async {
        do {
            _ = try await DiamondCoreClient().gameSetup(gameId: "999999")
            XCTFail("expected notFound")
        } catch CoreError.notFound {
        } catch {
            XCTFail("expected notFound, got \(error)")
        }
    }

    // MARK: Row numbers → batting order

    func test_lineupEntries_keepRowNumbers_dropBlankRows() {
        let rows = ["Ana Ruiz", "Ben Ortiz", "", "   ", "Eli Shaw", "", "", "", ""]
        XCTAssertEqual(AppState.lineupEntries(fromRows: rows),
                       [entry(1, "Ana Ruiz"), entry(2, "Ben Ortiz"), entry(5, "Eli Shaw")])
        XCTAssertEqual(AppState.lineupEntries(fromRows: Array(repeating: " ", count: 9)), [])
        XCTAssertEqual(AppState.lineupEntries(fromRows: []), [])
    }

    func test_appState_rowsOneTwoFive_storeBattingOrdersOneTwoFive_onRealCore() async throws {
        let core = DiamondCoreClient()
        let appState = try await makeAppState(core: core)
        await createGame(appState,
                         home: [],
                         visitor: ["Ana Ruiz", "Ben Ortiz", "", "", "Eli Shaw", "", "", "", ""])

        let gameId = try XCTUnwrap(appState.activeGame?.gameId, "the game started")
        let setup = try await core.gameSetup(gameId: gameId)
        XCTAssertEqual(setup.visitor.lineup,
                       [entry(1, "Ana Ruiz"), entry(2, "Ben Ortiz"), entry(5, "Eli Shaw")])
        XCTAssertEqual(setup.home.lineup, [])
        XCTAssertEqual(appState.activeRoster, ["Ana Ruiz", "Ben Ortiz", "Eli Shaw"])
    }

    func test_appState_allBlankRows_startWithEmptyLineups_onRealCore() async throws {
        let core = DiamondCoreClient()
        let appState = try await makeAppState(core: core)
        let blanks = Array(repeating: "", count: 9)
        await createGame(appState, home: blanks, visitor: blanks)

        let gameId = try XCTUnwrap(appState.activeGame?.gameId, "the game started")
        let setup = try await core.gameSetup(gameId: gameId)
        XCTAssertEqual(setup.home.lineup, [])
        XCTAssertEqual(setup.visitor.lineup, [])
        XCTAssertEqual(appState.activeRoster, [])
    }

    // MARK: Roster source

    func test_activeRoster_followsCoreSetup_notTypedText() async throws {
        // A core whose read-back differs from what the scorer typed: the roster must follow it.
        let core = MockCore(transformSetup: { s in
            GameSetup(gameId: s.gameId,
                      home: TeamSetup(id: s.home.id, name: s.home.name,
                                      lineup: [LineupEntry(battingOrder: 1, name: "Stored Home")]),
                      visitor: TeamSetup(id: s.visitor.id, name: s.visitor.name,
                                         lineup: [LineupEntry(battingOrder: 3, name: "Stored Visitor")]))
        })
        let appState = try await makeAppState(core: core)
        await createGame(appState, home: ["Typed Home"], visitor: ["Typed Visitor"])

        XCTAssertNotNil(appState.activeGame, "precondition: the game started")
        XCTAssertEqual(appState.activeRoster, ["Stored Visitor", "Stored Home"],
                       "visitor first, then home — from the core's setup, never the typed text")
    }

    func test_mockCore_storesAndReturnsTrimmedSetup() async throws {
        let core = MockCore()
        let result = try await core.createGame(
            homeTeam: "Hawks", visitorTeam: "Owls",
            homeLineup: [entry(4, "\tJo Vance\n")], visitorLineup: [],
            ownerId: owner, correlationId: "t177-mock")
        XCTAssertEqual(result.setup.home.lineup, [entry(4, "Jo Vance")])
        let read = try await core.gameSetup(gameId: result.gameId)
        XCTAssertEqual(read, result.setup)
    }

    func test_sharedNameAcrossTeams_yieldsOneRosterEntry_butCoreKeepsBoth() async throws {
        let core = DiamondCoreClient()
        let appState = try await makeAppState(core: core)
        await createGame(appState, home: ["ana ruiz", "Jo Vance"], visitor: ["Ana Ruiz", "Ben Ortiz"])

        XCTAssertEqual(appState.activeRoster, ["Ana Ruiz", "Ben Ortiz", "Jo Vance"],
                       "cross-team case-insensitive de-duplication stays in the roster")
        let gameId = try XCTUnwrap(appState.activeGame?.gameId)
        let setup = try await core.gameSetup(gameId: gameId)
        XCTAssertEqual(setup.home.lineup.map(\.name), ["ana ruiz", "Jo Vance"],
                       "the core does not de-duplicate across teams")
    }

    // MARK: Back-compat

    func test_fourArgumentCreateGame_stillCreatesLineuplessGames() async throws {
        let cores: [any CoreClient] = [DiamondCoreClient(), MockCore()]
        for core in cores {
            let result = try await core.createGame(homeTeam: "Hawks", visitorTeam: "Owls",
                                                   ownerId: owner, correlationId: "t177-4arg")
            XCTAssertEqual(result.setup.home.lineup, [], "\(type(of: core))")
            XCTAssertEqual(result.setup.visitor.lineup, [], "\(type(of: core))")
            XCTAssertEqual(result.state.inning, 1)
        }
    }

    // MARK: Rejection

    func test_coreRejectsLineup_surfacesCreateGameError_andNoGameStarts() async throws {
        let core = DiamondCoreClient()
        let appState = try await makeAppState(core: core)
        let tooLong = String(repeating: "a", count: 61)
        await createGame(appState, home: [], visitor: ["Ana Ruiz", tooLong])

        XCTAssertNil(appState.activeGame, "a rejected lineup starts no game")
        XCTAssertEqual(appState.activeRoster, [])
        let message = try XCTUnwrap(appState.presentedError?.message)
        XCTAssertTrue(message.hasPrefix("Could not start game:"), message)
    }

    func test_realCore_rejectedLineup_throwsInvalidState() async {
        do {
            _ = try await DiamondCoreClient().createGame(
                homeTeam: "Hawks", visitorTeam: "Owls",
                homeLineup: [entry(1, String(repeating: "b", count: 61))], visitorLineup: [],
                ownerId: owner, correlationId: "t177-reject")
            XCTFail("expected the core to reject a 61-character name")
        } catch CoreError.invalidState {
        } catch {
            XCTFail("expected invalidState (INVALID_ARGUMENT), got \(error)")
        }
    }
}
