# Architecture Decision Record (DECISIONS.md)

This file records architectural and governance decisions for Diamond Ledger, per Article XXXVIII
of the constitution (`.specify/memory/constitution.md`). Each entry is append-only; supersede
rather than rewrite. Newest decisions at the top.

---

## ADR-0006 — Build Authorized Ahead of the A1/A3 Demand Gate (Override → Parallel Instrument + Tripwires)

- **Status:** Accepted
- **Date:** 2026-06-01
- **Owner:** Project lead (zone17)
- **Review date:** 2026-07-31 (the original A1/A3 falsification deadline — first tripwire review)
- **Relates to:** `specs/001-voice-scorebook-core/` (spec + `probe-report.md`); discovery
  (`docs/product/discovery/`); experiments (`docs/product/experiments/`)

### Context

Discovery set a falsification **gate**: building the rules engine was to wait on the A1/A3 demand
smoke-test clearing **≥8% commitment by 2026-07-31**. The riskiest assumption — serious/official
scorekeepers will *switch to and pay for* voice→Retrosheet scoring, and Retrosheet export is valued
beyond the SABR niche — is rated **importance-high / evidence-low (confidence L)**. The
spec-coherence probe (`probe-report.md`) separately de-risked **feasibility** (the deterministic
core is buildable). The project lead has decided to **build regardless of the A1/A3 outcome** — a
founder-conviction bet grounded in lived domain pain (scored own child's games tee-ball→college) and
the judgment that a fake-door landing page under-measures a novel "feel-it-to-get-it" voice product
(genuine false-negative risk).

### Decision

Authorize the v1 build to proceed **ahead of, and independent of,** the A1/A3 demand gate. The gate
is **not removed** — it is **reframed from a hard go/no-go into a parallel instrument** run alongside
the build, with **pre-committed tripwires** (defined below, before data arrives) so any
course-correction stays evidence-driven rather than goalpost-moving.

**Risk explicitly accepted (Art. VI):** engineering the rules engine + mobile app (the main upfront
investment per the PR/FAQ) may be spent before the riskiest, confidence-L assumption
(paying-beachhead adoption) is validated. A correct engine with weak adoption is the accepted
downside; building does not, by itself, move adoption.

**Mitigations adopted ("decouple, don't override"):**
1. **Run A1/A3 in parallel anyway** (cheap: ~$1–3k + ~30 hrs) — keep the demand instrument live; do
   not go blind.
2. **Sequence the build so the first shippable artifact is demoable to ~20 real serious scorers** —
   turning the build into a stronger demand signal than the fake-door (directly tests the
   false-negative hypothesis).
3. **Keep the most expensive engine work deferred** (full Rule 9.16 earned-run reconstruction —
   already out of v1 scope) until early adoption signal exists.

### Tripwires (pre-committed 2026-06-01; reviewed 2026-07-31)

- **Demand:** if by 2026-07-31 A1/A3 commitment is **<8% AND <8/20** interviewed scorers show a
  commitment signal → **pause net-new engine investment beyond the demoable slice**; re-segment or
  evaluate the discovery-named pivot (archivist score-from-video) before committing further months.
- **Distribution:** if **~20 real serious scorers cannot be put in front of the demoable slice**
  within the build window → treat as an access/GTM red flag and reassess go-to-market before scaling.
- **Usability:** if the demoable slice's per-game correction rate is high enough that test scorers
  abandon (fails the SC-005 attention bar / SC-010 retention intent) → stop and fix the loop before
  building further (the A5 concern).
- Any tripwire trip triggers an **explicit, documented continue / redirect / pause decision** — never
  silent continuation.

### Alternatives Considered

- **Honor the gate (build only if A1/A3 passes).** Rejected by the project lead: founder conviction +
  fake-door false-negative risk for a novel voice product.
- **Drop A1/A3 entirely.** Rejected: discards a cheap behavioral signal for no benefit; willful
  blindness is strictly worse than parallel measurement.
- **Build the full engine first (incl. Rule 9.16) before any demand signal.** Rejected: maximizes
  sunk cost on the least-validated bet.

### Consequences / Reversibility

Planning (`/speckit.plan`) and the v1 build are unblocked now. **Reversible at the tripwire reviews**
— the parallel instrument + tripwires preserve the ability to pivot on evidence rather than lock in
sunk cost. No code/schema impact (governance decision).

### Impact

- **Process:** converts a hard gate into a monitored, tripwired parallel instrument; preserves the
  constitution's *test-before-build* intent in spirit (the test continues; the build no longer blocks
  on it) while honoring an explicit, auditable founder-conviction override (Articles VI, IX, XXV,
  XXXVIII).
- **Honesty (Art. VI):** the accepted risk and the false-negative rationale are recorded, not hidden.
- **Cost:** engineering spend begins before demand validation — the accepted risk.

---

## ADR-0005 — Compound-Gate Recursion Backstop: Don't Resolve Volatile Context via a Racing Live Call

- **Status:** Accepted
- **Date:** 2026-06-01
- **Owner:** Project lead (zone17)
- **Review date:** 2026-09-01
- **Amends:** ADR-0004 (compound-gate recursion fix)

### Context

ADR-0004 stopped `compound-flag.sh` from arming on `docs/*` merges (so the merge of the compound
docs themselves wouldn't ask to "compound the compound step"). It resolved the merged PR's head
branch with a **live `gh pr view <n> --json headRefName`** at hook time, and on any failure fell
through and armed (safe default).

Dogfooding exposed the gap: after `gh pr merge <n> --squash --delete-branch`, that live lookup
**races the branch deletion / merge-API propagation**. In a real session the lookup returned empty
for the just-merged compound-doc PR (a `docs/*` branch), so the `docs/*` skip never fired and the
gate armed on the compound step's own merge — the exact recursion ADR-0004 set out to prevent. (The
armed flag even read `merged_at=unknown`, since the hook ran under macOS bash 3.2, which lacks
`EPOCHSECONDS`.) The general defect: **a hook that re-fetches volatile context via a network call
races the very action that triggered it.**

### Decision

`compound-flag.sh` keeps the `docs/*` skip but makes resolution authoritative and adds an
**identity** backstop, covered by 24 assertions in `test-compound-hooks.sh` and the CI `hooks-test`
job:

1. **`gh pr view` is authoritative** for the head ref (primary `docs/*` skip).
2. **Anchored no-network fallback.** Only when `gh` is unavailable/empty, parse the head ref from
   `tool_response`, anchored to gh's real success line `Deleted branch <ref> and switched to branch`
   — so a stray `Deleted branch docs/x` substring elsewhere in the payload cannot fabricate a skip.
3. **Identity backstop (not a clock).** When the ce-compound Skill clears the flag, write an
   *await* marker (`.claude/.compound-done`). The compound doc's own `gh pr create` (while the
   await marker is fresh, ≤1h) captures its **PR number** from the printed `.../pull/<n>` URL. The
   merge of **exactly that PR number** is then skipped — robust even if `gh pr view` races to empty,
   and it can never suppress a *different* (substantive) merge. Timestamps use portable `date +%s`.

**Note — the first attempt was caught by code review.** An initial version parsed `Deleted branch`
from the *whole payload* with a bare substring grep and let it override the live lookup. The
`ce-adversarial-reviewer` flagged (P2) that this **reintroduced ADR-0004's own documented pitfall #1**
(scanning the whole payload for a trigger phrase causes false matches) — a `docs/*` mention anywhere
could suppress a non-docs reminder — and that a time-window marker could suppress a legitimate
substantive merge. Both were corrected to the authoritative + anchored + identity design above
before merge. Independent verification (Article XX) earned its keep here.

### Alternatives Considered

- **Whole-payload `Deleted branch` grep overriding gh (first attempt).** Rejected after review:
  reintroduced the false-match pitfall the change set out to document.
- **Time-window suppression of the next unresolved merge.** Rejected: suppresses by clock, so a
  real substantive merge with a transiently-unresolved ref in the window loses its reminder.
  Identity (PR number) suppresses exactly the compound doc's merge and nothing else.
- **Retry the `gh` lookup with a sleep.** Rejected: latency on every merge, still probabilistic.

### Consequences / Reversibility

The compound gate stops self-triggering on its own documentation merge even under the lookup race;
ordinary `docs/*` merges and substantive merges behave as before. High reversibility — revert the
hook + test edits and delete the marker line from `.gitignore`. No data/schema impact.

### Impact

- **Operational:** removes a spurious post-merge compound reminder (the one that fired this session).
- **Agent-native:** plain bash with `COMPOUND_TEST_HEAD_REF` + a `gh` PATH stub make every branch
  exercisable offline; learning generalized in
  `docs/solutions/best-practices/hook-command-string-matching-pitfalls.md`.
- **Security:** no new authority; reads the hook payload, writes two local flag files.

---

## ADR-0004 — Hook Hardening: Branch-Discipline Defense-in-Depth + Compound-Gate Recursion Fix

- **Status:** Accepted
- **Date:** 2026-06-01
- **Owner:** Project lead (zone17)
- **Review date:** 2026-09-01

### Context

Two gaps surfaced via independent review (ADR-0002) and dogfooding (ADR-0003):

1. The vendored `auto-commit.sh` wraps `git commit`, so the command-string `branch-discipline.sh`
   hook can't see it — an auto-commit could land on `main` (Article XVIII bypass).
2. The compound-loop gate (ADR-0003) re-arms on **any** `gh pr merge`, including the merge of the
   compound docs themselves — asking to compound the compound step (a mild recursion).

### Decision

**Branch-discipline defense-in-depth (closes #1):**
- Add a branch guard at the top of `auto-commit.sh` that refuses to commit on `main`/`master`
  (zero-setup, closes the named bypass even if `core.hooksPath` is unset).
- Add a repo-managed git hook `.githooks/pre-commit` that blocks commits to the default branch from
  **any** path — the altitude-correct generalization ("put the invariant where the action happens,"
  per `docs/solutions/best-practices/hook-command-string-matching-pitfalls.md`). Enabled per clone
  with `git config core.hooksPath .githooks` (documented in `CONTRIBUTING.md`). It recovers the
  underlying branch during a rebase (detached HEAD) so a rebase *on* `main` is also caught.

**Compound-gate recursion fix (closes #2):**
- `compound-flag.sh` no longer arms when the merged PR's head branch is `docs/*` (where compound
  and other documentation land). Resolved via `gh pr view --json headRefName`; on any failure it
  falls through and arms (safe default). Test override: `COMPOUND_TEST_HEAD_REF`.

All paths covered by `.claude/hooks/test-compound-hooks.sh` (12 assertions) and the CI `hooks-test`
job, including pre-commit block/allow and the docs/* skip.

### Alternatives Considered

- **Only edit auto-commit.sh.** Rejected as sole fix: doesn't generalize to other script-wrapped
  git; the `pre-commit` hook covers all paths.
- **Only add the pre-commit hook.** Rejected as sole fix: `core.hooksPath` is per-clone and easily
  unset, so the in-script guard is the no-setup backstop.
- **Skip-arm by changed paths (docs/solutions only).** Rejected: the real compound merge also edits
  instruction files (e.g. CLAUDE.md), so a path filter misses it; the `docs/*` branch convention is
  the cleaner, more robust signal.

### Tradeoffs

`core.hooksPath` must be set per clone (documented; the in-script guard backstops it). The `docs/*`
skip may occasionally suppress a reminder for a docs branch that did contain a real learning —
acceptable, since compounding can always be run manually, and the alternative (recursion) is worse.
The editing of a vendored file (`auto-commit.sh`) must be re-applied if Spec Kit overwrites it on
upgrade (noted in an inline comment).

### Consequences

- `main` is protected from direct commits via any path on clones that ran the one-time setup, and
  the specific auto-commit bypass is closed unconditionally.
- The compound gate stops nagging after documentation merges.

### Reversibility

High. Remove `.githooks/pre-commit` + unset `core.hooksPath`; revert the two hook edits. No data or
schema impact.

### Impact

- **Security:** Strengthens branch-discipline enforcement (Articles XVIII, XXVI, XXXIX).
- **Operational:** Adds a one-time `git config core.hooksPath .githooks` to onboarding.
- **Agent-native:** All guards are plain bash with test overrides any agent can exercise.

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
