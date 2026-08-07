#!/usr/bin/env bash
# apply-ruleset.sh — create or verify the `main-required-checks` ruleset on a repo.
#
# Makes the three CI gates (mutation, changed-lines-coverage, evals) required
# status checks on main, plus deletion and force-push protection. Idempotent:
# safe to run at every bootstrap and at every audit.
#
# WHY NO REQUIRED-REVIEW RULE: on a solo-maintainer repo, a 1-approval
# requirement is a deadlock — an author cannot approve their own PR — and with
# enforce_admins it makes main permanently unmergeable. Human review is
# enforced client-side by the CE Review gate (gh pr merge is blocked until
# /ce-code-review runs). Add a review rule here the day a second maintainer
# exists.
#
# PREREQUISITES: gh authenticated with admin access to the target repo, and the
# three workflows present with always-report triggers (Fix 2 in README.md) —
# requiring path-filtered checks strands every unrelated PR at
# "Expected — waiting for status".
#
# USAGE:
#   tools/ci/apply-ruleset.sh                  # target = repo of the cwd's origin
#   tools/ci/apply-ruleset.sh owner/name       # explicit target
#   tools/ci/apply-ruleset.sh --set-default-main [owner/name]
#                                              # also fix default_branch to main
#                                              # when it is something else
#
# EXIT CODES: 0 ruleset applied or verified current; 1 error;
#             2 ruleset exists but drifted from the expected rules (not changed
#             — rerun after reviewing, or fix by hand; this script never
#             silently rewrites an existing ruleset).

set -euo pipefail

RULESET_NAME="main-required-checks"
SET_DEFAULT=false
TARGET=""

for arg in "$@"; do
  case "$arg" in
    --set-default-main) SET_DEFAULT=true ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) TARGET="$arg" ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh is not installed." >&2; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is not installed." >&2; exit 1
fi

if [ -z "$TARGET" ]; then
  TARGET=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  if [ -z "$TARGET" ]; then
    echo "ERROR: no target given and the current directory has no resolvable GitHub repo." >&2
    exit 1
  fi
fi
echo "Target: $TARGET"

# --- Default branch: verify before trusting anything branch-shaped ----------
# A repo whose first push was a feature branch has that branch as its GitHub
# default; a ruleset aimed at the wrong branch protects nothing while reporting
# "active". The ruleset below pins refs/heads/main explicitly, but a non-main
# default also mis-bases every future PR, so it is surfaced here.
default_branch=$(gh api "repos/$TARGET" --jq .default_branch)
if [ "$default_branch" != "main" ]; then
  if $SET_DEFAULT; then
    if ! gh api "repos/$TARGET/branches/main" >/dev/null 2>&1; then
      echo "ERROR: default branch is '$default_branch' and no 'main' branch exists to switch to." >&2
      exit 1
    fi
    gh api --method PATCH "repos/$TARGET" -f default_branch=main --jq .default_branch >/dev/null
    echo "Default branch changed: $default_branch -> main"
    # Keep the cached value in sync so the drift check below does not read the
    # pre-change branch and report a ~DEFAULT_BRANCH ruleset as false drift.
    default_branch=main
  else
    echo "WARNING: default branch is '$default_branch', not 'main'. The ruleset still targets refs/heads/main explicitly, but PRs will base against '$default_branch' by default. Rerun with --set-default-main to fix." >&2
  fi
fi

expected_rules() {
  cat <<'JSON'
{
  "name": "main-required-checks",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["refs/heads/main"], "exclude": [] }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
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
}

existing_id=$(gh api "repos/$TARGET/rulesets" --jq \
  ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null | head -1)

if [ -z "$existing_id" ]; then
  gh api --method POST "repos/$TARGET/rulesets" \
    -H "Accept: application/vnd.github+json" \
    --input <(expected_rules) --jq '{id, name, enforcement}'
  echo "Ruleset created."
  exit 0
fi

# --- Verify the existing ruleset instead of rewriting it --------------------
actual=$(gh api "repos/$TARGET/rulesets/$existing_id")
drift=""

[ "$(echo "$actual" | jq -r .enforcement)" = "active" ] || drift="$drift enforcement"
# Accept ~DEFAULT_BRANCH only when the default branch actually is main. A repo
# whose default is still a feature branch (a push-order artifact) would otherwise
# hold a ruleset scoped to that branch and pass as "verified current" while main
# is unprotected — the exact failure this script's header warns about.
if [ "$default_branch" = "main" ]; then
  ref_ok='.conditions.ref_name.include == ["refs/heads/main"] or .conditions.ref_name.include == ["~DEFAULT_BRANCH"]'
else
  ref_ok='.conditions.ref_name.include == ["refs/heads/main"]'
fi
echo "$actual" | jq -e "$ref_ok" >/dev/null || drift="$drift ref-include"
# A ref_name.exclude entry can disable the ruleset for main while `include` still
# reads [refs/heads/main]; a non-empty exclude is drift.
echo "$actual" | jq -e '(.conditions.ref_name.exclude // []) | length == 0' >/dev/null || drift="$drift ref-exclude"
# A bypass actor (admin, org role, or GitHub App) can push to main and merge
# without any required check — a neutered ruleset that still looks active.
echo "$actual" | jq -e '(.bypass_actors // []) | length == 0' >/dev/null || drift="$drift bypass-actors"
for t in deletion non_fast_forward required_status_checks; do
  echo "$actual" | jq -e ".rules[] | select(.type == \"$t\")" >/dev/null || drift="$drift missing:$t"
done
# The success line claims "strict"; verify the strict up-to-date-with-main policy
# is actually on, or a ruleset with it off passes while two PRs that each pass
# alone can still merge into a broken main.
echo "$actual" | jq -e '.rules[] | select(.type == "required_status_checks") | select(.parameters.strict_required_status_checks_policy == true)' >/dev/null || drift="$drift not-strict"
for c in mutation changed-lines-coverage evals; do
  echo "$actual" | jq -e ".rules[] | select(.type == \"required_status_checks\") | .parameters.required_status_checks[] | select(.context == \"$c\")" >/dev/null || drift="$drift missing-check:$c"
done

if [ -n "$drift" ]; then
  echo "DRIFT: ruleset $existing_id exists but differs from expectation:$drift" >&2
  echo "Not modified — review it (gh api repos/$TARGET/rulesets/$existing_id) and reconcile by hand." >&2
  exit 2
fi

echo "Ruleset $existing_id verified current (active; deletion, non_fast_forward, 3 required checks, strict)."
exit 0
