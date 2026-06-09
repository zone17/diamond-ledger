#!/usr/bin/env bash
# accuracy.sh — SC-001 / SC-002 accuracy runner (T042 / #65 Story A8).
#
# Authority: evals/INTERFACE.md §2.4 + §3.4 (advisory-until-gold semantics) · evals/gold/BUILD.md.
#
# Measures the system's output against a GOLD game (a fully-coupled audio + hand-scored
# Reisner + independently-produced cwevent-clean Retrosheet triple, INTERFACE.md §2):
#   - SC-001: play-type accuracy   ≥ 90%
#   - SC-002: Reisner token accuracy ≥ 85%
#
# EPISTEMIC BOUNDARY (INTERFACE.md §3.4 — load-bearing):
#   This runner is ADVISORY until a real gold game exists with `meta.json.h3_ready == true`
#   (Squad C, handoff H3). Before then it can only measure SELF-CONSISTENCY (does the system
#   agree with itself across runs), NOT field accuracy (does it agree with a trained human).
#   Self-consistency at 98% is meaningless if the classifier is systematically wrong, so in
#   self-consistency mode it MUST label every number "(self-consistency, advisory)" and
#   EXIT 0 regardless of the values. Only with h3_ready does it hard-fail below the bars.
#
# Usage:
#   accuracy.sh [<gold-game-dir>]
#
#   <gold-game-dir>  a dir under evals/gold/. If omitted, the first evals/gold/<game>/ with
#                    a meta.json is auto-discovered. If none exists, SELF-CONSISTENCY mode.
#
# Exit codes:
#   0  Advisory (self-consistency) mode — ALWAYS, OR field-accuracy mode with SC-001/SC-002 met.
#   1  Field-accuracy mode (h3_ready) AND SC-001 < 90% or SC-002 < 85%.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
info() { echo "${GREEN}[accuracy]${NC} $*"; }
warn() { echo "${YELLOW}[accuracy] WARN${NC} $*"; }
fail() { echo "${RED}[accuracy] FAIL${NC} $*" >&2; }

echo "Accuracy runner (SC-001 ≥90% play-type / SC-002 ≥85% Reisner token)"
echo "==================================================================="

GOLD_ROOT="${REPO_ROOT}/evals/gold"

# ── Resolve the gold-game dir ─────────────────────────────────────────────────
GOLD_DIR="${1:-}"
if [[ -z "${GOLD_DIR}" ]]; then
    # Auto-discover the first gold game dir that has a meta.json.
    while IFS= read -r meta; do
        GOLD_DIR="$(dirname "${meta}")"
        break
    done < <(find "${GOLD_ROOT}" -mindepth 2 -maxdepth 2 -name meta.json 2>/dev/null | sort)
fi

# ── No gold game at all → SELF-CONSISTENCY (advisory), exit 0 ─────────────────
if [[ -z "${GOLD_DIR}" || ! -f "${GOLD_DIR}/meta.json" ]]; then
    warn "SELF-CONSISTENCY MODE — no real gold game present. These metrics are NOT field accuracy."
    echo ""
    echo "  No evals/gold/<game>/meta.json found (H3 handoff incomplete — Squad C produces"
    echo "  the gold triple per evals/gold/BUILD.md). The accuracy runner cannot measure"
    echo "  field accuracy yet; it is advisory and NON-BLOCKING (INTERFACE.md §3.4)."
    echo ""
    echo "  | Metric | Value | Mode |"
    echo "  |--------|-------|------|"
    echo "  | SC-001 play-type accuracy   | n/a (no gold) | (self-consistency, advisory) |"
    echo "  | SC-002 Reisner token accuracy | n/a (no gold) | (self-consistency, advisory) |"
    echo ""
    info "Accuracy runner: ADVISORY (self-consistency) — exit 0 (non-blocking until H3)."
    exit 0
fi

# ── Read h3_ready from meta.json ──────────────────────────────────────────────
GAME_ID="$(grep -oE '"game_id"[[:space:]]*:[[:space:]]*"[^"]*"' "${GOLD_DIR}/meta.json" | head -1 | sed -E 's/.*"game_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
REISNER_SCORER="$(grep -oE '"reisner"[[:space:]]*:[[:space:]]*"[^"]*"' "${GOLD_DIR}/meta.json" | head -1 | sed -E 's/.*"reisner"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
# h3_ready: true|false (tolerant of whitespace)
H3_READY="$(grep -oE '"h3_ready"[[:space:]]*:[[:space:]]*(true|false)' "${GOLD_DIR}/meta.json" | head -1 | grep -oE '(true|false)' || echo false)"

info "Gold dir: ${GOLD_DIR}"
info "Gold game: ${GAME_ID:-unknown}   h3_ready: ${H3_READY}"

if [[ "${H3_READY}" != "true" ]]; then
    # Gold dir exists but is not H3-ready → still SELF-CONSISTENCY (advisory).
    warn "SELF-CONSISTENCY MODE — gold game present but h3_ready=false. These metrics are NOT field accuracy."
    echo ""
    echo "  | Metric | Value | Mode |"
    echo "  |--------|-------|------|"
    echo "  | SC-001 play-type accuracy   | pending h3_ready | (self-consistency, advisory) |"
    echo "  | SC-002 Reisner token accuracy | pending h3_ready | (self-consistency, advisory) |"
    echo ""
    info "Accuracy runner: ADVISORY (self-consistency) — exit 0 (non-blocking until h3_ready)."
    exit 0
fi

# ── FIELD ACCURACY MODE (h3_ready) ────────────────────────────────────────────
# A real gold game is present and independently produced. Measure SC-001/SC-002 against
# the hand-scored ground truth and HARD-FAIL below the bars.
#
# The end-to-end speak→score pipeline (audio → ASR → parse → core) lives in the iOS/adapter
# layer (Squad B), which is not invokable from this shell harness yet. So this branch is
# WIRED for the contract (mode label + hard-fail thresholds) and will call the pipeline
# scorer once it is exposed as a CLI. Until that exists, fail LOUD rather than silently
# pass a field-accuracy gate we cannot actually compute.
echo ""
info "FIELD ACCURACY MODE — gold game: ${GAME_ID}, scorer: ${REISNER_SCORER}"

SCORER_BIN="${DL_PIPELINE_SCORER:-}"
if [[ -z "${SCORER_BIN}" || ! -x "${SCORER_BIN}" ]]; then
    fail "FIELD ACCURACY MODE requires the end-to-end pipeline scorer."
    fail ""
    fail "The headless TRANSCRIPT→score scorer now exists (DL-37 / ADR-0015): the \`dl-score\`"
    fail "CLI (transcript → GrammarParser → real core → JSON). Build + point at it with:"
    fail "    (cd ios && swift build --product dl-score)"
    fail "    export DL_PIPELINE_SCORER=\"\$(cd ios && swift build --product dl-score --show-bin-path)/dl-score\""
    fail "Feed the gold game's \`audio/narration.txt\` transcript fallback to it and diff the"
    fail "play_type / reisner_catalyst against reisner/scorecard.json (SC-001/SC-002)."
    fail ""
    fail "The AUDIO→transcript (ASR) leg stays device/sim-bound (DiamondSpeech, iOS-26). For the"
    fail "deterministic transcript→score path, a headless regression gate runs TODAY:"
    fail "    bash evals/runners/transcript-score.sh   (evals/transcript-regression/cases.jsonl)"
    fail ""
    fail "Refusing to emit a field-accuracy PASS without actually measuring it (INTERFACE.md §3.4)."
    exit 1
fi

# (Future) invoke the scorer, compute SC-001/SC-002 vs reisner/scorecard.json, hard-fail
# below 90%/85%, label every row "(field accuracy)". Placeholder hard-fail above guards the
# epistemic boundary until the scorer exists.
fail "Field-accuracy scoring path not yet implemented end-to-end; see the handoff above."
exit 1
