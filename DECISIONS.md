# Architecture Decision Record (DECISIONS.md)

This file records architectural and governance decisions for Diamond Ledger, per Article XXXVIII
of the constitution (`.specify/memory/constitution.md`). Each entry is append-only; supersede
rather than rewrite. Newest decisions at the top.

---

## ADR-0003 — Compound-Loop Gate (Continuous Improvement Flywheel)

- **Status:** Accepted
- **Date:** 2026-05-31
- **Owner:** Project lead (zone17)
- **Review date:** 2026-08-31

### Context

The constitution mandates a Continuous Improvement Flywheel (Article XXII) and that non-obvious
knowledge be captured after work completes (Article XVI). Relying on instructions alone to "always
run ce-compound" fails the moment agent context is compacted — the exact failure mode Article XXXIX
addresses by requiring mechanical enforcement.

### Problem

Nothing in the repository ensured the compound step actually ran after a unit of work landed, so
learnings risked being lost.

### Decision

Add a project-scoped, version-controlled hook pair that ties compounding to the natural milestone of
a **merged pull request**:

- `.claude/hooks/compound-flag.sh` (PostToolUse, all tools): arms `.claude/.needs-compound` after a
  `gh pr merge`; clears it after the ce-compound skill runs.
- `.claude/hooks/compound-reminder.sh` (Stop): if the flag is set, blocks the stop **once** and
  instructs the agent to run `/ce-compound`. Loop-safe via `stop_hook_active`; bypass by deleting
  the flag for genuinely trivial merges.
- Wired in `.claude/settings.json`; flag is git-ignored (runtime state).

Trigger chosen: **merge-triggered** (not every commit) — fires at a meaningful milestone and avoids
nagging on intermediate commits. Scope: **project** — committed so it travels with every clone
(Article XXXIX repository-managed equivalent).

### Alternatives Considered

- **Soft Stop reminder only.** Rejected: on `Stop` the agent has already decided to finish, so a
  non-blocking message wouldn't reliably cause the loop to run.
- **Hard gate on every commit.** Rejected: too noisy; most commits are intermediate.
- **Global hook (~/.claude).** Rejected here: the user chose project scope so it's versioned with
  Diamond Ledger; a global variant remains possible later.
- **Instruction in CLAUDE.md.** Rejected: not mechanically enforceable (Article XXXIX).

### Tradeoffs

Blocking a stop is intrusive by design; mitigated by being one-shot per stop sequence, clearing
automatically when ce-compound runs, and a documented one-file bypass. Detection is substring-based
(no jq dependency) for portability, at the cost of theoretical false matches — acceptable for a
local developer hook.

### Consequences

- After every merge, the session cannot quietly end without either compounding or an explicit skip.
- Learnings accrue in `docs/solutions/` over time, feeding the flywheel.

### Reversibility

High. Remove the two hook entries from `.claude/settings.json` (or the scripts) to disable; downgrade
to a soft reminder by changing the Stop hook's `decision: block` to a non-blocking message.

### Impact

- **Operational:** Adds a post-merge compound ritual.
- **Agent-native:** Both hooks are plain bash any agent can read and reason about.
- **Security:** No new authority; reads hook payloads, writes a single local flag file.

### Follow-ups (deferred)

- Consider extending the trigger to debugging/non-trivial non-PR work if learnings are being missed
  (the merge-only trigger's known gap).

---

## ADR-0002 — Software Factory: CI Enforcement + Hook-Based Branch Protection

- **Status:** Accepted
- **Date:** 2026-05-31
- **Owner:** Project lead (zone17)
- **Review date:** 2026-08-31 (revisit if repo goes public or upgrades to GitHub Pro)

### Context

Immediately after ratifying the constitution (ADR-0001), the repository needed its "software
factory" — the enforcement infrastructure the constitution mandates (Articles XXXIV, XXXIX) — before
feature work begins. The repo is **private on the GitHub free plan**, and the Spec Kit toolchain
(extensions, git skills, scripts, workflows) was sitting uncommitted.

### Problem

1. Constitutional rules (branch discipline, no secrets, governance integrity) were enforced only by
   local hooks on one machine, with nothing in the repository itself.
2. GitHub server-side rulesets/branch protection returned `403 — Upgrade to GitHub Pro or make this
   repository public` on the private free plan, so the planned `main` ruleset could not be created.
3. The Spec Kit scaffolding was untracked, making the environment non-reproducible (Article XXXV).

### Decision

- **Commit the Spec Kit scaffolding** (`.specify/extensions*`, `.specify/workflows/`,
  `.specify/init-options.json`, `.claude/skills/speckit-git-*`, executable-bit changes on
  `.specify/scripts/*.sh`) so the toolchain is reproducible and version-controlled.
- **Add `.github/workflows/ci.yml`** — an advisory CI pipeline whose jobs map directly to the
  Enforcement Matrix: `governance` (constitution + DECISIONS integrity), `branch-name` (Article
  XVIII naming), `secret-scan` (gitleaks, full history).
- **Adopt hook-based branch protection** as the Article XXXIX "repository-managed equivalent":
  local `branch-discipline.sh` + `security-gate-bash.sh` hard-block direct/force pushes to `main`.
  Document the PR-only convention in `CONTRIBUTING.md`.
- **Add a root `.gitignore`** (OS junk, secrets, local agent memory, forward-looking build
  artifacts).

### Alternatives Considered

- **Make the repo public to unlock free rulesets.** Rejected by owner: keep private for now.
- **Upgrade to GitHub Pro for private rulesets.** Rejected for now: not worth the cost at this
  stage; revisit at the review date.
- **Use the GitHub Actions `gitleaks-action`.** Rejected: it requests a license key for
  organizations; the pinned `zricethezav/gitleaks` CLI image is free and reproducible.

### Tradeoffs

CI is **advisory, not blocking** — without server-side required status checks, a determined local
actor could merge a red PR. Mitigated by: local hooks (the real hard gate today), `/watch-ci`
discipline, and a documented upgrade path. Accepted as proportionate for a solo, pre-product repo.

### Consequences

- The toolchain and enforcement live in the repo and travel with every clone.
- Every PR runs governance, branch-name, and secret-scan checks.
- Future work: if the repo goes public or Pro, add a `main` ruleset and mark the CI checks
  **required**.

### Reversibility

High. CI and `.gitignore` are editable; hook-only protection swaps cleanly to a server-side ruleset
when the plan allows.

### Impact

- **Security:** Adds secret scanning and codifies destructive-op / branch hard-blocks.
- **Operational:** Establishes `/watch-ci` as the post-push ritual.
- **Reproducibility:** Scaffolding is now version-controlled.
- **Agent-native:** CI checks are plain bash any agent can read, run, and reason about.

### Follow-ups (deferred, not blocking)

- Pin GitHub Actions to commit SHAs (currently major-version tags) — Article XXXVI.
- Add markdown structural linting once a noise-free config is tuned.
- Add a `DECISIONS.md`-changed-when-architectural-files-change check in CI (today enforced by the
  local `decision-gate.sh` hook).
- Promote CI checks to **required status checks** if the repo becomes public or Pro.

---

## ADR-0001 — Ratify the Diamond Ledger Engineering Constitution

- **Status:** Accepted
- **Date:** 2026-05-31
- **Owner:** Project lead (cryptozone1723@gmail.com)
- **Review date:** 2026-11-30 (6-month review)

### Context

Diamond Ledger is being built as an agent-native capability system — a composable graph of small,
permissioned, discoverable primitives usable by humans, agents, CLIs, APIs, and future interfaces —
rather than a traditional UI-first application with AI bolted on. Before any code lands, the project
needs a single binding engineering authority governing architecture, agent behavior, security,
testing, evaluation, documentation, branch discipline, CI/CD, observability, and the definition of
done.

### Problem

Without a ratified, enforceable standard, agent-generated work drifts: UI-only features bypass
agent parity, critical invariants get enforced only by prompts, knowledge fails to compound, and
branch/security discipline depends on willpower that context compaction erodes.

### Decision

Ratify the constitution at `.specify/memory/constitution.md` (v1.0.0) as the highest-level durable
engineering authority for the repository. It defines 40 articles, an enforcement matrix, 20
pull-request review questions, a 25-point definition of done, and governance with semantic
versioning.

### Alternatives Considered

- **No formal constitution; rely on global CLAUDE.md + ad-hoc review.** Rejected: not project-scoped,
  not versioned, no enforcement matrix, weak under context loss.
- **A short principles list (5–7 bullets).** Rejected: insufficient for an agent-native system where
  tool contracts, deterministic policy boundaries, memory safety, and harness engineering each need
  explicit, testable rules.
- **Defer until first code exists.** Rejected: the constitution's value is shaping the first
  capability, not retrofitting after patterns set.

### Tradeoffs

A comprehensive 40-article document carries process overhead and a learning curve. Mitigated by the
constitution's own "depth is the only variable" rule (Article IX) — lightweight loops for low-risk
work — and by the enforcement matrix distinguishing hard blocks from soft reminders.

### Consequences

- All non-trivial work passes Brainstorm → Plan → Work → Review → Compound (Article IX).
- New tools require contract-first design and contract tests (Articles I, XI).
- Agent-native parity, deterministic policy at tool boundaries, and risk-tiered autonomy become
  review gates (Articles II, VII, XXV, XXVIII).
- This DECISIONS.md must be updated for every future architectural change.

### Reversibility

High at this stage (no dependent code). Amending or relaxing articles follows the constitution's
own governance + semantic-versioning procedure.

### Impact

- **Migration:** None (greenfield).
- **Security:** Establishes hard gates for destructive ops, secrets, branch discipline, untrusted
  content, and tool-call policy.
- **Operational:** Introduces CI gates, CI-watch, and observability expectations before broad
  release.
- **Agent-native:** Core intent — agents are first-class users with full parity.
- **Cost:** Adds planning/review overhead, scoped by loop depth.

### Follow-ups (deferred, not blocking)

- Seed `PROJECT_CONTEXT.md` when the first capability/architecture lands.
- Seed `docs/solutions/patterns/critical-patterns.md` and `common-solutions.md` on first compounded
  learning.
- Stand up CI enforcement (branch protection, secret/dependency scanning, contract-test + eval
  gates) per the Enforcement Matrix.
