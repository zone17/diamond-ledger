---
title: Spec Kit + CI/merge-gate gotchas (branch naming, --no-review token, build/ ignore)
date: 2026-06-01
category: conventions
module: spec-kit / ci / git
problem_type: convention
component: development_workflow
severity: medium
applies_when:
  - Creating a Spec Kit feature branch and opening a PR
  - Merging a PR that the CE-review gate blocks
  - Adding a directory of source files that you need committed
tags: [spec-kit, branch-naming, ci, git-hooks, gitignore, merge-gate]
---

# Spec Kit + CI/merge-gate gotchas

## Context

Three small, recurring process frictions hit while shipping the first feature spec + prototype through
PRs. Each cost a wasted CI round or a silently-dropped file the first time. Documented so they cost
seconds next time.

## Guidance

**1. Spec Kit `NNN-feature` branches fail the Article XVIII branch-name CI check — rename them.**
`speckit.git.feature` creates branches like `001-voice-scorebook-core`, but the CI branch-name job
enforces `^(feat|fix|docs|refactor|chore|ci|test|perf|build|spike)/[a-z0-9-]+/[A-Z]+-[0-9]+-[a-z0-9-]+$`.
The `NNN-` form has no slashes and starts with a digit, so it always fails. Rename to the typed form
and rely on `.specify/feature.json` (which records the feature directory and is **branch-independent**)
to keep the Spec Kit linkage intact:

```sh
git branch -m 001-voice-scorebook-core feat/product/DL-001-voice-scorebook-core
# verify speckit still resolves the feature dir:
.specify/scripts/bash/check-prerequisites.sh --json --paths-only
```

(This recurred twice — PR #10 docs branch and the spec branch. A future fix: teach the CI regex to
accept Spec Kit `NNN-` branches, or have `speckit.git.feature` emit a compliant name.)

**2. The CE-review merge gate's `--no-review` bypass must be hidden from `gh`, not passed to it.**
`security-gate-bash.sh` blocks `gh pr merge` until `/ce:review` runs; the documented bypass for
docs/config-only changes is the token `--no-review`. But `gh pr merge` has **no such native flag** and
errors on it. The hook greps the command string, so place the token in a trailing shell comment — the
hook sees it, `gh` never parses it:

```sh
gh pr merge 12 --squash --delete-branch  # --no-review : docs/spec only, vetted by spec-coherence probe
```

Use the bypass only for genuinely trivial/non-production changes (docs, config, throwaway prototype),
and state the justification in the comment.

**3. `.gitignore` `build/` silently swallows any directory named `build/`.**
A prototype placed in `prototype/build/` was silently excluded — `git add` reported nothing and the
files never staged (no error). Confirm with `git check-ignore -v <path>`. Name source directories
something else (we used `app/`), or force-add intentionally with `git add -f`.

## Why This Matters

Each failure mode is *silent or delayed*: a red CI round after the fact, an unknown-flag error, or
files that vanish from a commit with no warning. They erode trust in the toolchain and waste cycles.
None is hard once you know it; all three are invisible until they bite.

## When to Apply

- Every Spec Kit feature: rename the branch before the first push/PR.
- Every gated merge of a docs/config/prototype PR: use the commented `--no-review` token.
- Any time `git add <dir>/` stages nothing unexpectedly: `git check-ignore -v` it.

## Related

- `docs/solutions/design-patterns/spec-coherence-probe.md`
- `DECISIONS.md` ADR-0002 (advisory CI + hook-based branch protection), ADR-0004 (branch discipline).
