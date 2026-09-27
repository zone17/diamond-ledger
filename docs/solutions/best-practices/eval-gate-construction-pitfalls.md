---
module: evals/runners
date: 2026-06-09
last_updated: 2026-09-27
problem_type: best_practice
component: ci_eval_harness
severity: high
applies_when:
  - "Writing a shell/CI runner that compares a program's output against a frozen expected baseline"
  - "A toolchain-guarded gate may SKIP when its build environment is unavailable"
  - "Embedding a Python/awk comparator inside a bash heredoc that interpolates program output"
  - "Declaring a new CI job a 'hard gate' that protects a correctness invariant"
  - "A gate reports some outcomes as 'safe' or 'advisory' categories next to its hard-fail signal"
  - "A gate measures more than one leg (e.g. two confidence levels) but asserts only one"
related_components:
  - ci-cd
  - eval-harness
tags: [eval-harness, ci-gate, vacuous-gate, shell, heredoc, injection, skip-vs-pass, baseline, dl-37, sc-003, robustness, tripwire, safe-category, dl-157]
---

# Pitfalls that turn a "hard" eval gate into a false guardian

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

### Pitfall 3 — a hard-fail branch no failing fixture exercises is unproven (DL-157)
The voice-accuracy gate (`evals/runners/voice-accuracy.sh`, PR #181) shipped with a tripwire that
proved three of its hard-fail branches and a green control. The multi-lens review then *reproduced*
three ways it went green while wrong, each in a branch or category the tripwire never pushed on:

- **A "safe" category absorbed wrong facts.** A variant that surfaced the *same judgment kind* as
  its base was counted as a safe miss — but "reached on error by the third baseman" against an E6
  base carries fielder 5 into the card's recommended call exactly as a confirm card would. The
  gate reported `confident-wrong rows: 0` on it. Fix: a safe category must also require the carried
  facts to equal the base (`is_safe_miss`, `evals/runners/voice-accuracy-compare.py:329`), and the
  same case became a confident-wrong reason (`confident_wrong_reason`, `:347`).
- **A measured leg had no hard signal.** The corpus ran at confidence 100 *and* at the production
  default 60, but the 60 leg only fed an advisory clarify-rate line, so a regression of the
  FR-008 low-confidence route (plays scoring silently at 60) would have stayed green. Fix: any
  parseable row with `ok` and `needs` in {none, confirm} at 60 is a hard failure (`silent_at_60`,
  `:466`).
- **The determinism branch was never tripped.** Nothing made run 1 and run 2 differ, so the
  `non-deterministic output → exit 1` path was dead weight nobody had seen work.

The fix pattern: **one tripwire fixture per hard-fail branch, and one per "safe" category that
could carry a wrong fact.** Branches the runner cannot easily provoke end-to-end (a silent score at
60, a one-byte run difference) are proven by keeping the runner's scratch dir
(`VOICE_ACCURACY_SCRATCH`), tampering with the raw outputs, and calling the comparator directly
(`tools/tests/voice-accuracy-tripwire.sh`, fixtures 6–8; 24 assertions).

### Pitfall 4 — expectations copied from today's output freeze today's bugs
Author corpus expectations from domain semantics and *then* run the pipeline. The voice-accuracy
corpus, written from play semantics, was red on its first run with 25 confident-wrong rows; those
rows exposed hard-coded default fielders in the parser (a lost "short" silently became 6-3). Had
the expectations been captured from `dl-score` output, all 25 would have been frozen as correct and
the gate would have guarded the bug. When a semantic expectation fails, fix the pipeline or prove
the expectation wrong from semantics — never relabel to green — and have someone other than the
author read the rows before freezing (constitution Article XX).

## Why This Matters
All four defects pass CI green while protecting nothing — the inverse of the project's cardinal rule
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
- **Every hard-fail branch has a tripwire fixture that makes it exit non-zero**, including the
  ones only reachable by tampering with raw outputs (determinism, secondary measured legs).
- **Every "safe"/advisory category is checked for carried wrong facts** — a category that reports
  "the pipeline refused to score" must not also admit rows that scored something different.
- **Every measured leg with an invariant gets a hard signal**, not only an advisory metric.
- **Expectations come from domain semantics, reviewed by someone other than the author**, never
  from a capture of current output.

## Examples — and the meta-lesson
All four runner findings here were surfaced by the adversarial persona in `/ce-code-review`, which
*constructed* the breaking inputs (a transcript with an embedded quote; a runner with no swift)
rather than re-checking the happy path. This is the same habit that catches loose-substring
classifier bugs ([[loose-substring-guard-silent-misclassification]]): for any gate, **write the
input that should trip it and prove it does** — a gate never exercised by a failing case is
unproven.

## Related
- DL-37 (ADR-0015), PR #163 review.
- DL-157 (ADR-0017), PR #181 review — pitfalls 3 and 4; `evals/voice-accuracy/README.md` records the corpus findings.
- [[harness-on-stale-base-flags-missing-upstream-fix]] — the baseline-freeze sibling trap.
- [[verify-generated-code-with-real-toolchain]] — `continue-on-error` advisory jobs hide failures.
- [[parallel-squad-integration]] — green CI ≠ correct; the review gate catches real P1s.
