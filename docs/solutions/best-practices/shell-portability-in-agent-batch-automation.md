---
module: development-workflow
date: 2026-06-02
last_updated: 2026-06-02
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - "An agent writes an inline shell script that loops to create/edit many resources (GitHub issues, files, API calls)"
  - "A script uses bash arrays (read -a / read -ra), printf-into-arrays, or BSD-incompatible sed/awk"
  - "Batch automation produced many outputs but they are malformed (empty fields, missing labels) yet the run reported success"
  - "Building an epic -> story -> subtask tree of GitHub issues via gh"
related_components:
  - github-issues
  - ci-cd
tags:
  - shell
  - zsh
  - bash
  - bsd-sed
  - macos
  - gh-cli
  - github-sub-issues
  - batch-automation
  - portability
---

# Shell portability in agent batch automation (zsh + BSD tools), and spot-check before you batch

## Context

While generating the GitHub issue tree for spec 001 (100 issues: epics -> stories -> subtasks), an
inline shell script built each issue's labels with bash arrays and parsed task titles with `sed`. It
**silently created 18 malformed issues** (empty titles, no labels) before the error was noticed — the
script kept going past the failures and printed `+T001 #21` for each, so the run *looked* successful.

Two portability faults, both specific to the Claude Code Bash tool environment on macOS:

1. **The Bash tool runs `zsh`, not `bash`.** Bash-isms in an *inline* command fail:
   - `read -ra ARR <<< "$str"` and `read -a ARR ...` → zsh errors `read: bad option: -a` (zsh uses
     `read -A`). The array stayed empty, so every `--label` flag silently vanished.
2. **macOS `sed` is BSD `sed`, not GNU.** An inline label/branch loop to strip leading `[tag]`
   groups — `sed -E 's/^- \[ \] T[0-9]+ //; :a; s/^\[[^]]*\] *//; ta'` — errors with
   `sed: 1: "...": unused label 'a'` on BSD sed (its `:label`/`t` branch syntax differs and does not
   accept the GNU one-liner form). The description came back empty, so titles became bare `T001 — `.

Because neither failure aborted the loop (`set -e` was not in effect for the inline command, and the
failing substitutions produced empty strings rather than non-zero exits at the `gh` call), the bad
state propagated to 18 live issues.

## Guidance

**1. Write batch automation as a `bash` script file, not an inline zsh command.**

```bash
# Write the logic to a file with an explicit bash shebang, then run it with bash.
cat > /tmp/build.sh <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
# ... arrays, functions, loops ...
SCRIPT
bash /tmp/build.sh          # NOT: source it in zsh, NOT: paste the array logic inline
```

A file run under `bash` gets real bash arrays, `read -ra`, `[[ ... ]]`, etc. — none of which are
guaranteed in the zsh the Bash tool launches.

**2. Parse text with `perl` (or `awk`), not BSD `sed` label loops.** Perl is present on macOS and is
portable:

```bash
# strip "- [ ] T013 " then iteratively strip leading [..] tag groups
desc=$(printf '%s' "$line" | perl -pe 's/^- \[ \] T\d+ //; 1 while s/^\s*\[[^\]]*\]\s*//;')
```

**3. Spot-check the FIRST created resource before batching the rest.** Create one issue/file, read it
back (`gh issue view N --json title,labels`), confirm title+labels are correct, *then* loop. One
verification call would have caught all 18 here. This is the cheapest guardrail.

**4. Make loops fail loud.** Use `set -euo pipefail` in the script file and have the create step assert
its inputs are non-empty (e.g. `[ -n "$names" ] || { echo "empty labels for $t"; exit 1; }`) so a
parse failure stops the batch instead of writing garbage.

**5. Repair in place, don't delete.** The fix was `gh issue edit <n> --title ... --add-label ...`
(re-deriving title/labels with the corrected parser) and re-running only the label/title step — no
issues were deleted, links were already correct. Editing is non-destructive and preserves issue
numbers and any existing sub-issue links.

### Concrete recipe: GitHub native sub-issue trees via `gh`

The same script built an epic -> story -> subtask tree. Native sub-issues (not task-list checkboxes)
need the GitHub REST sub-issues endpoint, and the key gotcha is **the child's DATABASE id, not its
issue number**:

```bash
# create child, then link it under a parent issue as a NATIVE sub-issue
child_num=$(gh issue create -R "$REPO" --title "..." --label "..." | grep -oE '[0-9]+$')
child_id=$(gh api "repos/$REPO/issues/$child_num" --jq .id)        # database id != issue number
gh api -X POST "repos/$REPO/issues/$PARENT_NUM/sub_issues" -F sub_issue_id="$child_id"
# verify: gh api repos/$REPO/issues/$PARENT_NUM/sub_issues --jq '.[].number'
```

Pattern that worked: epic-per-squad issues at the top, story issues linked under each epic, subtask
issues linked under each story; labels (`squad:*`, `epic`/`story`/`subtask`, `us:*`, `mvp`) + a
milestone carry the cross-cutting views.

## Why This Matters

A batch automation that fails *silently* is worse than one that crashes: it produces plausible-looking
output (issues got created, the log scrolled green) that a reviewer trusts. The cost here was a wasted
round plus 18 issues to repair. The root failure mode — **trusting a loop's success log instead of
verifying its actual output** — is the same shape as the SC-003 dead-counter and the `cwevent`
exit-0 gate documented elsewhere in this repo: *assert on the real signal, not a proxy.*

## When to Apply

Any time an agent writes a shell loop that creates or mutates more than ~3 resources (GitHub issues,
files, API calls, branches) — especially in the Claude Code Bash tool (zsh) on macOS (BSD coreutils).
Write it as a `bash` file, parse with perl, spot-check the first, fail loud.
