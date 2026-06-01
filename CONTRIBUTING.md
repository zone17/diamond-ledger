# Contributing to Diamond Ledger

Diamond Ledger is an **agent-native capability system**. All work — human or agent — is governed by
the constitution at [`.specify/memory/constitution.md`](.specify/memory/constitution.md). Read it
before contributing; it is binding. This file summarizes the workflow mechanics.

## Workflow: Compound Engineering (Article IX)

Every non-trivial change passes through **Brainstorm → Plan → Work → Review → Compound**. State the
loop depth before implementing. ~80% of effort is planning, verification, and review; ~20% is code.

## Branch discipline (Article XVIII)

- **Never commit or push directly to `main`.** All work lands via pull request.
- Branch names MUST match `{type}/{squad}/{ticket}-{slug}`, e.g.
  `feat/platform/PLAT-142-record-pitch-tool`, `docs/architecture/ARCH-033-capability-registry`.
- Allowed `type` values: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, `test`, `perf`, `build`,
  `spike`.

### One-time setup

Enable the repo-managed git hooks (blocks direct commits to `main`/`master` from any path —
ADR-0004):

```bash
git config core.hooksPath .githooks
```

### How `main` is protected

This repository is **private on the GitHub free plan**, where server-side rulesets are unavailable
(see [`DECISIONS.md`](DECISIONS.md) ADR-0002). Protection is therefore enforced by **local hooks**
(`~/.claude/hooks/enforcement/`), the constitution's sanctioned "repository-managed equivalent"
(Article XXXIX):

- `branch-discipline.sh` — hard-blocks `git commit` / `git push` on `main`.
- `security-gate-bash.sh` — blocks force-pushes and destructive commands.

If the repo later moves to public or GitHub Pro, add a `main` ruleset (require PR, required status
checks, no force-push, no deletion, linear history) and require the CI checks below.

## Continuous integration (advisory)

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every PR and push to `main`. Because
required status checks are unavailable on this plan, CI is **advisory** — it informs review and
MUST be green before merge by convention. Jobs map to the constitution's Enforcement Matrix:

| Job | Enforces |
|-----|----------|
| `governance` | Constitution integrity + `DECISIONS.md` presence (Articles XVI, XXXVIII, XL) |
| `branch-name` | Typed squad branch naming (Article XVIII) |
| `secret-scan` | No committed secrets (Articles XXVI, XXXVI) |

After any push, PR update, or merge, run `/watch-ci` to monitor the pipeline.

## Compound loop after merges (Articles XVI, XXII)

A project hook closes the Continuous Improvement Flywheel. After a `gh pr merge`,
`.claude/hooks/compound-flag.sh` arms `.claude/.needs-compound`; the `Stop` hook
(`compound-reminder.sh`) then blocks the session from ending **once** until you run the compound
step:

```
/ce-compound
```

Running it captures non-obvious learnings into `docs/solutions/` and auto-clears the gate. For a
genuinely trivial merge, skip by deleting the flag: `rm .claude/.needs-compound`. See
[`DECISIONS.md`](DECISIONS.md) ADR-0003. To disable entirely, remove the hook entries from
`.claude/settings.json`.

## Architectural changes (Article XXXVIII)

Any architectural change — new tools, endpoints, agents, skills, migrations, dependencies,
permission/event-schema changes, infrastructure, or deployment-model changes — MUST add an entry to
[`DECISIONS.md`](DECISIONS.md) (newest at the top).

## Definition of Done

A change is not done until it satisfies the 25-point Definition of Done and answers the 20
Pull-Request Review Questions in the constitution. Both are reproduced there — review them before
opening a PR.

## Merging

- Merge via **squash or rebase** (linear history is the convention).
- Keep PRs focused — one concern per PR (Article XL).
- Run an independent review (`/code-review` or `/ce:review`) proportional to risk (Article XX).
