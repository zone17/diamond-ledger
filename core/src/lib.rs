//! # dl-core — Diamond Ledger deterministic core
//!
//! The platform-independent, integer/fixed-point-only deterministic moat.
//!
//! ## No-float rule (ADR-0007 / D1 / FR-003 / I6)
//!
//! This crate **must never use `f32` or `f64`**. Byte-identical determinism across
//! iOS, Android, CLI, and agent surfaces is a hard requirement. IEEE-754 transcendental
//! functions vary by platform/libm/version; baseball scoring is overwhelmingly integer
//! and discrete. Any ratio (AVG, OBP, ERA …) is computed at the adapter or UI layer.
//!
//! The lint below turns any float arithmetic into a **compile error** — this is the
//! CI-enforced gate. Do not suppress it; fix the code.
#![deny(clippy::float_arithmetic)]

pub mod authz;
pub mod classify;
pub mod eventlog;
pub mod ffi;
pub mod model;
pub mod primitives;
pub mod reisner;
pub mod retrosheet;
pub mod rules;
