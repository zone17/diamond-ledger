#!/usr/bin/env bash
# PostToolUse hook (all tools). Maintains the compound-loop flag:
#   - arms  .claude/.needs-compound  after a `gh pr merge` Bash command executes
#   - clears .claude/.needs-compound after the ce-compound Skill actually runs
# Implements the Continuous Improvement Flywheel (constitution Articles XVI, XXII).
#
# Recursion guard (ADR-0004 / ADR-0005): the merge of the compound docs themselves must
# not re-arm the gate ("compound the compound step"). Two layers:
#   1. PRIMARY — skip when the merged head ref is docs/*, resolved AUTHORITATIVELY via
#      `gh pr view`. A no-network payload hint is a fallback only, and is ANCHORED to
#      gh's real success line so a bare "Deleted branch docs/x" substring elsewhere in
#      the payload cannot cause a false skip (ADR-0005, fixes the pitfall in ADR-0004).
#   2. IDENTITY BACKSTOP — `gh pr view` can transiently race a just-completed
#      `gh pr merge --delete-branch` and return empty. So we also capture the compound
#      doc's OWN PR number (from its `gh pr create`) and skip exactly that one merge by
#      number — identity, not a clock, so a substantive merge is never wrongly skipped.
#
# Matching is scoped to the payload's tool_name so the gate cannot arm on a doc edit /
# commit message that merely mentions "gh pr merge", nor clear because some Read/Grep/
# Edit payload happened to contain "ce-compound" (ADR-0003). Dependency-free: no jq.
set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FLAG="$ROOT/.claude/.needs-compound"
DONE="$ROOT/.claude/.compound-done"   # compound-PR identity marker (ADR-0005)
CAPTURE_TTL=3600                       # max age (s) of an await-marker to still capture a PR

# macOS ships bash 3.2 (no EPOCHSECONDS); `date +%s` is the portable source. The `|| echo 0`
# is a fail-safe: 0 reads as "long ago", which only ever errs toward arming (never a silent skip).
now_epoch() { date +%s 2>/dev/null || echo 0; }

# PostToolUse payload (JSON) on stdin: tool_name, tool_input, tool_response.
payload="$(cat 2>/dev/null || true)"

# Best-effort tool_name extraction (whitespace tolerant, never aborts the hook).
tool_name="$(printf '%s' "$payload" \
  | grep -Eo '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/' || true)"

# --- Clear on the ce-compound Skill; arm the marker to capture the doc PR (state A). ---
if [ "$tool_name" = "Skill" ] \
  && printf '%s' "$payload" | grep -Eq 'ce-compound|workflows:compound|compound-engineering'; then
  rm -f "$FLAG"
  printf 'await=%s\n' "$(now_epoch)" > "$DONE"   # state A: awaiting the compound doc's PR
  exit 0
fi

# --- Capture the compound doc's PR number at `gh pr create` (state A -> state B). ------
# gh prints the new PR URL (.../pull/<n>) into tool_response. Only capture while a fresh
# await-marker is present, i.e. right after a compound run. This is the IDENTITY signal.
if [ "$tool_name" = "Bash" ] \
  && printf '%s' "$payload" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+create' \
  && [ -f "$DONE" ]; then
  await_ts="$(sed -n 's/^await=//p' "$DONE" 2>/dev/null | head -n1 || true)"
  case "$await_ts" in ''|*[!0-9]*) await_ts=0 ;; esac
  if [ "$await_ts" -gt 0 ] && [ "$(( $(now_epoch) - await_ts ))" -lt "$CAPTURE_TTL" ]; then
    new_pr="$(printf '%s' "$payload" | grep -oE 'pull/[0-9]+' | head -n1 \
      | grep -oE '[0-9]+' || true)"
    if [ -n "$new_pr" ]; then printf 'pr=%s\n' "$new_pr" > "$DONE"; fi   # state B
  fi
  exit 0
fi

# --- Arm on `gh pr merge`, unless docs/* (primary) or the captured compound PR (identity). ---
if [ "$tool_name" = "Bash" ] \
  && printf '%s' "$payload" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
  pr_num="$(printf '%s' "$payload" | grep -oE 'merge[[:space:]]+[0-9]+' \
    | grep -oE '[0-9]+' | head -n1 || true)"

  # Identity backstop FIRST: if this is exactly the captured compound doc PR, skip and
  # clear the marker — robust even when the head-ref lookup below races to empty.
  compound_pr="$(sed -n 's/^pr=//p' "$DONE" 2>/dev/null | head -n1 || true)"
  if [ -n "$pr_num" ] && [ -n "$compound_pr" ] && [ "$compound_pr" = "$pr_num" ]; then
    rm -f "$DONE"
    exit 0
  fi

  # Resolve the head ref. gh is AUTHORITATIVE (primary). Test override: COMPOUND_TEST_HEAD_REF.
  head_ref="${COMPOUND_TEST_HEAD_REF:-}"
  if [ -z "$head_ref" ] && [ -n "$pr_num" ] && command -v gh >/dev/null 2>&1; then
    head_ref="$(gh pr view "$pr_num" --json headRefName --jq .headRefName 2>/dev/null || true)"
  fi
  # No-network FALLBACK only — anchored to gh's real "Deleted branch <ref> and switched
  # to branch" line so a stray "Deleted branch docs/x" mention can't fabricate a skip.
  if [ -z "$head_ref" ]; then
    head_ref="$(printf '%s' "$payload" \
      | grep -oE 'Deleted branch [A-Za-z0-9._/-]+ and switched to branch' | head -n1 \
      | sed -E 's/^Deleted branch (.*) and switched to branch$/\1/' || true)"
  fi

  # Primary guard: documentation merges (resolved head ref) never arm.
  case "$head_ref" in
    docs/*) exit 0 ;;
  esac

  printf 'merged_at=%s\n' "$(now_epoch)" > "$FLAG"
  exit 0
fi

exit 0
