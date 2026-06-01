#!/usr/bin/env bash
# PostToolUse hook (all tools). Maintains the compound-loop flag:
#   - arms  .claude/.needs-compound  after a `gh pr merge` Bash command executes
#   - clears .claude/.needs-compound after the ce-compound Skill actually runs
# Implements the Continuous Improvement Flywheel (constitution Articles XVI, XXII).
#
# Matching is scoped to the payload's tool_name so the gate cannot arm on a doc
# edit / commit message that merely mentions "gh pr merge", nor clear because some
# Read/Grep/Edit payload happened to contain "ce-compound" (independent review,
# ADR-0003). Dependency-free: no jq required.
set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FLAG="$ROOT/.claude/.needs-compound"
DONE="$ROOT/.claude/.compound-done"   # one-shot "just compounded" marker (ADR-0005)
SUPPRESS_TTL=3600                      # ignore a stale marker older than this (seconds)

# Portable epoch seconds: macOS ships bash 3.2 (no EPOCHSECONDS), so prefer `date`.
now_epoch() { date +%s 2>/dev/null || printf '%s' "${EPOCHSECONDS:-0}"; }

# PostToolUse payload (JSON) on stdin: tool_name, tool_input, tool_response.
payload="$(cat 2>/dev/null || true)"

# Best-effort tool_name extraction (whitespace tolerant, never aborts the hook).
tool_name="$(printf '%s' "$payload" \
  | grep -Eo '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 \
  | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/' || true)"

# Clear only when the compound skill itself ran (a Skill invocation), not when some
# other tool's payload merely mentions the word "compound".
if [ "$tool_name" = "Skill" ] \
  && printf '%s' "$payload" | grep -Eq 'ce-compound|workflows:compound|compound-engineering'; then
  rm -f "$FLAG"
  # Drop a fresh, one-shot marker so the *next* merge — almost always the merge of
  # the compound doc this run just produced — does not re-arm the gate even when its
  # docs/* head ref cannot be resolved at hook time (ADR-0005 recursion backstop).
  now_epoch > "$DONE"
  exit 0
fi

# Arm only when an actual `gh pr merge` ran as a Bash command.
if [ "$tool_name" = "Bash" ] \
  && printf '%s' "$payload" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
  # Don't arm on a docs/* branch merge: those are documentation (incl. the compound
  # docs themselves), so arming would ask to compound the compound step (ADR-0004).
  pr_num="$(printf '%s' "$payload" | grep -oE 'merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
  head_ref="${COMPOUND_TEST_HEAD_REF:-}"
  # (1) No-network hint: `gh pr merge --delete-branch` prints "Deleted branch <ref>"
  #     into tool_response. Prefer it — it cannot race the way a fresh lookup can.
  if [ -z "$head_ref" ]; then
    head_ref="$(printf '%s' "$payload" \
      | grep -oE 'Deleted branch [A-Za-z0-9._/-]+' | head -n1 \
      | sed -E 's/^Deleted branch //' || true)"
  fi
  # (2) Live lookup as a fallback. This is the call that RACED the branch deletion in
  #     ADR-0004 and silently armed; it is now only a fallback, with (3) as backstop.
  if [ -z "$head_ref" ] && [ -n "$pr_num" ] && command -v gh >/dev/null 2>&1; then
    head_ref="$(gh pr view "$pr_num" --json headRefName --jq .headRefName 2>/dev/null || true)"
  fi

  # Consume any one-shot just-compounded marker (always consume so it never lingers).
  suppress=0
  if [ -f "$DONE" ]; then
    marker_ts="$(cat "$DONE" 2>/dev/null || echo 0)"
    rm -f "$DONE"
    case "$marker_ts" in ''|*[!0-9]*) marker_ts=0 ;; esac
    [ "$marker_ts" -gt 0 ] && [ "$(( $(now_epoch) - marker_ts ))" -lt "$SUPPRESS_TTL" ] && suppress=1
  fi

  # Primary guard: documentation merges (resolved head ref) never arm.
  case "$head_ref" in
    docs/*) exit 0 ;;
  esac

  # (3) Backstop: head ref unresolved AND we just compounded -> this is almost
  #     certainly the compound doc's own merge whose docs/* ref raced the lookup.
  #     Skip exactly once. A resolved non-docs ref still arms normally (safe default
  #     preserved); the marker is consumed either way so it can't suppress a later
  #     substantive merge.
  if [ -z "$head_ref" ] && [ "$suppress" -eq 1 ]; then
    exit 0
  fi

  printf 'merged_at=%s\n' "$(now_epoch)" > "$FLAG"
  exit 0
fi

exit 0
