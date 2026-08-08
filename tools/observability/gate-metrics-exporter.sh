#!/usr/bin/env bash
# gate-metrics-exporter.sh — turn the enforcement layer's event logs into the
# Prometheus series the Grafana gate-outcome panels read. Run on a timer (cron
# or launchd) or by hand; it is idempotent (pushes an absolute snapshot each
# time, not a delta).
#
# This is a READ-ONLY reader of the event logs plus one HTTP push. It does not
# touch the enforcement hooks — the hooks already emit guardrail_block and
# supply_chain_decision events; this only aggregates and exposes them, so the
# OWED gate-outcome panels light up without editing the machine layer.
#
# Series pushed (job=ce-gate-metrics):
#   ce_guardrail_blocks_total{hook="..."}          — blocks fired, by enforcement hook
#   ce_supply_chain_decisions_total{decision="..."}— supply-chain gate verdicts
#   ce_pipeline_events_total{event="..."}          — pr_merge / pr_create / git_push counts
#
# USAGE:
#   tools/observability/gate-metrics-exporter.sh            # aggregate + push
#   tools/observability/gate-metrics-exporter.sh --dry-run  # print the exposition, push nothing
#
# ENV:
#   CE_METRICS_DIR   default ~/.claude/metrics
#   PUSHGATEWAY_URL  default http://localhost:9091

set -euo pipefail

CE_METRICS_DIR="${CE_METRICS_DIR:-$HOME/.claude/metrics}"
PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-http://localhost:9091}"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

command -v python3 >/dev/null 2>&1 || { echo "gate-metrics-exporter: python3 required" >&2; exit 1; }

CE_EVENTS="$CE_METRICS_DIR/ce-events.jsonl"
SC_EVENTS="$CE_METRICS_DIR/supply-chain-events.jsonl"

# Build the Prometheus exposition from the event logs. Python does the JSON
# aggregation; label values are sanitized to [a-zA-Z0-9_-] so a malformed hook
# name cannot break the exposition format.
exposition=$(python3 - "$CE_EVENTS" "$SC_EVENTS" <<'PY'
import json, sys, re
ce_path, sc_path = sys.argv[1], sys.argv[2]
def san(s):
    return re.sub(r'[^A-Za-z0-9_-]', '_', str(s or 'unknown'))
blocks, decisions, pipeline = {}, {}, {}
PIPELINE_EVENTS = {'pr_merge', 'pr_create', 'git_push', 'git_commit'}
try:
    for line in open(ce_path):
        try: e = json.loads(line)
        except Exception: continue
        t = e.get('type')
        if t == 'guardrail_block':
            blocks[san(e.get('hook'))] = blocks.get(san(e.get('hook')), 0) + 1
        elif t in PIPELINE_EVENTS:
            pipeline[t] = pipeline.get(t, 0) + 1
except FileNotFoundError:
    pass
try:
    for line in open(sc_path):
        try: e = json.loads(line)
        except Exception: continue
        if e.get('type') == 'supply_chain_decision':
            d = san(e.get('decision'))
            decisions[d] = decisions.get(d, 0) + 1
except FileNotFoundError:
    pass
out = []
out.append('# TYPE ce_guardrail_blocks_total counter')
for hook, n in sorted(blocks.items()):
    out.append(f'ce_guardrail_blocks_total{{hook="{hook}"}} {n}')
out.append('# TYPE ce_supply_chain_decisions_total counter')
for d, n in sorted(decisions.items()):
    out.append(f'ce_supply_chain_decisions_total{{decision="{d}"}} {n}')
out.append('# TYPE ce_pipeline_events_total counter')
for ev, n in sorted(pipeline.items()):
    out.append(f'ce_pipeline_events_total{{event="{ev}"}} {n}')
print('\n'.join(out))
PY
)

# CI gate pass/fail by job, per repo. Best-effort: reads the last runs of the
# four gate workflows across the fleet via gh, and appends
# ce_ci_gate_runs_total{repo,job,conclusion}. Skips silently when gh is missing
# or unauthenticated (a scheduled run must never hang or fail on this).
CI_REPOS="${CI_GATE_REPOS:-zone17/WorkAlly zone17/llm-wiki-saas zone17/good-local zone17/diamond-ledger}"
if command -v gh >/dev/null 2>&1; then
  ci_lines=$(python3 - <<'PYHDR'
print('# TYPE ce_ci_gate_runs_total counter')
PYHDR
)
  ci_tmp=$(mktemp "${TMPDIR:-/tmp}/ce-ci-runs-XXXXXX.json")
  for repo in $CI_REPOS; do
    # Pass the runs JSON via a FILE (argv), not stdin: `python3 - <<'PY'` uses the
    # heredoc for stdin, so a piped body would be ignored. The script opens argv.
    timeout 20 gh run list -R "$repo" --limit 40 \
      --json workflowName,conclusion,event > "$ci_tmp" 2>/dev/null || printf '[]' > "$ci_tmp"
    agg=$(python3 - "$repo" "$ci_tmp" <<'PY'
import json, sys, re
repo, path = sys.argv[1], sys.argv[2]
def san(s): return re.sub(r'[^A-Za-z0-9_-]', '_', str(s or 'unknown'))
GATES = {'mutation-testing','changed-lines-coverage','evals','a11y-perf'}
counts = {}
try:
    with open(path) as fh: runs = json.load(fh)
except Exception: runs = []
for r in runs:
    wf = r.get('workflowName','')
    if wf not in GATES: continue
    key = (san(repo), san(wf), san(r.get('conclusion') or 'pending'))
    counts[key] = counts.get(key, 0) + 1
for (rp, job, concl), n in sorted(counts.items()):
    # Label is `workflow`, NOT `job`: the pushgateway reserves `job` for its own
    # grouping label and would overwrite ours, collapsing every workflow's rows
    # into one and failing the push as inconsistent.
    print(f'ce_ci_gate_runs_total{{repo="{rp}",workflow="{job}",conclusion="{concl}"}} {n}')
PY
)
    [ -n "$agg" ] && ci_lines="$ci_lines
$agg"
  done
  rm -f "$ci_tmp"
  exposition="$exposition
$ci_lines"
fi

if $DRY_RUN; then
  printf '%s\n' "$exposition"
  exit 0
fi

# One push of the absolute snapshot. Bounded timeout so a down pushgateway is a
# clean skip, not a hang (this may run on a timer).
if printf '%s\n' "$exposition" | curl -sS --max-time 10 --data-binary @- \
     "$PUSHGATEWAY_URL/metrics/job/ce-gate-metrics" >/dev/null 2>&1; then
  n=$(printf '%s\n' "$exposition" | grep -c '^ce_' || true)
  echo "gate-metrics-exporter: pushed $n series to $PUSHGATEWAY_URL (job=ce-gate-metrics)"
else
  echo "gate-metrics-exporter: pushgateway unreachable at $PUSHGATEWAY_URL — skipped (no series pushed)" >&2
  exit 0
fi
