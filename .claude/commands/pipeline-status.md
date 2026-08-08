---
description: Show where this repo sits in the idea-to-delivery pipeline (deterministic scan)
---

Run the deterministic pipeline scanner and report the result to the user:

```bash
bash tools/pipeline-status.sh
```

This writes `docs/pipeline-status.json` (schema `pipeline-status/v1`) and prints a
checklist of the foundation phases (product-idea → discovery → design-foundation →
constitution), per-feature progress (feature-design → specify → design-signoff →
plan → tasks), and the `next_phase`.

The scan is source-of-truth for "what is already done": a phase is done only when
its artifact exists on disk. The idea-to-delivery workflow's step 0 uses
`tools/pipeline-status.sh --check <phase>` (exit 0 = done) to skip foundation
phases that are already complete, so re-running the pipeline on an established
repo does not re-do finished work.

After reporting, if the user asked "where are we" or "what's next", lead with
`next_phase` and the next command from README-pipeline.md's step table.
