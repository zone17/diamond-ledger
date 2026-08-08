#!/usr/bin/env bash
# pipeline-status.sh — deterministic scan of where a repo sits in the
# idea-to-delivery pipeline. Emits docs/pipeline-status.json.
#
# Deterministic and side-effect-free except for the one JSON write: it reads the
# tree, never the network, never git history state that a re-run could change.
# The idea-to-delivery workflow's step 0 reads this file to skip phases whose
# artifact already exists, so this scanner is the source of truth for "what is
# already done" — it must never guess. A phase is done only when its artifact is
# present on disk; absence is reported as not-done, never inferred.
#
# USAGE:
#   tools/pipeline-status.sh                 # scan cwd, write docs/pipeline-status.json, print summary
#   tools/pipeline-status.sh --json          # also print the JSON to stdout
#   tools/pipeline-status.sh --check <phase> # exit 0 if <phase> is done, 1 if not (for workflow step-0)
#   PIPELINE_STATUS_OUT=path tools/pipeline-status.sh   # override output path

set -euo pipefail

OUT="${PIPELINE_STATUS_OUT:-docs/pipeline-status.json}"
MODE="summary"; CHECK_PHASE=""
for arg in "$@"; do
  case "$arg" in
    --json) MODE="json" ;;
    --check) MODE="check" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) [ "$MODE" = "check" ] && CHECK_PHASE="$arg" ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "pipeline-status: jq is required" >&2; exit 1; }

# A foundation phase is (id, human label, artifact glob). Done = at least one
# matching path exists and is non-empty. The globs are the pipeline's own
# artifact contract; keep them in sync with README-pipeline.md's step table.
foundation_check() {
  # $1 glob (may be a directory or a file); done if a non-empty file matches.
  local g="$1" f
  for f in $g; do
    [ -f "$f" ] && [ -s "$f" ] && return 0
  done
  return 1
}

phase_json() {  # id label done evidence
  jq -n --arg id "$1" --arg label "$2" --argjson done "$3" --arg ev "$4" \
    '{id:$id, label:$label, done:$done, evidence:$ev}'
}

# --- Foundation phases (once per project) -----------------------------------
# One record per phase: "id|label|space-separated globs". No associative arrays
# so this stays portable to bash 3.2 (macOS /bin/bash). Order is pipeline order.
FOUNDATION_PHASES='product-idea|PR/FAQ (the bet)|docs/PRFAQ.md docs/prfaq.md
discovery|Discovery (validate the bet)|docs/discovery/00-discovery-brief.md docs/discovery/*.md
design-foundation|Design foundation|DESIGN.md
constitution|Constitution (binding law)|.specify/memory/constitution.md'

foundation_entries="[]"
foundation_done=0; foundation_total=0
while IFS='|' read -r id label globs; do
  [ -n "$id" ] || continue
  foundation_total=$((foundation_total+1))
  done=false; ev=""
  for g in $globs; do
    if foundation_check "$g"; then
      done=true
      for f in $g; do [ -f "$f" ] && { ev="$f"; break; }; done
      break
    fi
  done
  $done && foundation_done=$((foundation_done+1))
  foundation_entries=$(jq --argjson e "$(phase_json "$id" "$label" "$done" "$ev")" '. + [$e]' <<< "$foundation_entries")
done <<< "$FOUNDATION_PHASES"

# --- Features (per-feature progress) ----------------------------------------
# A feature is discovered from docs/flows/<slug>.md (the feature-design output
# that gates /speckit.specify). For each, report the downstream artifacts.
features="[]"
if [ -d docs/flows ]; then
  for flow in docs/flows/*.md; do
    [ -f "$flow" ] || continue
    slug=$(basename "$flow" .md)
    [ "$slug" = ".gitkeep" ] && continue
    spec=""; for s in "specs/$slug/spec.md" ".specify/specs/$slug/spec.md" "specs/"*"$slug"*"/spec.md"; do
      for f in $s; do [ -f "$f" ] && [ -s "$f" ] && { spec="$f"; break 2; }; done
    done
    plan=""; for p in "specs/$slug/plan.md" ".specify/specs/$slug/plan.md"; do [ -f "$p" ] && plan="$p" && break; done
    tasks=""; for t in "specs/$slug/tasks.md" ".specify/specs/$slug/tasks.md"; do [ -f "$t" ] && tasks="$t" && break; done
    # design sign-off = a "## UI Mockup" section signed into the spec
    signoff=false; [ -n "$spec" ] && grep -q '^##[[:space:]]*UI Mockup' "$spec" 2>/dev/null && signoff=true
    features=$(jq \
      --arg slug "$slug" --arg flow "$flow" --arg spec "$spec" --arg plan "$plan" \
      --arg tasks "$tasks" --argjson signoff "$signoff" \
      '. + [{
        slug:$slug, flow:$flow,
        feature_design:{done:true, evidence:$flow},
        specify:{done:($spec|length>0), evidence:$spec},
        design_signoff:{done:$signoff, evidence:($spec)},
        plan:{done:($plan|length>0), evidence:$plan},
        tasks:{done:($tasks|length>0), evidence:$tasks}
      }]' <<< "$features")
  done
fi

# --- Assemble ---------------------------------------------------------------
# next_phase = the first not-done foundation phase (in pipeline order), else
# "feature-work" once the foundation is complete.
next_phase=$(jq -r '[.[] | select(.done==false)][0].id // "feature-work"' <<< "$foundation_entries")

result=$(jq -n \
  --argjson foundation "$foundation_entries" \
  --argjson features "$features" \
  --arg next "$next_phase" \
  --argjson fdone "$foundation_done" --argjson ftotal "$foundation_total" \
  '{
     schema: "pipeline-status/v1",
     foundation: {done: $fdone, total: $ftotal, phases: $foundation},
     features: $features,
     next_phase: $next
   }')

# --check <phase> — exit status only, for the workflow step-0 skip.
if [ "$MODE" = "check" ]; then
  [ -n "$CHECK_PHASE" ] || { echo "pipeline-status: --check needs a phase id" >&2; exit 2; }
  if jq -e --arg id "$CHECK_PHASE" '.foundation.phases[] | select(.id==$id and .done==true)' >/dev/null <<< "$result"; then
    exit 0
  fi
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$result" > "$OUT"

if [ "$MODE" = "json" ]; then
  printf '%s\n' "$result"
fi

# Human summary
echo "Pipeline status ($OUT):"
jq -r '.foundation.phases[] | "  [\(if .done then "x" else " " end)] \(.label)\(if .evidence != "" then "  <- " + .evidence else "" end)"' <<< "$result"
fc=$(jq '.features | length' <<< "$result")
if [ "$fc" -gt 0 ]; then
  echo "  features:"
  jq -r '.features[] | "    \(.slug): design\(if .feature_design.done then "+" else "-" end) spec\(if .specify.done then "+" else "-" end) signoff\(if .design_signoff.done then "+" else "-" end) plan\(if .plan.done then "+" else "-" end) tasks\(if .tasks.done then "+" else "-" end)"' <<< "$result"
fi
echo "  next: $(jq -r '.next_phase' <<< "$result")"
