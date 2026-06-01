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
  exit 0
fi

# Arm only when an actual `gh pr merge` ran as a Bash command.
if [ "$tool_name" = "Bash" ] \
  && printf '%s' "$payload" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
  printf 'merged_at=%s\n' "${EPOCHSECONDS:-unknown}" > "$FLAG"
  exit 0
fi

exit 0
