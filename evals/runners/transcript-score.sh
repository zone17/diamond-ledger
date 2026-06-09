#!/usr/bin/env bash
# transcript-score.sh — end-to-end transcript→score regression gate (DL-37).
#
# Runs the headless `dl-score` CLI (transcript → GrammarParser → real Rust core → JSON) over a
# frozen corpus of English play calls (evals/transcript-regression/cases.jsonl) and asserts the
# pipeline's output (classification / judgment-required / Reisner catalyst, or out-of-grammar
# surfacing) matches the expected baseline. This is the FIRST headless coverage of the full
# transcript→score path — the GrammarParser + FactBridge + core seam that previously could only
# be exercised inside the iOS app. It would have caught the DL-154/#162 regression (all play
# types collapsing to a 6-3 groundout) instantly.
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

# ── Toolchain guard — SKIP (advisory) when the macOS/rust toolchain is unavailable ────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "not macOS — the dl-score CLI needs the macOS toolchain to build. (Linux CI: skip.)"
    exit 0
fi
command -v swift >/dev/null 2>&1 || { warn "swift not found — install Xcode. Skipping."; exit 0; }
command -v cargo >/dev/null 2>&1 || { warn "cargo not found — install rustup. Skipping."; exit 0; }

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
info "Scoring $(grep -c . "${CASES}") cases…"
TRANSCRIPTS="$(python3 -c "import json,sys
for line in open('${CASES}'):
    line=line.strip()
    if line: print(json.loads(line)['transcript'])")"

ACTUAL="$(printf '%s\n' "${TRANSCRIPTS}" | "${BIN}")"

python3 - "${CASES}" <<PY
import json, sys

cases = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
actual = [json.loads(l) for l in """${ACTUAL}""".splitlines() if l.strip()]
by_t = {a["transcript"]: a for a in actual}

passed = failed = 0
for c in cases:
    t = c["transcript"]
    a = by_t.get(t)
    problems = []
    if a is None:
        problems.append("no output line")
    else:
        if a["ok"] != c["expect_ok"]:
            problems.append(f"ok={a['ok']} != {c['expect_ok']}")
        if a["classification"] != c["expect_classification"]:
            problems.append(f"cls={a['classification']!r} != {c['expect_classification']!r}")
        if a["judgment_required"] != c["expect_judgment_required"]:
            problems.append(f"judgment_required={a['judgment_required']} != {c['expect_judgment_required']}")
        if "expect_reisner_catalyst" in c and a.get("reisner_catalyst") != c["expect_reisner_catalyst"]:
            problems.append(f"reisner_catalyst={a.get('reisner_catalyst')!r} != {c['expect_reisner_catalyst']!r}")
        if "expect_error" in c and (a.get("error") or "") != c["expect_error"] and c["expect_error"] not in (a.get("error") or ""):
            problems.append(f"error={a.get('error')!r} != {c['expect_error']!r}")
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
sys.exit(1 if failed else 0)
PY
RC=$?

echo ""
if [[ ${RC} -eq 0 ]]; then
    info "Transcript→score regression gate: PASS."
else
    fail "Transcript→score regression gate: FAIL — the scoring pipeline diverged from baseline."
fi
exit ${RC}
