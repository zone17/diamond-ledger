#!/usr/bin/env bash
# voice-accuracy.sh — voice-accuracy harness: mis-heard-transcript robustness gate (DL-157).
#
# One command answers, reproducibly and with an honest label: "does the deterministic pipeline
# ever score a plausibly mis-heard transcript as a WRONG play silently, for text-detectable
# mis-hearings?" (Article VII / FR-008). It runs the headless `dl-score` CLI (transcript →
# GrammarParser → real Rust core) over the canonical transcript corpus PLUS a corpus of
# text-level variants of those transcripts (mis-hearings, numerals, fillers, roster names, roster
# collisions), and the headless `dl-bias` CLI over a corpus of (base, biased) ASR hypothesis
# pairs, then judges the raw output with evals/runners/voice-accuracy-compare.py.
#
# The ONLY hard signal is a CONFIDENT-WRONG row: a variant that at confidence 100 scores
# (`ok`, `needs` ∈ {none, confirm}) with facts that differ from its base's, or that surfaces a
# judgment its base does not (or a different judgment kind). A variant the pipeline refuses to
# score — clarify (`ambiguous(…)`), out-of-grammar, or the base's own judgment kind — is a SAFE
# MISS: counted and reported, advisory. Everything else it prints is FIXTURE ROBUSTNESS
# (advisory — not field accuracy): the corpus is synthetic text, not field audio, and no ASR leg
# runs here (SpeechAnalyzer is iOS-26 device-bound; the WER hook in the comparator is a no-op).
#
# Shape copied from transcript-score.sh (KTD5): scratch dir; the CLIs' output reaches the
# comparator as FILES on argv, never interpolated into source; `cmd || RC=$?` so the banner
# survives `set -e`; exit 2 on zero work; Darwin hard-fails on a missing toolchain; non-Darwin
# prints a distinct SKIP marker and exits 0.
#
# What it runs (KTD1: `--roster` is per dl-score process):
#   - canonical rows (TRANSCRIPT_CASES) + roster-less variants: one dl-score batch per
#     confidence (100 and 60), no --roster;
#   - variants that carry a roster: one dl-score batch per (exact roster value, confidence);
#   - biasing pairs: one dl-bias invocation;
#   - the whole measurement TWICE, byte-diffing the raw outputs (R6: non-determinism fails).
#   Base facts come from the canonical row scored at 100 in the no-roster batch.
#
# Exit codes:
#   0  PASS — no confident-wrong row, no canonical regression against TRANSCRIPT_CASES
#      expectations, no biasing-pair mismatch, byte-identical output across the two runs.
#      ALSO 0 on non-Darwin, where the CLIs cannot build: a distinct SKIP marker is printed.
#   1  FAIL — any of the above tripped; or the corpus violates its schema; or (Darwin) the
#      toolchain is missing.
#   2  NO WORK — zero variants, zero pairs, or a missing corpus file: a run that measured
#      nothing is never green.
#
# Usage:  bash evals/runners/voice-accuracy.sh            (or: make voice-accuracy-gate)
#   VOICE_ACCURACY_DIR   corpus dir holding variants.jsonl + biasing-pairs.jsonl
#                        (default evals/voice-accuracy)
#   TRANSCRIPT_CASES     canonical corpus (default evals/transcript-regression/cases.jsonl)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CORPUS_DIR="${VOICE_ACCURACY_DIR:-${REPO_ROOT}/evals/voice-accuracy}"
CASES="${TRANSCRIPT_CASES:-${REPO_ROOT}/evals/transcript-regression/cases.jsonl}"
VARIANTS="${CORPUS_DIR}/variants.jsonl"
PAIRS="${CORPUS_DIR}/biasing-pairs.jsonl"
COMPARE="${SCRIPT_DIR}/voice-accuracy-compare.py"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
info() { echo "${GREEN}[voice-accuracy]${NC} $*"; }
warn() { echo "${YELLOW}[voice-accuracy] SKIP${NC} $*"; }
fail() { echo "${RED}[voice-accuracy] FAIL${NC} $*" >&2; }
nowork() { echo "${RED}[voice-accuracy] NO WORK${NC} $*" >&2; }

echo "Voice-accuracy harness (DL-157 / dl-score + dl-bias)"
echo "====================================================="

[[ -f "${COMPARE}" ]] || { fail "comparator not found: ${COMPARE}"; exit 1; }
[[ -f "${CASES}" ]] || { nowork "canonical corpus not found: ${CASES}"; exit 2; }
[[ -f "${VARIANTS}" ]] || { nowork "variants corpus not found: ${VARIANTS} (set VOICE_ACCURACY_DIR)"; exit 2; }
[[ -f "${PAIRS}" ]] || { nowork "biasing-pairs corpus not found: ${PAIRS} (set VOICE_ACCURACY_DIR)"; exit 2; }

# ── Toolchain guard ───────────────────────────────────────────────────────────────────────────
# SKIP (advisory, exit 0) ONLY on non-Darwin, where the dl-score CLI genuinely cannot build
# (Linux can't link the macOS slice). On Darwin — the canonical CI runner + dev box — a MISSING
# toolchain is a HARD FAIL, not a skip: a "hard gate" that silently exits 0 because swift/cargo
# vanished is exactly the vacuous-green failure this gate exists to prevent. (Review: SKIP==PASS.)
if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "not macOS — the dl-score/dl-bias CLIs need the macOS toolchain to build. (Linux CI: advisory skip.)"
    exit 0
fi
command -v swift >/dev/null 2>&1 || { fail "swift not found on macOS — Xcode required for this gate."; exit 1; }
command -v cargo >/dev/null 2>&1 || { fail "cargo not found on macOS — rustup required for this gate."; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 not found — required for the comparator."; exit 1; }

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# ── Ensure the core XCFramework (with the macOS slice) exists ──────────────────────────────────
XCF="${REPO_ROOT}/ios/Generated/DiamondLedgerCore.xcframework"
if [[ ! -d "${XCF}/macos-arm64_x86_64" ]]; then
    info "Building core XCFramework (macOS slice needed)…"
    bash "${REPO_ROOT}/scripts/build-xcframework.sh" >/dev/null
fi

# ── Build dl-score + dl-bias (macOS) ──────────────────────────────────────────────────────────
info "Building dl-score and dl-bias…"
( cd "${REPO_ROOT}/ios" && swift build --product dl-score >/dev/null && swift build --product dl-bias >/dev/null )
BIN_DIR="$(cd "${REPO_ROOT}/ios" && swift build --product dl-score --show-bin-path)"
SCORE_BIN="${BIN_DIR}/dl-score"
BIAS_BIN="${BIN_DIR}/dl-bias"
[[ -x "${SCORE_BIN}" ]] || { nowork "dl-score binary not produced at ${SCORE_BIN}"; exit 2; }
[[ -x "${BIAS_BIN}" ]]  || { nowork "dl-bias binary not produced at ${BIAS_BIN}"; exit 2; }

# ── Stage the batches ─────────────────────────────────────────────────────────────────────────
# Robustness (review): corpora and CLI output are passed to the comparator as FILE PATHS (argv),
# never interpolated into Python source. A transcript containing a quote or backslash must FAIL
# a row loudly, not corrupt the comparator. The scratch dir holds every staged file.
# VOICE_ACCURACY_SCRATCH (optional): a caller-owned directory to stage into and KEEP — the
# tripwire uses it to tamper with the raw outputs and re-judge them (fixtures 7/8).
if [[ -n "${VOICE_ACCURACY_SCRATCH:-}" ]]; then
  SCRATCH="${VOICE_ACCURACY_SCRATCH}"; mkdir -p "${SCRATCH}"
else
  SCRATCH="$(mktemp -d)"
  trap 'rm -rf "${SCRATCH}"' EXIT
fi

RC=0
python3 "${COMPARE}" stage --cases "${CASES}" --variants "${VARIANTS}" --pairs "${PAIRS}" \
    --out "${SCRATCH}/run1" || RC=$?
if [[ ${RC} -ne 0 ]]; then
    fail "corpus could not be staged (rc=${RC}) — see the schema errors above."
    exit 1
fi
# Identical staging for the second run (R6): same inputs, fresh outputs.
cp -R "${SCRATCH}/run1" "${SCRATCH}/run2"

N_VARIANTS="$(grep -c . "${VARIANTS}" || true)"
N_PAIRS="$(grep -c . "${PAIRS}" || true)"
if [[ "${N_VARIANTS}" -eq 0 || "${N_PAIRS}" -eq 0 ]]; then
    # The comparator prints the labeled NO WORK verdict; the exit code is what matters here.
    python3 "${COMPARE}" compare --cases "${CASES}" --variants "${VARIANTS}" --pairs "${PAIRS}" \
        --run "${SCRATCH}/run1" || RC=$?
    nowork "zero variants (${N_VARIANTS}) or zero pairs (${N_PAIRS}) — nothing was measured (rc=${RC})."
    exit 2
fi

# ── Run dl-score per batch and dl-bias over the pairs, twice ──────────────────────────────────
# One dl-score process per (roster group, confidence): `--roster` is a per-process flag (KTD1).
# Roster and confidence come from the staged files, never from string-munged JSON in bash.
run_once() { # $1 = run dir
    local run="$1" d conf roster
    for d in "${run}"/batches/*/; do
        conf="$(cat "${d}/confidence.txt")"
        if [[ -f "${d}/roster.txt" ]]; then
            roster="$(cat "${d}/roster.txt")"
            "${SCORE_BIN}" --confidence "${conf}" --roster "${roster}" "${d}/input.txt" > "${d}/out.jsonl"
        else
            "${SCORE_BIN}" --confidence "${conf}" "${d}/input.txt" > "${d}/out.jsonl"
        fi
    done
    "${BIAS_BIN}" "${run}/pairs/input.jsonl" > "${run}/pairs/out.jsonl"
}

N_BATCHES="$(ls -d "${SCRATCH}"/run1/batches/*/ | wc -l | tr -d ' ')"
info "Scoring ${N_VARIANTS} variants (+ canonical rows) in ${N_BATCHES} dl-score batches and ${N_PAIRS} biasing pairs — run 1 of 2…"
run_once "${SCRATCH}/run1"
info "Repeating the whole measurement — run 2 of 2 (determinism check, R6)…"
run_once "${SCRATCH}/run2"

# ── Judge ─────────────────────────────────────────────────────────────────────────────────────
# `|| RC=$?` so set -e does not abort before the PASS/FAIL banner runs (review: dead-banner fix).
echo ""
RC=0
python3 "${COMPARE}" compare --cases "${CASES}" --variants "${VARIANTS}" --pairs "${PAIRS}" \
    --run "${SCRATCH}/run1" --rerun "${SCRATCH}/run2" || RC=$?

echo ""
case ${RC} in
    0) info "Voice-accuracy gate: PASS (${N_VARIANTS} variants, ${N_PAIRS} pairs; two identical runs)." ;;
    2) nowork "Voice-accuracy gate: NO WORK (rc=2) — zero rows measured." ;;
    *) fail "Voice-accuracy gate: FAIL (rc=${RC}) — a confident-wrong row, canonical regression, pair mismatch, or non-determinism. See the hard-signal block above." ;;
esac
exit ${RC}
