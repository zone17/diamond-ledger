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
# ENFORCE_ADMINS: default TRUE. With it false, ANY admin credential — including
# every automated agent session running under the owner's `gh` auth — can
# `gh pr merge --admin` past all four required checks and the review rule. That
# bypass is the main threat here, not an edge case, so admins are held to the
# same gates. The tradeoff on a solo repo: no one can merge to main without a
# second approver, so merging a PR means either adding a reviewer or briefly
# toggling this off by hand (`gh api --method DELETE repos/OWNER/REPO/branches/
# main/protection/enforce_admins`) and re-enabling after. Set ENFORCE_ADMINS=false
# only for a throwaway/personal repo where the bypass does not matter.
#
# USAGE:
#   tools/ci/apply-branch-protection.sh [owner/name]      # enforce_admins=true (default)
#   ENFORCE_ADMINS=false tools/ci/apply-branch-protection.sh owner/name
#
# EXIT: 0 applied/verified; 1 error.

set -euo pipefail

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is not installed." >&2; exit 1; }

TARGET="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
[ -n "$TARGET" ] || { echo "ERROR: no target given and cwd has no resolvable GitHub repo." >&2; exit 1; }
ENFORCE_ADMINS="${ENFORCE_ADMINS:-true}"

echo "Target: $TARGET  (enforce_admins=$ENFORCE_ADMINS)"

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
  required_pull_request_reviews: {
    dismiss_stale_reviews: true,
    require_code_owner_reviews: false,
    required_approving_review_count: 1
  },
  required_conversation_resolution: true,
  required_linear_history: true,
  allow_force_pushes: false,
  allow_deletions: false,
  restrictions: null
}')

gh api --method PUT "repos/$TARGET/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  --input <(printf '%s' "$body") \
  --jq '{checks: [.required_status_checks.checks[].context], strict: .required_status_checks.strict, reviews: .required_pull_request_reviews.required_approving_review_count, dismiss_stale: .required_pull_request_reviews.dismiss_stale_reviews, enforce_admins: .enforce_admins.enabled, force_pushes: .allow_force_pushes.enabled, deletions: .allow_deletions.enabled}'

echo "Branch protection applied on $TARGET main."
