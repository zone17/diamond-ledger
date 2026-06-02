#!/usr/bin/env bash
# build-xcframework.sh — compile dl-core for iOS and emit Swift bindings + an XCFramework.
#
# This is the A-side of handoff H1 (T037): it turns the UniFFI-annotated Rust core into
# the artifact Squad B drops into the iOS app (T071/T044), swapping out `MockCore` with
# no protocol changes.
#
# Outputs (under ios/Generated/ by default):
#   - DiamondLedgerCore.xcframework   — static lib slices for device + simulator
#   - DiamondLedgerCore.swift          — the generated Swift bindings (rename of dl_core.swift)
#
# Pipeline (each step matters):
#   1. rustup target add the three iOS triples (device + 2 sim arches).
#   2. cargo build --release --features uniffi  per target  → libdl_core.a per arch.
#   3. uniffi-bindgen generate (Swift) from ONE built dylib (in-crate generator → no
#      version skew). This emits dl_core.swift + dl_coreFFI.h + dl_coreFFI.modulemap.
#   4. Rename the FFI module to a headers/ dir and rewrite the modulemap so the
#      XCFramework exposes a clean `DiamondLedgerCoreFFI` module.
#   5. lipo the two simulator arches into one fat static lib.
#   6. xcodebuild -create-xcframework with the device .a + the fat sim .a + headers.
#
# CACHE PITFALL (load-bearing — see DECISIONS.md ADR-0009 / docs/solutions):
#   `cargo build` for the host (no --features uniffi) OVERWRITES target/debug/libdl_core.dylib
#   with a NON-uniffi dylib, after which `uniffi-bindgen generate --library` silently emits
#   ZERO files (no error). This script therefore (a) builds the host bindgen dylib WITH the
#   feature immediately before generating, and (b) DELETES the output dir before regenerating
#   so a stale binding can never masquerade as a fresh one.
#
# Usage:
#   scripts/build-xcframework.sh [--debug] [--out <dir>] [--kotlin]
#
#   --debug    build the Rust core in dev profile (default: release)
#   --out DIR  output dir (default: ios/Generated)
#   --kotlin   also emit Kotlin bindings (android fast-follow; cheap, off by default)
#
# Requires: macOS, Xcode (xcodebuild, lipo), rustup. cargo installs the iOS std via rustup.

set -euo pipefail

# ── Locate repo root ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck disable=SC1091
source "$HOME/.cargo/env" 2>/dev/null || true

# ── Arg parsing ───────────────────────────────────────────────────────────────
PROFILE="release"
PROFILE_FLAG="--release"
OUT_DIR="${REPO_ROOT}/ios/Generated"
EMIT_KOTLIN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)  PROFILE="debug"; PROFILE_FLAG="" ; shift ;;
        --out)    OUT_DIR="$2"; shift 2 ;;
        --kotlin) EMIT_KOTLIN=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

CRATE="dl-core"
LIB_BASENAME="libdl_core"           # cdylib/staticlib name (lib name = dl_core)
FRAMEWORK_NAME="DiamondLedgerCore"
# UniFFI 0.28 names the FFI module + header from the crate LIB name (dl_core → dl_coreFFI),
# NOT the framework name. The generated dl_core.swift does `import dl_coreFFI`, so the modulemap
# must name the clang module `dl_coreFFI` and the header is `dl_coreFFI.h` (not libdl_coreFFI.h).
FFI_MODULE="dl_coreFFI"

# iOS triples: device (arm64) + simulator (arm64 + x86_64).
IOS_DEVICE_TARGET="aarch64-apple-ios"
IOS_SIM_ARM64_TARGET="aarch64-apple-ios-sim"
IOS_SIM_X86_TARGET="x86_64-apple-ios"

info()  { printf '\033[0;32m[xcframework]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[xcframework] WARN\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[0;31m[xcframework] FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# ── Preflight: macOS toolchain ────────────────────────────────────────────────
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found — install Xcode (not just CommandLineTools)."
command -v lipo >/dev/null 2>&1       || fail "lipo not found — install Xcode toolchain."
command -v cargo >/dev/null 2>&1      || fail "cargo not found — install rustup."

info "Profile: ${PROFILE}   Out: ${OUT_DIR}"

# ── Step 1: ensure iOS targets are installed ──────────────────────────────────
info "Ensuring rustup iOS targets are installed..."
for t in "${IOS_DEVICE_TARGET}" "${IOS_SIM_ARM64_TARGET}" "${IOS_SIM_X86_TARGET}"; do
    if ! rustup target list --installed 2>/dev/null | grep -qx "$t"; then
        info "  rustup target add $t"
        rustup target add "$t"
    fi
done

# ── Step 2: build the static lib per target (WITH the uniffi feature) ──────────
info "Building ${CRATE} (--features uniffi) for the iOS targets..."
for t in "${IOS_DEVICE_TARGET}" "${IOS_SIM_ARM64_TARGET}" "${IOS_SIM_X86_TARGET}"; do
    info "  cargo build ${PROFILE_FLAG} --features uniffi --target ${t}"
    cargo build ${PROFILE_FLAG} --features uniffi -p "${CRATE}" --target "${t}"
done

device_lib="${REPO_ROOT}/target/${IOS_DEVICE_TARGET}/${PROFILE}/${LIB_BASENAME}.a"
sim_arm_lib="${REPO_ROOT}/target/${IOS_SIM_ARM64_TARGET}/${PROFILE}/${LIB_BASENAME}.a"
sim_x86_lib="${REPO_ROOT}/target/${IOS_SIM_X86_TARGET}/${PROFILE}/${LIB_BASENAME}.a"
for f in "${device_lib}" "${sim_arm_lib}" "${sim_x86_lib}"; do
    [[ -f "$f" ]] || fail "expected static lib not produced: $f"
done

# ── Step 3: generate Swift bindings from a freshly-built host dylib ────────────
# Rebuild the HOST dylib WITH the feature immediately before generating (cache pitfall).
info "Building host bindgen dylib (--features uniffi)..."
cargo build ${PROFILE_FLAG} --features uniffi -p "${CRATE}" --lib

host_dylib="${REPO_ROOT}/target/${PROFILE}/${LIB_BASENAME}.dylib"
[[ -f "${host_dylib}" ]] || fail "host dylib not found: ${host_dylib}"

# DELETE-BEFORE-REGENERATE: a stale binding must never survive (cache pitfall).
GEN_TMP="$(mktemp -d)"
trap 'rm -rf "${GEN_TMP}"' EXIT
info "Generating Swift bindings (delete-before-regenerate)..."
cargo run ${PROFILE_FLAG} --features uniffi -p "${CRATE}" --bin uniffi-bindgen -- \
    generate --library "${host_dylib}" --language swift --out-dir "${GEN_TMP}"

[[ -f "${GEN_TMP}/dl_core.swift" ]] || fail "uniffi-bindgen produced NO Swift file (cache pitfall: host dylib lacked the uniffi feature)."

if [[ "${EMIT_KOTLIN}" -eq 1 ]]; then
    info "Generating Kotlin bindings (android fast-follow)..."
    cargo run ${PROFILE_FLAG} --features uniffi -p "${CRATE}" --bin uniffi-bindgen -- \
        generate --library "${host_dylib}" --language kotlin --out-dir "${GEN_TMP}/kotlin"
fi

# ── Step 4: assemble headers + modulemap for the XCFramework ──────────────────
HEADERS_DIR="${GEN_TMP}/headers"
mkdir -p "${HEADERS_DIR}"
cp "${GEN_TMP}/${FFI_MODULE}.h" "${HEADERS_DIR}/"
# A clean module.modulemap naming the FFI module the Swift bindings `import`.
cat > "${HEADERS_DIR}/module.modulemap" <<EOF
module ${FFI_MODULE} {
    header "${FFI_MODULE}.h"
    export *
}
EOF

# ── Step 5: lipo the two simulator arches into one fat static lib ─────────────
info "lipo-ing simulator arches (arm64 + x86_64)..."
SIM_FAT="${GEN_TMP}/${LIB_BASENAME}-sim.a"
lipo -create "${sim_arm_lib}" "${sim_x86_lib}" -output "${SIM_FAT}"

# ── Step 6: assemble the XCFramework (delete-before-regenerate) ────────────────
mkdir -p "${OUT_DIR}"
XCF="${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"
rm -rf "${XCF}"
info "Creating ${FRAMEWORK_NAME}.xcframework..."
xcodebuild -create-xcframework \
    -library "${device_lib}" -headers "${HEADERS_DIR}" \
    -library "${SIM_FAT}"    -headers "${HEADERS_DIR}" \
    -output "${XCF}"

# Place the Swift bindings next to the framework (renamed to the framework name).
cp "${GEN_TMP}/dl_core.swift" "${OUT_DIR}/${FRAMEWORK_NAME}.swift"
if [[ "${EMIT_KOTLIN}" -eq 1 ]]; then
    rm -rf "${OUT_DIR}/kotlin"
    cp -R "${GEN_TMP}/kotlin" "${OUT_DIR}/kotlin"
fi

info "DONE."
info "  XCFramework: ${XCF}"
info "  Swift bindings: ${OUT_DIR}/${FRAMEWORK_NAME}.swift  (module imports: ${FFI_MODULE})"
[[ "${EMIT_KOTLIN}" -eq 1 ]] && info "  Kotlin bindings: ${OUT_DIR}/kotlin/"
info ""
info "iOS consumption (Squad B / T071): see ios/Generated/README.md"
