---
module: cross-cutting
date: 2026-06-02
last_updated: 2026-06-02
problem_type: best_practice
component: development_workflow
severity: medium
applies_when:
  - "Looking for a previously-solved P2/P3 process, tooling, or convention problem before redoing it"
tags:
  - common-solutions
  - index
  - workflow
  - tooling
  - conventions
---

# Common Solutions (P2/P3) — Diamond Ledger

Canonical index of recurring P2/P3 solutions. Each row points to the detailed doc; the checklist is
the fast path. Add a row when a new P2/P3 learning is compounded.

## Index

| # | Solution | Class | Detailed doc |
|---|----------|-------|--------------|
| 1 | Shell portability in agent batch automation (zsh + BSD tools) | P2 | [best-practices/shell-portability-in-agent-batch-automation](../best-practices/shell-portability-in-agent-batch-automation.md) |
| 2 | GitHub native sub-issue trees via `gh` (database id, not number) | P3 | same as #1 (recipe section) |
| 3 | `/watch-ci`: `skipped` ≠ `failure`; gate re-arms per push/PR/merge | P3 | [workflow-issues/watch-ci-gate-choreography](../workflow-issues/watch-ci-gate-choreography.md) |
| 4 | Spec Kit branch naming + merge-gate gotchas | P2 | [conventions/speckit-branch-naming-and-merge-gotchas](../conventions/speckit-branch-naming-and-merge-gotchas.md) |
| 5 | Enforcement-hook command-string matching pitfalls | P2 | [best-practices/hook-command-string-matching-pitfalls](../best-practices/hook-command-string-matching-pitfalls.md) |
| 6 | Spec-coherence probe (break a spec before building) | P2 | [design-patterns/spec-coherence-probe](../design-patterns/spec-coherence-probe.md) |
| 7 | Private-repo branch-protection fallback (hooks, not rulesets) | P3 | [conventions/private-repo-branch-protection-fallback](../conventions/private-repo-branch-protection-fallback.md) |
| 8 | Verify generated code with the real toolchain (not static review); Cargo workspace + advisory-CI gotchas | P2 | [best-practices/verify-generated-code-with-real-toolchain](../best-practices/verify-generated-code-with-real-toolchain.md) |
| 9 | Parallel-squad integration: advisory CI masks merge failures · worktrees outside the repo (+ `git -C` space-path footgun) · gate the cardinal invariant not a proxy · **green CI ≠ correct — the review gate catches real P1s on every PR** · ADR-number collision (renumber the later merger) · board reconciliation (`Closes #NN`) | P2 | [workflow-issues/parallel-squad-integration](../workflow-issues/parallel-squad-integration.md) |
| 10 | SwiftUI swipe-dismissible `.sheet` must reconcile owner state in `onDismiss` (button handlers don't run on gesture-dismiss) | P2 | [ui-bugs/swiftui-sheet-ondismiss-state-reconciliation](../ui-bugs/swiftui-sheet-ondismiss-state-reconciliation.md) |

## Checklists (fast path)

**#1 Batch automation (issues/files/API in a loop):** write a `#!/usr/bin/env bash` **file** (the Bash
tool runs zsh — no bash arrays inline); parse with `perl -pe`, not BSD `sed` label loops; `set -euo
pipefail` + assert non-empty inputs; **create one, read it back, then batch**; repair with
`gh issue edit` (don't delete).

**#2 Native sub-issues:** `child_id=$(gh api repos/$R/issues/$n --jq .id)` then
`gh api -X POST repos/$R/issues/$PARENT/sub_issues -F sub_issue_id=$child_id`. Tree =
epic-per-squad → stories → subtasks; labels + milestone carry cross-cutting views.

**#3 watch-ci:** clear the gate with `gh run list --limit 3`; read run-level `.conclusion` AND literal
per-job conclusions — `skipped` is fine (e.g. a `pull_request`-only job on a `main` push), only
`failure`/`cancelled`/`timed_out` matter; never auto-fix a `main` failure. **A `continue-on-error` job
fails while the run stays green — always read per-job.**

**#8 Verify generated code:** install the real toolchain locally (`rustup` ~2 min) and run
`cargo check --workspace --all-targets` + `cargo clippy -- -D clippy::float_arithmetic` before merging —
don't trust an agent's static review or an advisory CI job. Cargo workspace root must sit ABOVE its
members (repo-root `/Cargo.toml` when members are siblings); pin a toolchain that builds dev-deps too.

**#4 Branches:** never `NNN-feature` (fails the Article XVIII CI regex) — use
`{type}/{squad}/{TICKET}-{slug}`; `docs/*` auto-bypasses the CE-review merge gate; bypass for
docs/trivial with a trailing `# --no-review : <reason>` on the `gh pr merge` line.

**Meta — surface decisions, don't silently pick:** for consequential architecture forks, present the
options to the human with a sourced recommendation (AskUserQuestion) and record the choice in an ADR;
run `/speckit-analyze` as the independent cross-artifact review for planning-doc PRs (it satisfies the
Article XX review, justifying a `--no-review` docs-only merge).

---

*See [critical-patterns.md](./critical-patterns.md) for P1 invariants. Project map:
[`docs/PROJECT_CONTEXT.md`](../../PROJECT_CONTEXT.md).*
