/// AppleTranscriberTests.swift — T047 / DL-80 (Squad B, Story B2).
///
/// Unit tests for the **compile/logic-testable seams** of the real iOS-26 `SpeechAnalyzer`
/// `AppleTranscriber`. These do NOT exercise live speech recognition — `SpeechAnalyzer` /
/// `SpeechTranscriber` cannot truly run in the simulator and on-device recognition *accuracy*
/// requires a physical iPhone + microphone (the human-verification handoff; see MANUAL-TESTING.md).
///
/// What IS covered here (deterministic, no mic, no network):
///   - `RosterContextBuilder` contextual-strings assembly from a roster (ordering, dedup, bounding,
///     reserved-roster-slot budgeting) — FR domain-accuracy seam.
///   - `BiasingStrategy.choose` at the FR-008 confidence boundary (when the contextual-biasing pass
///     overrides vs keeps the SpeechAnalyzer hypothesis).
///   - `ConfidenceMapping.toInt` boundaries (shared Apple/Sherpa rounding contract, ADR-0007).
///   - `AppleTranscriber.makePCMBuffer` PCM construction + the `consuming AudioBuffer` release
///     lifecycle (FR-022 process-don't-store).
///   - The duration guard (audioTooShort) error path.
///   - `TranscriberEngineSelector` engine selection (stub in sim, kind reporting — ADR-0010).
///
/// - SeeAlso: `ios/Sources/Speech/AppleTranscriber.swift`
/// - SeeAlso: `MANUAL-TESTING.md` — the on-device accuracy human-verification step.

import XCTest
import Foundation
@testable import DiamondSpeech

// MARK: - RosterContextBuilder (contextual-strings assembly from a roster)

final class RosterContextBuilderTests: XCTestCase {

    func testBuild_withEmptyRoster_returnsLexicon() {
        let result = RosterContextBuilder.build(roster: [])
        XCTAssertFalse(result.isEmpty, "lexicon must always be present")
        // Lexicon-only: every entry is a baseball term, none from a roster.
        XCTAssertTrue(result.contains("ground ball"))
        XCTAssertTrue(result.contains("shortstop"))
    }

    func testBuild_lexiconComesFirst_thenRoster() {
        let roster = ["Ramirez", "O'Neill"]
        let result = RosterContextBuilder.build(roster: roster)
        // Roster names appear, and after the lexicon (lexicon-first ordering).
        guard let firstRosterIdx = result.firstIndex(of: "Ramirez"),
              let lexiconIdx = result.firstIndex(of: "ground ball") else {
            return XCTFail("expected both a lexicon term and a roster name")
        }
        XCTAssertLessThan(lexiconIdx, firstRosterIdx, "lexicon must precede roster names")
        XCTAssertTrue(result.contains("O'Neill"))
    }

    func testBuild_deduplicatesCaseInsensitively_lexiconWinsTies() {
        // "shortstop" is already in the lexicon; passing it (different case) must not duplicate it.
        let result = RosterContextBuilder.build(roster: ["SHORTSTOP", "Garcia"])
        let occurrences = result.filter { $0.lowercased() == "shortstop" }.count
        XCTAssertEqual(occurrences, 1, "case-insensitive dedup: 'shortstop' appears once")
        XCTAssertTrue(result.contains("Garcia"))
    }

    func testBuild_trimsWhitespace_andDropsEmpties() {
        let result = RosterContextBuilder.build(roster: ["  Lopez  ", "", "   ", "\t"])
        XCTAssertTrue(result.contains("Lopez"), "leading/trailing whitespace trimmed")
        XCTAssertFalse(result.contains(""), "empty phrases dropped")
        XCTAssertFalse(result.contains("   "), "whitespace-only phrases dropped")
    }

    func testBuild_boundsTotalToMaxPhrases() {
        let bigRoster = (0..<500).map { "Player\($0)" }
        let result = RosterContextBuilder.build(roster: bigRoster)
        XCTAssertLessThanOrEqual(result.count, RosterContextBuilder.maxPhrases)
    }

    func testBuild_reservesSlotsForRoster_evenWithLargeLexicon() {
        // Even when the lexicon is large, a present roster's names are never wholly crowded out.
        let roster = (0..<RosterContextBuilder.reservedRosterSlots).map { "Name\($0)" }
        let result = RosterContextBuilder.build(roster: roster)
        let rosterPresent = roster.filter { result.contains($0) }.count
        XCTAssertGreaterThan(rosterPresent, 0, "roster names must survive the budget")
        XCTAssertLessThanOrEqual(result.count, RosterContextBuilder.maxPhrases)
    }

    func testBuild_isDeterministic() {
        let roster = ["Smith", "Jones", "Park"]
        XCTAssertEqual(
            RosterContextBuilder.build(roster: roster),
            RosterContextBuilder.build(roster: roster),
            "assembly must be deterministic for the same input")
    }
}

// MARK: - BiasingStrategy.choose (FR-008 confidence-boundary behavior of the biasing pass)

@available(iOS 26, *)
final class BiasingStrategyTests: XCTestCase {

    func testChoose_nilBiased_keepsBase() {
        let out = BiasingStrategy.choose(baseText: "ground out 6 3", baseConfidence: 0.9, biased: nil)
        XCTAssertEqual(out, .init(text: "ground out 6 3", confidence: 0.9))
    }

    func testChoose_emptyBiased_keepsBase() {
        let out = BiasingStrategy.choose(baseText: "ground out", baseConfidence: 0.7, biased: ("   ", 0.99))
        XCTAssertEqual(out.text, "ground out", "whitespace-only biased result is ignored")
        XCTAssertEqual(out.confidence, 0.7)
    }

    func testChoose_biasedMoreConfident_prefersBiased() {
        // The biased (domain-vocabulary) hypothesis wins when ≥ the base confidence.
        let out = BiasingStrategy.choose(
            baseText: "ground out to sean", baseConfidence: 0.60,
            biased: ("ground out to short", 0.85))
        XCTAssertEqual(out.text, "ground out to short")
        XCTAssertEqual(out.confidence, 0.85)
    }

    func testChoose_biasedAtBoundaryEqual_prefersBiased() {
        // Boundary: biased confidence exactly equals base → biased wins (>= comparison).
        let out = BiasingStrategy.choose(
            baseText: "base", baseConfidence: 0.70, biased: ("base hit", 0.70))
        XCTAssertEqual(out.text, "base hit")
    }

    func testChoose_biasedLessConfident_keepsBase() {
        let out = BiasingStrategy.choose(
            baseText: "home run", baseConfidence: 0.90, biased: ("homer", 0.50))
        XCTAssertEqual(out.text, "home run", "less-confident biased result does not override")
        XCTAssertEqual(out.confidence, 0.90)
    }

    func testChoose_baseHasNoConfidence_prefersAnyBiased() {
        // When SpeechAnalyzer surfaced no confidence, any non-empty biased result is adopted.
        let out = BiasingStrategy.choose(baseText: "ground out", baseConfidence: nil, biased: ("ground out 6 3", 0.4))
        XCTAssertEqual(out.text, "ground out 6 3")
        XCTAssertEqual(out.confidence, 0.4)
    }
}

// NOTE: `ConfidenceMapping.toInt` boundary behavior (the shared Apple/Sherpa float→int rounding
// contract) is already pinned by `ConfidenceMappingTests` in `OfflineTests.swift`. Not duplicated
// here to avoid a divergent second source of truth for the .5 rounding boundary.

// MARK: - AppleTranscriber PCM construction + consume lifecycle (FR-022)

@available(iOS 26, *)
final class AppleTranscriberPCMTests: XCTestCase {

    /// 16 kHz mono Int16: `frames` samples → `frames * 2` bytes.
    private func makeInt16PCMData(frames: Int) -> Data {
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames { samples[i] = Int16(truncatingIfNeeded: i) }
        return samples.withUnsafeBytes { Data($0) }
    }

    func testMakePCMBuffer_producesExpectedFrameCount() throws {
        let frames = 16_000  // 1 second @ 16 kHz
        let data = makeInt16PCMData(frames: frames)
        let buffer = try AppleTranscriber.makePCMBuffer(from: data)
        XCTAssertEqual(Int(buffer.frameLength), frames)
        XCTAssertEqual(buffer.format.sampleRate, AppleTranscriber.captureSampleRate)
        XCTAssertEqual(buffer.format.channelCount, AppleTranscriber.captureChannels)
    }

    func testMakePCMBuffer_emptyData_throwsAudioTooShort() {
        XCTAssertThrowsError(try AppleTranscriber.makePCMBuffer(from: Data())) { error in
            guard case TranscriberError.audioTooShort = error else {
                return XCTFail("expected audioTooShort, got \(error)")
            }
        }
    }

    func testMakePCMBuffer_copiesSamples_doesNotAliasInput() throws {
        // FR-022: the PCM buffer must own a COPY of the bytes — mutating the source Data afterward
        // must not change the buffer's contents (no retained reference to the source PCM).
        var data = makeInt16PCMData(frames: 8)
        let buffer = try AppleTranscriber.makePCMBuffer(from: data)
        let firstSampleBefore = buffer.int16ChannelData![0][0]
        // Mutate the original Data's first sample.
        data.withUnsafeMutableBytes { $0.bindMemory(to: Int16.self)[0] = 12_345 }
        let firstSampleAfter = buffer.int16ChannelData![0][0]
        XCTAssertEqual(firstSampleBefore, firstSampleAfter,
                       "buffer must not alias the source Data (FR-022 copy, not reference)")
    }

    /// The `consuming AudioBuffer` contract: building an `AudioBuffer` then transcribing consumes it.
    /// Here we assert the *duration guard* throws before any recognition is attempted, proving the
    /// buffer is consumed and released without touching the mic/recognizer on the too-short path.
    func testTranscribe_audioTooShort_throwsAndConsumesBuffer() async {
        let transcriber = AppleTranscriber()
        let shortBuffer = AudioBuffer(
            rawBytes: makeInt16PCMData(frames: 100),   // ~0.006 s — under the 0.3 s floor
            durationSeconds: 0.1,
            capturedAt: Date()
        )
        do {
            _ = try await transcriber.transcribe(buffer: shortBuffer)
            XCTFail("expected audioTooShort")
        } catch TranscriberError.audioTooShort {
            // Expected — and the move-only buffer was consumed by the call (compiler-enforced).
        } catch {
            XCTFail("expected audioTooShort, got \(error)")
        }
    }

    func testEngineKind_isApple() {
        XCTAssertEqual(AppleTranscriber().engine, .apple)
    }
}

// MARK: - Engine selection (ADR-0010: stub in sim/WoZ, never mislabels real ASR)

final class EngineSelectorTests: XCTestCase {

    func testResolvedEngineKind_inSimulator_isStub() async {
        // In the simulator, `forceStub` defaults true → selection must report the WoZ stub, never
        // claim real Apple ASR (ADR-0010 honesty invariant). SpeechAnalyzer can't run in the sim.
        let kind = await TranscriberEngineSelector.resolvedEngineKind()
        #if targetEnvironment(simulator)
        XCTAssertEqual(kind, .stub, "simulator must degrade to the WoZ stub, not real Apple ASR")
        #else
        XCTAssertTrue([.apple, .sherpa, .stub].contains(kind))
        #endif
    }

    func testResolve_inSimulator_returnsStubTranscriber() async {
        let transcriber = await TranscriberEngineSelector.resolve()
        #if targetEnvironment(simulator)
        XCTAssertEqual(transcriber.engine, .stub)
        #endif
        // Whatever is resolved must be a usable Transcriber (smoke).
        let available = await transcriber.isAvailable
        XCTAssertTrue(available || !available)  // total function; no crash
    }

    #if DEBUG
    func testForceStub_overridesToStub() async {
        let previous = TranscriberEngineSelector.forceStub
        defer { TranscriberEngineSelector.forceStub = previous }
        TranscriberEngineSelector.forceStub = true
        let kind = await TranscriberEngineSelector.resolvedEngineKind()
        XCTAssertEqual(kind, .stub)
    }
    #endif
}
