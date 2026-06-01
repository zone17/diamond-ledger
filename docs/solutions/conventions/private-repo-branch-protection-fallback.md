---
module: development-workflow
date: 2026-06-01
problem_type: convention
component: development_workflow
severity: medium
applies_when:
  - "Setting up branch protection on a private GitHub repo on the free plan"
  - "gh api .../rulesets returns HTTP 403 'Upgrade to GitHub Pro or make this repository public'"
tags:
  - branch-protection
  - rulesets
  - github
  - private-repo
  - hooks
---

# Private free-plan repos can't use server-side rulesets — fall back to local hooks

## Context

Creating a branch-protection ruleset via `gh api -X POST repos/{owner}/{repo}/rulesets` on a
**private** repo on the GitHub **free** plan returns:

```json
{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}
```

Server-side branch protection / rulesets require a public repo or a paid plan.

## Guidance

When server-side protection is unavailable and the repo must stay private, treat **local
enforcement hooks as the sanctioned equivalent** (constitution Article XXXIX — "use
repository-managed equivalents where global hooks cannot be committed"):

- `branch-discipline.sh` hard-blocks direct `git commit`/`git push` on `main`.
- `security-gate-bash.sh` blocks force-pushes and destructive commands.

Document the decision (an ADR), note in `CONTRIBUTING.md` that protection is hook-based and that CI
is **advisory** (no required status checks without server-side protection), and record the upgrade
path: if the repo goes public or to Pro, create the ruleset and mark CI checks required.

## Why This Matters

It is easy to assume `gh api .../rulesets` "just works" and silently ship an unprotected `main`.
Naming the constraint, choosing hooks explicitly, and writing the upgrade path keeps the protection
story honest and reversible rather than an unspoken gap.

## When to Apply

Any private repo on the free plan that wants branch protection. Also a prompt to weigh public-vs-Pro
early, since both unlock the feature for free/cheap.

## Examples

```bash
# fails on private free plan:
gh api -X POST repos/zone17/diamond-ledger/rulesets --input ruleset.json
# → 403 Upgrade to GitHub Pro or make this repository public

# fallback already in place (local hooks); verify they fire:
git commit -m x        # → blocked by branch-discipline.sh on main
```
