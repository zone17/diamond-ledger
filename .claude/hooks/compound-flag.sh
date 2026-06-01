#!/usr/bin/env bash
# PostToolUse hook (all tools). Maintains the compound-loop flag:
#   - sets   .claude/.needs-compound  after a `gh pr merge`
#   - clears .claude/.needs-compound  after the ce-compound skill runs
# Implements the Continuous Improvement Flywheel (constitution Articles XVI, XXII).
# Dependency-free: parses the hook payload by substring, no jq required.
set -euo pipefail

# Resolve project root (CLAUDE_PROJECT_DIR is set by Claude Code; fall back to script location).
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FLAG="$ROOT/.claude/.needs-compound"

# The PostToolUse payload (JSON) arrives on stdin and contains the tool name and input.
payload="$(cat 2>/dev/null || true)"

# A PR merge actually executed (PostToolUse only fires when the tool ran) -> arm the gate.
if printf '%s' "$payload" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
  printf 'merged_at=%s\n' "${EPOCHSECONDS:-unknown}" > "$FLAG"
  exit 0
fi

# The compound skill ran -> work was captured, disarm the gate.
if printf '%s' "$payload" | grep -Eq 'ce-compound|workflows:compound|compound-engineering'; then
  rm -f "$FLAG"
  exit 0
fi

exit 0
