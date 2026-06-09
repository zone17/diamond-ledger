---
module: evals/runners
date: 2026-06-09
problem_type: best_practice
component: ci_eval_harness
severity: high
applies_when:
  - "Writing a shell/CI runner that compares a program's output against a frozen expected baseline"
  - "A toolchain-guarded gate may SKIP when its build environment is unavailable"
  - "Embedding a Python/awk comparator inside a bash heredoc that interpolates program output"
  - "Declaring a new CI job a 'hard gate' that protects a correctness invariant"
related_components:
  - ci-cd
  - eval-harness
tags: [eval-harness, ci-gate, vacuous-gate, shell, heredoc, injection, skip-vs-pass, baseline, dl-37, sc-003, robustness]
---

# Two pitfalls that turn a "hard" eval gate into a false guardian

## Context
DL-37 added a CI regression gate (`evals/runners/transcript-score.sh`) that runs a scorer over a
frozen corpus and diffs the output against expected values. The `/ce:review` gate flagged **two
P1 defects in the gate itself** — both make a gate that *looks* protective actually unable to do
its job. They are general to any output-vs-baseline CI runner, not specific to this project.

## Guidance

### Pitfall 1 — never interpolate program output into comparator *source*
The runner spliced the scorer's stdout into a Python heredoc as a string literal:

```bash
# WRONG — program output becomes Python SOURCE
ACTUAL="$(printf '%s\n' "$TRANSCRIPTS" | "$BIN")"
python3 - "$CASES" <<PY
actual = [json.loads(l) for l in """${ACTUAL}""".splitlines() if l.strip()]
PY
```

If any output byte is a `"` or `\`, the Python lexer mangles it **before** `json.loads` runs: a
`\b` becomes a backspace, `"""` terminates the triple-quote → `SyntaxError`/`JSONDecodeError`. The
cruel part: those are exactly the **regression inputs the gate exists to catch** (a scorer emitting
an error string with a quote/backslash), so the gate crashes — or reds a *correct* pipeline —
precisely when it matters. Under `set -e` the crash aborts before the diagnostic banner, leaving an
opaque traceback.

```bash
# RIGHT — pass output as DATA (a file path / stdin), never as source
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
printf '%s\n' "$TRANSCRIPTS" | "$BIN" > "$SCRATCH/actual.jsonl"
python3 "$SCRATCH/compare.py" "$CASES" "$SCRATCH/actual.jsonl"   # both inputs are argv paths
```

### Pitfall 2 — a SKIP that exits 0 is indistinguishable from a PASS
The runner skipped (advisory `exit 0`) whenever its toolchain was missing — including on the very
runner where it's declared a *hard* gate:

```bash
# WRONG — on the canonical CI runner, a vanished toolchain silently "passes"
command -v swift >/dev/null || { warn "swift missing — skipping"; exit 0; }
```

A green check that **tested nothing** is the vacuous-gate anti-pattern. SKIP and PASS must be
distinguishable, and the platform that is *supposed* to run the gate must FAIL (not skip) when it
can't:

```bash
# RIGHT — skip only where the gate genuinely cannot run; hard-fail where it should
if [[ "$(uname -s)" != "Darwin" ]]; then warn "non-macOS: advisory skip"; exit 0; fi
command -v swift >/dev/null || { fail "swift missing on macOS — Xcode required"; exit 1; }
# ...and prove work happened:
if [[ "$passed_plus_failed" -eq 0 ]]; then fail "zero cases scored — vacuous run"; exit 2; fi
```

## Why This Matters
Both defects pass CI green while protecting nothing — the inverse of the project's cardinal rule
("a 'never silently X' gate is only as good as its instrumentation"). A gate you trust to catch a
correctness regression must be **robust against its own inputs** (Pitfall 1) and must **prove it
actually ran** (Pitfall 2), or it is theater. The corpus-freeze step has a sibling trap: freeze the
baseline only from *verified-correct* output on a *current* base — see
[[harness-on-stale-base-flags-missing-upstream-fix]].

## When to Apply
Any shell/CI runner that (a) embeds a comparator interpreter inline, or (b) can short-circuit when
its build environment is missing. Add a standing checklist for new eval gates:
- Program output reaches the comparator as **data** (file/stdin/argv), never interpolated into code.
- SKIP ≠ PASS: emit a distinct marker; the canonical runner hard-fails on a missing toolchain.
- Assert **N>0** units were actually compared (a zero-work run fails).
- A real regression must produce a **non-zero exit AND a legible diagnostic** (don't let `set -e`
  swallow the banner — capture with `cmd || RC=$?`).
- Strengthen weak matches: require an expected token to be *present*, but don't let an unrelated
  message that merely *contains* the token pass (drop loose "equal-or-substring" branches).

## Examples — and the meta-lesson
All four runner findings here were surfaced by the adversarial persona in `/ce-code-review`, which
*constructed* the breaking inputs (a transcript with an embedded quote; a runner with no swift)
rather than re-checking the happy path. This is the same habit that catches loose-substring
classifier bugs ([[loose-substring-guard-silent-misclassification]]): for any gate, **write the
input that should trip it and prove it does** — a gate never exercised by a failing case is
unproven.

## Related
- DL-37 (ADR-0015), PR #163 review.
- [[harness-on-stale-base-flags-missing-upstream-fix]] — the baseline-freeze sibling trap.
- [[verify-generated-code-with-real-toolchain]] — `continue-on-error` advisory jobs hide failures.
- [[parallel-squad-integration]] — green CI ≠ correct; the review gate catches real P1s.
