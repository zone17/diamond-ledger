#!/usr/bin/env bash
# Regression tests for the compound-loop hooks (ADR-0003).
# Run: bash .claude/hooks/test-compound-hooks.sh   (exits non-zero on any failure)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_PROJECT_DIR="$(cd "$DIR/../.." && pwd)"
FLAG="$CLAUDE_PROJECT_DIR/.claude/.needs-compound"
FLAG_SH="$DIR/compound-flag.sh"
STOP_SH="$DIR/compound-reminder.sh"

pass=0; fail=0
ok()   { printf '  PASS: %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL: %s\n' "$1"; fail=$((fail+1)); }
reset(){ rm -f "$FLAG"; }

# --- compound-flag.sh: arming ---
reset
printf '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 3 --squash"}}' | bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "arms on Bash gh pr merge" || bad "arms on Bash gh pr merge"

reset
printf '{"tool_name":"Edit","tool_input":{"new_string":"Run gh pr merge --squash to land it"}}' | bash "$FLAG_SH"
[ -f "$FLAG" ] && bad "must NOT arm on Edit mentioning gh pr merge" || ok "ignores Edit mentioning gh pr merge"

reset
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m \\"docs: explain gh pr merge gate\\""}}' | bash "$FLAG_SH"
# Known accepted edge: a Bash commit message containing the phrase still arms (low risk). Document, don't assert false.
[ -f "$FLAG" ] && printf '  NOTE: Bash commit message containing the phrase arms (accepted low-risk edge)\n' || true

# --- compound-flag.sh: clearing ---
reset; : > "$FLAG"
printf '{"tool_name":"Skill","tool_input":{"skill":"compound-engineering:ce-compound"}}' | bash "$FLAG_SH"
[ -f "$FLAG" ] && bad "must clear on ce-compound Skill" || ok "clears on ce-compound Skill"

reset; : > "$FLAG"
printf '{"tool_name":"Read","tool_input":{"file_path":".claude/hooks/compound-flag.sh"}}' | bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "does NOT clear on Read of the hook file" || bad "wrongly cleared on Read of hook file"

reset; : > "$FLAG"
printf '{"tool_name":"Bash","tool_input":{"command":"grep -r compound-engineering ."}}' | bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "does NOT clear on Bash grep for compound-engineering" || bad "wrongly cleared on grep"

# --- compound-reminder.sh: Stop behavior ---
reset; : > "$FLAG"
OUT="$(printf '{"hook_event_name":"Stop","stop_hook_active":false}' | bash "$STOP_SH")"
printf '%s' "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && ok "blocks Stop when flagged" || bad "did not block Stop when flagged"

reset; : > "$FLAG"
OUT="$(printf '{"hook_event_name":"Stop","stop_hook_active":true}' | bash "$STOP_SH")"
[ -z "$OUT" ] && ok "silent on re-entrant Stop (loop-safe)" || bad "emitted output on re-entrant Stop"

reset
OUT="$(printf '{"hook_event_name":"Stop","stop_hook_active":false}' | bash "$STOP_SH")"
[ -z "$OUT" ] && ok "silent Stop when no flag" || bad "emitted output with no flag"

reset
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
