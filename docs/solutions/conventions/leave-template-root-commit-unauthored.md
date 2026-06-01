---
module: development-workflow
date: 2026-06-01
problem_type: convention
component: development_workflow
severity: low
applies_when:
  - "Asked to re-author git commits to a different identity"
  - "The target includes the repo's initial/root commit from a third-party template"
tags:
  - git
  - authorship
  - force-push
  - branch-discipline
  - root-commit
---

# Don't re-author the template root commit — it needs a force-push and isn't yours

## Context

When asked to set commit authorship to the user's GitHub identity, the repo's first commit
(`Initial commit from Specify template`) is tempting to re-author too. Two reasons not to.

## Guidance

1. **It can't be done safely.** Re-authoring the root commit rewrites every subsequent SHA and
   requires a **force-push to `main`** — hard-blocked by `security-gate-bash.sh` and prohibited by
   the constitution (Article XXVI). Feature-branch commits that haven't merged can be re-authored
   freely (`git rebase <base> --exec "git commit --amend --reset-author --no-edit"`, after stashing
   unrelated working-tree changes), but the published root on `main` cannot.
2. **It isn't honest.** That commit is a third-party scaffold import. Stamping your identity on it
   misrepresents authorship. Leave template/vendored import commits as their original author.

For attribution of your *own* commits when the GitHub account email is private, use the GitHub
no-reply form `ID+login@users.noreply.github.com` (get `ID` from `gh api user --jq .id`) — it
attributes to the account without leaking a personal email into public history.

## Why This Matters

Avoids a pointless fight with a security hard-gate and keeps git history truthful about who wrote
what. An honest provenance trail is worth more than uniform authorship.

## When to Apply

Any "author these as me" request where the range includes a vendored/template import commit, or any
attempt to rewrite already-published `main` history.

## Examples

```bash
gh api user --jq '{id,login}'        # → 3618627 / zone17  (email private)
git config user.email "3618627+zone17@users.noreply.github.com"
# re-author only the unmerged feature commits:
git stash -u && git rebase <root> --exec "git commit --amend --reset-author --no-edit" && git stash pop
# leave the root commit alone — re-authoring it would require a blocked force-push to main
```
