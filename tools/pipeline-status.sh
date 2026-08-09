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
#   tools/pipeline-status.sh --next-feature  # one line: topmost unfinished v1 roadmap item
#                                            # (the workflow's gate-start-feature reads this)
#   tools/pipeline-status.sh --next-slug     # bare slug of that item (newline-free), for
#                                            # the workflow's inputs.feature_slug fallback
#   PIPELINE_STATUS_OUT=path tools/pipeline-status.sh   # override output path

set -euo pipefail

OUT="${PIPELINE_STATUS_OUT:-docs/pipeline-status.json}"
MODE="summary"; CHECK_PHASE=""
for arg in "$@"; do
  case "$arg" in
    --json) MODE="json" ;;
    --check) MODE="check" ;;
    --next-feature) MODE="next-feature" ;;
    --next-slug) MODE="next-slug" ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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

# --check <phase> — exit status only, for the workflow step-0 skip. Handled
# BEFORE the features/backlog sections so a malformed docs/roadmap.md (or any
# backlog-parsing failure) can never break the foundation skip primitive.
if [ "$MODE" = "check" ]; then
  [ -n "$CHECK_PHASE" ] || { echo "pipeline-status: --check needs a phase id" >&2; exit 2; }
  if jq -e --arg id "$CHECK_PHASE" '.[] | select(.id==$id and .done==true)' >/dev/null <<< "$foundation_entries"; then
    exit 0
  fi
  exit 1
fi

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

# --- Backlog (docs/roadmap.md burn-down) -------------------------------------
# The roadmap (written by /feature-backlog) is the ordered feature list; each
# item's STAGE is derived from tree artifacts (never from the Status line, which
# is display metadata) — except `shipped`, which only the human sets in the
# roadmap and the scanner trusts as the explicit human act it is.
# Stage ladder: not-started -> in-design (flow) -> specced (spec.md) ->
# building (tasks.md) -> verified (docs/verification report) -> shipped.
ROADMAP="docs/roadmap.md"
backlog="null"
roadmap_sections=0; roadmap_parsed=0; roadmap_malformed=0
if [ -f "$ROADMAP" ] && [ -s "$ROADMAP" ]; then
  backlog="[]"
  # awk emits `SECTIONS <n>` first (integrity: every "### N." heading counts),
  # then one record per parsed section, fields joined by \x1f (unit separator —
  # NOT IFS whitespace, so empty fields survive the read and cannot shift later
  # fields the way TABs did). All fields are scrubbed of control chars at the
  # source so downstream consumers (jq, the gate message, the agent prompt)
  # never see terminal-escape or separator bytes.
  # Field lines are the roadmap format contract (see feature-backlog skill).
  roadmap_records=$(LC_ALL=C awk '
    function scrub(s) { gsub(/[\000-\010\013\014\016-\037\177]/, "", s); gsub(/\t/, " ", s); return s }
    function flush() {
      if (name != "" || slug != "") {
        printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", scrub(name), scrub(slug), scrub(status), scrub(size), scrub(serves), scrub(feeds), v1
      }
      name=""; slug=""; status=""; size=""; serves=""; feeds=""
    }
    BEGIN { v1 = "true" }
    /^## v1 line/       { flush(); v1 = "false"; next }
    /^## Promised but/  { flush(); inledger=1; next }
    inledger            { next }
    /^### /             { flush(); sections++; name=$0; sub(/^### [0-9]+\.[ ]*/, "", name); next }
    /^[[:space:]]*[-*][[:space:]]*Slug:/   { slug=$0;   sub(/^[[:space:]]*[-*][[:space:]]*Slug:[ ]*`?/, "", slug);   sub(/`.*$/, "", slug); gsub(/[ ]/, "", slug); next }
    /^[[:space:]]*[-*][[:space:]]*Status:/ { status=$0; sub(/^[[:space:]]*[-*][[:space:]]*Status:[ ]*/, "", status); sub(/[ ].*$/, "", status); next }
    /^[[:space:]]*[-*][[:space:]]*Size:/   { size=$0;   sub(/^[[:space:]]*[-*][[:space:]]*Size:[ ]*/, "", size);     sub(/[ ].*$/, "", size); next }
    /^[[:space:]]*[-*][[:space:]]*Serves:/ { serves=$0; sub(/^[[:space:]]*[-*][[:space:]]*Serves:[ ]*/, "", serves);
                                             if (serves ~ /^".*"$/) { sub(/^"/, "", serves); sub(/"$/, "", serves) } next }
    /^[[:space:]]*[-*][[:space:]]*Feeds:/  { feeds=$0;  sub(/^[[:space:]]*[-*][[:space:]]*Feeds:[ ]*/, "", feeds);   next }
    END { flush(); printf "SECTIONS %d\n", sections }
  ' "$ROADMAP")
  while IFS=$'\x1f' read -r bname bslug bstatus bsize bserves bfeeds bv1; do
    case "$bname" in
      "SECTIONS "*) roadmap_sections="${bname#SECTIONS }"; continue ;;
    esac
    # A section with a heading but a missing/invalid slug is MALFORMED, not
    # skippable — silent drops put the wrong item in front of the gate.
    case "$bslug" in
      ''|*[!a-z0-9-]*)
        roadmap_malformed=$((roadmap_malformed+1))
        echo "pipeline-status: MALFORMED roadmap section '${bname:-<unnamed>}' — missing or invalid Slug (must match ^[a-z0-9-]+$)" >&2
        continue ;;
    esac
    # v1 comes from parser state, but validate it anyway — a field shift here
    # once flipped a deferred item to v1:true silently.
    case "$bv1" in true|false) ;; *)
      roadmap_malformed=$((roadmap_malformed+1))
      echo "pipeline-status: MALFORMED roadmap record for '$bslug' — v1 flag read as '${bv1:-<empty>}'" >&2
      continue ;;
    esac
    roadmap_parsed=$((roadmap_parsed+1))
    # Derive the stage from artifacts on disk (the scanner never guesses).
    stage="not-started"
    [ -f "docs/flows/$bslug.md" ] && [ -s "docs/flows/$bslug.md" ] && stage="in-design"
    for f in "specs/$bslug/spec.md" ".specify/specs/$bslug/spec.md" "specs/"*"$bslug"*"/spec.md"; do
      [ -f "$f" ] && [ -s "$f" ] && { stage="specced"; break; }
    done
    for f in "specs/$bslug/tasks.md" ".specify/specs/$bslug/tasks.md" "specs/"*"$bslug"*"/tasks.md"; do
      [ -f "$f" ] && [ -s "$f" ] && { stage="building"; break; }
    done
    # `verified` requires the report to SAY it passed — a FAILED acceptance
    # report on disk must not remove the feature from the gate.
    for v in "docs/verification/"*"$bslug"*; do
      if [ -f "$v" ] && [ -s "$v" ] && grep -qiE 'Result:?\**[[:space:]]*PASS' "$v" 2>/dev/null; then
        stage="verified"; break
      fi
    done
    # `shipped` is the one human-set stage: the roadmap's Status line records the
    # human act of shipping (merge to main), which no tree artifact proves.
    [ "$bstatus" = "shipped" ] && stage="shipped"
    backlog=$(jq \
      --arg name "$bname" --arg slug "$bslug" --arg stage "$stage" \
      --arg size "$bsize" --arg serves "$bserves" --arg feeds "$bfeeds" --arg v1 "$bv1" \
      '. + [{name:$name, slug:$slug, stage:$stage, size:$size, serves:$serves, feeds:$feeds, v1:($v1=="true")}]' \
      <<< "$backlog")
  done <<< "$roadmap_records"
  if [ "$roadmap_sections" -ne $((roadmap_parsed + roadmap_malformed)) ]; then
    echo "pipeline-status: WARNING — $roadmap_sections roadmap sections but $((roadmap_parsed + roadmap_malformed)) accounted for; docs/roadmap.md may have drifted from the format contract" >&2
    missing=$((roadmap_sections - roadmap_parsed - roadmap_malformed))
    [ "$missing" -gt 0 ] && roadmap_malformed=$((roadmap_malformed + missing))
  fi
fi

# --- Assemble ---------------------------------------------------------------
# next_phase = the first not-done foundation phase (in pipeline order), else
# "feature-work" once the foundation is complete.
next_phase=$(jq -r '[.[] | select(.done==false)][0].id // "feature-work"' <<< "$foundation_entries")

result=$(jq -n \
  --argjson foundation "$foundation_entries" \
  --argjson features "$features" \
  --argjson backlog "$backlog" \
  --arg next "$next_phase" \
  --argjson sections "$roadmap_sections" --argjson malformed "$roadmap_malformed" \
  --argjson fdone "$foundation_done" --argjson ftotal "$foundation_total" \
  '{
     schema: "pipeline-status/v1",
     foundation: {done: $fdone, total: $ftotal, phases: $foundation},
     features: $features,
     backlog: (if $backlog == null then null else {
       items: $backlog,
       by_stage: ($backlog | group_by(.stage) | map({key: .[0].stage, value: length}) | from_entries),
       parse: {sections: $sections, malformed: $malformed}
     } end),
     next_phase: $next
   }')

# Selection used by --next-feature and --next-slug: topmost UNFINISHED V1 item.
# v1-only: after the v1 line ships, deferred evidence-gated items must not be
# silently proposed as "Next" — that state gets its own explicit message.
next_unfinished() {
  jq -r '[.[] | select(.v1 == true and .stage != "shipped" and .stage != "verified")][0] // empty | @json' <<< "$backlog"
}

# --next-slug — bare slug of the topmost unfinished v1 item (newline-free), for
# the workflow's `| default()` fallbacks on inputs.feature_slug. Empty output
# when there is no next item; deterministic; exit 0 always.
if [ "$MODE" = "next-slug" ]; then
  ni=$(next_unfinished)
  [ -n "$ni" ] && jq -rj '.slug' <<< "$ni"
  exit 0
fi

# --next-feature — one line for the workflow's gate-start-feature. Reads only
# the roadmap + tree (deterministic); exit 0 on every NON-ERROR state, with
# error states worded as BLOCKED so a gate can never present a parser failure
# as a plausible empty backlog.
if [ "$MODE" = "next-feature" ]; then
  if [ "$backlog" = "null" ]; then
    echo "No docs/roadmap.md — run /feature-backlog to derive the backlog, or launch this run with inputs.feature + feature_slug."
    exit 0
  fi
  item_count=$(jq 'length' <<< "$backlog")
  if [ "$roadmap_malformed" -gt 0 ]; then
    echo "BLOCKED: docs/roadmap.md has $roadmap_malformed malformed section(s) ($roadmap_sections sections, $item_count parsed) — fix the roadmap format before approving anything (see the feature-backlog skill's format contract)."
    exit 0
  fi
  if [ "$item_count" -eq 0 ]; then
    echo "BLOCKED: docs/roadmap.md exists but contains no parseable backlog items — do not approve; fix the roadmap or re-run /feature-backlog."
    exit 0
  fi
  next_item=$(next_unfinished)
  if [ -z "$next_item" ]; then
    deferred=$(jq '[.[] | select(.v1 == false and .stage != "shipped" and .stage != "verified")] | length' <<< "$backlog")
    if [ "$deferred" -gt 0 ]; then
      echo "v1 backlog complete — $deferred deferred item(s) remain below the v1 line in docs/roadmap.md. Run /feature-backlog to reconsider scope, or launch with inputs.feature + feature_slug to build one deliberately."
    else
      echo "Backlog complete — every roadmap item is verified or shipped. Run /feature-backlog to regenerate."
    fi
    exit 0
  fi
  # The description paragraph: lines of the item section that are prose (not
  # field lines / headings / quotes / tables), joined to one line — this is the
  # /feature-design G1 brief, passed verbatim. Control chars are stripped so
  # the gate message and the agent prompt never receive terminal-escape bytes.
  nslug=$(jq -r '.slug' <<< "$next_item")
  ndesc=$(LC_ALL=C awk -v want="$nslug" '
    /^### /            { insec=0 }
    /^[[:space:]]*[-*][[:space:]]*Slug:/ { s=$0; sub(/^[[:space:]]*[-*][[:space:]]*Slug:[ ]*`?/, "", s); sub(/`.*$/, "", s); gsub(/[ ]/, "", s); if (s == want) insec=1; next }
    insec && /^[[:space:]]*[-*] / { next }
    insec && /^#/      { insec=0; next }
    insec && /^>/      { next }
    insec && /^\|/     { next }
    insec && NF        { printf "%s ", $0 }
  ' "$ROADMAP" | LC_ALL=C tr -d '\000-\010\013-\037\177' | sed -e 's/[[:space:]]*$//')
  jq -r --arg desc "$ndesc" \
    '(if .stage == "not-started" then "Next" else "Resume (stage: " + .stage + ")" end)
     + ": " + .name + " — serves " + (.serves | if length > 80 then .[0:77] + "..." else . end | @json)
     + ", feeds " + .feeds + ". Slug: " + .slug + ". Brief: " + $desc' <<< "$next_item" \
    | LC_ALL=C tr -d '\000-\010\013-\037\177'
  exit 0
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
if jq -e '.backlog != null' >/dev/null <<< "$result"; then
  echo "  backlog ($(jq '.backlog.items | length' <<< "$result") items, docs/roadmap.md):"
  jq -r '.backlog.by_stage | to_entries[] | "    \(.key): \(.value)"' <<< "$result"
fi
echo "  next: $(jq -r '.next_phase' <<< "$result")"
