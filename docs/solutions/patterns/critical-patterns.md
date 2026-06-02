---
module: cross-cutting
date: 2026-06-02
last_updated: 2026-06-02
problem_type: best_practice
component: architecture
severity: high
applies_when:
  - "Designing a validation/eval gate, a deterministic engine, or a classification/authority boundary"
  - "Reviewing whether a 'pass' can actually fail, or whether behavior keys on facts vs a caller label"
tags:
  - critical-patterns
  - index
  - determinism
  - validation-gates
  - judgment-classification
---

# Critical Patterns (P1) — Diamond Ledger

Canonical index of P1-class patterns: the invariants whose violation is high-impact and recurring.
Each entry: the pattern, a detection rule, a minimal snippet, and when to apply. Detailed write-ups
live in the linked `docs/solutions/` docs and in the spec/plan; this file is the index — do not
duplicate full explanations here.

## P1-1 — Assert on the real signal, not a proxy (no vacuous gates)

A gate that checks a *proxy* for success instead of the actual outcome can pass while the thing it
guards is broken. Three instances of the same shape have already bitten this project:

- **SC-003 dead counter** — a `silent_resolutions == 0` gate where the counter was never incremented:
  mathematically pinned to pass (probe finding, spec FR-006a/SC-003).
- **`cwevent` exit code** — Chadwick `cwevent` returns **exit 0 even on malformed plays**; an
  exit-code gate is vacuous. Must assert on **stderr** (`WARNING|Invalid|Can't find|could not open`)
  and ≥1 event row (`research.md` D4, `tasks.md` T060).
- **Batch-automation success log** — a `gh issue create` loop printed green while writing 18 malformed
  issues; the log was a proxy, the read-back was the signal
  ([shell-portability-in-agent-batch-automation](../best-practices/shell-portability-in-agent-batch-automation.md)).
- **Agent static review vs compilation** — a workflow's validation agent reported "workspace coherent,
  no compile errors"; the real `cargo check` found a workspace-hierarchy error + 2 derive mismatches. A
  static read is a proxy; the compiler is the signal. Worse, an advisory `continue-on-error` CI job
  showed the run green while the build failed — read the per-*job* conclusion
  ([verify-generated-code-with-real-toolchain](../best-practices/verify-generated-code-with-real-toolchain.md)).

**Detection:** a "pass" condition no code path can make fail; an exit-code/HTTP-200 check on a tool
that succeeds on bad input; a loop trusted by its log rather than verified by reading its output.

**Rule:** wire an adversarial input that *should* trip the gate and prove it fails; assert on the
authoritative signal, not a convenient proxy.

**When to apply:** every eval gate, CI check, and batch mutation.

## P1-2 — Fact-derived classification, never label-derived (the cardinal seam)

Classification/judgment/authority decisions MUST derive from normalized **facts**, never from a
caller-supplied **type/label** — a labeled-"deterministic" play whose facts are a judgment call must
still be flagged. The probe broke exactly this (5/5 silent resolutions). See spec FR-006/FR-006a/
FR-010, `tasks.md` story A3, and the [spec-coherence-probe](../design-patterns/spec-coherence-probe.md).

**Detection:** `classify(input.type)` / gating on a string the caller controls. **Rule:** inspect
facts; validate with a mislabeled-input adversarial corpus wired as a hard-fail gate.
**When to apply:** any classifier, permission check, or routing decision on caller-supplied input.

## P1-3 — Deterministic core = integer/fixed-point only (no floats)

A core that must produce byte-identical output across platforms MUST avoid floating point: IEEE-754
transcendentals (`sin`/`exp`/…) are not portable across libm/version/runtime. Keep the engine
integer/fixed-point (CI-linted `deny` on `f32`/`f64`); compute display ratios at the adapter/UI layer.
See `research.md` D1, ADR-0007, `tasks.md` T016 (FR-003/I6).

**Detection:** a float in a path that feeds a hash/equality/persistence boundary. **Rule:** forbid
floats in the core by lint; prove determinism by replaying the log twice and diffing.
**When to apply:** any deterministic engine, ledger, or replayable state machine.

## P1-4 — Owner-as-decider authority asserted at every boundary

Authority is enforced **deterministically at each primitive call** (caller is the game owner or an
explicitly authorized agent), not by a non-empty "decider" string and not in the UI. Requires a real
authenticated identity to bind to (FR-020/I5; the analysis G1 gap = no sign-in task to provide that
identity). See `tasks.md` T036/T081.

**Detection:** authority checked once, in the client, or satisfied by any non-empty value.
**Rule:** assert + audit authority inside each capability before any state change.
**When to apply:** every state-changing primitive, human or agent caller.

---

*See [common-solutions.md](./common-solutions.md) for P2/P3 recurring solutions. Full project map +
invariant index: [`docs/PROJECT_CONTEXT.md`](../../PROJECT_CONTEXT.md).*
