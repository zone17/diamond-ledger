---
module: enforcement-hooks
date: 2026-06-01
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - "Writing a Claude Code hook that triggers on tool calls or git operations"
  - "An enforcement hook either fires when it should not, or fails to fire when it should"
related_components:
  - development_workflow
tags:
  - hooks
  - enforcement
  - false-positive
  - branch-discipline
  - tool-name
  - claude-code
---

# Hooks that pattern-match command strings have two blind spots

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
