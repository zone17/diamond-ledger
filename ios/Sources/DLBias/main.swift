// dl-bias — headless roster-biasing decision harness (DL-157 / R8 / KTD4).
//
// Issue #157 proposes a second, contextually-biased ASR leg (SFSpeechRecognizer with roster names,
// positions and play words as `contextualStrings`) beside the base SpeechAnalyzer transcription.
// Whether the biased hypothesis may REPLACE the base is decided by one pure rule —
// `BiasingDecision.decide` in SpeechTypes — and this CLI is the way to measure that rule OFF the
// device: feed it an adversarial corpus of (base, biased) hypothesis pairs and it labels each one
// with the decision the production `BiasingStrategy` would make (same function, same policy).
// Article VII / FR-008: the biasing ships only if it NEVER turns a plausibly mis-heard transcript
// into a confidently-scored wrong play; this tool produces the evidence for that claim.
//
// What it does NOT do: it does not run ASR (no audio in, no engine), it does not parse or score
// (see dl-score for the transcript→score leg), and it does not decide pass/fail — it is a
// measurement tool. The runner (evals/runners/voice-accuracy.sh) compares each row's `decision` /
// `text` against the corpus's `expect_*` fields and owns the exit code. The confidences it
// reports are the policy's OUTPUT for the confidences given in the corpus, not a measurement of
// any real engine — label accordingly (FIXTURE ROBUSTNESS, not field accuracy).
//
// Usage:
//   dl-bias [<file>]        # read JSON Lines from <file>, or stdin if omitted
//
// Input: one JSON object per line (blank lines and lines whose first non-space char is '#' are
// skipped). Fields:
//   id                 string   row id (echoed)
//   base               string   base-leg text
//   base_confidence    number   optional, 0…1, or null  (nil = unknown — the iOS 26 reality)
//   biased             string   or null when the biased leg produced nothing
//   biased_confidence  number   0…1, required when `biased` is non-null
//   contextual_set     [string] phrases the biased leg was told about (lexicon + roster)
//   expect_decision, expect_text   optional, echoed through untouched (the comparator reads them)
//
// Output: one sorted-key JSON object per input line, in input order:
//   id, decision ("override" | "keep_base"), text, confidence (0…100 or null),
//   uncapped_confidence (the same decision with the silent-scoring switch ON — what the
//   correction would carry if the R20 cap were lifted), reason (BiasingReason raw value),
//   distance (normalized token edit distance, 4 places), plus any echoed expect_* fields.
// A malformed line emits {"error": "...", "line": <n>} and processing continues. Exit 0 always.

import Foundation
import SpeechTypes
import Parse

// MARK: - Input

struct BiasRow {
    let id: String
    let base: String
    let baseConfidence: Float?
    let biased: BiasedHypothesis?
    let vocabulary: ContextualVocabulary
    let echoed: [String: Any]
}

enum RowError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case notAnObject
    case missing(String)
    case wrongType(String, expected: String)
    case outOfRange(String)

    var description: String {
        switch self {
        case .invalidJSON(let m):            return "invalid JSON: \(m)"
        case .notAnObject:                   return "line is not a JSON object"
        case .missing(let f):                return "missing required field '\(f)'"
        case .wrongType(let f, let e):       return "field '\(f)' must be \(e)"
        case .outOfRange(let f):             return "field '\(f)' must be a number in 0...1"
        }
    }
}

/// Decode one corpus row. Schema violations are errors — a row the harness cannot interpret must
/// surface, not silently default (the same never-guess rule the parser follows).
func decodeRow(_ line: String) throws -> BiasRow {
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    } catch {
        throw RowError.invalidJSON(error.localizedDescription)
    }
    guard let dict = object as? [String: Any] else { throw RowError.notAnObject }

    func string(_ key: String) throws -> String {
        guard let v = dict[key] else { throw RowError.missing(key) }
        guard let s = v as? String else { throw RowError.wrongType(key, expected: "a string") }
        return s
    }
    /// A 0…1 confidence. `nil` when absent or JSON null (allowed only where the caller permits).
    func unitConfidence(_ key: String) throws -> Float? {
        guard let v = dict[key], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, !(v is Bool) else { throw RowError.wrongType(key, expected: "a number or null") }
        let d = n.doubleValue
        guard d.isFinite, (0.0...1.0).contains(d) else { throw RowError.outOfRange(key) }
        return Float(d)
    }

    let id = try string("id")
    let base = try string("base")
    let baseConfidence = try unitConfidence("base_confidence")

    let biased: BiasedHypothesis?
    if let v = dict["biased"], !(v is NSNull) {
        guard let text = v as? String else { throw RowError.wrongType("biased", expected: "a string or null") }
        guard let conf = try unitConfidence("biased_confidence") else {
            throw RowError.missing("biased_confidence (required when 'biased' is non-null)")
        }
        biased = BiasedHypothesis(text: text, confidence: conf)
    } else {
        biased = nil
    }

    guard let rawSet = dict["contextual_set"] else { throw RowError.missing("contextual_set") }
    guard let phrases = rawSet as? [String] else {
        throw RowError.wrongType("contextual_set", expected: "an array of strings")
    }

    var echoed: [String: Any] = [:]
    for key in ["expect_decision", "expect_text"] {
        if let v = dict[key] { echoed[key] = v }
    }

    return BiasRow(id: id, base: base, baseConfidence: baseConfidence, biased: biased,
                   vocabulary: ContextualVocabulary(phrases: phrases), echoed: echoed)
}

// MARK: - Output

func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func confidenceInt(_ native: Float?) -> Any {
    guard let native else { return NSNull() }
    return ConfidenceMapping.toInt(native)
}

/// Decide one row under the default policy and under the silent-scoring policy (for the
/// uncapped confidence), and shape the JSON line.
func decide(_ row: BiasRow) -> [String: Any] {
    let threshold = GrammarParser.lowConfidenceThreshold
    let capped = BiasingDecision.decide(
        base: row.base, baseConfidence: row.baseConfidence, biased: row.biased,
        vocabulary: row.vocabulary, policy: .default(parserThreshold: threshold)
    )
    let uncapped = BiasingDecision.decide(
        base: row.base, baseConfidence: row.baseConfidence, biased: row.biased,
        vocabulary: row.vocabulary,
        policy: BiasingPolicy(parserThreshold: threshold, silentScoringEnabled: true)
    )
    let distance = TokenEditDistance.normalized(row.base, row.biased?.text ?? "")

    var out: [String: Any] = [
        "id": row.id,
        "decision": capped.reason.isOverride ? "override" : "keep_base",
        "text": capped.text,
        "confidence": confidenceInt(capped.confidence),
        "uncapped_confidence": confidenceInt(uncapped.confidence),
        "reason": capped.reason.rawValue,
        // Rounded to 4 places and emitted as a decimal so the JSON reads "0.3333", not the
        // 17-digit binary expansion JSONSerialization prints for a raw Double.
        "distance": NSDecimalNumber(string: String(format: "%.4f", distance)),
    ]
    for (k, v) in row.echoed { out[k] = v }
    return out
}

// MARK: - Entry point

func readInput() -> String {
    let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    if let path = args.first {
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
    var data = Data()
    while let chunk = try? FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
        data.append(chunk)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

var lineNumber = 0
for rawLine in readInput().split(separator: "\n", omittingEmptySubsequences: false) {
    lineNumber += 1
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    do {
        emit(decide(try decodeRow(line)))
    } catch {
        emit(["error": "\(error)", "line": lineNumber])
    }
}
exit(0)
