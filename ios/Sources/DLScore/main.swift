// dl-score — headless transcript→score CLI (DL-37).
//
// Restores agent/CLI parity (Art. II / FR-018) for the SCORING pipeline: the deterministic
// text→score path (GrammarParser → real Rust core) must be invokable OFF the iOS device — from
// a macOS CLI, CI, the eval harness, or an agent — not trapped inside the SwiftUI app. Before
// this, `evals/runners/accuracy.sh` could not run its field-accuracy branch because no
// `$DL_PIPELINE_SCORER` existed; the whole accuracy story was stuck at "self-consistency,
// advisory" with no way to measure the transcript→score leg headlessly.
//
// What it does NOT do: it does not run ASR (audio→text). That leg is the iOS-26-only
// `SpeechAnalyzer` engine (`DiamondSpeech`), still device/sim-bound. dl-score takes the
// TRANSCRIPT as input and measures the deterministic, platform-independent leg
// (transcript → grammar parse → fact-derived classification → Reisner) where most of the
// scoring risk lives and which we fully control.
//
// Model: one transcript line == one independent play scored in a FRESH game (top of the 1st,
// bases empty). This sidesteps the FR-007 pending-confirmation guard (a second recordPlay on a
// game with an unconfirmed entry is rejected) and matches how the per-transcript regression
// corpora (judgment-corpus, seed.jsonl) are structured: each case is an independent
// classification probe. Full-game sequential scoring (confirm/resolve each play for
// state-dependent Reisner cells) is a documented follow-up, gated on the human gold scorecard.
//
// Usage:
//   dl-score [<file>]        # read transcript lines from <file>, or stdin if omitted
//   echo "ground ball to short, threw him out at first" | dl-score
//
// Output: JSON Lines (one JSON object per input line) on stdout. Blank lines and lines whose
// first non-space char is '#' are skipped (comments). Exit 0 always (it is a measurement tool,
// not a gate — the runner decides pass/fail). A per-line scoring error is reported in the line's
// JSON `error` field, never as a process failure.

import Foundation
import SpeechTypes
import Parse
import Core

// MARK: - Output schema

/// One scored line. Codable → JSON. Field names are snake_case to match the wire format the
/// eval corpora and the Rust boundary use (DL-67/ADR-0009). All fields past `classification`
/// default to nil/false so the failure/success factories below stay one-liners (no 13-arg
/// memberwise init repeated at every emit site).
struct ScoredLine: Codable {
    let transcript: String
    /// The normalized facts the GrammarParser extracted (diagnostic — shows what the parser saw,
    /// which the core's fact-derived classifier reads, I1). Empty on parse failure.
    let facts: [String: String]
    /// true iff the grammar parsed AND the core accepted the facts.
    let ok: Bool
    /// "deterministic" | "judgment" | "out_of_format" | "parse_error" | "core_error"
    let classification: String
    /// The associated reason string for an `out_of_format` classification (nil otherwise).
    var out_of_format_reason: String? = nil
    /// For a judgment play: the JudgmentKind rawValue (e.g. "hitVsError"). nil otherwise.
    var judgment_kind: String? = nil
    /// true iff the core surfaced an open judgment (Card B). The cardinal SC-003 signal.
    var judgment_required: Bool = false
    /// The open judgment's decision id — an agent needs this to resolve it headlessly (FR-011).
    var decision_id: UInt64? = nil
    /// The alternative scoring-call tokens an agent/scorer may choose from to resolve the judgment.
    var alternatives: [String]? = nil
    /// One-line rationale for the core's recommended call (judgment path).
    var recommended_reason: String? = nil
    /// Loop-control: "none" | "confirm" | "clarify" | "judgment".
    var needs: String? = nil
    /// The core's recommended call token (judgment path; e.g. "hit", "error:6").
    var recommended_token: String? = nil
    /// Human-readable recommended label.
    var recommended_label: String? = nil
    /// Rendered Reisner cell (situation/catalyst/runner-fate/pitch-marks).
    var reisner_situation: String? = nil
    var reisner_catalyst: String? = nil
    var reisner_runner_fate: String? = nil
    /// Populated only when ok == false (parse failure / out-of-grammar / core error).
    var error: String? = nil

    /// A failed line (parse error / core error) — `ok=false`, only the diagnostic fields set.
    static func failure(transcript: String, facts: [String: String], classification: String,
                        error: String) -> ScoredLine {
        ScoredLine(transcript: transcript, facts: facts, ok: false,
                   classification: classification, error: error)
    }
}

// MARK: - Helpers

/// (classification label, judgment kind, out-of-format reason) for a core classification.
func classificationLabel(_ c: RecordPlayClassification) -> (String, String?, String?) {
    switch c {
    case .deterministic:            return ("deterministic", nil, nil)
    case .judgment(let kind):       return ("judgment", kind.rawValue, nil)
    case .outOfFormat(let reason):  return ("out_of_format", nil, reason)
    }
}

func emit(_ line: ScoredLine) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(line), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func readInputLines() -> [String] {
    let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    let raw: String
    if let path = args.first {
        raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    } else {
        var data = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
        }
        raw = String(data: data, encoding: .utf8) ?? ""
    }
    return raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

// MARK: - Entry point

@main
struct DLScore {
    static let ownerId = "dl-score-harness"

    static func main() async {
        let parser = GrammarParser()
        let core = DiamondCoreClient()
        var corr = 0

        for rawLine in readInputLines() {
            let transcript = rawLine.trimmingCharacters(in: .whitespaces)
            if transcript.isEmpty || transcript.hasPrefix("#") { continue }
            corr += 1
            await scoreOne(transcript, parser: parser, core: core, corr: corr)
        }
    }

    /// Score one transcript in a fresh game and emit its JSON line. Never throws — failures
    /// become the line's `error` field (a measurement tool reports, it does not abort).
    static func scoreOne(
        _ transcript: String,
        parser: GrammarParser,
        core: DiamondCoreClient,
        corr: Int
    ) async {
        // 1. Grammar parse (transcript → normalized facts). Out-of-grammar / ambiguous /
        //    empty are SURFACED, never silently guessed (FR-008/FR-017).
        let facts: NormalizedPlay
        do {
            facts = try parser.parse(
                Transcript(text: transcript, confidence: 100, engine: .stub, finalizedAt: Date())
            )
        } catch let e as ParseError {
            let reason: String
            switch e {
            case .outOfGrammar:        reason = "out_of_grammar"
            case .ambiguous(let c):    reason = "ambiguous(\(c.count) candidates)"
            case .emptyInput:          reason = "empty_input"
            }
            emit(.failure(transcript: transcript, facts: [:], classification: "parse_error", error: reason))
            return
        } catch {
            emit(.failure(transcript: transcript, facts: [:], classification: "parse_error",
                          error: "parse: \(error)"))
            return
        }

        // 2. Fresh game + record_play against the REAL core. Fresh game per line avoids the
        //    FR-007 pending-confirmation guard and matches the per-transcript corpus model.
        do {
            let game = try await core.createGame(
                homeTeam: "HOME", visitorTeam: "AWAY",
                ownerId: ownerId, correlationId: "g-\(corr)"
            )
            let r = try await core.recordPlay(
                gameId: game.gameId, ownerId: ownerId,
                normalizedFacts: facts, correlationId: "p-\(corr)"
            )
            let (cls, kind, oofReason) = classificationLabel(r.classification)
            // Judgment payload — an agent needs decision_id + alternatives to RESOLVE it headlessly
            // (FR-011), not just the boolean that one is open (agent-native parity, AN-1).
            let j = r.judgment
            emit(ScoredLine(
                transcript: transcript, facts: facts, ok: true, classification: cls,
                out_of_format_reason: oofReason,
                judgment_kind: kind,
                judgment_required: r.needs == .judgment,
                decision_id: j?.id,
                alternatives: j.map { $0.alternatives.map(\.token) },
                recommended_reason: j?.recommendation.oneLineReason,
                needs: r.needs.rawValue,
                recommended_token: j?.recommendation.call.token,
                recommended_label: j?.recommendation.call.label,
                reisner_situation: r.reisner.situationDiamond,
                reisner_catalyst: r.reisner.catalystSymbols,
                reisner_runner_fate: "\(r.reisner.runnerFate)"
            ))
        } catch {
            emit(.failure(transcript: transcript, facts: facts, classification: "core_error",
                          error: "core: \(error)"))
        }
    }
}
