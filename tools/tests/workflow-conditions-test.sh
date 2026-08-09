#!/usr/bin/env bash
# workflow-conditions-test.sh — evaluate every `condition:` in the registered
# idea-to-delivery workflow against the INSTALLED spec-kit expression engine,
# on BOTH branches plus the unresolvable-reference case.
#
# WHY: the infix-`contains` incident (DECISIONS.md #22) hid for three workflow
# versions because only the false branch was ever observed — and a broken
# condition also evaluates False. A condition is proven only when (a) the true
# branch fires on true-shaped input, (b) the false branch on false-shaped
# input, and (c) an unresolvable step reference routes to the FAIL-SAFE side
# (do-the-work / gate-pause), never silently past it.
#
# USAGE: bash tools/tests/workflow-conditions-test.sh   (repo root; needs the
#        specify CLI's python env on disk — skips cleanly when absent)
# EXIT: 0 all pass or engine absent (skip); 1 any failure.
set -uo pipefail

ENGINE_DIR=$(dirname "$(head -1 "$(command -v specify 2>/dev/null || echo /dev/null)" 2>/dev/null | sed 's/^#!//')" 2>/dev/null)/..
PYBIN=$(head -1 "$(command -v specify 2>/dev/null || echo /dev/null)" 2>/dev/null | sed 's/^#!//')
if [ -z "$PYBIN" ] || [ ! -x "$PYBIN" ]; then
  echo "workflow-conditions-test: specify CLI not found — skipping (not a failure)"
  exit 0
fi

"$PYBIN" - <<'PY'
import sys
from specify_cli.workflows.expressions import evaluate_condition

class Ctx:
    def __init__(self, inputs=None, steps=None):
        self.inputs = inputs or {}
        self.steps = steps or {}

def out(stdout):
    return {"output": {"stdout": stdout}}

FOUNDATION = "{{ inputs.skip_foundation == false and 'foundation-complete' not in steps.pipeline_status.output.stdout }}"
BACKLOG    = "{{ 'roadmap-present' not in steps.backlog_status.output.stdout }}"
DISCOVERY  = "{{ 'present' in steps.check-discovery-gates.output.stdout }}"

cases = [
    # (name, condition, ctx, expected)
    ("foundation TRUE on incomplete",  FOUNDATION, Ctx({"skip_foundation": False}, {"pipeline_status": out("foundation-incomplete\n")}), True),
    ("foundation FALSE on complete",   FOUNDATION, Ctx({"skip_foundation": False}, {"pipeline_status": out("foundation-complete\n")}), False),
    ("foundation FALSE on skip flag",  FOUNDATION, Ctx({"skip_foundation": True},  {"pipeline_status": out("foundation-incomplete\n")}), False),
    # FAIL-SAFE: unresolvable step reference must mean RUN the foundation
    ("foundation fail-safe on unresolvable ref", FOUNDATION, Ctx({"skip_foundation": False}, {}), True),
    ("backlog TRUE on missing",   BACKLOG, Ctx({}, {"backlog_status": out("roadmap-missing\n")}), True),
    ("backlog FALSE on present",  BACKLOG, Ctx({}, {"backlog_status": out("roadmap-present\n")}), False),
    # FAIL-SAFE: unresolvable ref -> derive-the-backlog branch (which pauses at a gate)
    ("backlog fail-safe on unresolvable ref", BACKLOG, Ctx({}, {}), True),
    ("discovery TRUE on present", DISCOVERY, Ctx({}, {"check-discovery-gates": out("present\n")}), True),
    ("discovery FALSE on missing", DISCOVERY, Ctx({}, {"check-discovery-gates": out("missing\n")}), False),
    # FAIL-SAFE: unresolvable ref -> False -> the BLOCKED gate branch (blocks, never advances)
    ("discovery fail-safe on unresolvable ref", DISCOVERY, Ctx({}, {}), False),
]

fails = 0
for name, cond, ctx, want in cases:
    got = evaluate_condition(cond, ctx)
    ok = got == want
    print(f"  {'ok' if ok else 'FAIL'}: {name} -> {got} (want {want})")
    if not ok:
        fails += 1

print(f"\nworkflow-conditions tests: {len(cases)-fails} passed, {fails} failed")
sys.exit(1 if fails else 0)
PY