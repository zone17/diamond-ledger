#!/usr/bin/env bash
# voice-accuracy-tripwire.sh — proves evals/runners/voice-accuracy.sh actually trips (DL-157 / R12).
#
# A gate never exercised by a failing case is unproven (docs/solutions/best-practices/
# eval-gate-construction-pitfalls.md). Each fixture below is a corpus that MUST make the runner
# exit non-zero with a legible banner naming the offending row — or a corpus that must make it
# refuse to claim work it did not do:
#
#   1. confident-wrong: a variant with a DIFFERENT play ("fly ball … caught") marked same_as_base
#      against a ground-out base → exit 1, banner names the variant id (R2 rule 1).
#   2. judgment-on-deterministic-base: a variant that surfaces a hitVsError judgment against a
#      deterministic ground-out base → exit 1, banner names the row (R2 rule 2).
#   3. empty corpus (zero variants, zero pairs) → exit 2 (vacuous run, never green).
#   4. biasing pair whose expect_decision is wrong → exit 1, banner names the pair id (R8).
#   5. a correct corpus → exit 0, and every line carrying a "%" carries the fixture-robustness
#      label (R4) — the control case, so a runner that fails EVERYTHING cannot pass this file.
#
# The runner is pointed at scratch corpora via VOICE_ACCURACY_DIR / TRANSCRIPT_CASES; the real
# corpus under evals/voice-accuracy/ is never read here.
#
# USAGE: bash tools/tests/voice-accuracy-tripwire.sh   (from anywhere; macOS + Xcode + rustup)
# EXIT: 0 all assertions hold; 1 any failure. Non-Darwin: prints a SKIP marker and exits 0
#       (the runner itself SKIPs there, so no assertion can be exercised).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="${REPO_ROOT}/evals/runners/voice-accuracy.sh"
LABEL='FIXTURE ROBUSTNESS (advisory — not field accuracy)'

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "voice-accuracy-tripwire: SKIP — not macOS; the runner under test cannot build here."
    exit 0
fi
[[ -f "${RUNNER}" ]] || { echo "FAIL: runner not found at ${RUNNER}"; exit 1; }

PASS=0; FAIL=0
t() { # name expected_substring actual
  local name="$1" want="$2" got="$3"
  case "$got" in
    *"$want"*) PASS=$((PASS+1)); echo "  ok: $name" ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: $name"; echo "        want substring: $want"; echo "        got (tail): $(printf '%s' "$got" | tail -n 8 | head -c 600)" ;;
  esac
}
t_rc() { # name expected_rc actual_rc
  local name="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); echo "  ok: $name (exit $got)"; else FAIL=$((FAIL+1)); echo "  FAIL: $name — want exit $want, got exit $got"; fi
}

# ── Fixture builders ─────────────────────────────────────────────────────────
# Canonical rows are drawn from evals/transcript-regression/cases.jsonl (same ids, same
# expectations) so the scratch harness measures the real pipeline, not a toy.
mk_cases() { # $1 = path
  cat > "$1" <<'JSONL'
{"id":"tr-groundout-63","transcript":"ground ball to short, threw him out at first","expect_ok":true,"expect_classification":"deterministic","expect_judgment_required":false,"expect_reisner_catalyst":"6-3"}
{"id":"tr-flyout-8","transcript":"fly ball to center caught for the out","expect_ok":true,"expect_classification":"deterministic","expect_judgment_required":false,"expect_reisner_catalyst":"8"}
{"id":"tr-judgment-error-ss","transcript":"reached on error by the shortstop","expect_ok":true,"expect_classification":"judgment","expect_judgment_required":true,"expect_judgment_kind":"hitVsError","expect_reisner_catalyst":"6"}
JSONL
}
mk_good_pair() { # $1 = path (one pair whose expectation matches the policy)
  cat > "$1" <<'JSONL'
{"id":"pair-divergent-keeps-base","base":"ground ball to short","base_confidence":0.9,"biased":"fly ball to center","biased_confidence":0.9,"contextual_set":["short"],"expect_decision":"keep_base","expect_text":"ground ball to short"}
JSONL
}
mk_good_variant() { # $1 = path (one filler variant that genuinely scores the same as its base)
  cat > "$1" <<'JSONL'
{"id":"v-filler-um-groundout","base_id":"tr-groundout-63","kind":"filler","transcript":"um ground ball to short, threw him out at first","expect":"same_as_base"}
JSONL
}
run_runner() { # $1 = corpus dir, $2 = cases path; prints combined output, returns runner rc
  VOICE_ACCURACY_DIR="$1" TRANSCRIPT_CASES="$2" bash "${RUNNER}" 2>&1
}

echo "voice-accuracy tripwire (runner: evals/runners/voice-accuracy.sh)"

# ── 1. confident-wrong variant marked same_as_base → exit 1, names the row ───
DIR=$(mktemp -d); mk_cases "$DIR/cases.jsonl"; mk_good_pair "$DIR/biasing-pairs.jsonl"
cat > "$DIR/variants.jsonl" <<'JSONL'
{"id":"v-wrong-flyball-as-groundout","base_id":"tr-groundout-63","kind":"mishear","transcript":"fly ball to center caught for the out","expect":"same_as_base"}
JSONL
out=$(run_runner "$DIR" "$DIR/cases.jsonl"); rc=$?
t_rc "confident-wrong: runner exits 1" 1 "$rc"
t "confident-wrong: banner names the variant row" "v-wrong-flyball-as-groundout" "$out"
t "confident-wrong: banner names the base row" "tr-groundout-63" "$out"
t "confident-wrong: reported under the hard signal" "confident-wrong rows: 1" "$out"
t "confident-wrong: final verdict is FAIL" "Voice-accuracy harness: FAIL" "$out"
rm -rf "$DIR"

# ── 2. judgment surfaced on a deterministic base → exit 1 ────────────────────
DIR=$(mktemp -d); mk_cases "$DIR/cases.jsonl"; mk_good_pair "$DIR/biasing-pairs.jsonl"
cat > "$DIR/variants.jsonl" <<'JSONL'
{"id":"v-judgment-on-deterministic","base_id":"tr-groundout-63","kind":"mishear","transcript":"reached on error by the shortstop","expect":"same_as_base"}
JSONL
out=$(run_runner "$DIR" "$DIR/cases.jsonl"); rc=$?
t_rc "judgment-on-deterministic: runner exits 1" 1 "$rc"
t "judgment-on-deterministic: banner names the row" "v-judgment-on-deterministic" "$out"
t "judgment-on-deterministic: banner says why" "judgment" "$out"
rm -rf "$DIR"

# ── 3. empty corpus → exit 2 (no work is never green) ────────────────────────
DIR=$(mktemp -d); mk_cases "$DIR/cases.jsonl"
: > "$DIR/variants.jsonl"; : > "$DIR/biasing-pairs.jsonl"
out=$(run_runner "$DIR" "$DIR/cases.jsonl"); rc=$?
t_rc "empty corpus: runner exits 2" 2 "$rc"
t "empty corpus: says it did no work" "zero" "$out"
rm -rf "$DIR"

# ── 4. biasing pair with a wrong expect_decision → exit 1, names the pair ────
DIR=$(mktemp -d); mk_cases "$DIR/cases.jsonl"; mk_good_variant "$DIR/variants.jsonl"
cat > "$DIR/biasing-pairs.jsonl" <<'JSONL'
{"id":"pair-wrongly-expects-override","base":"ground ball to short","base_confidence":0.9,"biased":"fly ball to center","biased_confidence":0.9,"contextual_set":["short"],"expect_decision":"override","expect_text":"fly ball to center"}
JSONL
out=$(run_runner "$DIR" "$DIR/cases.jsonl"); rc=$?
t_rc "wrong pair expectation: runner exits 1" 1 "$rc"
t "wrong pair expectation: banner names the pair" "pair-wrongly-expects-override" "$out"
t "wrong pair expectation: reported as a pair mismatch" "pair mismatches: 1" "$out"
rm -rf "$DIR"

# ── 5. control: a correct corpus passes, and every '%' line is labeled ───────
DIR=$(mktemp -d); mk_cases "$DIR/cases.jsonl"; mk_good_variant "$DIR/variants.jsonl"; mk_good_pair "$DIR/biasing-pairs.jsonl"
out=$(run_runner "$DIR" "$DIR/cases.jsonl"); rc=$?
t_rc "control corpus: runner exits 0" 0 "$rc"
t "control corpus: final verdict is PASS" "Voice-accuracy harness: PASS" "$out"
t "control corpus: determinism reported" "determinism:" "$out"
unlabeled=$(printf '%s\n' "$out" | grep '%' | grep -v -F "$LABEL" || true)
if [[ -z "$unlabeled" ]]; then PASS=$((PASS+1)); echo "  ok: control corpus: every '%' line carries the label"; else FAIL=$((FAIL+1)); echo "  FAIL: unlabeled accuracy-shaped line(s):"; printf '%s\n' "$unlabeled" | sed 's/^/        /'; fi
rm -rf "$DIR"

echo ""
echo "voice-accuracy tripwire: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
