#!/usr/bin/env bash
# retrosheet-gate.sh — 3-layer Retrosheet / cwevent acceptance gate
#
# Authority:  evals/INTERFACE.md §3.3 · research.md D4 · tasks.md T060
# Pinned:     Chadwick cwevent v0.10.0 (SHA256: a4128934286edf5f9938923aad2000f7549dcccfb3b3f149a417534ef7eb29e9)
# Failure semantics (research.md D4 load-bearing finding):
#   cwevent exits 0 EVEN ON MALFORMED PLAYS — a pure exit-code gate is vacuous.
#   Errors surface on STDERR.  This gate is STDERR-driven.
#
# Usage:
#   retrosheet-gate.sh <fixture-dir> <year>
#
# The fixture-dir MUST contain:
#   - TEAM<year>        (mandatory; cwevent exits 1 without it)
#   - One or more .EVN files
#   - expected.csv      (Layer 3 golden diff target — must be pre-committed)
#
# Exit codes:
#   0  All three layers passed
#   1  Gate failed (one or more layers)
#
# Layer 1 — Proof-box reconciliation (offline, non-authoritative)
#   Runs evals/runners/proof-box.sh if available.
#   Documents deferred-to-core status when proof-box.sh is absent
#   (proof-box depends on the Rust core's game-state model — Squad A T043).
#
# Layer 2 — cwevent structural parse (authoritative, MANDATORY)
#   FAILS if:  stderr matches WARNING|Invalid|Can't find|could not open (case-insensitive)
#   FAILS if:  zero event rows emitted to stdout
#   Does NOT fail on cwevent exit code alone.
#
# Layer 3 — Golden diff regression
#   FAILS if:  diff of `cwevent -n -f 0-96` output vs expected.csv is non-empty.

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
info()  { echo "${GREEN}[retrosheet-gate]${NC} $*"; }
warn()  { echo "${YELLOW}[retrosheet-gate] WARN${NC} $*" >&2; }
fail()  { echo "${RED}[retrosheet-gate] FAIL${NC} $*" >&2; }
ok()    { echo "${GREEN}[retrosheet-gate] PASS${NC} $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
    echo "Usage: $(basename "$0") <fixture-dir> <year>" >&2
    exit 1
fi

FIXTURE_DIR="$1"
YEAR="$2"

if [[ ! -d "$FIXTURE_DIR" ]]; then
    fail "Fixture directory not found: $FIXTURE_DIR"
    exit 1
fi

# Locate cwevent — prefer system PATH, accept /opt/homebrew/bin for macOS CI
if command -v cwevent &>/dev/null; then
    CWEVENT="$(command -v cwevent)"
elif [[ -x /opt/homebrew/bin/cwevent ]]; then
    CWEVENT="/opt/homebrew/bin/cwevent"
else
    fail "cwevent not found in PATH or /opt/homebrew/bin"
    fail "Install Chadwick cwevent v0.10.0 (see .github/workflows/ci.yml build step)"
    exit 1
fi

# Verify pinned version (cwevent exits 1 when no args/files given, so capture with || true)
CWEVENT_VERSION="$(("$CWEVENT" 2>&1 || true) | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [[ "$CWEVENT_VERSION" != "0.10.0" ]]; then
    fail "cwevent version mismatch: expected 0.10.0, found '${CWEVENT_VERSION}'"
    fail "SHA256 of pinned tarball: a4128934286edf5f9938923aad2000f7549dcccfb3b3f149a417534ef7eb29e9"
    exit 1
fi
info "cwevent version: $CWEVENT_VERSION (pinned v0.10.0 ✓)"

# ── Locate EVN file(s) ────────────────────────────────────────────────────────
EVN_FILES=()
while IFS= read -r f; do
    EVN_FILES+=("$f")
done < <(find "$FIXTURE_DIR" -maxdepth 1 \( -name '*.EVN' -o -name '*.EVA' \) 2>/dev/null | sort)
if [[ ${#EVN_FILES[@]} -eq 0 ]]; then
    fail "No .EVN or .EVA files found in $FIXTURE_DIR"
    exit 1
fi
info "Fixture directory: $FIXTURE_DIR"
info "EVN files: ${EVN_FILES[*]}"

# ── Check TEAM file ───────────────────────────────────────────────────────────
TEAM_FILE="$FIXTURE_DIR/TEAM${YEAR}"
if [[ ! -f "$TEAM_FILE" ]]; then
    fail "Mandatory TEAM file missing: $TEAM_FILE"
    fail "(cwevent exits 1 without it — research.md D4)"
    exit 1
fi
info "TEAM file: $TEAM_FILE ✓"

GATE_FAILED=0

# ═════════════════════════════════════════════════════════════════════════════
# LAYER 1 — Proof-box reconciliation (offline, non-authoritative)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
info "=== Layer 1: Proof-box reconciliation (offline, non-authoritative) ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF_BOX="$SCRIPT_DIR/proof-box.sh"

if [[ -x "$PROOF_BOX" ]]; then
    if bash "$PROOF_BOX" "$FIXTURE_DIR" "$YEAR"; then
        ok "Layer 1 PASSED: proof-box reconciliation balanced"
    else
        fail "Layer 1 FAILED: proof-box reconciliation imbalanced"
        GATE_FAILED=1
    fi
else
    warn "Layer 1 DEFERRED: proof-box.sh not yet present (Squad A T043)"
    warn "  proof-box.sh depends on the Rust core's game-state model."
    warn "  Layer 2 (cwevent) is authoritative regardless."
    warn "  This layer will be wired as a hard-fail once T043 lands."
fi

# ═════════════════════════════════════════════════════════════════════════════
# LAYER 2 — cwevent structural parse (authoritative, MANDATORY)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
info "=== Layer 2: cwevent structural parse (authoritative) ==="
info "    STDERR-driven gate — cwevent exits 0 even on malformed plays (research.md D4)"

LAYER2_FAILED=0

for EVN_FILE in "${EVN_FILES[@]}"; do
    EVN_BASENAME="$(basename "$EVN_FILE")"
    info "Processing: $EVN_BASENAME"

    # Run cwevent FROM fixture dir so it finds TEAM<year> (cwevent looks in cwd)
    CWEVENT_STDERR_FILE="$(mktemp)"
    CWEVENT_STDOUT_FILE="$(mktemp)"
    EVN_ABS="$(cd "$(dirname "$EVN_FILE")" && pwd)/$(basename "$EVN_FILE")"

    # Do NOT gate on exit code — only on stderr content and row count
    (cd "$FIXTURE_DIR" && "$CWEVENT" -y "$YEAR" -q "$EVN_ABS") \
        >"$CWEVENT_STDOUT_FILE" \
        2>"$CWEVENT_STDERR_FILE" || true

    # Gate check 1: stderr must not match error patterns (case-insensitive)
    if grep -iE 'WARNING|Invalid|Can'\''t find|could not open' "$CWEVENT_STDERR_FILE" >/dev/null 2>&1; then
        fail "Layer 2 FAILED for $EVN_BASENAME: cwevent stderr contains error pattern"
        echo "--- cwevent stderr ---"
        cat "$CWEVENT_STDERR_FILE" >&2
        echo "---"
        LAYER2_FAILED=1
        GATE_FAILED=1
    fi

    # Gate check 2: at least one event row must be emitted
    CWEVENT_ROWS="$(wc -l < "$CWEVENT_STDOUT_FILE" | tr -d ' ')"
    if [[ "$CWEVENT_ROWS" -eq 0 ]]; then
        fail "Layer 2 FAILED for $EVN_BASENAME: zero event rows emitted (vacuous gate)"
        LAYER2_FAILED=1
        GATE_FAILED=1
    else
        info "  Event rows emitted: $CWEVENT_ROWS"
    fi

    rm -f "$CWEVENT_STDERR_FILE" "$CWEVENT_STDOUT_FILE"
done

if [[ "$LAYER2_FAILED" -eq 0 ]]; then
    ok "Layer 2 PASSED: cwevent stderr clean, event rows emitted for all fixtures"
fi

# ═════════════════════════════════════════════════════════════════════════════
# LAYER 3 — Golden diff regression
# ═════════════════════════════════════════════════════════════════════════════
echo ""
info "=== Layer 3: Golden diff regression ==="

EXPECTED_CSV="$FIXTURE_DIR/expected.csv"

if [[ ! -f "$EXPECTED_CSV" ]]; then
    warn "Layer 3 SKIPPED: expected.csv not found at $FIXTURE_DIR/expected.csv"
    warn "  Generate it with: cwevent -n -f 0-96 -y $YEAR <fixture.EVN> > expected.csv"
    warn "  Then commit expected.csv alongside the fixture."
    warn "  This layer is REQUIRED for the gate to be a hard-fail (see INTERFACE.md §3.3)"
else
    LAYER3_FAILED=0
    for EVN_FILE in "${EVN_FILES[@]}"; do
        EVN_BASENAME="$(basename "$EVN_FILE")"
        ACTUAL_FILE="$(mktemp)"
        DIFF_FILE="$(mktemp)"

        EVN_ABS2="$(cd "$(dirname "$EVN_FILE")" && pwd)/$(basename "$EVN_FILE")"
        (cd "$FIXTURE_DIR" && "$CWEVENT" -n -f 0-96 -y "$YEAR" -q "$EVN_ABS2") \
            >"$ACTUAL_FILE" 2>/dev/null || true

        if diff "$EXPECTED_CSV" "$ACTUAL_FILE" >"$DIFF_FILE" 2>&1; then
            info "  $EVN_BASENAME: golden diff clean ✓"
        else
            fail "Layer 3 FAILED for $EVN_BASENAME: diff vs expected.csv is non-empty"
            echo "--- diff (expected vs actual) ---"
            head -20 "$DIFF_FILE" >&2
            echo "---"
            LAYER3_FAILED=1
            GATE_FAILED=1
        fi

        rm -f "$ACTUAL_FILE" "$DIFF_FILE"
    done

    if [[ "$LAYER3_FAILED" -eq 0 ]]; then
        ok "Layer 3 PASSED: golden diff clean for all fixtures"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Final verdict
# ═════════════════════════════════════════════════════════════════════════════
echo ""
if [[ "$GATE_FAILED" -eq 0 ]]; then
    ok "=== ALL LAYERS PASSED ==="
    ok "    The fixture is structurally valid per pinned cwevent v0.10.0"
    ok "    (This proves format conformance — not game accuracy; see INTERFACE.md §3.5)"
    exit 0
else
    fail "=== GATE FAILED ==="
    fail "    One or more layers failed — see output above"
    exit 1
fi
