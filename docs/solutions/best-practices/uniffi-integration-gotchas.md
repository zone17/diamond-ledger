---
module: core-ffi
date: 2026-06-02
last_updated: 2026-06-02
problem_type: best_practice
component: uniffi
severity: high
applies_when:
  - "Wiring UniFFI onto an existing typed Rust boundary (proc-macro path, no UDL)"
  - "Generating Swift/Kotlin bindings with `uniffi-bindgen generate --library`"
  - "Building an iOS XCFramework from a Rust core"
  - "Exporting integer newtypes, fixed-size arrays, or a struct error over UniFFI"
tags: [uniffi, ffi, xcframework, swift, bindgen, cache-pitfall, integer-only]
---

# UniFFI integration gotchas (H1 / T037)

Wiring UniFFI onto Diamond Ledger's existing `core/src/ffi.rs` boundary surfaced four
non-obvious constraints. Each one fails *silently* or with a cryptic proc-macro panic, so
they are worth remembering.

## 1. The `--library` cache pitfall (silent zero-output bindgen)

`uniffi-bindgen generate --library <dylib>` reads the UniFFI metadata embedded in the
**built dylib**. A plain host `cargo build` (or `cargo build --workspace`) rebuilds
`target/<profile>/libdl_core.dylib` **without** the `uniffi` feature, stripping the
metadata. Running bindgen against that stale dylib emits **ZERO files and no error** — the
output dir is just empty.

**Fix:** rebuild the host dylib WITH the feature immediately before generating, and
**delete the output dir before regenerating** so a stale binding can never masquerade as
fresh:

```bash
cargo build --features uniffi -p dl-core --lib        # rebuild dylib WITH the feature
rm -rf out/ && mkdir -p out/                          # delete-before-regenerate
cargo run --features uniffi -p dl-core --bin uniffi-bindgen -- \
    generate --library target/debug/libdl_core.dylib --language swift --out-dir out/
test -s out/dl_core.swift || { echo "cache pitfall: empty bindings"; exit 1; }
```

The `make uniffi-bindings` target and `scripts/build-xcframework.sh` both bake this in, and
CI asserts the Swift file is non-empty.

## 2. Integer newtypes can't be `uniffi::Record` — use `custom_newtype!`

A single-field tuple struct (`pub struct GameId(pub u64)`) makes `#[derive(uniffi::Record)]`
panic with `called Option::unwrap() on a None value`. UniFFI Records need named/multiple
fields. For an integer newtype, map it to its underlying builtin instead:

```rust
#[cfg(feature = "uniffi")]
uniffi::custom_newtype!(GameId, u64);
```

Same wire shape as `#[serde(transparent)]`, and it makes the newtype implement `TypeId` so
other exported types can reference it.

## 3. No fixed-size arrays at the boundary

UniFFI has no `[T; N]` type. `pub batting_index: [u8; 2]` fails with
`the trait bound [u8; 2]: TypeId is not satisfied`. Use a `Vec<T>` at the FFI struct (keep
the fixed array internally and `.to_vec()` at the projection boundary). Document the length
invariant in the field doc.

## 4. A `uniffi::Error` must be an enum, not a struct

The structured boundary error (a struct carrying a machine-readable `code`, per Art. I)
cannot `derive(uniffi::Error)`. Keep it a `uniffi::Record` and throw it via a thin
single-variant enum wrapper, preserving every field (zero info loss):

```rust
#[derive(uniffi::Error)]
pub enum CoreFfiError { Core(Error) }      // Error is a uniffi::Record
impl From<Error> for CoreFfiError { /* ... */ }
```

## 5. Feature-gate everything; ship an in-crate bindgen

Gate all annotations with `#[cfg_attr(feature = "uniffi", ...)]` so the pure crate (and the
no-float clippy gate) build with zero FFI coupling. Ship the generator as an in-crate
`[[bin]] uniffi-bindgen` with `required-features = ["uniffi"]` so the generator is ALWAYS
the same UniFFI version as the proc-macros (version skew silently emits broken bindings).

## See also

- `core/src/ffi.rs`, `core/src/primitives/mod.rs` (`#[uniffi::export] impl DiamondCore`)
- `scripts/build-xcframework.sh`, `ios/Generated/README.md` (iOS consumption / T071)
- `DECISIONS.md` ADR-0009
- `best-practices/verify-generated-code-with-real-toolchain.md` (same "verify with the real
  toolchain, not a static review" lesson)
