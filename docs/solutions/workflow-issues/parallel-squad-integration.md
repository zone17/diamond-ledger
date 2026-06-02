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
  - "Reviewing/merging agent-built squad PRs that pass CI, into one trunk"
tags:
  - parallel-agents
  - integration
  - ci
  - continue-on-error
  - git-worktree
  - sc-003
  - eval-gates
  - code-review-gate
  - adr-collision
  - board-reconciliation
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

**Two footguns when committing to a worktree from the *base-repo* session** (both hit repeatedly):
1. `cd <worktree> && git commit` is **false-positive blocked** — the hook resolves the branch from the
   hook's launch CWD (the base repo, on `main`), not the linked worktree's HEAD, so it thinks you're
   committing to `main`.
2. The `git -C <path>` escape hatch **also breaks when the worktree path contains a space** — the
   hook's parser (`sed -E 's/.*git\s+-C\s+([^ ]+).*/\1/'`) truncates the path at the first space, then
   fails to resolve a branch and *allows by default* (so it happens to work, but for the wrong reason).
   Robust options: let the **agent that owns the worktree** do its own commit/push from inside it (its
   CWD is the feature branch, so the hook passes cleanly); or use a **space-free worktree path**
   (or a space-free symlink to it) so `git -C` resolves the real branch.

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

## 4. Green CI ≠ correct — the multi-agent review gate catches what CI cannot

The squads' *second* round (real UniFFI core, iOS ASR, gold dataset) each merged green on CI, yet a
full `/ce:review` (3 reviewer personas per PR) caught **real P1 blockers on every PR** that CI passed:

| PR | Blocker CI missed | Why it mattered |
|----|-------------------|-----------------|
| core | `confirm_play` had no `JUDGMENT_REQUIRED` gate | a play that surfaced a judgment could be **confirmed without resolving it** — an I2 no-silent-judgment hole at the *confirm* boundary (the gate only checked the `record` boundary) |
| core | fact-layer enums serialized **PascalCase** while the contract pins `snake_case` | a wire-format break that **only bites at H1** (MockCore→real-core swap) — invisible until the seam goes live, then SC-008 parity fails on first call |
| core | non-atomic `fs::write` of the CLI event log | crash mid-write corrupts the durable log unrecoverably — exactly what the persistence feature exists to prevent |
| iOS | `SFSpeechRecognitionTask` never stored/cancelled | continuation could hang (no `isFinal`) or double-resume → an **FR-008 silent transcript drop** on the primary engine |
| iOS | missing `NSMicrophoneUsageDescription` | guaranteed hard crash on first device mic use + App Store rejection |

None are caught by `cargo test`/`xcodebuild` because they're **contract/seam/edge-case** defects, not
compile or unit-test failures. This is the strongest evidence for the **80/20 review-heavy CE loop**:
agent-built code that compiles and passes its own tests still ships latent cross-language contract and
concurrency bugs. The highest-leverage reviewer targets: cross-language wire format (serde rename),
*every* boundary of a "never silently X" invariant (not just the obvious one), and async/continuation
lifecycles.

**Rules:**
- Run a real review → fix → re-verify → merge gate on each squad PR; do **not** merge on green CI alone.
- Independently re-verify the *cardinal* invariant on the fixed commit before merge (here: re-run the
  SC-003 gate after the core fixes) — fixes near the invariant can silently regress it.
- Merge order matters when branches share a file: merge the most isolated first, the cross-cutting last.

## 5. Two squads numbered the same ADR — renumber the later merger

Both parallel branches authored **`ADR-0009`** (different decisions: UniFFI wiring vs ASR adapter
shape). `DECISIONS.md` was the **only** file two PRs both touched (the squad boundaries otherwise held
perfectly). Each PR showed `MERGEABLE` against the *unchanged* base, but the first merge makes the
second conflict. Resolution: pick a deterministic merge order, keep the **first-merged** ADR number,
and have the **later** merger renumber to the next free number (`0010`) while resolving the
`DECISIONS.md` conflict during its `git merge origin/main`.

**Prevention:** reserve ADR/migration/issue numbers up front per squad (e.g. A=0009-0019, B=0020-0029),
**or** treat any append-only shared ledger (`DECISIONS.md`, a CHANGELOG, a migrations dir) as a *known
append-conflict* the last merger resolves by renumbering — never assume disjoint file sets means no
conflict.

## 6. Reconcile the board before re-planning — PRs must `Closes #NN`

After the first round, **53 issues were merged-but-still-open** because the squad PRs never wrote
`Closes #NN`. An accurate tracker is a prerequisite for "what's the next story?" — you cannot pull the
next item off a board that lies about what's done. Fix: bulk-close the verified-done issues (grounded
in a codebase audit, not the tracker), and make every future PR body carry `Closes #NN` so merges
auto-close.

While bulk-closing, the **zsh word-split gotcha recurred** (see
[shell-portability-in-agent-batch-automation](../best-practices/shell-portability-in-agent-batch-automation.md)):

```bash
DONE="39 40 41 …"
for i in $DONE; do gh issue close "$i"; done   # zsh: $DONE is ONE word → loop runs ONCE with the whole string
```

zsh does **not** word-split unquoted `$DONE` (bash does). The loop silently closed **0** issues. Fix:
inline the literals (`for i in 39 40 41 …`) or force splitting (`for i in ${=DONE}`).

## When to Apply

Any multi-agent/multi-squad parallel build that merges into one trunk; any CI with advisory jobs; any
manual git-worktree use; any eval gate for a safety/"never silently" invariant.
