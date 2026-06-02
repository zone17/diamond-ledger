#!/usr/bin/env bash
# check-no-raw-audio.sh — Privacy gate: no raw-audio-persistence path (T070 / FR-022 / COPPA)
#
# Authority:  FR-022 (process-don't-store), FR-029 (COPPA/consent path)
# Enforced by: CI secret-scan job (hard-fail); local: bash scripts/check-no-raw-audio.sh
#
# This script scans Rust, Swift, and Kotlin source for patterns that would indicate
# raw PCM audio being persisted to disk, a database, telemetry, or any storage sink.
# It is a HARD-FAIL gate: any unallowlisted match exits 1 with a ::error:: annotation.
#
# ADDING AN ALLOWLIST EXCEPTION
#   Add a shell glob to the PRIVACY_ALLOWLIST array below.
#   The glob is matched against the full file path reported by grep (e.g. "/repo/ios/...").
#   Every exception MUST have an inline comment explaining the FR-022 exception rationale
#   and must be reviewed in a PR; exceptions are never silent.
#
# EXTENDING PATTERNS
#   Add patterns to AUDIO_WRITE_PATTERNS below; all are POSIX-ERE applied with grep -E.
#   Do NOT weaken an existing pattern or change the gate exit code without an ADR update.
#
# SELF-TEST
#   Run with --self-test to verify all violation patterns fire correctly and clean
#   code does not trigger false positives. The CI job also runs this mode first.
#   Exit 0 = all self-tests pass; exit 1 = a self-test failed (gate is broken).
#
# Usage:
#   bash scripts/check-no-raw-audio.sh [<repo-root>]   # normal gate scan
#   bash scripts/check-no-raw-audio.sh --self-test      # verify the patterns themselves
#
# Exit codes:
#   0  Gate passes (no violations, or all matches are allowlisted)
#   1  Gate fails — violation found, or self-test failed

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
info()  { echo "${GREEN}[privacy-gate]${NC} $*"; }
warn()  { echo "${YELLOW}[privacy-gate] WARN${NC} $*" >&2; }
fail()  { echo "${RED}[privacy-gate] FAIL${NC} $*" >&2; }
ok()    { echo "${GREEN}[privacy-gate] PASS${NC} $*"; }

# ── Allowlist ──────────────────────────────────────────────────────────────────
# Shell globs matched against the full file path of any flagged match.
# A match whose file path matches ANY glob below is suppressed (not a gate failure).
# EVERY entry needs an inline comment with: rationale + ADR/ticket reference.
#
# Example (do not uncomment without a real rationale):
#   "*/ios/Tests/AudioTestHelpers.swift"  # test-only mock; never ships — DL-999
PRIVACY_ALLOWLIST=(
    # No exceptions yet.
)

# ── Patterns ───────────────────────────────────────────────────────────────────
# POSIX-ERE patterns applied with grep -E. A line matches if it contains a
# combination of an audio-naming token and a persistence-action token.
#
# Design principle: err toward false positives (manual review) rather than
# false negatives (silent violations). A flagged clean line requires a reviewer
# to add it to PRIVACY_ALLOWLIST with justification — that is the intended flow.
#
# Pattern taxonomy:
#   P1 — receiver-side: <audio-object>.<write-verb>(...)
#   P2 — argument-side: .<write-verb>(from: <audio>)  /  write_all(&<audio>)
#   P3 — named write functions: writeAudio(), saveAudio(), etc.
#   P4 — extension-based: path ending in .pcm/.wav/.raw + write verb
#   P5 — FileManager audio copies
#   P6 — fwrite / pwrite syscall with audio arg (C/Rust unsafe)
#   P7 — SQLite / GRDB / CoreData audio blob insert
#   P8 — UserDefaults audio set
#   P9 — CloudKit audio record save
#
# Audio token vocabulary (camelCase + snake_case; covers Swift, Kotlin, Rust):
#   Receiver tokens: pcmBuffer, PCMBuffer, AVAudioPCMBuffer, AudioBuffer,
#     recordingBuffer, audioBuffer, RawAudio, pcmData, audioData, recordingData,
#     capturedAudio, sampleData, audioSamples, audioFrame,
#     pcm_buf, pcm_data, audio_data, audio_samples, audio_frame, recording_data
#
AUDIO_WRITE_PATTERNS=(
    # P1 — audio-named object as the RECEIVER of a write/save/store/persist call.
    #   Swift: try pcmBuffer.write(to: url)
    #   Swift: try audioData.write(to: fileURL)
    #   Rust:  pcm_data.save(path)   (less common but still a violation)
    '(pcm[Bb]uffer|PCMBuffer|AVAudioPCMBuffer|AudioBuffer|recordingBuffer|audioBuffer|RawAudio|pcm_buf|pcm_data|pcmData|audioData|recordingData|capturedAudio|sampleData|audioSamples|audioFrame|audio_data|audio_samples|audio_frame|recording_data)[^[:alpha:]]*\.(write|write_all|writeBytes|writeData|save|store|persist|insert|upload|append|create|flush)'

    # P2 — audio-named object as an ARGUMENT to a write call (reversed direction).
    #   Swift:  avAudioFile.write(from: pcmBuffer)
    #   Rust:   f.write_all(&audio_samples)?
    #   Kotlin: outputStream.write(pcmData) / file.writeBytes(pcmBytes)
    #   The pattern requires a write verb followed (anywhere on the same call) by
    #   an audio token — capturing the argument position.
    #   Note: no trailing \b on the audio token so 'pcm' matches inside 'pcmBytes', etc.
    #   [[:space:]] not \s — POSIX ERE portable across macOS BSD grep and GNU grep.
    '\.(write|write_all|writeBytes|writeData)[[:space:]]*\(.*\b(pcm|audio|wav|raw|sound)'

    # P3 — named write/save functions whose name encodes the intent.
    #   writeAudio(), saveAudio(), persistAudio(), writeRaw(), etc.
    '(writeAudio|saveAudio|persistAudio|storeAudio|uploadAudio|flushAudio|commitAudio|writeRaw|storeRaw|persistRaw|saveRaw|writePCM|savePCM|persistPCM|writeRecording|saveRecording)[[:space:]]*\('

    # P4 — file path with audio-like extension AND a write/create operation on the same line.
    #   Swift: FileHandle(forWritingAtPath: "output.pcm") — verb precedes extension
    #   Any:   fopen("capture.wav", "wb") — verb follows extension as mode string
    #   Two sub-patterns joined with alternation:
    #     P4a: write-indicating symbol before the audio extension (verb-then-ext)
    #     P4b: audio extension followed (on the same line) by a write verb (ext-then-verb)
    '((fopen|FileHandle|forWriting|forCreating)[^;]*(\.pcm|\.wav|\.raw|\.caf|\.aiff)|(\.pcm|\.wav|\.raw|\.caf|\.aiff|\.audio)[^;]*(write|save|store|create|open|append|flush))'

    # P5 — FileManager copying/creating audio-named files.
    #   Swift: try FileManager.default.copyItem(at: audioURL, to: dest)
    'FileManager[^;]*\.(create|copyItem|moveItem)[^;]*(audio|\.pcm|\.wav|\.raw)'

    # P6 — C/Rust low-level write syscall with an audio-named argument.
    #   Rust: fwrite(pcm_buf, ...) / write(fd, &audio_data, len)
    '(fwrite|pwrite)\s*\([^)]*\b(pcm|audio|wav|raw|sound)\b'

    # P7 — SQLite / GRDB / CoreData insert of audio blob.
    '(db\.|database\.|grdb\.|sqlite)[^;]*(insert|execute)[^;]*(audio|pcm|wav|raw|sound)'

    # P8 — UserDefaults persistence of audio-named data.
    'UserDefaults[^;]*(set|setValue)[^;]*(audio|pcm|wav|recording)'

    # P9 — CloudKit record with audio field saved to the store.
    'CKRecord[^;]*(audio|pcm|wav|recording)[^;]*(save|modify|push)'
)

# ── Comment-line filter ────────────────────────────────────────────────────────
# grep -rn output format is: /path/to/file:LINENO:  <code content>
# The '^' anchor in a POSIX grep pattern matches the start of the FULL grep output
# line (i.e., before the file path), NOT the start of the source code content.
# To skip comment lines we must anchor AFTER the last path:lineno: prefix.
# Pattern: match `:` then optional whitespace then a comment start token.
#
# Covers: Swift //  •  Rust //  •  Kotlin //  •  Shell #  •  Block comment * / /*
COMMENT_FILTER=':[[:space:]]*(//|#|/\*|\*[^/]|\*/)'

# ── Allowlist helper ───────────────────────────────────────────────────────────
# Returns 0 (true) if the filepath in $1 matches any PRIVACY_ALLOWLIST glob.
is_allowlisted() {
    local filepath="$1"
    local glob
    for glob in "${PRIVACY_ALLOWLIST[@]}"; do
        # shellcheck disable=SC2254  # glob is intentionally a pattern
        case "$filepath" in
            $glob) return 0 ;;
        esac
    done
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# Verifies that:
#   (a) every known-violation string triggers at least one pattern (must-catch)
#   (b) known-clean strings do not trigger any pattern (must-not-catch)
#
# The test strings are embedded here to keep the gate self-contained.
# Run: bash scripts/check-no-raw-audio.sh --self-test
# ══════════════════════════════════════════════════════════════════════════════

run_self_test() {
    info "=== Self-test mode: verifying patterns against known violations and clean code ==="
    echo ""

    # ── Violation strings that MUST be caught ─────────────────────────────────
    # Each entry is a tuple: "LABEL|CODE_SNIPPET"
    # The code snippet is the source-code content portion only (no path:lineno: prefix).
    # The self-test prepends a fake path:lineno: prefix so the comment filter fires
    # correctly, then checks at least one AUDIO_WRITE_PATTERNS entry matches.
    declare -a MUST_CATCH=(
        # P1 — camelCase receiver (previously missing from token list)
        "P1a camelCase pcmData.write|    try pcmData.write(to: fileURL)"
        "P1b camelCase audioData.write|    try audioData.write(to: outputURL)"
        "P1c camelCase recordingData.write|    try recordingData.write(to: tempURL)"
        "P1d camelCase capturedAudio.write|    try capturedAudio.write(to: archiveURL)"
        "P1e camelCase audioSamples.write|    audioSamples.write(to: path)"
        "P1f camelCase audioFrame.save|    audioFrame.save(to: diskPath)"
        "P1g snake_case pcm_data write_all|    f.write_all(&pcm_data)?"
        "P1h snake_case audio_samples write_all|    writer.write_all(&audio_samples)?"
        "P1i pcmBuffer.write existing|    try pcmBuffer.write(to: url)"
        # P2 — reversed argument (previously missing entirely)
        "P2a avAudioFile.write(from:)|    try avAudioFile.write(from: pcmBuffer)"
        "P2b write_all audio arg|    f.write_all(&audio_data)?"
        "P2c writeBytes pcmBytes|    file.writeBytes(pcmBytes)"
        "P2d writeData audioData|    stream.writeData(audioData)"
        # P3 — named functions
        "P3a writeAudio()|    writeAudio(buffer: pcmFrame)"
        "P3b saveRecording()|    saveRecording(to: cache)"
        # P4 — extension-based
        "P4a .pcm open|    let fh = FileHandle(forWritingAtPath: capture.pcm)"
        "P4b .wav write|    fopen(outputFile.wav, wb)"
    )

    # ── Clean strings that MUST NOT be caught ─────────────────────────────────
    declare -a MUST_NOT_CATCH=(
        "CLEAN forward streaming|    engine.process(from: pcmBuffer)"
        "CLEAN read not write|    let data = try Data(contentsOf: audioURL)"
        "CLEAN comment Swift|    // try pcmData.write(to: fileURL)"
        "CLEAN comment Rust|    // f.write_all(&audio_samples)?"
        "CLEAN comment hash|    # writeAudio(buffer)"
        "CLEAN unrelated write|    file.write(jsonData)"
        "CLEAN unrelated save|    context.save()"
    )

    local ST_FAILED=0
    local ST_PASS=0
    local ST_FAIL=0

    info "--- Must-catch violations (gate MUST fire) ---"
    for entry in "${MUST_CATCH[@]}"; do
        LABEL="${entry%%|*}"
        SNIPPET="${entry#*|}"
        # Prepend fake path:lineno: so the comment filter has the right format to skip
        FAKE_LINE="/fake/file.swift:42:${SNIPPET}"
        CAUGHT=0
        for PAT in "${AUDIO_WRITE_PATTERNS[@]}"; do
            if echo "$FAKE_LINE" | grep -qE "$PAT" 2>/dev/null; then
                CAUGHT=1
                break
            fi
        done
        if [[ "$CAUGHT" -eq 1 ]]; then
            ok "  CAUGHT  [$LABEL]: $SNIPPET"
            ST_PASS=$((ST_PASS + 1))
        else
            fail "  MISSED  [$LABEL]: $SNIPPET"
            fail "    — no pattern matched; this violation would slip through the gate"
            ST_FAIL=$((ST_FAIL + 1))
            ST_FAILED=1
        fi
    done

    echo ""
    info "--- Must-not-catch (clean code — gate MUST NOT fire) ---"
    for entry in "${MUST_NOT_CATCH[@]}"; do
        LABEL="${entry%%|*}"
        SNIPPET="${entry#*|}"
        FAKE_LINE="/fake/file.swift:42:${SNIPPET}"

        TRIGGERED=0
        for PAT in "${AUDIO_WRITE_PATTERNS[@]}"; do
            RAW_MATCH=""
            RAW_MATCH="$(echo "$FAKE_LINE" | grep -E "$PAT" 2>/dev/null || true)"
            if [[ -n "$RAW_MATCH" ]]; then
                # Apply the comment filter: if the line (after path:lineno:) is a comment,
                # it would be suppressed in the real scan — treat as not triggered here too.
                if echo "$RAW_MATCH" | grep -qE "$COMMENT_FILTER" 2>/dev/null; then
                    : # comment — would be filtered; not a real trigger
                else
                    TRIGGERED=1
                    break
                fi
            fi
        done

        if [[ "$TRIGGERED" -eq 0 ]]; then
            ok "  CLEAN   [$LABEL]: $SNIPPET"
            ST_PASS=$((ST_PASS + 1))
        else
            fail "  FALSE+  [$LABEL]: $SNIPPET"
            fail "    — pattern fired on clean code; review the pattern for over-reach"
            ST_FAIL=$((ST_FAIL + 1))
            ST_FAILED=1
        fi
    done

    echo ""
    info "Self-test results: $ST_PASS passed, $ST_FAIL failed"
    if [[ "$ST_FAILED" -ne 0 ]]; then
        fail "=== SELF-TEST FAILED ==="
        fail "    Fix the broken patterns before deploying this gate."
        exit 1
    else
        ok "=== SELF-TEST PASSED ==="
        ok "    All violation strings caught; all clean strings pass through."
        exit 0
    fi
}

# ── Mode dispatch ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--self-test" ]]; then
    run_self_test
fi

# ── Repo root ──────────────────────────────────────────────────────────────────
REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ ! -d "$REPO_ROOT" ]]; then
    fail "repo root not found: $REPO_ROOT"
    exit 1
fi
info "Scanning repo root: $REPO_ROOT"

# ── Source directories to scan ────────────────────────────────────────────────
# Rust core (deterministic engine) — should never touch audio at all.
# iOS Swift sources — the audio capture layer; must NOT persist PCM frames.
# Kotlin Android adapter — same rule.
# adapters/   — CLI, agent; no audio write paths expected.
SCAN_DIRS=()
for d in core ios adapters android; do
    [[ -d "$REPO_ROOT/$d" ]] && SCAN_DIRS+=("$REPO_ROOT/$d")
done

if [[ ${#SCAN_DIRS[@]} -eq 0 ]]; then
    warn "No source directories found yet (core/, ios/, adapters/, android/)."
    warn "Gate passes vacuously — will enforce once source directories exist."
    ok "No source directories to scan — gate passes (vacuous, pre-code state)."
    exit 0
fi

# ── Scan ───────────────────────────────────────────────────────────────────────
GATE_FAILED=0
TOTAL_MATCHES=0

info "Scanning ${#SCAN_DIRS[@]} source directory/directories for raw-audio persistence patterns..."
info "Patterns: ${#AUDIO_WRITE_PATTERNS[@]}"
info "Allowlist entries: ${#PRIVACY_ALLOWLIST[@]}"
echo ""

for PATTERN in "${AUDIO_WRITE_PATTERNS[@]}"; do
    # grep -rn: recursive + line numbers.  Output format: /path/file.swift:LINENO:  code
    # --include: Swift, Kotlin, Rust source only.
    # Pipe 1: drop comment lines (anchored after the path:lineno: prefix — see COMMENT_FILTER).
    # Pipe 2: the result is candidate violations; check allowlist per file.
    RAW_MATCHES=""
    RAW_MATCHES="$(
        grep -rn --include="*.swift" --include="*.kt" --include="*.rs" \
            -E "$PATTERN" \
            "${SCAN_DIRS[@]}" 2>/dev/null \
        | grep -vE "$COMMENT_FILTER" \
        || true
    )"

    if [[ -z "$RAW_MATCHES" ]]; then
        continue
    fi

    # Apply allowlist: suppress matches whose file path is allowlisted.
    EFFECTIVE_MATCHES=""
    while IFS= read -r match_line; do
        # Extract the file path (everything before the first ':')
        FILE_PATH="${match_line%%:*}"
        if is_allowlisted "$FILE_PATH"; then
            warn "Allowlisted match suppressed (${FILE_PATH}): ${match_line}"
        else
            EFFECTIVE_MATCHES="${EFFECTIVE_MATCHES}${match_line}"$'\n'
        fi
    done <<< "$RAW_MATCHES"

    # Trim trailing newline
    EFFECTIVE_MATCHES="${EFFECTIVE_MATCHES%$'\n'}"

    if [[ -n "$EFFECTIVE_MATCHES" ]]; then
        fail "Raw-audio persistence pattern matched:"
        fail "  Pattern: $PATTERN"
        while IFS= read -r match_line; do
            FILE_PATH="${match_line%%:*}"
            echo "::error file=${FILE_PATH}::Raw-audio persistence path detected (FR-022): ${match_line}"
            fail "  ${match_line}"
        done <<< "$EFFECTIVE_MATCHES"
        MATCH_COUNT="$(echo "$EFFECTIVE_MATCHES" | wc -l | tr -d ' ')"
        TOTAL_MATCHES=$((TOTAL_MATCHES + MATCH_COUNT))
        GATE_FAILED=1
        echo ""
    fi
done

# ── COPPA consent structural check ────────────────────────────────────────────
# FR-029: when the iOS Auth module exists, it must contain an explicit COPPA /
# consent / parental-gating marker.  This is a HARD-FAIL gate (not a warning).
echo ""
info "=== COPPA / Parental Consent structural check (FR-029) ==="
AUTH_DIR="$REPO_ROOT/ios/Sources/Auth"
if [[ -d "$AUTH_DIR" ]]; then
    CONSENT_FILES="$(find "$AUTH_DIR" -name "*.swift" -print0 \
        | xargs -0 grep -l -iE "(coppa|consent|age.{0,10}verif|parental)" 2>/dev/null \
        || true)"
    if [[ -z "$CONSENT_FILES" ]]; then
        fail "ios/Sources/Auth exists but contains NO COPPA/consent marker."
        fail "  FR-029 requires explicit parental/age-gating in the Auth module."
        fail "  Add a Swift file with a COPPA consent flow before shipping."
        echo "::error::COPPA consent marker missing in ios/Sources/Auth (FR-029)"
        GATE_FAILED=1
    else
        ok "COPPA consent marker found:"
        while IFS= read -r f; do
            info "  $f"
        done <<< "$CONSENT_FILES"
    fi
else
    info "ios/Sources/Auth not yet present — COPPA check deferred (T081)."
    info "  Gate will HARD-FAIL once ios/Sources/Auth is created without a consent marker."
fi

# ── Final verdict ──────────────────────────────────────────────────────────────
echo ""
if [[ "$GATE_FAILED" -eq 0 ]]; then
    ok "=== PRIVACY GATE PASSED ==="
    ok "    No raw-audio persistence paths found in ${SCAN_DIRS[*]}"
    ok "    FR-022 (process-don't-store) is structurally enforced."
    exit 0
else
    fail "=== PRIVACY GATE FAILED ==="
    fail "    $TOTAL_MATCHES raw-audio persistence match(es) found."
    fail "    Fix: route audio through in-memory buffers only — do NOT write PCM to disk,"
    fail "    databases, telemetry, or any persistent sink (FR-022 / COPPA)."
    fail "    If a match is a legitimate false positive, add the file path glob to the"
    fail "    PRIVACY_ALLOWLIST array at the top of scripts/check-no-raw-audio.sh with"
    fail "    an inline comment explaining the FR-022 exception rationale, then open a PR."
    exit 1
fi
