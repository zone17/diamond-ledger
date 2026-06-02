---
module: development-workflow
date: 2026-06-02
last_updated: 2026-06-02
problem_type: workflow_issue
component: development_workflow
severity: high
applies_when:
  - "Multiple agent squads build in parallel branches and you merge them into one main"
  - "CI jobs are wired continue-on-error (advisory) and the run shows green"
  - "Creating a git worktree for a feature branch while the base repo enforces 'main only'"
  - "Designing an eval gate for a 'never silently resolve' invariant"
tags:
  - parallel-agents
  - integration
  - ci
  - continue-on-error
  - git-worktree
  - sc-003
  - eval-gates
---

# Parallel-squad integration: advisory CI masks failures, worktree hygiene, and gating the right invariant

Three squads (core / iOS / factory) built in parallel against frozen interfaces and merged into
`main`. Each branch was green; the *integration* surfaced real failures none had alone. Plus two
tooling/design lessons. Captured so the next parallel build avoids the same rounds.

## 1. Integration is its own gate — and `continue-on-error` hides it

When the squads combined, two failures appeared that existed on **no single branch**:
- The factory squad's CI ran `cargo clippy --workspace -- -D warnings` (deny **all** warnings). The
  core squad's branch only ran `-D clippy::float_arithmetic`, so 8 ordinary style lints (`map_or`,
  `is_some()`, a redundant `Copy` clone, doc indentation) passed there and only failed once the two
  combined.
- The core squad's SC-003 gate test used a relative corpus path; the factory squad's CI passed a
  *relative* `CORPUS_PATH`. `cargo test` runs integration tests with **CWD = the package dir
  (`core/`)**, not the repo root, so `evals/...` resolved to `core/evals/...` → not found. Neither
  was visible until A's gate met C's invocation.

**Both were invisible because the jobs were `continue-on-error: true`** — the run reported **success**
while the jobs were **red**. This is the same proxy-vs-signal trap documented in
[critical-patterns P1-1](../patterns/critical-patterns.md) and
[verify-generated-code-with-real-toolchain](../best-practices/verify-generated-code-with-real-toolchain.md):
a green *run* is a proxy; the per-job conclusion is the signal.

**Rules:**
- Treat **integration as a distinct verification step**, not the sum of green branches. Build a
  one-command end-to-end smoke (`make demo`: build + test + lint + the eval gates) and run it on the
  merged tree.
- Reproduce the CI gate **exactly** (e.g. `-D warnings`, not just one lint) — a narrower local check
  passes work the CI will reject.
- After every merge, read **per-job** conclusions; a `continue-on-error` job that's red is a real
  failure. Make gates **enforcing** (drop `continue-on-error`) only once they're green on `main`.
- Make eval/test file paths **CWD-independent**: resolve against `CARGO_MANIFEST_DIR` (or an absolute
  root), never the process CWD — `cargo test` runs from the package dir.

## 2. Git worktrees must live OUTSIDE the repo working tree

Creating a feature worktree **inside** the repo (`.claude/worktrees/dl-104`, under the main checkout)
produced a **corrupted partial checkout** (top-level source files missing, spurious deletions) and
later a broken ref (`refs/heads/...-demo 2`) that blocked `git fetch`. Creating the worktree as a
**sibling outside the repo** (`/Users/fp/Desktop/dl104`) checked out cleanly.

```bash
# good — sibling, outside the repo working tree:
git worktree add -b feat/<squad>/<TICKET>-<slug> ../<repo>-<ticket> main
# avoid — nested inside the repo's own working tree (.claude/worktrees/… for manual use):
```
Also: the base-repo branch-discipline hook keeps the base repo on `main` and wants feature work in
worktrees — commit with `git -C <worktree> commit` (the hook reads the branch from the `-C` target),
and clean up stale refs with `git worktree prune` + `rm` of any broken-named ref file.

## 3. Gate the cardinal invariant, not a stricter proxy

SC-003 / I2 is *"every fact-classified judgment is **surfaced**, never **silently resolved**"* — it is
**not** *"the engine's judgment **kind** exactly matches the corpus's expected kind."* On 3 multi-trigger
edge cases the core's trigger-priority surfaced a *different* judgment kind than the corpus expected —
but every one **still stopped and asked** (no silent resolution). The cardinal invariant held.

So the gate hard-fails only on the true SC-003 condition (a judgment classified Deterministic/
OutOfFormat, or the silent-resolution counter > 0, or a missing trigger), and reports **kind**
disagreements as **non-fatal, tracked** warnings (accuracy debt for the owning squads to reconcile).
Gating on the stricter proxy (kind-exact) would have blocked merge on a genuine, debatable
domain-priority question that is *not* the invariant the probe broke.

**Rule:** when gating a "never do X silently" invariant, assert exactly *"X did not happen silently"* —
not a tighter correctness property that happens to be checkable. Track the tighter property separately.

## When to Apply

Any multi-agent/multi-squad parallel build that merges into one trunk; any CI with advisory jobs; any
manual git-worktree use; any eval gate for a safety/"never silently" invariant.
