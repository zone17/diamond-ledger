#!/usr/bin/env bash
# h2-export.sh — SC-004 end-to-end Retrosheet export validation (H2 / DL-36)
#
# Authority:  FR-016 / SC-004 / I4 — cwevent v0.10.0 is the AUTHORITATIVE gate
# Research:   research.md D4 (STDERR-driven gate — cwevent exits 0 on malformed plays)
# Ticket:     DL-36 (H2 integration: prove real core export passes pinned cwevent gate)
#
# What this script does:
#   1. Runs the Rust integration test `h2_export_passes_cwevent_format_checks`
#      (core/tests/h2_export.rs) via `cargo test`. The test drives the real
#      CoreApi through a representative multi-play game (3 innings, both sides),
#      calls finalize_scorecard, and writes the resulting EVN file to:
#        evals/retrosheet-fixtures/h2/BOS2024010101.EVN
#   2. Runs the 3-layer retrosheet-gate.sh against that EVN file.
#      Layer 2 is the authoritative SC-004 check: cwevent stderr must be clean
#      and at least one event row must be emitted.
#
# Usage:
#   bash evals/runners/h2-export.sh
#   bash evals/runners/h2-export.sh --skip-build   # use last-built binary
#
# Exit codes:
#   0  All layers passed (SC-004 GREEN)
#   1  Gate failed
#   2  cwevent not available (skip-with-note — does not break CI)
#
# CI usage (.github/workflows/ci.yml):
#   This script is wired as an ADVISORY job only (guard: `command -v cwevent`).
#   It does NOT make the CI pipeline hard-fail when cwevent is not installed.
#   The intent: anyone with Chadwick installed locally can run this script and
#   get the full proof; CI enforces the gate when cwevent is available.

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
info()  { echo "${GREEN}[h2-export]${NC} $*"; }
warn()  { echo "${YELLOW}[h2-export] WARN${NC} $*" >&2; }
fail()  { echo "${RED}[h2-export] FAIL${NC} $*" >&2; }
ok()    { echo "${GREEN}[h2-export] PASS${NC} $*"; }

# ── Locate repo root (works from any cwd) ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Check prerequisites ───────────────────────────────────────────────────────

# cwevent availability — skip-with-note if not installed (advisory-only in CI).
if ! command -v cwevent &>/dev/null && ! [[ -x /opt/homebrew/bin/cwevent ]]; then
    warn "cwevent not found — skipping SC-004 gate (install Chadwick v0.10.0 to run locally)"
    warn "See .github/workflows/ci.yml for the advisory CI job."
    exit 2
fi

# cargo / rustup
if ! command -v cargo &>/dev/null; then
    if [[ -x "$HOME/.cargo/bin/cargo" ]]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    else
        fail "cargo not found — install Rust toolchain"
        exit 1
    fi
fi

# Pinned cwevent version check.
CWEVENT_BIN="$(command -v cwevent 2>/dev/null || echo /opt/homebrew/bin/cwevent)"
CWEVENT_VER="$(("$CWEVENT_BIN" 2>&1 || true) | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [[ "$CWEVENT_VER" != "0.10.0" ]]; then
    fail "cwevent version mismatch: expected 0.10.0, found '${CWEVENT_VER}'"
    exit 1
fi
info "cwevent version: $CWEVENT_VER (pinned v0.10.0 ✓)"

# ── Step 1: Run the Rust integration test ────────────────────────────────────
info "=== Step 1: Build game through CoreApi + serialize EVN (cargo test) ==="

SKIP_BUILD=0
if [[ "${1:-}" == "--skip-build" ]]; then
    SKIP_BUILD=1
    info "  (--skip-build: skipping cargo test, using last-built EVN)"
fi

FIXTURE_DIR="$REPO_ROOT/evals/retrosheet-fixtures/h2"
EVN_FILE="$FIXTURE_DIR/BOS2024010101.EVN"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    info "  Running: cargo test --test h2_export h2_export_passes_cwevent_format_checks"
    (
        cd "$REPO_ROOT"
        cargo test --test h2_export h2_export_passes_cwevent_format_checks \
            2>&1 | grep -v "^   Compiling\|^    Checking\|^    Finished\|^     Running"
    )
    ok "Step 1 PASSED: CoreApi game built, EVN written to $EVN_FILE"
else
    if [[ ! -f "$EVN_FILE" ]]; then
        fail "EVN not found at $EVN_FILE — run without --skip-build to generate it"
        exit 1
    fi
    info "  Reusing existing EVN: $EVN_FILE"
fi

if [[ ! -f "$EVN_FILE" ]]; then
    fail "EVN file not found after cargo test: $EVN_FILE"
    exit 1
fi

# ── Step 2: Run the 3-layer cwevent gate ─────────────────────────────────────
echo ""
info "=== Step 2: 3-layer retrosheet gate (retrosheet-gate.sh) ==="

GATE_SCRIPT="$SCRIPT_DIR/retrosheet-gate.sh"
if [[ ! -x "$GATE_SCRIPT" ]]; then
    fail "retrosheet-gate.sh not found or not executable: $GATE_SCRIPT"
    exit 1
fi

if bash "$GATE_SCRIPT" "$FIXTURE_DIR" "2024"; then
    echo ""
    ok "=== SC-004 GREEN: real core export passes pinned cwevent v0.10.0 gate ==="
    ok "    Fixture: $EVN_FILE"
    ok "    All 3 layers passed (proof-box, cwevent stderr, golden diff)"
    exit 0
else
    echo ""
    fail "=== SC-004 FAILED: gate rejected the core's export ==="
    fail "    See above for which layer failed."
    exit 1
fi
