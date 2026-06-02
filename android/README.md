# android/

Android fast-follow — Kotlin adapter over the same `dl-core` Rust library via UniFFI Kotlin bindings.

**Status:** placeholder — not yet started. Phase C / after iOS Phase B ships.

## Planned approach (ADR-0007 / D1 / D8)

- UniFFI generates Kotlin bindings from the same `dl-core` crate that powers iOS.
- The `Transcriber` protocol's portable engine (sherpa-onnx / Parakeet) slots in as the ASR layer.
- No business logic is re-implemented here; this is a thin client of `core/`.

See `specs/001-voice-scorebook-core/research.md` D1 and D2 for the full rationale.
