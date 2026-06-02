#!/usr/bin/env bash
# parity.sh — CLI/agent path vs UI/core path equivalence (SC-008 / T040 / #65 Story A8).
#
# Authority: evals/INTERFACE.md §3.1 (parity gate, HARD-FAIL) · spec SC-008 · Art. II.
#
# SC-008: the same normalized facts produce the SAME result regardless of caller. There
# are two independent code paths to the deterministic core:
#
#   1. CLI/agent path  — the `dl` CLI building a game across SEPARATE invocations, with the
#                        event log PERSISTED between commands (#128). This is the
#                        agent-native surface (Art. II): new-game → record → confirm → …
#   2. UI/core path    — a single FRESH in-memory `DiamondCore` replaying the same facts
#                        in one process. This is exactly what the UniFFI/iOS UI invokes
#                        (`dl replay-core`).
#
# This gate runs identical normalized facts through BOTH paths and asserts the final
# projected `GameState` is BYTE-IDENTICAL. Any difference → HARD-FAIL (exit 1): the
# persistence layer or an adapter introduced divergence, breaking parity/determinism (I6).
#
# Usage: parity.sh
#
# Exit codes:
#   0  CLI/agent path and core path produced byte-identical state.
#   1  Any divergence, or a path errored.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
info() { echo "${GREEN}[parity]${NC} $*"; }
fail() { echo "${RED}[parity] FAIL${NC} $*" >&2; }

echo "Parity gate (SC-008 — CLI/agent path vs UI/core path)"
echo "====================================================="

cd "${REPO_ROOT}"
# shellcheck disable=SC1091
source "$HOME/.cargo/env" 2>/dev/null || true

# ── Build the dl CLI ──────────────────────────────────────────────────────────
info "Building the dl CLI..."
cargo build -q -p dl-cli
DL="${REPO_ROOT}/target/debug/dl"
[[ -x "${DL}" ]] || { fail "dl CLI not built at ${DL}"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STATE="${WORK}/dl-state.json"
OPS="${WORK}/ops.json"

OWNER="owner-parity"

# A deterministic 3-out half-inning of normalized facts (two groundouts, one strikeout),
# each recorded then confirmed. The SAME facts drive both paths.
GROUNDOUT='{"situation":{"runners":{"first":null,"second":null,"third":null},"outs":0,"count":{"balls":0,"strikes":0},"batter_hand":"right"},"catalyst":{"batter_event":"fielded_out","fielders":[6,3],"ball_type":"ground","advances":[{"runner":1,"from":"home","to":"out","by_error":null}],"touched_or_misplayed_by":[]}}'
STRIKEOUT='{"situation":{"runners":{"first":null,"second":null,"third":null},"outs":0,"count":{"balls":0,"strikes":2},"batter_hand":"right"},"catalyst":{"batter_event":"strikeout","fielders":[],"ball_type":"none","advances":[{"runner":1,"from":"home","to":"out","by_error":null}],"touched_or_misplayed_by":[]}}'

# ── Path 1: CLI/agent path (persisted, across separate `dl` invocations) ──────
info "Path 1 — CLI/agent (persisted event log across invocations, #128)..."
export DL_STATE_FILE="${STATE}"
"${DL}" new-game Hawks Eagles "${OWNER}" >/dev/null

seq=1
for play in "${GROUNDOUT}" "${GROUNDOUT}" "${STRIKEOUT}"; do
    "${DL}" record-play 1 "${play}" "${OWNER}" >/dev/null
    "${DL}" confirm-play 1 "${seq}" "${OWNER}" >/dev/null
    seq=$((seq + 2))   # each record+confirm adds 2 events; PlayRecorded seq = 1,3,5
done
CLI_STATE="$("${DL}" state 1)"
unset DL_STATE_FILE

# ── Path 2: UI/core path (fresh in-memory core, single process replay) ────────
info "Path 2 — UI/core (fresh in-memory DiamondCore replay)..."
cat > "${OPS}" <<EOF
[
  {"op":"new-game","home":"Hawks","visitor":"Eagles","owner":"${OWNER}"},
  {"op":"record-play","game_id":1,"play":${GROUNDOUT},"owner":"${OWNER}"},
  {"op":"confirm-play","game_id":1,"seq":1,"owner":"${OWNER}"},
  {"op":"record-play","game_id":1,"play":${GROUNDOUT},"owner":"${OWNER}"},
  {"op":"confirm-play","game_id":1,"seq":3,"owner":"${OWNER}"},
  {"op":"record-play","game_id":1,"play":${STRIKEOUT},"owner":"${OWNER}"},
  {"op":"confirm-play","game_id":1,"seq":5,"owner":"${OWNER}"}
]
EOF
CORE_STATE="$("${DL}" replay-core "${OPS}")"

# ── Compare byte-for-byte ─────────────────────────────────────────────────────
echo "${CLI_STATE}"  > "${WORK}/cli.json"
echo "${CORE_STATE}" > "${WORK}/core.json"

echo ""
if diff -u "${WORK}/cli.json" "${WORK}/core.json" >"${WORK}/diff.txt" 2>&1; then
    info "PASS: CLI/agent path and UI/core path produced BYTE-IDENTICAL state (SC-008)."
    echo "      Final state (both paths):"
    sed 's/^/        /' "${WORK}/cli.json"
    echo ""
    echo "Parity gate: GREEN"
    exit 0
else
    fail "PARITY VIOLATION (SC-008): CLI/agent path != UI/core path for identical facts."
    echo "--- diff (cli vs core) ---" >&2
    cat "${WORK}/diff.txt" >&2
    echo "---" >&2
    exit 1
fi
