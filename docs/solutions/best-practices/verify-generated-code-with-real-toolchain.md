---
module: development-workflow
date: 2026-06-02
last_updated: 2026-06-02
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - "An agent or multi-agent workflow generated code (Rust, Swift, etc.) and a static 'looks coherent' review was done"
  - "The local environment lacks the compiler/toolchain, so verification was deferred to CI"
  - "A CI job that builds generated code is marked continue-on-error (advisory) and the run shows green"
  - "Setting up a Cargo workspace whose members are sibling directories"
related_components:
  - ci-cd
  - rust
tags:
  - rust
  - cargo
  - workspace
  - toolchain
  - verification
  - generated-code
  - static-review
  - continue-on-error
---

# Agent static review is not compilation — install the real toolchain and let it be the gate

## Context

The foundational Rust+Swift scaffold for Diamond Ledger was produced by a multi-agent workflow whose
final phase was a dedicated "validation" agent doing a careful static read. It reported *"Cargo
workspace coherent"* and *"model.rs & ffi.rs: no Rust compile errors found."* It was wrong on both
counts. The first real `cargo check` failed with:

1. `error: workspace member '.../adapters/cli/Cargo.toml' is not hierarchically below the workspace
   root '.../core/Cargo.toml'` — a manifest-structure error a human-style read doesn't surface.
2. `error[E0204]` — a struct derived `Copy` while holding a `String`/non-Copy field.
3. `error[E0277]` — a struct derived `Default` while a field's enum had no `Default`.

A reviewer reading code top-to-bottom pattern-matches on *intent* and misses errors that only a type
checker / resolver enforces. **"Looks coherent" is a proxy; "compiles" is the signal.** (Same shape as
the SC-003 dead counter and the `cwevent` exit-0 gate — see
[critical-patterns P1-1](../patterns/critical-patterns.md).)

A second trap compounded it: the CI `core-build` job was `continue-on-error: true` (correct, so a
not-yet-wired job can't block merges), which means **the overall run shows green even when that job
fails**. Reading only the run-level conclusion would have hidden the failing compile.

## Guidance

1. **In a no-local-toolchain environment, install the toolchain and actually build before merging
   generated code.** Don't defer to "CI will catch it" when the CI job is advisory, and don't trust an
   agent's static review as a compile substitute.
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
     --default-toolchain <pinned-version> --profile minimal
   source "$HOME/.cargo/env"
   rustup component add clippy
   cargo check --workspace --all-targets        # lib + bins + dev-deps (proptest/insta)
   cargo clippy --workspace -- -D clippy::float_arithmetic   # invariant gate
   ```
   `--all-targets` matters: a plain `cargo check` skips dev-deps, so a test-only MSRV/compile problem
   stays hidden until someone writes the first test.

2. **Read the per-JOB conclusion, never just the run conclusion**, when any CI job is
   `continue-on-error`. A green run can contain a failed advisory job.
   ```bash
   gh run view "$RUN" --json jobs --jq '.jobs[]|"\(.conclusion)\t\(.name)"'  # success|failure|skipped per job
   ```

3. **Cargo workspace layout: members must live hierarchically BELOW the workspace root.** If the
   members are sibling dirs (`core/`, `adapters/cli/`, `adapters/agent/`), the `[workspace]` root must
   be a **repo-root `/Cargo.toml`** listing them — not a `core/Cargo.toml` that points at `../adapters/*`.
   Put `rust-toolchain.toml` and `clippy.toml` at the repo root (the workspace root) so `rustup show`
   and clippy pick them up when CI runs from the root. Commit `Cargo.lock`; ignore `/target/`.

4. **Pin the toolchain to a version that builds the whole dependency tree**, not just the lib. The
   agent picked 1.83; `cargo check` (lib) passed, but `proptest`'s MSRV is 1.85+, so the first test
   would have broken the pin. Verify `--all-targets` on the pinned version and bump deliberately.

5. **iOS/Swift IS locally verifiable — drive `xcodebuild` yourself; don't outsource the build loop to
   screenshots.** Earlier this project assumed agent-authored Swift was "compile-untested" because the
   environment seemed to lack Xcode. It didn't — `xcode-select` was pointed at the **Command Line
   Tools** (which `git`/`cc` want, but which lack `xcodebuild` + the iOS SDK). Point `DEVELOPER_DIR` at
   the full Xcode and you can build + test on a simulator:
   ```bash
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # NOT CommandLineTools
   xcrun simctl list runtimes | grep iOS          # find an installed runtime
   xcodebuild -scheme <Scheme> -showdestinations  # find an EXISTING device (e.g. iPhone 17, not 16)
   xcodebuild -scheme <Scheme> -destination 'platform=iOS Simulator,name=iPhone 17' build
   xcodebuild -scheme <Scheme> -destination 'platform=iOS Simulator,name=iPhone 17' test
   ```
   This turned a multi-round screenshot loop into a tight local iterate-fix-rebuild loop.
   **Swift 6 first-build gotchas** (all caught only by the real build):
   - *Wrong destination is the loudest false alarm:* an iOS-only package (`platforms: [.iOS(...)]`,
     no `.macOS`) built for **"My Mac"** reports ~every modern SwiftUI API (`@Observable`, `App`,
     `WindowGroup`, `@Environment`) as *"only available in macOS N"*. **Build for an iOS Simulator** —
     all of them vanish; it's not a code problem.
   - *Strict concurrency:* a non-`Sendable` value (e.g. a `~Copyable` `AudioBuffer`) can't be passed
     into an `actor`-isolated `async` protocol method → conform the value type to `Sendable` (Xcode's
     fix-it is reliable) when its fields are all `Sendable`.
   - *Real type errors hide behind the noise:* `Color.tint` doesn't exist (`.tint` is a modifier) →
     `.accentColor`; a substring grammar rule matching `"sacrifice"` conflated "sacrifice **fly**"
     with a sac-bunt → require the distinguishing token (`"bunt"`).
   - Gitignore Xcode per-user state (`**/xcuserdata/`, `*.xcuserstate`) — `git add -A` will otherwise
     commit another developer's IDE state.

## Why This Matters

A green-looking review plus a green-looking CI run gave false confidence on code that did not compile.
The fix was cheap (install rustup, ~2 min) and caught three real errors before they reached `main`. The
generalizable rule: **for generated code, the authoritative gate is the compiler/linter/test runner —
run it; do not accept a proxy** (a static read, a `continue-on-error` job, or a run-level green).

## When to Apply

Any time an agent/workflow generates compilable code and you're about to merge it — especially when the
local box lacks the toolchain and the CI build job is advisory. Install, build, lint, read per-job
results, then merge.
