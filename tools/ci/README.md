# tools/ci — the CI gates, and the one step that cannot be automated from here

Three workflows enforce the constitution's testing articles on pull requests:

| Workflow | Status-check context | Article | Gate |
|---|---|---|---|
| `.github/workflows/mutation-testing.yml` | `mutation` | XXI | Mutation score ≥ 60 on the sacred paths, ratcheting to 80 |
| `.github/workflows/changed-lines-coverage.yml` | `changed-lines-coverage` | XIX | ≥ 80% coverage of the lines a PR changed |
| `.github/workflows/evals.yml` | `evals` | XXIV | Eval suites pass on model-powered changes |

The status-check context is the job's display name. Each workflow has exactly one job, and its `id`
and `name:` are deliberately identical to the table above, so these strings are stable — do not
rename a job without updating branch protection, or the required check silently becomes a check that
never reports.

Supporting files in this directory:

- `sacred-paths.txt` — the directories Articles II, XXI and XXVI protect. Shared with Unit 6's
  `tools/hooks-staging/tdd-gate.conf`; the mutation workflow verifies its own trigger against this
  file on every run and fails on drift.
- `model-powered-paths.txt` — the paths whose contents shape model output. Same drift check in
  `evals.yml`.
- `stryker.config.json` — Stryker starter config. `thresholds.break` is the mutation floor.

## The step that cannot be automated from here

**WorkAlly has no GitHub remote.** `git remote -v` is empty, so there is no repository to configure,
no branch to protect and no API to call. Everything below is written to be run verbatim the day a
remote exists — by a human, or by whoever runs Unit 11's template against a freshly created repo.

Branch protection is also the only part of this unit that is not code. A workflow file is a fact
about the repository; a required status check is a fact about the *server*, and nothing in the
checkout can assert it. Until these three are marked required, all three are advisory: a PR can go
red and still merge.

### Prerequisites

```bash
gh auth status                       # must be authenticated
gh auth refresh -s admin:repo_hook,repo   # branch protection needs admin scope on the repo
export OWNER=your-org
export REPO=WorkAlly
```

Confirm the check names have reported at least once before requiring them — GitHub will accept a
context string that no workflow ever produces, and that check stays pending forever:

```bash
gh api "repos/$OWNER/$REPO/commits/main/check-runs" --jq '.check_runs[].name'
```

### Option A — classic branch protection (works on all plan tiers)

Sets the whole protection object in one call. This **overwrites** existing protection on `main`, so
read the current state first if the branch is already protected:

```bash
gh api "repos/$OWNER/$REPO/branches/main/protection" > /tmp/protection-before.json
```

```bash
gh api --method PUT "repos/$OWNER/$REPO/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      { "context": "mutation" },
      { "context": "changed-lines-coverage" },
      { "context": "evals" }
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "required_conversation_resolution": true,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "restrictions": null
}
JSON
```

`"strict": true` means a branch must be up to date with `main` before merging — it is what stops two
PRs that each pass alone from merging into a broken `main`.

To add the three checks to protection that already exists, without touching the rest:

```bash
gh api --method PATCH "repos/$OWNER/$REPO/branches/main/protection/required_status_checks" \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "strict": true,
  "checks": [
    { "context": "mutation" },
    { "context": "changed-lines-coverage" },
    { "context": "evals" }
  ]
}
JSON
```

### Option B — repository ruleset (preferred where available)

Rulesets are additive, versioned, and can cover several branches at once, so they compose better than
classic protection when more than one team edits the rules:

```bash
gh api --method POST "repos/$OWNER/$REPO/rulesets" \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "name": "main-required-checks",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "mutation" },
          { "context": "changed-lines-coverage" },
          { "context": "evals" }
        ]
      }
    }
  ]
}
JSON
```

### Verify

```bash
gh api "repos/$OWNER/$REPO/branches/main/protection" \
  --jq '.required_status_checks.checks[].context'
gh api "repos/$OWNER/$REPO/rulesets" --jq '.[].name'
```

Then open a throwaway PR that touches `src/auth/` and confirm `mutation` appears in its checks.

## Read this before you mark them required

All three workflows are path-filtered: they only start when a PR touches the paths they govern. That
is what keeps CI fast and keeps this repo green while it has no application code — but it collides
with required status checks in a way that will block every unrelated PR if you skip this section.

**The collision.** When a workflow does not run because its path filter did not match, GitHub does
not report a status for it. A required check with no status stays *Expected — waiting for status*,
and the PR cannot merge. A docs-only PR would sit forever waiting on `mutation`. This is documented
GitHub behavior for path-filtered workflows, not a bug in these files, and it is why marking these
required without a change is the wrong move.

Two fixes; pick one per workflow and apply it in the same change that marks the check required.

**Fix 1 — a companion no-op workflow (GitHub's documented approach).** Add a second workflow file
with the *same* `name:` and the *same* job name, triggered on the inverse filter, whose only step
succeeds. Exactly one of the two runs on any PR, and the required context always reports:

```yaml
# .github/workflows/mutation-testing-skip.yml
name: mutation-testing
on:
  pull_request:
    paths-ignore:
      - 'src/auth/**'
      - 'src/payments/**'
      - 'src/billing/**'
      - 'migrations/**'
jobs:
  mutation:
    name: mutation
    runs-on: ubuntu-latest
    steps:
      - run: echo "No sacred path touched — mutation testing not required for this PR."
```

The cost is a third path list to keep in sync. If you take this route, extend the drift check already
in `mutation-testing.yml` to cover the companion file too.

**Fix 2 — move the filter inside the job.** Drop `paths:` from the trigger so the workflow runs on
every PR, and decide inside the job whether to do the expensive work:

```yaml
on:
  pull_request:            # no paths filter — the job always reports a status
jobs:
  mutation:
    name: mutation
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - id: changed
        env:
          BASE_REF: ${{ github.base_ref }}
        run: |
          set -euo pipefail
          git fetch --no-tags origin "+refs/heads/${BASE_REF}:refs/remotes/origin/${BASE_REF}"
          patterns=$(sed -e 's/#.*//' -e 's#/\*\*$##' -e 's/[[:space:]]*$//' \
                       tools/ci/sacred-paths.txt | grep -v '^$')
          hit=false
          for p in $patterns; do
            if git diff --name-only "origin/${BASE_REF}...HEAD" | grep -q "^${p}/"; then hit=true; fi
          done
          echo "sacred=$hit" >> "$GITHUB_OUTPUT"
      # ... remaining steps gated on steps.changed.outputs.sacred == 'true'
```

This costs a runner minute on every PR and buys a single source of truth for the path list. **Prefer
this one** for the sacred-path workflows: the list already lives in `sacred-paths.txt`, and Fix 1
would create a fourth copy of it that can drift out of sync silently — on the gate that protects auth
and payments.

Neither fix is applied here, deliberately. Today the path filters are the thing keeping an
application-less repo green, and no check is required yet, so the collision cannot bite. Apply the
fix when you apply branch protection, not before.

## Also on the day you make these required

**Pin actions to commit SHAs.** Every `uses:` in these workflows is pinned by major version, which is
the floor this repo accepts and is still mutable: `actions/checkout@v4` is a tag the upstream owner
can move. A required check runs with repository context, so a moved tag is a supply-chain path into
CI. Rewrite them:

```bash
# One action, one SHA:
gh api repos/actions/checkout/commits/v4 --jq .sha

# Or do the whole tree with pinact (reviews every rewrite for you):
go install github.com/suzuki-shunsuke/pinact/cmd/pinact@latest
pinact run .github/workflows/*.yml
```

Keep the version as a trailing comment so Dependabot can still update them:
`uses: actions/checkout@<sha> # v4.2.2`.

**Arm the evals gate.** `evals.yml` skips while `evals/promptfooconfig.yaml` carries its scaffold
marker. A required check that always skips is theater. Follow the checklist at the end of
`evals/README.md`, then set `REQUIRE_EVALS: 'true'`.

**Turn on the coverage strictness knob.** `changed-lines-coverage.yml` sets
`REQUIRE_COVERAGE_REPORT: 'false'`, so a missing coverage report downgrades to a notice. Once a real
suite exists, flip it to `'true'` — otherwise a broken coverage command disables the gate without
turning anything red.

**Decide what forks get.** `evals.yml` needs `ANTHROPIC_API_KEY`, and GitHub does not expose secrets
to pull requests from forks. If this repo ever takes outside contributions, the eval gate will skip
on their PRs (guard 3) and cannot be satisfied by them. The options are: keep evals advisory for
forks, or run them from a `pull_request_target` workflow — which executes trusted code against
untrusted input and needs its own review before you go near it.

**Ratchet the mutation floor.** `stryker.config.json` sets `thresholds.break` to 60. Article XXI's
floor for these paths is 80% killed mutants. Raise it as the suite improves; lowering it is a
`DECISIONS.md` entry, not a quick fix for a red build.

## Provenance

These files are the reusable snippets Unit 11's project template ships to new repositories. A repo
created from that template gets the three workflows, both path manifests, the Stryker config, the
eval scaffold and this README — and its bootstrap step is exactly the branch-protection call above,
run once against the newly created remote. Fixes made here should land in the template, not only
here.
