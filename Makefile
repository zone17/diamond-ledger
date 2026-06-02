# Diamond Ledger — developer + manual-test entry points.
# Run from the repo root. Requires the pinned Rust toolchain (rust-toolchain.toml);
# `cargo` is auto-installed by rustup on first use.
#
#   make demo    # one-command end-to-end pipeline smoke (no Mac needed)
#   make test    # the engine test suite (cargo test --workspace)
#   make gates   # the eval gates: SC-003 judgment + (if cwevent) Retrosheet
#   make lint    # clippy with the no-float + all-warnings gate
#   make cli     # build the dl CLI and print its usage

.PHONY: demo test lint gates judgment-gate retrosheet-gate proof-box-gate parity-gate accuracy-gate \
        cli ffi-check uniffi-bindings xcframework help
.DEFAULT_GOAL := help

CARGO ?= cargo

# Host dynamic-library extension for the UniFFI cdylib: .dylib on macOS, .so on Linux.
# uniffi-bindgen reads metadata from the BUILT host library; the extension is OS-specific
# (Linux CI builds libdl_core.so, not .dylib). Detected via `uname`.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  DYLIB_EXT := dylib
else
  DYLIB_EXT := so
endif
HOST_DYLIB := target/debug/libdl_core.$(DYLIB_EXT)

help:
	@echo "Diamond Ledger — make targets:"
	@echo "  make demo         end-to-end pipeline smoke (build + test + lint + gates)"
	@echo "  make test         cargo test --workspace"
	@echo "  make lint         cargo clippy --workspace -- -D warnings (incl. no-float)"
	@echo "  make gates        SC-003 judgment + proof-box + parity + Retrosheet (if cwevent)"
	@echo "  make cli          build the dl CLI and show usage"
	@echo "  make ffi-check    build dl-core with --features uniffi (FFI surface compiles)"
	@echo "  make uniffi-bindings  generate Swift bindings from the host dylib (no Mac SDK)"
	@echo "  make xcframework  build the iOS XCFramework + Swift bindings (needs Xcode)"

# ---------------------------------------------------------------------------
# make demo — the push-button 'does the whole pipeline work?' check.
# Builds the workspace, runs the engine tests (determinism + proof-box +
# adversarial judgment invariants), enforces the no-float lint, runs the
# cardinal SC-003 judgment gate over the full corpus, and (if Chadwick cwevent
# is installed) validates the reduced-Retrosheet fixtures. Exits non-zero on any
# failure. No Mac / Xcode required — this exercises the deterministic core.
# ---------------------------------------------------------------------------
demo: test lint gates
	@echo ""
	@echo "============================================================"
	@echo "  ✅ make demo PASSED — engine + no-float + SC-003 + Retrosheet"
	@echo "     The deterministic pipeline works end-to-end."
	@echo "  (The iOS V3 glance app is tested separately in Xcode — see"
	@echo "   MANUAL-TESTING.md.)"
	@echo "============================================================"

test:
	@echo ">> cargo test --workspace (engine: determinism, proof-box, judgment invariants)"
	$(CARGO) test --workspace

lint:
	@echo ">> cargo clippy --workspace -- -D warnings (no-float + all warnings)"
	$(CARGO) clippy --workspace -- -D warnings

gates: judgment-gate proof-box-gate parity-gate accuracy-gate retrosheet-gate

# SC-003 cardinal gate: every fact-classified judgment is surfaced, never silently
# resolved; silent_resolution_counter == 0; all four triggers exercised.
judgment-gate:
	@echo ">> SC-003 judgment gate (full corpus)"
	bash evals/runners/judgment-gate.sh

# Proof-box Layer-1 (offline): AB+BB+Sac+HBP+Interference = Runs+Putouts+LOB for every
# half-inning the core projects (INTERFACE.md §3.3 Layer 1). Hard-fail on imbalance.
proof-box-gate:
	@echo ">> Proof-box Layer-1 gate (offline balance identity)"
	bash evals/runners/proof-box.sh

# SC-008 parity: the CLI/agent path and the core path produce byte-identical results
# for identical normalized facts. Hard-fail on any divergence.
parity-gate:
	@echo ">> Parity gate (SC-008 — CLI/agent vs core)"
	bash evals/runners/parity.sh

# SC-001/SC-002 accuracy. ADVISORY until Squad C's real gold game lands (h3_ready);
# self-consistency only until then. Never hard-fails in advisory mode.
accuracy-gate:
	@echo ">> Accuracy gate (SC-001/SC-002 — advisory until gold)"
	bash evals/runners/accuracy.sh

# Retrosheet acceptance: validate the reduced-grammar fixtures through pinned
# Chadwick cwevent (stderr-driven 3-layer). Skipped with a note if cwevent is not
# installed locally (CI builds the pinned v0.10.0 and runs it hard).
retrosheet-gate:
	@if command -v cwevent >/dev/null 2>&1; then \
		echo ">> Retrosheet gate (pinned Chadwick cwevent, stderr-driven 3-layer)"; \
		bash evals/runners/retrosheet-gate.sh evals/retrosheet-fixtures/2024 2024 || exit 1; \
	else \
		echo ">> Retrosheet gate SKIPPED locally — cwevent not installed."; \
		echo "   CI builds pinned Chadwick cwevent v0.10.0 and runs this as a hard gate."; \
		echo "   To run locally: install Chadwick (brew install chadwick) then re-run."; \
	fi

cli:
	@echo ">> building dl CLI"
	$(CARGO) build -p dl-cli
	@echo ""
	@./target/debug/dl --help

# ---------------------------------------------------------------------------
# UniFFI / iOS handoff (H1 / T037)
# ---------------------------------------------------------------------------

# Compile the core with the UniFFI surface enabled — verifies every boundary type
# and the exported DiamondCore impl still satisfy UniFFI (no Mac SDK required).
ffi-check:
	@echo ">> cargo build -p dl-core --features uniffi (FFI surface compiles)"
	$(CARGO) build -p dl-core --features uniffi

# Generate the Swift bindings only, from the host dylib. No iOS SDK / Xcode needed,
# so CI (ubuntu/macos) can assert the bindings generate non-empty (cache-pitfall guard).
# Output: target/uniffi/swift/dl_core.swift (+ FFI header + modulemap).
uniffi-bindings:
	@echo ">> generating Swift bindings from the host lib ($(HOST_DYLIB), delete-before-regenerate)"
	$(CARGO) build -p dl-core --features uniffi --lib
	@rm -rf target/uniffi/swift && mkdir -p target/uniffi/swift
	$(CARGO) run -p dl-core --features uniffi --bin uniffi-bindgen -- \
		generate --library $(HOST_DYLIB) --language swift --out-dir target/uniffi/swift
	@test -s target/uniffi/swift/dl_core.swift \
		|| (echo "FAIL: bindgen produced no Swift (cache pitfall — host lib lacked the feature)"; exit 1)
	@echo "OK: target/uniffi/swift/dl_core.swift generated ($$(wc -l < target/uniffi/swift/dl_core.swift) lines)"

# Build the full iOS XCFramework + Swift bindings (device + simulator). Needs Xcode.
xcframework:
	@echo ">> building iOS XCFramework (scripts/build-xcframework.sh)"
	bash scripts/build-xcframework.sh
