#!/usr/bin/env bash
# Regression tests for the compound-loop hooks (ADR-0003, ADR-0005).
# Run: bash .claude/hooks/test-compound-hooks.sh   (exits non-zero on any failure)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_PROJECT_DIR="$(cd "$DIR/../.." && pwd)"
FLAG="$CLAUDE_PROJECT_DIR/.claude/.needs-compound"
DONE="$CLAUDE_PROJECT_DIR/.claude/.compound-done"
FLAG_SH="$DIR/compound-flag.sh"
STOP_SH="$DIR/compound-reminder.sh"

# Hermetic `gh` stub so head-ref resolution can be forced to "unresolved" (mirrors the
# post-`--delete-branch` race ADR-0005 guards) without a network call. On PATH only for
# tests that opt in via $GHSTUB_PATH.
GHSTUB_DIR="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$GHSTUB_DIR/gh"
chmod +x "$GHSTUB_DIR/gh"
GHSTUB_PATH="$GHSTUB_DIR:$PATH"
trap 'rm -rf "$GHSTUB_DIR"' EXIT

pass=0; fail=0
ok()   { printf '  PASS: %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL: %s\n' "$1"; fail=$((fail+1)); }
reset(){ rm -f "$FLAG" "$DONE"; }
fresh_await(){ printf 'await=%s\n' "$(date +%s 2>/dev/null || echo 0)" > "$DONE"; }

# --- compound-flag.sh: arming ---
reset
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

# --- compound-flag.sh: clearing + identity marker (ADR-0005) ---
reset; : > "$FLAG"
printf '{"tool_name":"Skill","tool_input":{"skill":"compound-engineering:ce-compound"}}' | bash "$FLAG_SH"
[ -f "$FLAG" ] && bad "must clear on ce-compound Skill" || ok "clears on ce-compound Skill"
grep -q '^await=' "$DONE" 2>/dev/null && ok "ce-compound writes an await marker (state A)" || bad "did not write await marker"

reset; : > "$FLAG"
printf '{"tool_name":"Read","tool_input":{"file_path":".claude/hooks/compound-flag.sh"}}' | bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "does NOT clear on Read of the hook file" || bad "wrongly cleared on Read of hook file"

reset; : > "$FLAG"
printf '{"tool_name":"Bash","tool_input":{"command":"grep -r compound-engineering ."}}' | bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "does NOT clear on Bash grep for compound-engineering" || bad "wrongly cleared on grep"

# --- Identity capture at gh pr create (state A -> state B) ---
reset; fresh_await
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create --base main --title x"},"tool_response":"https://github.com/zone17/diamond-ledger/pull/42\n"}' | bash "$FLAG_SH"
grep -q '^pr=42$' "$DONE" 2>/dev/null && ok "captures compound PR number at gh pr create (fresh await)" || bad "did not capture compound PR number"

reset   # no await marker present
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create --base main"},"tool_response":"https://github.com/zone17/diamond-ledger/pull/99\n"}' | bash "$FLAG_SH"
[ -f "$DONE" ] && bad "must NOT capture a PR with no await marker" || ok "does NOT capture PR without a fresh await marker"

reset; printf 'await=1\n' > "$DONE"   # stale await (1970)
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create"},"tool_response":"https://github.com/zone17/diamond-ledger/pull/7\n"}' | bash "$FLAG_SH"
grep -q '^pr=' "$DONE" 2>/dev/null && bad "must NOT capture with a stale await marker (TTL)" || ok "does NOT capture with a stale await marker (TTL expired)"

# --- Identity backstop at merge: skip exactly the captured compound PR, even unresolved ---
reset; printf 'pr=8\n' > "$DONE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 8 --squash --delete-branch"}}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && bad "identity backstop must skip the captured compound PR" || ok "identity backstop skips the captured compound PR (gh unresolved)"
[ -f "$DONE" ] && bad "marker must be cleared after its PR merges" || ok "marker cleared after the compound PR merges"

# A DIFFERENT PR with an unresolved ref still arms (no clock-based over-suppression — fixes review P2 #2)
reset; printf 'pr=8\n' > "$DONE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 9 --squash --delete-branch"}}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "a substantive merge (different PR#) still arms despite a captured compound PR" || bad "wrongly suppressed a different PR's merge"

# --- Anchored no-network hint (fallback only) ---
# Positive: a NON-docs "Deleted branch <ref> and switched to branch" resolves and ARMS.
reset
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 5 --squash --delete-branch"},"tool_response":"Deleted branch feat/platform/PLAT-9-x and switched to branch main\n"}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "anchored hint resolves a non-docs ref and arms" || bad "anchored hint failed to arm on a non-docs ref"

# A docs/* anchored line skips (no gh).
reset
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 6 --squash --delete-branch"},"tool_response":"Deleted branch docs/product/PROD-2-x and switched to branch main\n"}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && bad "anchored docs/* hint must skip" || ok "anchored docs/* hint skips arming"

# OVER-MATCH GUARD (fixes review P2 #1): a BARE "Deleted branch docs/x" (no "and switched
# to branch") on a NON-docs merge must NOT fabricate a skip — it must ARM.
reset
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 10 --squash"},"tool_response":"PR body mentioned: Deleted branch docs/evil earlier. Merged."}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "bare 'Deleted branch docs/x' substring does NOT falsely skip a non-docs merge" || bad "over-match: bare docs substring wrongly suppressed a non-docs merge"

# --- Malformed marker safety ---
reset; : > "$DONE"   # empty marker file
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 11 --squash --delete-branch"}}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "empty marker file is safe (arms, no crash)" || bad "empty marker file mishandled"

reset; printf 'garbage\n' > "$DONE"   # non-numeric / non-keyed marker
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 12 --squash --delete-branch"}}' \
  | PATH="$GHSTUB_PATH" bash "$FLAG_SH"
[ -f "$FLAG" ] && ok "garbage marker content is safe (arms, no crash)" || bad "garbage marker content mishandled"

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
