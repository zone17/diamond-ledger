#!/usr/bin/env bash
# transcript-score.sh — end-to-end transcript→score regression gate (DL-37).
#
# Runs the headless `dl-score` CLI (transcript → GrammarParser → real Rust core → JSON) over a
# frozen corpus of English play calls (evals/transcript-regression/cases.jsonl) and asserts the
# pipeline's output (classification / judgment-required / judgment-kind / Reisner catalyst, or
# out-of-grammar surfacing) matches the expected baseline. This is the first headless coverage of
# the DETERMINISTIC, ISOLATED-PLAY transcript→score path — the GrammarParser + FactBridge + core
# seam that previously could only be exercised inside the iOS app. It would have caught the
# DL-154/#162 regression (all play types collapsing to a 6-3 groundout) instantly. It does NOT
# cover state-dependent scoring (fresh game per line) or the ASR leg — see the corpus README.
#
# Why this can be a HARD gate (unlike the advisory iOS xcodebuild job): the deterministic core
# runs as a macOS slice of the XCFramework (ADR-0015), so this needs only the macOS SDK + rust —
# both present on GitHub macos runners. No iOS-26 SDK required.
#
# Exit codes:
#   0  All cases matched the expected baseline (PASS), OR the toolchain is genuinely unavailable
#      (Linux / no Xcode / no cargo) → SKIP, advisory, printed LOUD.
#   1  A real regression: one or more cases diverged from the expected baseline.
#
# Usage:  bash evals/runners/transcript-score.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CASES="${REPO_ROOT}/evals/transcript-regression/cases.jsonl"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
info() { echo "${GREEN}[transcript-score]${NC} $*"; }
warn() { echo "${YELLOW}[transcript-score] SKIP${NC} $*"; }
fail() { echo "${RED}[transcript-score] FAIL${NC} $*" >&2; }

echo "Transcript→score regression gate (DL-37 / dl-score)"
echo "==================================================="

[[ -f "${CASES}" ]] || { fail "corpus not found: ${CASES}"; exit 1; }

# ── Toolchain guard ───────────────────────────────────────────────────────────────────────────
# SKIP (advisory, exit 0) ONLY on non-Darwin, where the dl-score CLI genuinely cannot build
# (Linux can't link the macOS slice). On Darwin — the canonical CI runner + dev box — a MISSING
# toolchain is a HARD FAIL, not a skip: a "hard gate" that silently exits 0 because swift/cargo
# vanished is exactly the vacuous-green failure this gate exists to prevent. (Review: SKIP==PASS.)
if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "not macOS — the dl-score CLI needs the macOS toolchain to build. (Linux CI: advisory skip.)"
    exit 0
fi
command -v swift >/dev/null 2>&1 || { fail "swift not found on macOS — Xcode required for this gate."; exit 1; }
command -v cargo >/dev/null 2>&1 || { fail "cargo not found on macOS — rustup required for this gate."; exit 1; }

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# ── Ensure the core XCFramework (with the macOS slice) exists ──────────────────────────────────
XCF="${REPO_ROOT}/ios/Generated/DiamondLedgerCore.xcframework"
if [[ ! -d "${XCF}/macos-arm64_x86_64" ]]; then
    info "Building core XCFramework (macOS slice needed)…"
    bash "${REPO_ROOT}/scripts/build-xcframework.sh" >/dev/null
fi

# ── Build dl-score (macOS) ─────────────────────────────────────────────────────────────────────
info "Building dl-score…"
( cd "${REPO_ROOT}/ios" && swift build --product dl-score >/dev/null )
BIN="$(cd "${REPO_ROOT}/ios" && swift build --product dl-score --show-bin-path)/dl-score"
[[ -x "${BIN}" ]] || { fail "dl-score binary not produced at ${BIN}"; exit 1; }

# ── Run dl-score over the corpus transcripts and diff against the expected baseline ────────────
# Robustness (review): the corpus and the CLI output are passed to the comparator as FILE PATHS
# (argv), never interpolated into Python source. A transcript or error string containing a quote
# or backslash must FAIL a case loudly, not corrupt the comparator (which would red a CORRECT
# pipeline or crash opaquely). A scratch dir holds both staged files.
N_CASES="$(grep -c . "${CASES}")"
info "Scoring ${N_CASES} cases…"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
python3 -c "import json,sys
for line in open(sys.argv[1]):
    line=line.strip()
    if line: print(json.loads(line)['transcript'])" "${CASES}" | "${BIN}" > "${SCRATCH}/actual.jsonl"

# Compare via a staged python file reading both inputs as argv paths (no source interpolation).
cat > "${SCRATCH}/compare.py" <<'PY'
import json, sys
cases  = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
actual = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
by_t = {a["transcript"]: a for a in actual}

passed = failed = 0
for c in cases:
    t = c["transcript"]
    a = by_t.get(t)
    problems = []
    if a is None:
        problems.append("no output line from dl-score")
    else:
        if a["ok"] != c["expect_ok"]:
            problems.append(f"ok={a['ok']} != {c['expect_ok']}")
        if a["classification"] != c["expect_classification"]:
            problems.append(f"cls={a['classification']!r} != {c['expect_classification']!r}")
        if a["judgment_required"] != c["expect_judgment_required"]:
            problems.append(f"judgment_required={a['judgment_required']} != {c['expect_judgment_required']}")
        # judgment_kind asserted when expected — a WRONG kind that still surfaces a judgment must
        # not pass (the gate checks the cardinal SC-003 signal AND the specific kind).
        if "expect_judgment_kind" in c and a.get("judgment_kind") != c["expect_judgment_kind"]:
            problems.append(f"judgment_kind={a.get('judgment_kind')!r} != {c['expect_judgment_kind']!r}")
        if "expect_reisner_catalyst" in c and a.get("reisner_catalyst") != c["expect_reisner_catalyst"]:
            problems.append(f"reisner_catalyst={a.get('reisner_catalyst')!r} != {c['expect_reisner_catalyst']!r}")
        # EXACT error-substring match would be too brittle (the error carries variable context),
        # so require the expected token to be PRESENT — but only the explicit presence check, not
        # the loose "or equal" that let an unrelated error containing the token slip through.
        if "expect_error" in c and c["expect_error"] not in (a.get("error") or ""):
            problems.append(f"error={a.get('error')!r} missing expected {c['expect_error']!r}")
    if problems:
        failed += 1
        print(f"\033[0;31m  FAIL\033[0m {c['id']:32} {t[:40]!r}")
        for p in problems:
            print(f"         - {p}")
    else:
        passed += 1
        print(f"\033[0;32m  ok  \033[0m {c['id']:32} {c['expect_classification']}")

print()
print(f"  {passed} passed, {failed} failed, {len(cases)} total")
# A run that scored ZERO cases is a vacuous pass — fail it (review: no silent green).
if len(cases) == 0 or passed + failed == 0:
    print("  ERROR: zero cases scored — vacuous run, failing.")
    sys.exit(2)
sys.exit(1 if failed else 0)
PY

# `|| RC=$?` so set -e does not abort before the PASS/FAIL banner runs (review: dead-banner fix).
RC=0
python3 "${SCRATCH}/compare.py" "${CASES}" "${SCRATCH}/actual.jsonl" || RC=$?

echo ""
if [[ ${RC} -eq 0 ]]; then
    info "Transcript→score regression gate: PASS (${N_CASES} cases)."
else
    fail "Transcript→score regression gate: FAIL (rc=${RC}) — pipeline diverged from baseline (or zero cases ran)."
fi
exit ${RC}
