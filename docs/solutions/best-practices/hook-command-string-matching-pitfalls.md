---
module: enforcement-hooks
date: 2026-06-01
last_updated: 2026-06-01
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - "Writing a Claude Code hook that triggers on tool calls or git operations"
  - "An enforcement hook either fires when it should not, or fails to fire when it should"
  - "A hook re-fetches state (a branch, a status) via a live call right after the action it gates"
related_components:
  - development_workflow
tags:
  - hooks
  - enforcement
  - false-positive
  - branch-discipline
  - tool-name
  - claude-code
  - race-condition
---

# Hooks that pattern-match command strings have three blind spots

## Context

Enforcement hooks commonly inspect a payload as raw text and `grep` for a trigger phrase. Two
distinct, costly failure modes surfaced this session while building the compound-loop gate and while
relying on the global `branch-discipline.sh` hook.

## Guidance

**1. Scanning the *whole* tool payload for a trigger phrase causes false arm AND false clear.**
A PostToolUse payload contains `tool_name`, `tool_input`, **and** `tool_response`. A hook that greps
the entire blob for, say, `gh pr merge` will fire on a doc edit or commit message that merely
*mentions* the phrase. Worse, a hook that clears a gate when it sees `ce-compound` will clear it the
moment any tool **reads the hook file itself** or greps the repo for that token — silently defeating
the gate. Fix: extract and switch on `tool_name` first, then match the specific field:

```bash
tool_name="$(printf '%s' "$payload" \
  | grep -Eo '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/' || true)"

# arm only on an actual Bash `gh pr merge`; clear only on a Skill invocation of the compound skill
[ "$tool_name" = "Bash" ]  && grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge' <<<"$payload" && arm
[ "$tool_name" = "Skill" ] && grep -Eq 'ce-compound|compound-engineering' <<<"$payload" && clear
```

**2. A hook that matches the Bash *command string* is blind to git invoked inside a script.**
`branch-discipline.sh` blocks `git commit`/`git push` by pattern-matching the bash command. A
vendored script that runs `git commit` internally (e.g. Spec Kit's `auto-commit.sh`) is invoked as
`bash auto-commit.sh` — the hook never sees `git commit`, so the guard is bypassed. Defense in depth:
put the invariant where the action happens (a git `pre-commit`/`pre-push` hook, or a branch guard
inside the script), not only at the command-string layer.

**3. A hook that re-fetches volatile state via a live call races the action that triggered it —
and the "read it from the payload instead" fix walks straight back into pitfall #1.**
A PostToolUse hook runs *after* the command, so state the command changed may already be moving.
The compound-loop gate (ADR-0004) skipped `docs/*` merges by resolving the PR head branch with a
live `gh pr view <n>` — but `gh pr merge <n> --delete-branch` deletes that branch, the lookup
**raced the deletion / API propagation** and returned empty, the `docs/*` skip fell through to its
arm-default, and the gate armed on the compound doc's own merge (the recursion it existed to
prevent).

The instructive part is the *first fix* (ADR-0005, caught in code review before merge): "don't
re-fetch — read `Deleted branch <ref>` from the payload." Done naively that greps the **whole
payload** for the phrase and lets it override the lookup — which is **pitfall #1 all over again**:
any `Deleted branch docs/x` substring in a PR body, commit message, or unrelated output fabricates a
false `docs/*` skip and silently drops a real reminder. The author's happy-path tests passed; an
adversarial reviewer caught it. Lesson: re-read this file's own pitfall #1 whenever you reach for a
payload string.

The robust resolution that survived review:
- **Keep the authoritative lookup primary** (`gh pr view` does return the ref reliably post-merge in
  practice; the race is transient and narrow).
- **If you use a payload hint, anchor it to the tool's *real* output line, as a fallback only** —
  here `Deleted branch <ref> and switched to branch`, never a bare `Deleted branch <ref>` substring.
- **For a non-fetch backstop, key on identity, not a clock.** Capture the compound PR's *number*
  from its `gh pr create` (`.../pull/<n>`) and skip exactly that one merge — so a transient race
  never suppresses a *different*, substantive merge:

```bash
# capture identity at create-time (state A -> state B), not a timestamp window
new_pr="$(printf '%s' "$payload" | grep -oE 'pull/[0-9]+' | head -n1 | grep -oE '[0-9]+')"
[ -n "$new_pr" ] && printf 'pr=%s\n' "$new_pr" > "$DONE"

# at merge: skip ONLY the captured PR, even if the live ref lookup raced to empty
[ -n "$pr_num" ] && [ "$compound_pr" = "$pr_num" ] && { rm -f "$DONE"; exit 0; }
```

Also: macOS ships bash 3.2, which lacks `EPOCHSECONDS` (it silently became the literal `unknown` in
the flag file) — prefer `date +%s` for portable timestamps in hooks.

## Why This Matters

A gate whose "satisfied" state can be flipped by reading a file is worse than no gate — it reports
safety that does not exist. And a branch-discipline hook that a wrapped `git` slips past gives false
confidence that `main` is protected. Both were caught only by an independent reviewer
(`ce-correctness-reviewer`), not by the author's own happy-path testing — evidence for Article XX
(independent verification).

## When to Apply

Any time you write or audit a hook that gates on tool calls or git. Always add a regression test
that asserts the **negative** cases: that reading the hook file does NOT trigger it, and that a
script-wrapped git is still caught.

## Examples

Negative-case tests that lock in the fix:

```bash
# must NOT clear the gate just because a Read payload contains the token
printf '{"tool_name":"Read","tool_input":{"file_path":".../compound-flag.sh"}}' | bash flag.sh
[ -f "$FLAG" ] && echo PASS   # flag survives

# must NOT arm on an Edit that merely mentions the phrase
printf '{"tool_name":"Edit","tool_input":{"new_string":"run gh pr merge"}}' | bash flag.sh
[ ! -f "$FLAG" ] && echo PASS
```
