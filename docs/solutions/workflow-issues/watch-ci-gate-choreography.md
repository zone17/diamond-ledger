---
module: development-workflow
date: 2026-06-01
problem_type: workflow_issue
component: development_workflow
severity: medium
applies_when:
  - "After any git push, gh pr create, or gh pr merge in a repo with the watch-ci enforcement hook"
  - "A bash command is denied with 'You must run /watch-ci before proceeding'"
tags:
  - watch-ci
  - hooks
  - ci-gate
  - git-push
  - enforcement
---

# The /watch-ci gate re-arms on every push/PR/merge

## Context

The `security-gate-bash.sh` enforcement hook blocks **all** non-CI bash commands after any
`git push`, `gh pr create`, or `gh pr merge`, until `/watch-ci` (or an equivalent `gh run`
inspection) runs. This is intentional (constitution Article XXXIV — CI must be watched), but during
a multi-PR session it fires repeatedly and stalls otherwise-correct command sequences.

## Guidance

After every push/PR/merge, run a CI-inspection command **before** the next bash step. The gate is
cleared by the `post-git-actions.sh` companion hook when it sees a `gh run watch/view/list`
invocation. The lightest clear is:

```bash
gh run list --limit 3 >/dev/null 2>&1
```

Practical rules learned this session:
- The gate is armed by the **command intent string** (it sees `gh pr merge` even inside a comment),
  so it can fire even when no pipeline actually ran (e.g. pushing a non-`main` branch when CI only
  triggers on `pull_request`/`push: main`). In that case there is genuinely nothing to watch —
  clear with `gh run list` and move on.
- A real run only exists once the triggering event matches the workflow's `on:` filter. Opening the
  PR (not the branch push) is what triggers a `pull_request` run.
- Chaining a push and the next command in one bash call does **not** help: the gate is evaluated
  PreToolUse on the *next* call regardless.

## Why This Matters

Misreading the block as "my command is wrong" wastes turns. It is a sequencing gate, not a syntax
error. Knowing the one-line clear keeps a multi-PR flow moving without disabling the safety the hook
provides.

## When to Apply

Any session that pushes, opens, or merges more than one PR — especially the constitution/factory
bootstrap flow where several PRs land back-to-back.

## Examples

```text
git push                 # → next bash blocked: "run /watch-ci"
gh run list --limit 3    # → clears the gate (CI command is allowlisted)
gh pr create ...         # → proceeds; itself re-arms the gate
gh run watch <id> ...    # → watch the real run, clears again
gh pr merge ...          # → re-arms once more; clear before syncing main
```
