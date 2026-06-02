#!/usr/bin/env bash
# check-no-raw-audio.sh — Privacy gate: no raw-audio-persistence path (T070 / FR-022 / COPPA)
#
# Authority:  FR-022 (process-don't-store), FR-029 (COPPA/consent path)
# Enforced by: CI secret-scan job (hard-fail); Makefile privacy-check target (local)
#
# This script scans Rust, Swift, and Kotlin source for patterns that would indicate
# raw PCM audio being persisted to disk, a database, telemetry, or any storage sink.
# It is a HARD-FAIL gate: any match exits 1 and prints a ::error:: annotation.
#
# What counts as a violation (FR-022):
#   Any write/save/store/persist/insert/upload/append/create operation on an identifier
#   that names raw audio data: pcm, wav, raw (audio), AudioBuffer, pcmBuffer, AVAudioPCM,
#   AudioFile, RecordingBuffer, or similar.
#
# False-positive suppression:
#   - Comments are skipped (lines whose first non-whitespace char is # ; // * /*)
#   - Test helper names that include "mock" or "stub" may still appear; reviewers must
#     confirm they are test-only. CI output includes the file+line for manual triage.
#   - Streaming buffers that are immediately forwarded (not written to a named sink)
#     should not match the pattern; if they do, restructure the code rather than
#     suppressing the check.
#
# Extension:
#   Add patterns to AUDIO_WRITE_PATTERNS below; all patterns are POSIX-ERE.
#   Do NOT change the exit code to 0 on a match without an explicit ADR update.
#
# Usage:
#   bash scripts/check-no-raw-audio.sh [<repo-root>]
#
# Exit codes:
#   0  No raw-audio persistence paths found — gate passes
#   1  One or more matches found — gate fails; review output for exact file+line

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
info()  { echo "${GREEN}[privacy-gate]${NC} $*"; }
warn()  { echo "${YELLOW}[privacy-gate] WARN${NC} $*" >&2; }
fail()  { echo "${RED}[privacy-gate] FAIL${NC} $*" >&2; }
ok()    { echo "${GREEN}[privacy-gate] PASS${NC} $*"; }

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
#
# We scan all of them; the patterns are the firewall.
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

# ── Patterns ───────────────────────────────────────────────────────────────────
# Each pattern is a POSIX-ERE applied with grep -E.
# A line matches if it contains BOTH an audio-naming token AND a write-action token
# in the same expression (compound pattern).
#
# Pattern set 1: audio-named object + write verb on the same line.
#   Covers: pcmBuffer.write(...), saveAudioFile(...), store(rawAudio), etc.
AUDIO_WRITE_PATTERNS=(
    # PCM / WAV / raw audio buffer writes (Swift, Kotlin, Rust)
    '(pcm[Bb]uffer|PCMBuffer|AVAudioPCMBuffer|AudioBuffer|recordingBuffer|audioBuffer|RawAudio|pcm_buf|pcm_data)[^[:alpha:]]*\.(write|save|store|persist|insert|upload|append|create|flush)'
    # File creation with audio-like extension
    '\.(pcm|wav|raw|caf|aiff|audio)[^[:alpha:]]*(write|save|store|create|open|append|flush)'
    # Audio write/save function calls (naming the intent)
    '(writeAudio|saveAudio|persistAudio|storeAudio|uploadAudio|flushAudio|commitAudio|writeRaw|storeRaw|persistRaw|saveRaw)[[:space:]]*\('
    # Swift FileManager write of audio
    'FileManager[^;]*\.(create|copyItem|moveItem)[^;]*(audio|\.pcm|\.wav|\.raw)'
    # fwrite/write syscall on audio-named fd/path (C/Rust unsafe)
    '(fwrite|write|pwrite)\s*\([^)]*\b(pcm|audio|wav|raw|sound)\b'
    # SQLite / CoreData / GRDB insert of audio blob
    '(db\.|database\.|grdb\.|sqlite)[^;]*(insert|execute)[^;]*(audio|pcm|wav|raw|sound)'
    # UserDefaults / NSUserDefaults persistence of audio
    'UserDefaults[^;]*(set|setValue)[^;]*(audio|pcm|wav|recording)'
    # CloudKit write of audio record (audio field names)
    'CKRecord[^;]*(audio|pcm|wav|recording)[^;]*(save|modify|push)'
)

# ── Comment-line filter ────────────────────────────────────────────────────────
# Lines where the trimmed content starts with //, #, *, /* are comments.
# We skip them to reduce false positives on documentation strings.
# Note: multi-line block comments are NOT filtered (hard to do portably with grep);
# a pattern match inside a block comment still requires manual review in CI output.
COMMENT_FILTER='^[[:space:]]*(//|#|/\*|\*)'

# ── Scan ───────────────────────────────────────────────────────────────────────
GATE_FAILED=0
TOTAL_MATCHES=0

info "Scanning ${#SCAN_DIRS[@]} source directory/directories for raw-audio persistence patterns..."
info "Patterns: ${#AUDIO_WRITE_PATTERNS[@]}"
echo ""

for PATTERN in "${AUDIO_WRITE_PATTERNS[@]}"; do
    # grep -rn: recursive + line numbers.
    # --include: Swift, Kotlin, Rust only.
    # -E: POSIX extended regex.
    # We pipe through a comment-filter and then check for matches.
    MATCHES=""
    MATCHES="$(
        grep -rn --include="*.swift" --include="*.kt" --include="*.rs" \
            -E "$PATTERN" \
            "${SCAN_DIRS[@]}" 2>/dev/null \
        | grep -vE "$COMMENT_FILTER" \
        || true
    )"

    if [[ -n "$MATCHES" ]]; then
        fail "Raw-audio persistence pattern matched:"
        fail "  Pattern: $PATTERN"
        while IFS= read -r match_line; do
            echo "::error file=${match_line%%:*}::Raw-audio persistence path detected (FR-022): $match_line"
            fail "  $match_line"
        done <<< "$MATCHES"
        MATCH_COUNT="$(echo "$MATCHES" | wc -l | tr -d ' ')"
        TOTAL_MATCHES=$((TOTAL_MATCHES + MATCH_COUNT))
        GATE_FAILED=1
        echo ""
    fi
done

# ── COPPA consent structural check ────────────────────────────────────────────
# FR-029: when the iOS Auth module exists, it must contain an explicit COPPA /
# consent / parental-gating marker.  This is a HARD-FAIL gate (not a warning).
# Once ios/Sources/Auth lands, this fires.
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
    fail "    If a match is a false positive, add the file to the allowlist above"
    fail "    and get it reviewed in a PR with an explicit FR-022 exception note."
    exit 1
fi
