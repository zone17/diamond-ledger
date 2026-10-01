---
title: Adding a field to a persisted, append-only event without breaking old data or determinism
date: 2026-09-30
category: best-practices
module: core/src/eventlog
problem_type: best_practice
component: data_model
severity: high
applies_when:
  - "A serialized event, snapshot, or state-file struct gains a field"
  - "Determinism or parity checks compare serialized output byte for byte"
  - "Old state files or logs must keep loading after the change"
tags: [event-sourcing, serde, backward-compatibility, determinism, fixtures, version-skew, rust]
related_components: [adapters/cli, evals]
---

# Adding a field to a persisted, append-only event without breaking old data or determinism

## Context
PR #190 (#177) added `home_lineup` and `visitor_lineup` to `GameStartedPayload`, the event that starts every game in the append-only log. Three things depend on that event's exact bytes: old `.dl-state.json` files written by the CLI, the eventlog determinism test, and `evals/runners/parity.sh`, which diffs CLI output against a replay. A careless field addition breaks all three: old files fail to load ("corrupt state file"), and every lineup-less game changes its JSON.

## Guidance

1. **Capture the fixture with the unmodified binary, before touching code.** The back-compat test is only honest if the "old" bytes were written by old code. For #177 the worker ran the pre-change CLI first and saved its exact output:
   ```text
   DL_STATE_FILE=<tmp> dl new-game Hawks Owls owner-1   # pre-change binary
   -> core/tests/fixtures/pre-lineup-snapshot.json       # exact bytes, no trailing newline
   ```
   A fixture written by the new code would pass even if the format had changed.

2. **Make every new field optional on read and invisible when empty.**
   ```rust
   #[serde(default, skip_serializing_if = "Vec::is_empty")]
   pub home_lineup: Vec<LineupSlot>,
   ```
   `default` lets old snapshots deserialize. `skip_serializing_if` makes a game without the field serialize byte-identically to before, so the determinism and parity checks need no new baseline. Use `Option::is_none` for optional scalars, matching the existing `Team.lineup` idiom in `core/src/ffi.rs`.

3. **Test both directions against the fixture.** `core/tests/lineup_setup.rs` restores the old fixture and reads the game back, and `lineup_less_game_serializes_byte_identically_to_pre_change_fixture` proves a new game without the field produces the same bytes. The CLI test suite repeats the byte check through the real binary.

4. **Name the risk new code cannot fix: version skew.** Nothing in the loader rejects unknown fields (there is no `deny_unknown_fields`), so an *older* `dl` binary reading a *newer* state file silently ignores the new fields. It then rewrites the file without them on its next mutating command. That is silent data loss, and only old code could prevent it. Record it as a known risk, as the PR #190 review record `.specify/reviews/PR-190.md` does. If old and new binaries must ever share state, add a format version to the snapshot and have the loader refuse a newer version than it understands.

## Why This Matters
The failure is silent in every direction. A missing `default` surfaces only when a user loads an old file. A missing `skip_serializing_if` surfaces as a determinism or parity diff that looks like a logic regression. A fixture captured from the new code hides both. The version-skew loss never surfaces at all, because the old binary reports success.

## When to Apply
Any change to a struct that is serialized into the event log, a snapshot, or a state file, including fields added to nested records such as `LineupSlot`. The same review in #190 found two neighbouring traps worth checking at the same time:
- **A parity check whose two sides share builder helpers proves less than its name.** `parity.sh` builds both paths through the same CLI helpers, so it proves the serde round trip, not the Swift-to-UniFFI path the app uses. Real-core XCTests cover that path.
- **An input syntax that can only express a subset of what the store accepts hides parity gaps.** A dense `1..N` roster syntax meant agents could not reproduce gapped iOS lineups until reviewers flagged it; the fix was an explicit `N:` prefix.

## Related
- `docs/solutions/best-practices/uniffi-integration-gotchas.md` covers carrying the new field across the FFI boundary.
- `docs/solutions/best-practices/derived-export-must-match-canonical-projection.md` covers consumers that re-read the log.
- DECISIONS.md ADR-0020 records the lineup decision; `.specify/reviews/PR-190.md` records the version-skew risk.
