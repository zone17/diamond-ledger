#!/usr/bin/env bash
# proof-box.sh — Layer-1 offline proof-box self-check (T043 / #71 Story A9).
#
# Authority: evals/INTERFACE.md §3.3 Layer 1 · spec SC-011 · FR-005a.
#
# Verifies the Reisner half-inning accounting identity on the deterministic core's
# OWN projection (offline, fast, non-authoritative):
#
#     AB + BB + Sac + HBP + Interference == Runs + Putouts + LOB(stranded)
#
# Every plate appearance is charged to exactly one LEFT term and resolves to exactly one
# RIGHT term (scored / retired / left on base), so the identity is a closed accounting
# invariant. Any imbalance is a projection bug → HARD-FAIL (exit 1).
#
# This is Layer 1 of the 3-layer Retrosheet gate (INTERFACE.md §3.3). It feeds Squad C's
# gate: retrosheet-gate.sh calls this as its Layer 1. It does NOT validate Retrosheet
# structure — that is Layer 2 (cwevent). A passing proof box does NOT prove a valid .EVN.
#
# Usage:
#   proof-box.sh [<fixture-dir>] [<year>]
#
#   Both args are OPTIONAL and currently IGNORED — this check exercises the Rust core's
#   game-state model directly via a cargo integration test, not the .EVN fixtures. The
#   positional args exist so retrosheet-gate.sh can call `proof-box.sh <dir> <year>`
#   uniformly (a future revision may cross-check a fixture's box against the core).
#
# Exit codes:
#   0  All projected half-innings balance.
#   1  Any imbalance (SC-011), or the core test harness failed to run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
info() { echo "${GREEN}[proof-box]${NC} $*"; }
fail() { echo "${RED}[proof-box] FAIL${NC} $*" >&2; }

echo "Proof-box Layer-1 gate (offline, non-authoritative)"
echo "==================================================="
echo "Identity: AB + BB + Sac + HBP + Interference = Runs + Putouts + LOB  (SC-011)"
echo ""

cd "${REPO_ROOT}"
# shellcheck disable=SC1091
source "$HOME/.cargo/env" 2>/dev/null || true

info "Running the proof-box invariant over the core's projection (cargo test)..."
if cargo test --package dl-core --test proof_box_gate -- --nocapture; then
    echo ""
    info "PASS: every projected half-inning balances (AB+BB+Sac+HBP+INT == R+PO+LOB)."
    echo "Proof-box Layer-1 gate: GREEN"
    exit 0
else
    echo ""
    fail "Proof-box imbalance detected (SC-011) — see the failing assertion above."
    fail "A half-inning where AB+BB+Sac+HBP+INT != R+PO+LOB is a projection bug."
    exit 1
fi
