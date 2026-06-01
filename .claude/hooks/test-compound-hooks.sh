#!/usr/bin/env bash
# Regression tests for the compound-loop hooks (ADR-0003).
# Run: bash .claude/hooks/test-compound-hooks.sh   (exits non-zero on any failure)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_PROJECT_DIR="$(cd "$DIR/../.." && pwd)"
FLAG="$CLAUDE_PROJECT_DIR/.claude/.needs-compound"
DONE="$CLAUDE_PROJECT_DIR/.claude/.compound-done"
FLAG_SH="$DIR/compound-flag.sh"
STOP_SH="$DIR/compound-reminder.sh"

# Hermetic `gh` stub so head-ref resolution can be forced to "unresolved" without a
# network call (mirrors the post-`--delete-branch` race in ADR-0004/0005). On PATH
# only inside the tests that opt in via $GHSTUB_PATH.
GHSTUB_DIR="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$GHSTUB_DIR/gh"  # any gh call -> empty/failed
chmod +x "$GHSTUB_DIR/gh"
GHSTUB_PATH="$GHSTUB_DIR:$PATH"
trap 'rm -rf "$GHSTUB_DIR"' EXIT

pass=0; fail=0
ok()   { printf '  PASS: %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL: %s\n' "$1"; fail=$((fail+1)); }
reset(){ rm -f "$FLAG" "$DONE"; }

# --- compound-flag.sh: arming ---
reset
COMPOUND_TEST_HEAD_REF="feat/platform/PLAT-999-x" \
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 3 --squash"}}' | \
  COMPOUND_TEST_HEAD_REF="feat/platform/PLAT-999-x" bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "arms on Bash gh pr merge (feat branch)" || bad "arms on Bash gh pr merge (feat branch)"

reset
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 4 --squash"}}' | \
  COMPOUND_TEST_HEAD_REF="docs/architecture/ARCH-002-x" bash "$FLAG_SH"
[ -f "$FLAG" ] && bad "must NOT arm on docs/* branch merge" || ok "does NOT arm on docs/* branch merge"

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

# --- compound-flag.sh: recursion backstop (ADR-0005) ---

# Clearing on ce-compound also drops the one-shot just-compounded marker.
reset; : > "$FLAG"
printf '{"tool_name":"Skill","tool_input":{"skill":"compound-engineering:ce-compound"}}' | bash "$FLAG_SH"
[ -f "$DONE" ] && ok "ce-compound writes the one-shot .compound-done marker" || bad "did not write .compound-done marker"

# No-network hint: a "Deleted branch docs/..." line in tool_response skips arming
# even with no COMPOUND_TEST_HEAD_REF and no working gh (the race scenario).
reset
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 8 --squash --delete-branch"},"tool_response":"Deleted branch docs/product/PROD-002-x and switched to branch main"}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && bad "must NOT arm when tool_response shows a docs/* Deleted branch" || ok "no-network hint skips arming on docs/* Deleted branch"

# Backstop: head ref unresolved (gh stubbed to fail) + fresh marker -> suppress once.
reset; now_ts="$(date +%s 2>/dev/null || echo 0)"; printf '%s\n' "$now_ts" > "$DONE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 999 --squash --delete-branch"}}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && bad "backstop must suppress arm when ref unresolved + fresh marker" || ok "backstop suppresses recursion when ref unresolved + fresh marker"
[ -f "$DONE" ] && bad "marker must be consumed (one-shot)" || ok "marker is consumed one-shot"

# One-shot: a SECOND unresolved merge after the marker was consumed arms (safe default restored).
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 1000 --squash --delete-branch"}}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "arms on next unresolved merge once marker is consumed (safe default)" || bad "failed to arm after marker consumed"

# A resolved NON-docs ref still arms even with a fresh marker (marker consumed, not applied).
reset; printf '%s\n' "$(date +%s 2>/dev/null || echo 0)" > "$DONE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 5 --squash"}}' \
  | COMPOUND_TEST_HEAD_REF="feat/platform/PLAT-7-x" bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "resolved feat ref still arms despite fresh marker" || bad "fresh marker wrongly suppressed a resolved feat merge"
[ -f "$DONE" ] && bad "marker must be consumed even when not applied" || ok "marker consumed even when not applied to a resolved ref"

# Stale marker (TTL expired) + unresolved ref -> arms (safe default).
reset; printf '%s\n' "1" > "$DONE"   # epoch 1 = 1970, far older than SUPPRESS_TTL
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 1001 --squash --delete-branch"}}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "stale marker does not suppress (TTL expired)" || bad "stale marker wrongly suppressed arming"

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

# --- .githooks/pre-commit: default-branch guard (ADR-0004) ---
PRECOMMIT="$CLAUDE_PROJECT_DIR/.githooks/pre-commit"
if [ -f "$PRECOMMIT" ]; then
  PRECOMMIT_TEST_BRANCH=main bash "$PRECOMMIT" >/dev/null 2>&1 && bad "pre-commit must block main" || ok "pre-commit blocks commits on main"
  PRECOMMIT_TEST_BRANCH=master bash "$PRECOMMIT" >/dev/null 2>&1 && bad "pre-commit must block master" || ok "pre-commit blocks commits on master"
  PRECOMMIT_TEST_BRANCH="feat/platform/PLAT-1-x" bash "$PRECOMMIT" >/dev/null 2>&1 && ok "pre-commit allows typed branch" || bad "pre-commit wrongly blocked a feature branch"
else
  bad ".githooks/pre-commit missing"
fi

reset
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
