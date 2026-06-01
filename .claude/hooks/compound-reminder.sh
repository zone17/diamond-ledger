#!/usr/bin/env bash
# Stop hook. If a PR was merged this session but ce-compound hasn't run, block the
# stop once and instruct the agent to run the compound step — closing the
# Continuous Improvement Flywheel (constitution Articles XVI, XXII, XXXIX).
#
# Loop-safe: when the stop is itself a continuation triggered by this hook
# (stop_hook_active), it steps aside so the agent is never trapped.
# Bypass: delete .claude/.needs-compound to skip for genuinely trivial merges.
set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FLAG="$ROOT/.claude/.needs-compound"

payload="$(cat 2>/dev/null || true)"

# Avoid re-blocking within the same stop sequence (prevents tight loops).
if printf '%s' "$payload" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

# Nothing to compound -> allow stop.
[ -f "$FLAG" ] || exit 0

# Gate: block the stop and tell the agent what to do. Emit JSON on stdout.
reason="A pull request was merged but the compound step has not run. Per the Continuous Improvement Flywheel (constitution Articles XVI & XXII), run the ce-compound skill (/ce-compound) now to capture non-obvious learnings, failure modes, and patterns into docs/solutions/. Running it auto-clears this gate. To skip for a genuinely trivial merge, delete .claude/.needs-compound."

# Use python3 for safe JSON encoding when available; otherwise emit a minimal literal.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$reason" <<'PY'
import json, sys
print(json.dumps({"decision": "block", "reason": sys.argv[1]}))
PY
else
  printf '{"decision":"block","reason":"%s"}\n' "A PR was merged but ce-compound has not run. Run /ce-compound to capture learnings (Articles XVI, XXII). Delete .claude/.needs-compound to skip."
fi
exit 0
