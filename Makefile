# Diamond Ledger — developer + manual-test entry points.
# Run from the repo root. Requires the pinned Rust toolchain (rust-toolchain.toml);
# `cargo` is auto-installed by rustup on first use.
#
#   make demo    # one-command end-to-end pipeline smoke (no Mac needed)
#   make test    # the engine test suite (cargo test --workspace)
#   make gates   # the eval gates: SC-003 judgment + (if cwevent) Retrosheet
#   make lint    # clippy with the no-float + all-warnings gate
#   make cli     # build the dl CLI and print its usage

.PHONY: demo test lint gates judgment-gate retrosheet-gate cli help
.DEFAULT_GOAL := help

CARGO ?= cargo

help:
	@echo "Diamond Ledger — make targets:"
	@echo "  make demo   end-to-end pipeline smoke (build + test + lint + gates)"
	@echo "  make test   cargo test --workspace"
	@echo "  make lint   cargo clippy --workspace -- -D warnings (incl. no-float)"
	@echo "  make gates  SC-003 judgment gate + Retrosheet cwevent gate (if installed)"
	@echo "  make cli    build the dl CLI and show usage"

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

gates: judgment-gate retrosheet-gate

# SC-003 cardinal gate: every fact-classified judgment is surfaced, never silently
# resolved; silent_resolution_counter == 0; all four triggers exercised.
judgment-gate:
	@echo ">> SC-003 judgment gate (full corpus)"
	bash evals/runners/judgment-gate.sh

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
