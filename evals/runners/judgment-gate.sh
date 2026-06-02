#!/usr/bin/env bash
# judgment-gate.sh — SC-003 hard-fail gate (T041)
#
# Loads evals/judgment-corpus/seed.jsonl (per evals/INTERFACE.md), feeds each entry
# through classify() via a Rust test harness, and HARD-FAILS (exit 1) on:
#   1. Any corpus entry classified as Deterministic or OutOfFormat.
#   2. silent_resolution_counter > 0.
#   3. Not all four trigger types (HitVsError, EarnedVsUnearned, ContestedCredit,
#      AmbiguousAdvance) are represented in the corpus.
#   4. Corpus file absent or empty.
#
# Usage: bash evals/runners/judgment-gate.sh [corpus.jsonl]
#
# Authority: evals/INTERFACE.md §3.2 — hard-fail semantics.
# This is Squad A's eval runner; Squad C produces the real corpus.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Default corpus.
CORPUS="${1:-${REPO_ROOT}/evals/judgment-corpus/seed.jsonl}"

echo "SC-003 Judgment Gate"
echo "===================="
echo "Corpus: ${CORPUS}"
echo ""

# ── Gate 4: corpus must exist and be non-empty ──────────────────────────────
if [[ ! -f "${CORPUS}" ]]; then
    echo "HARD-FAIL: Corpus file not found: ${CORPUS}"
    exit 1
fi

LINE_COUNT=$(wc -l < "${CORPUS}" | tr -d ' ')
if [[ "${LINE_COUNT}" -eq 0 ]]; then
    echo "HARD-FAIL: Corpus is empty (zero entries). A zero-size corpus is vacuous."
    exit 1
fi
echo "Corpus entries: ${LINE_COUNT}"

# ── Run the Rust judgment-gate test harness ─────────────────────────────────
# We invoke the dedicated integration test that reads the corpus and runs classify()
# on each entry. The test binary hard-fails (exit 1) on any violation.
cd "${REPO_ROOT}"
source "$HOME/.cargo/env" 2>/dev/null || true

echo ""
echo "Running classify() against corpus via cargo test..."
CORPUS_PATH="${CORPUS}" cargo test --package dl-core judgment_gate_runner --no-fail-fast 2>&1
TEST_EXIT=$?

if [[ "${TEST_EXIT}" -ne 0 ]]; then
    echo ""
    echo "HARD-FAIL: Judgment gate FAILED (exit ${TEST_EXIT})"
    echo "See above for misclassified entries or silent-resolution violations."
    exit 1
fi

echo ""
echo "PASS: All corpus entries classified as Judgment variants."
echo "PASS: silent_resolution_counter == 0."
echo "PASS: All four trigger types present."
echo ""
echo "SC-003 Judgment Gate: GREEN"
exit 0
