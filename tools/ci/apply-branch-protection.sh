#!/usr/bin/env bash
# apply-branch-protection.sh — classic branch protection on main, the fleet's
# Unit-A configuration. Idempotent: the PUT sets the whole protection object, so
# re-running converges to this config.
#
# Requires the four always-report gate workflows to exist (mutation,
# changed-lines-coverage, evals, a11y-perf). Because those are Fix-2
# always-report checks, they report green in seconds on a PR that touches no
# governed path — so requiring them never wedges a docs-only PR.
#
# NO GITHUB-SIDE REQUIRED REVIEW (required_pull_request_reviews: null). These are
# solo-operator repos: GitHub does not count a PR author's own approval, so a
# required review of 1 is unsatisfiable and the only way past it was a routine
# 1->0->1 toggle — a control that is repeatedly lowered is worse than an honest 0.
# Human accountability lives in TWO other places instead:
#   (a) the CE-review merge gate — a multi-persona `/ce-code-review` is required
#       before `gh pr merge` (enforced client-side by security-gate-bash; escape
#       hatches --no-review / hotfix|docs branches are now logged + audited); and
#   (b) the merge action itself remaining human-initiated or human-authorized.
# See DECISIONS.md (2026-08-08) and constitution Enforcement Matrix (review row).
#
# ENFORCE_ADMINS: default TRUE. With no required review, admins=true no longer
# locks out the solo maintainer (merges need only the four checks, no approval),
# so there is no deadlock and no reason to weaken it. It keeps force-push /
# deletion / linear-history / check requirements binding on admins too.
#
# USAGE:
#   tools/ci/apply-branch-protection.sh [owner/name]     # default = repo of cwd's origin
#   ENFORCE_ADMINS=false tools/ci/apply-branch-protection.sh owner/name   # opt out (not recommended)
#
# EXIT: 0 applied/verified; 1 error.

set -euo pipefail

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is not installed." >&2; exit 1; }

TARGET="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
[ -n "$TARGET" ] || { echo "ERROR: no target given and cwd has no resolvable GitHub repo." >&2; exit 1; }
ENFORCE_ADMINS="${ENFORCE_ADMINS:-true}"

echo "Target: $TARGET  (enforce_admins=$ENFORCE_ADMINS, required_reviews=0/null — review is the CE-review gate)"

# required_pull_request_reviews is JSON null: no GitHub-side approval required.
# The review control is the CE-review merge gate, not a GitHub review count.
body=$(jq -n --argjson ea "$ENFORCE_ADMINS" '{
  required_status_checks: {
    strict: true,
    checks: [
      { context: "mutation" },
      { context: "changed-lines-coverage" },
      { context: "evals" },
      { context: "a11y-perf" }
    ]
  },
  enforce_admins: $ea,
  required_pull_request_reviews: null,
  required_conversation_resolution: true,
  required_linear_history: true,
  allow_force_pushes: false,
  allow_deletions: false,
  restrictions: null
}')

gh api --method PUT "repos/$TARGET/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  --input <(printf '%s' "$body") \
  --jq '{checks: [.required_status_checks.checks[].context], strict: .required_status_checks.strict, reviews: (.required_pull_request_reviews.required_approving_review_count // 0), enforce_admins: .enforce_admins.enabled, force_pushes: .allow_force_pushes.enabled, deletions: .allow_deletions.enabled}'

echo "Branch protection applied on $TARGET main (review control = CE-review gate, not GitHub reviews)."
