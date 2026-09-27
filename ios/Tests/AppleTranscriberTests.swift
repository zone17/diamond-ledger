/// AppleTranscriberTests.swift — T047 / DL-80 (Squad B, Story B2) + DL-157 biasing adapter.
///
/// Unit tests for the **compile/logic-testable seams** of the real iOS-26 `SpeechAnalyzer`
/// `AppleTranscriber`. These do NOT exercise live speech recognition — `SpeechAnalyzer` /
/// `SpeechTranscriber` cannot truly run in the simulator and on-device recognition *accuracy*
/// requires a physical iPhone + microphone (the human-verification handoff; see MANUAL-TESTING.md).
///
/// What IS covered here (deterministic, no mic, no network):
///   - `RosterContextBuilder` contextual-strings assembly from a roster (ordering, dedup, bounding,
///     reserved-roster-slot budgeting) — FR domain-accuracy seam.
///   - `BiasingStrategy.choose` as a thin adapter over `SpeechTypes.BiasingDecision` (DL-157):
///     the four-guard override rule, the R20 confidence cap, and the re-pinned P0b invariant.
///   - The `parserThreshold` mirror is pinned equal to `GrammarParser.lowConfidenceThreshold`.
///   - `ConfidenceMapping.toInt` boundaries (shared Apple/Sherpa rounding contract, ADR-0007).
///   - `AppleTranscriber.makePCMBuffer` PCM construction + the `consuming AudioBuffer` release
///     lifecycle (FR-022 process-don't-store).
///   - The duration guard (audioTooShort) error path.
///   - `TranscriberEngineSelector` engine selection (stub in sim, kind reporting — ADR-0010).
///
/// - SeeAlso: `ios/Sources/Speech/AppleTranscriber.swift`
/// - SeeAlso: `ios/Sources/SpeechTypes/BiasingDecision.swift` — the rule itself (+ its own tests)
/// - SeeAlso: `MANUAL-TESTING.md` — the on-device accuracy human-verification step.

import XCTest
import Foundation
import Parse
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

// MARK: - FR-008 / default confidence safety (P0 fix, DL-80 code review) + DL-157 policy pins

/// Pins the `defaultConfidenceWhenUnreported` value relative to `GrammarParser.lowConfidenceThreshold`.
///
/// iOS 26's `SpeechTranscriber` never exposes a scalar confidence (`confidence(from:)` always nil),
/// so EVERY production `SpeechAnalyzer` transcript receives `defaultConfidenceWhenUnreported`.
/// This must be BELOW 70 so the parser's clarify path fires for any unmeasured hypothesis — never
/// a silent wrong play (FR-008 / Article VII). These tests certify that invariant structurally.
@available(iOS 26, *)
final class FR008DefaultConfidenceTests: XCTestCase {

    /// The threshold the GrammarParser uses to trigger its clarify/ambiguity path, as mirrored
    /// inside DiamondSpeech (which cannot import Parse).
    private let parserThreshold = BiasingStrategy.parserThreshold

    /// The mirror must equal the real thing. `DiamondSpeech` restates the integer because it must
    /// not depend on `Parse`; this test is what keeps the two from drifting.
    func testParserThreshold_matchesGrammarParser() {
        XCTAssertEqual(BiasingStrategy.parserThreshold, GrammarParser.lowConfidenceThreshold,
                       "BiasingStrategy.parserThreshold must mirror GrammarParser.lowConfidenceThreshold")
    }

    /// R20 / ADR-0017: hands-free scoring from a biased correction stays closed on this build.
    func testSilentScoringSwitch_isOff() {
        XCTAssertFalse(BiasingStrategy.silentScoringEnabled,
                       "the silent-scoring switch flips only on on-device measurement after T046")
        XCTAssertFalse(BiasingStrategy.policy.silentScoringEnabled)
        XCTAssertEqual(BiasingStrategy.policy.parserThreshold, GrammarParser.lowConfidenceThreshold)
    }

    /// The cap an accepted correction carries must itself sit below the parser threshold, so no
    /// biased text can reach the parser as "confident enough to score silently".
    func testPolicyCap_isBelowParserThreshold() {
        let capInt = ConfidenceMapping.toInt(BiasingStrategy.policy.cappedConfidence)
        XCTAssertLessThan(capInt, GrammarParser.lowConfidenceThreshold,
                          "capped confidence \(capInt) must be < \(GrammarParser.lowConfidenceThreshold)")
    }

    func testDefaultConfidence_isBelowParserThreshold() {
        // This is the P0 structural safety pin: an unmeasured SpeechAnalyzer result MUST default
        // to a confidence below the parser's 70 threshold so FR-008 can fire. A regression here
        // (≥ 0.70) would cause every unconfident utterance to be silently parsed as a clean play.
        let defaultInt = ConfidenceMapping.toInt(AppleTranscriber.defaultConfidenceWhenUnreported)
        XCTAssertLessThan(
            defaultInt, parserThreshold,
            "defaultConfidenceWhenUnreported (\(AppleTranscriber.defaultConfidenceWhenUnreported)) → "
            + "\(defaultInt) must be < \(parserThreshold) so FR-008 clarify path can fire")
    }

    func testDefaultConfidence_isNot_aboveOrAtThreshold() {
        // Belt-and-suspenders: assert the raw Float value is strictly under 0.70, so there's no
        // float-to-int rounding edge case that could accidentally produce 70 or above.
        XCTAssertLessThan(
            AppleTranscriber.defaultConfidenceWhenUnreported, Float(parserThreshold) / 100.0,
            "raw defaultConfidenceWhenUnreported must be < 0.70 — no rounding edge near the threshold")
    }

    func testTranscribe_audioTooShort_confidenceIsNeverReturned() async {
        // The duration-guard fires before confidence is ever computed; no FR-008 bypass possible.
        let transcriber = AppleTranscriber()
        let shortBuffer = AudioBuffer(
            rawBytes: Data(repeating: 0, count: 32),
            durationSeconds: 0.1,
            capturedAt: Date()
        )
        do {
            _ = try await transcriber.transcribe(buffer: shortBuffer)
            XCTFail("expected audioTooShort")
        } catch TranscriberError.audioTooShort {
            // Expected.
        } catch {
            XCTFail("expected audioTooShort, got \(error)")
        }
    }
}

// MARK: - BiasingStrategy.choose (thin adapter over BiasingDecision — DL-157 Key Decision 3)
//
// History: the DL-80 review removed `testChoose_baseHasNoConfidence_prefersAnyBiased` and
// `testChoose_biasedAtBoundaryEqual_prefersBiased` because they certified the UNSAFE behavior where
// a nil base confidence caused an unconditional override (P0b). DL-157 settles the rule the other
// way round: the decision rests on the BIASED leg's measured confidence plus token agreement, the
// biased engine may correct words but never confidence, and an accepted correction is capped below
// the parser threshold while silent scoring is off. The exhaustive guard-order coverage lives in
// `BiasingDecisionTests`; these tests pin the adapter — that `choose` really delegates, with the
// production policy and the contextual set that was actually sent to the recognizer.

@available(iOS 26, *)
final class BiasingStrategyTests: XCTestCase {

    /// The contextual set a live transcription carries with an empty roster: the lexicon.
    private let lexicon = RosterContextBuilder.build(roster: [])

    func testChoose_nilBiased_keepsBase() {
        let out = BiasingStrategy.choose(
            baseText: "ground out 6 3", baseConfidence: 0.9, biased: nil, contextualStrings: lexicon)
        XCTAssertEqual(out, .init(text: "ground out 6 3", confidence: 0.9))
    }

    func testChoose_emptyBiased_keepsBase() {
        let out = BiasingStrategy.choose(
            baseText: "ground out", baseConfidence: 0.7, biased: ("   ", 0.99), contextualStrings: lexicon)
        XCTAssertEqual(out.text, "ground out", "whitespace-only biased result is ignored")
        XCTAssertEqual(out.confidence, 0.7)
    }

    /// Known base confidence, all guards pass: the words are corrected but the confidence is still
    /// capped (silent scoring off) — the biased leg's 0.85 never reaches the parser as-is.
    func testChoose_knownBase_agreedCorrection_overridesTextWithCap() {
        let out = BiasingStrategy.choose(
            baseText: "ground out to sean", baseConfidence: 0.60,
            biased: ("ground out to short", 0.85), contextualStrings: lexicon)
        XCTAssertEqual(out.text, "ground out to short")
        XCTAssertEqual(out.confidence, BiasingStrategy.policy.cappedConfidence)
        XCTAssertEqual(out.confidence, 0.69)
    }

    /// R19: biasing never lowers a known confidence — a less-confident biased leg (here also below
    /// the threshold) keeps the base and its own 0.90.
    func testChoose_biasedLessConfident_keepsBase() {
        let out = BiasingStrategy.choose(
            baseText: "home run", baseConfidence: 0.90, biased: ("homer", 0.50), contextualStrings: lexicon)
        XCTAssertEqual(out.text, "home run", "less-confident biased result does not override")
        XCTAssertEqual(out.confidence, 0.90)
    }

    /// R19 at the top end: both legs above the threshold, base higher → base wins with its own
    /// confidence (guard 7, `baseMoreConfident`).
    func testChoose_knownBaseHigherThanBiased_keepsBaseAndItsConfidence() {
        let out = BiasingStrategy.choose(
            baseText: "ground out to sean", baseConfidence: 0.95,
            biased: ("ground out to short", 0.85), contextualStrings: lexicon)
        XCTAssertEqual(out.text, "ground out to sean")
        XCTAssertEqual(out.confidence, 0.95)
    }

    /// P0b safety pin, re-pinned to the settled invariant: a nil base (the ONLY production state
    /// for SpeechAnalyzer today) plus a FAILED guard keeps the base text with NIL confidence — the
    /// biased text must not win and no confidence may be fabricated. Two failing guards are shown:
    /// a biased confidence under the threshold, and a divergent text.
    func testChoose_baseHasNoConfidence_keepsBase_notBiased() {
        // Guard 3: biased confidence 0.40 < 0.70.
        let lowConf = BiasingStrategy.choose(
            baseText: "ground out", baseConfidence: nil,
            biased: ("ground out 6 3", 0.4), contextualStrings: lexicon)
        XCTAssertEqual(
            lowConf.text, "ground out",
            "nil base + under-threshold biased confidence → keep base (P0b / Article VII)")
        XCTAssertNil(lowConf.confidence,
            "with nil base confidence the outcome confidence must also be nil (no fabricated signal)")

        // Guard 4: confident but divergent (4 of 6 tokens differ → 0.67 > 0.30).
        let divergent = BiasingStrategy.choose(
            baseText: "ground out", baseConfidence: nil,
            biased: ("ground out six three at first", 0.95), contextualStrings: lexicon)
        XCTAssertEqual(divergent.text, "ground out",
            "nil base + divergent biased text → keep base even at 0.95 biased confidence")
        XCTAssertNil(divergent.confidence)

        // Guard 3 at the exact boundary: 0.65 (< 0.70) — the plan's canonical example.
        let boundary = BiasingStrategy.choose(
            baseText: "ground out to sean", baseConfidence: nil,
            biased: ("ground out to short", 0.65), contextualStrings: lexicon)
        XCTAssertEqual(boundary.text, "ground out to sean")
        XCTAssertNil(boundary.confidence)
    }

    /// DL-157 Key Decision 3: a nil base with every guard passing (biased 0.85 ≥ 0.70, one OOV
    /// token "sean" replaced by the contextual "short") corrects the WORDS but caps the
    /// confidence below the parser threshold (silent scoring off) — never the biased leg's 0.85.
    func testChoose_nilBase_allGuardsPass_overridesTextButCapsConfidence() {
        let out = BiasingStrategy.choose(
            baseText: "ground out to sean", baseConfidence: nil,
            biased: ("ground out to short", 0.85), contextualStrings: lexicon)
        XCTAssertEqual(out.text, "ground out to short", "agreed correction: biased words win")
        XCTAssertEqual(out.confidence, 0.69, "R20 cap: (70 - 1) / 100, never the biased 0.85")
        XCTAssertLessThan(ConfidenceMapping.toInt(out.confidence ?? 1),
                          GrammarParser.lowConfidenceThreshold,
                          "a capped correction still lands in the parser's clarify path")
    }

    /// Guard 6: a known-vocabulary word swapped for another known-vocabulary word ("single" →
    /// "double", both in the lexicon) is exactly the kind of plausible mis-hear biasing must never
    /// "correct" — keep the base.
    func testChoose_inVocabularySwap_keepsBase() {
        let out = BiasingStrategy.choose(
            baseText: "single to short", baseConfidence: nil,
            biased: ("double to short", 0.95), contextualStrings: lexicon)
        XCTAssertEqual(out.text, "single to short", "single→double is a known→known swap: refused")
        XCTAssertNil(out.confidence)
    }

    /// Guard 5: a differing token that is NOT in the contextual set cannot be introduced.
    func testChoose_nonContextualToken_keepsBase() {
        let out = BiasingStrategy.choose(
            baseText: "ground out to sean", baseConfidence: nil,
            biased: ("ground out to shawn", 0.95), contextualStrings: lexicon)
        XCTAssertEqual(out.text, "ground out to sean", "'shawn' is not contextual: refused")
        XCTAssertNil(out.confidence)
    }

    /// The roster really reaches the decision: with "Wright" in the contextual set (as
    /// `RosterContextBuilder` assembles it), the OOV "rite" may be corrected to the player's name;
    /// with the lexicon alone it may not.
    func testChoose_rosterName_isContextual_onlyWhenSent() {
        let withRoster = RosterContextBuilder.build(roster: ["Wright"])
        let corrected = BiasingStrategy.choose(
            baseText: "fly ball to rite caught", baseConfidence: nil,
            biased: ("fly ball to Wright caught", 0.90), contextualStrings: withRoster)
        XCTAssertEqual(corrected.text, "fly ball to Wright caught", "roster name is contextual")
        XCTAssertEqual(corrected.confidence, 0.69, "still capped — words, never confidence")

        let refused = BiasingStrategy.choose(
            baseText: "fly ball to rite caught", baseConfidence: nil,
            biased: ("fly ball to Wright caught", 0.90), contextualStrings: lexicon)
        XCTAssertEqual(refused.text, "fly ball to rite caught", "without the roster, 'Wright' is OOV")
        XCTAssertNil(refused.confidence)
    }

    /// The adapter and the pure decision agree on the same inputs — `choose` is a delegation,
    /// not a second implementation (KTD2).
    func testChoose_matchesBiasingDecision_onTheSameInputs() {
        let cases: [(String, Float?, (String, Float)?)] = [
            ("ground out to sean", nil, ("ground out to short", 0.85)),
            ("ground out to sean", 0.60, ("ground out to short", 0.85)),
            ("single to short", nil, ("double to short", 0.95)),
            ("home run", 0.90, ("homer", 0.50)),
            ("", nil, ("ground out", 0.99)),
            ("ground out", nil, nil),
        ]
        for (base, baseConf, biased) in cases {
            let adapter = BiasingStrategy.choose(
                baseText: base, baseConfidence: baseConf, biased: biased, contextualStrings: lexicon)
            let pure = BiasingDecision.decide(
                base: base, baseConfidence: baseConf,
                biased: biased.map { BiasedHypothesis(text: $0.0, confidence: $0.1) },
                vocabulary: ContextualVocabulary(phrases: lexicon),
                policy: BiasingStrategy.policy)
            XCTAssertEqual(adapter.text, pure.text, "text for \(base) / \(String(describing: biased))")
            XCTAssertEqual(adapter.confidence, pure.confidence, "confidence for \(base)")
        }
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

    /// The buffer the push-to-talk pipeline synthesizes today (capture T046 absent): a nominal
    /// 1.0 s duration but NO bytes. The duration guard passes and the PCM builder must still
    /// refuse it as `audioTooShort` — a visible error, not a recognition attempt on nothing.
    func testTranscribe_emptyBytesWithNominalDuration_throwsAudioTooShort() async {
        let transcriber = AppleTranscriber()
        let emptyBuffer = AudioBuffer(rawBytes: Data(), durationSeconds: 1.0, capturedAt: Date())
        do {
            _ = try await transcriber.transcribe(buffer: emptyBuffer)
            XCTFail("expected audioTooShort for an empty capture")
        } catch TranscriberError.audioTooShort {
            // Expected.
        } catch TranscriberError.permissionDenied {
            // Also acceptable off-device: a denied/restricted speech authorization is checked
            // before the PCM builder. Either way nothing is recognized silently.
        } catch {
            XCTFail("expected audioTooShort (or permissionDenied), got \(error)")
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
