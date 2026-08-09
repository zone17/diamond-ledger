#!/usr/bin/env bash
# pipeline-status-test.sh — fixture tests for tools/pipeline-status.sh, focused
# on the roadmap parser and the --next-feature/--next-slug selection the
# idea-to-delivery workflow's gate depends on.
#
# Every fixture below is a failure mode that was actually reproduced during the
# 2026-08-08 ce-code-review of the Feature Backlog layer (findings #4-#10 of
# that review): silent section drops, TAB field shifts, FAILED-verification
# false "verified", v1-line leaks, zero-item "Backlog complete", control-char
# passthrough. A change that reintroduces any of them fails here first.
#
# USAGE: bash tools/tests/pipeline-status-test.sh   (from the repo root)
# EXIT: 0 all pass; 1 any failure.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/tools/pipeline-status.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot locate tools/pipeline-status.sh"; exit 1; }

PASS=0; FAIL=0
t() { # name expected_substring actual
  local name="$1" want="$2" got="$3"
  case "$got" in
    *"$want"*) PASS=$((PASS+1)); echo "  ok: $name" ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: $name"; echo "        want substring: $want"; echo "        got: $(printf '%s' "$got" | head -c 200)" ;;
  esac
}
t_not() { # name forbidden_substring actual
  local name="$1" bad="$2" got="$3"
  case "$got" in
    *"$bad"*) FAIL=$((FAIL+1)); echo "  FAIL: $name (found forbidden: $bad)" ;;
    *) PASS=$((PASS+1)); echo "  ok: $name" ;;
  esac
}

mkfix() { # writes a minimal valid 2-item roadmap (1 v1 + 1 deferred) to $DIR/docs/roadmap.md
  mkdir -p "$DIR/docs"
  cat > "$DIR/docs/roadmap.md" <<'EOF'
# Roadmap — fixture

## Backlog

### 1. Alpha Feature
- Slug: `alpha-feature`
- Status: not-started
- Size: M
- Serves: "the alpha promise"
- Feeds: A1
- Depends: —

Alpha does the first thing a user needs.

## v1 line

**Everything below this line is not v1.**

### 2. Deferred Feature
- Slug: `deferred-feature`
- Status: not-started
- Size: L
- Serves: "a later promise"
- Feeds: none
- Depends: —

Deferred does a later thing.

## Promised but unplanned

| Promise (verbatim) | Disposition |
|---|---|
EOF
}

run() { (cd "$DIR" && PIPELINE_STATUS_OUT="$DIR/status.json" bash "$SCRIPT" "$@" 2>&1); }

echo "pipeline-status fixture tests"

# ── 1. happy path ────────────────────────────────────────────────────────────
DIR=$(mktemp -d); mkfix
out=$(run --next-feature)
t "happy: proposes the v1 item" "Slug: alpha-feature" "$out"
t "happy: brief extracted" "Alpha does the first thing" "$out"
slug=$(run --next-slug)
t "happy: --next-slug bare" "alpha-feature" "$slug"
run >/dev/null; par=$(jq -c '.backlog.parse' "$DIR/status.json")
t "happy: 2 sections 0 malformed" '{"sections":2,"malformed":0}' "$par"
v1flag=$(jq -r '.backlog.items[1].v1' "$DIR/status.json")
t "happy: deferred item v1=false" "false" "$v1flag"
rm -rf "$DIR"

# ── 2. v1 filter: v1 shipped -> deferred item NOT proposed ──────────────────
DIR=$(mktemp -d); mkfix
sed -i '' -e 's/^- Status: not-started$/- Status: shipped/' "$DIR/docs/roadmap.md" 2>/dev/null || sed -i -e '0,/^- Status: not-started$/s//- Status: shipped/' "$DIR/docs/roadmap.md"
# (BSD sed lacks 0, addressing: shipped both; re-fix the deferred one back)
python3 - "$DIR/docs/roadmap.md" <<'PY'
import sys
p=sys.argv[1]; lines=open(p).read().split('\n')
seen=0
for i,l in enumerate(lines):
    if l.startswith('- Status:'):
        seen+=1
        lines[i]='- Status: shipped' if seen==1 else '- Status: not-started'
open(p,'w').write('\n'.join(lines))
PY
out=$(run --next-feature)
t "v1-complete: names deferred count, does NOT propose deferred" "v1 backlog complete" "$out"
t_not "v1-complete: deferred slug not proposed" "Slug: deferred-feature" "$out"
rm -rf "$DIR"

# ── 3. FAILED verification report must NOT stage verified ───────────────────
DIR=$(mktemp -d); mkfix
mkdir -p "$DIR/docs/verification" "$DIR/docs/flows"
echo "flow" > "$DIR/docs/flows/alpha-feature.md"
printf '# Verification alpha-feature\n**Result:** FAILED\n' > "$DIR/docs/verification/alpha-feature-2026.md"
stage=$(run >/dev/null; jq -r '.backlog.items[0].stage' "$DIR/status.json")
t "FAILED report: stage stays in-design (not verified)" "in-design" "$stage"
printf '# Verification alpha-feature\n**Result:** PASSED\n' > "$DIR/docs/verification/alpha-feature-2026.md"
stage=$(run >/dev/null; jq -r '.backlog.items[0].stage' "$DIR/status.json")
t "PASSED report: stage becomes verified" "verified" "$stage"
rm -rf "$DIR"

# ── 4. indented Slug line: loosened regex still parses ──────────────────────
DIR=$(mktemp -d); mkfix
python3 - "$DIR/docs/roadmap.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
open(p,'w').write(t.replace('- Slug: `alpha-feature`','  - Slug: `alpha-feature`',1))
PY
out=$(run --next-feature)
t "indented Slug: still parsed (no silent drop)" "Slug: alpha-feature" "$out"
rm -rf "$DIR"

# ── 5. missing Slug line: loud malformed, BLOCKED at the gate ───────────────
DIR=$(mktemp -d); mkfix
python3 - "$DIR/docs/roadmap.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
open(p,'w').write(t.replace('- Slug: `alpha-feature`\n','',1))
PY
out=$(run --next-feature)
t "missing Slug: BLOCKED (not silently dropped)" "BLOCKED" "$out"
rm -rf "$DIR"

# ── 6. TAB in a field: no field shift, no crash, no fail-open --check ───────
DIR=$(mktemp -d); mkfix
printf 'x' > "$DIR/docs/PRFAQ.md"  # give --check something real
mkdir -p "$DIR/.specify/memory"; printf 'law' > "$DIR/.specify/memory/constitution.md"
python3 - "$DIR/docs/roadmap.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
open(p,'w').write(t.replace('### 1. Alpha Feature','### 1. Alpha\tFeature',1))
PY
out=$(run --next-feature); rc=$?
t "TAB in name: still proposes the item" "Slug: alpha-feature" "$out"
(cd "$DIR" && PIPELINE_STATUS_OUT="$DIR/status.json" bash "$SCRIPT" --check constitution >/dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && { PASS=$((PASS+1)); echo "  ok: TAB in roadmap: --check constitution still exit 0"; } || { FAIL=$((FAIL+1)); echo "  FAIL: --check broke on roadmap TAB (exit $rc)"; }
v1flag=$(run >/dev/null; jq -r '.backlog.items[1].v1' "$DIR/status.json")
t "TAB in name: deferred v1 flag unshifted" "false" "$v1flag"
rm -rf "$DIR"

# ── 7. zero parseable items but file present: BLOCKED, not 'complete' ───────
DIR=$(mktemp -d); mkdir -p "$DIR/docs"
printf '# Roadmap\n\nprose only, no items\n' > "$DIR/docs/roadmap.md"
out=$(run --next-feature)
t "zero items: BLOCKED" "BLOCKED" "$out"
t_not "zero items: never says Backlog complete" "Backlog complete" "$out"
rm -rf "$DIR"

# ── 8. control chars in roadmap: stripped from output ───────────────────────
DIR=$(mktemp -d); mkfix
python3 - "$DIR/docs/roadmap.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
open(p,'w').write(t.replace('Alpha does the first thing a user needs.',
  'Alpha does the first thing \x1b[2J\x07a user needs.',1))
PY
out=$(run --next-feature)
esc=$(printf '\033')
case "$out" in
  *"$esc"*) FAIL=$((FAIL+1)); echo "  FAIL: ESC byte survived into --next-feature output" ;;
  *) PASS=$((PASS+1)); echo "  ok: control chars stripped from output" ;;
esac
rm -rf "$DIR"

# ── 9. bad slug charset: malformed + BLOCKED ────────────────────────────────
DIR=$(mktemp -d); mkfix
python3 - "$DIR/docs/roadmap.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
open(p,'w').write(t.replace('- Slug: `alpha-feature`','- Slug: `../escape*glob`',1))
PY
out=$(run --next-feature)
t "bad slug charset: BLOCKED" "BLOCKED" "$out"
rm -rf "$DIR"

# ── 10. no roadmap at all: graceful fallback, exit 0 ────────────────────────
DIR=$(mktemp -d); mkdir -p "$DIR/docs"
out=$(run --next-feature); rc=$?
t "no roadmap: fallback message" "No docs/roadmap.md" "$out"
[ "$rc" -eq 0 ] && { PASS=$((PASS+1)); echo "  ok: no roadmap: exit 0"; } || { FAIL=$((FAIL+1)); echo "  FAIL: exit $rc"; }
rm -rf "$DIR"

echo ""
echo "pipeline-status tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]