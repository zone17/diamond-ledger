//! `uniffi-bindgen` CLI entry point (T037 / H1).
//!
//! UniFFI's recommended pattern is to ship the binding generator *inside* the crate
//! so the generator and the proc-macro library are always the SAME UniFFI version
//! (a version skew between them silently emits broken bindings — the canonical
//! UniFFI footgun). `scripts/build-xcframework.sh` invokes:
//!
//! ```bash
//! cargo run --features uniffi --bin uniffi-bindgen -- \
//!     generate --library <path-to-libdl_core.a-or-.dylib> --language swift --out-dir <out>
//! ```
//!
//! This binary only exists when the `uniffi` feature is enabled (see the
//! `required-features` gate in `core/Cargo.toml`), so the default build never
//! compiles it.

fn main() {
    uniffi::uniffi_bindgen_main();
}
