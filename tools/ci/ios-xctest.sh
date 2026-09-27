#!/usr/bin/env bash
# ios-xctest.sh — build the iOS app and run the full XCTest suite on an iOS 26 simulator (#182).
#
# Why a script: the XcodeGen project (ios/DiamondLedger.xcodeproj) has no test scheme — the tests
# live in the SwiftPM package's `DiamondLedgerTests` target — and when a directory holds both a
# .xcodeproj and a Package.swift, xcodebuild picks the project. So this script generates a
# throwaway workspace that references the package directly, which exposes the package schemes
# (`DiamondLedgerTests`, `dl-score`, `dl-bias`), exactly the setup that runs the suite locally.
# The same script is `make ios-test` and the CI step, so local and CI cannot drift.
#
# Steps: (1) ensure the UniFFI XCFramework exists (delete-before-regenerate per ADR-0009 when it
# is missing), (2) build the app target from the XcodeGen project, (3) run every XCTest on the
# first available iOS 26+ iPhone simulator (never a hard-coded device name — runner images
# rotate their simulator sets).
#
# EXIT: 0 build + every test passed; 1 build failure, test failure, or a missing toolchain on
# macOS; 2 zero tests executed (a vacuous run is never green). Non-Darwin: SKIP marker, exit 0.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS_DIR="${REPO_ROOT}/ios"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
info() { echo "${GREEN}[ios-xctest]${NC} $*"; }
fail() { echo "${RED}[ios-xctest] FAIL${NC} $*" >&2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "[ios-xctest] SKIP — not macOS; the iOS simulator and Xcode are unavailable here."
    exit 0
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v xcodebuild >/dev/null 2>&1 || { fail "xcodebuild not found — Xcode 26 required."; exit 1; }
command -v cargo >/dev/null 2>&1 || { fail "cargo not found — rustup required to build the core XCFramework."; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 not found — used to pick a simulator."; exit 1; }

# ── 1. Core XCFramework ────────────────────────────────────────────────────────────────────────
XCF="${IOS_DIR}/Generated/DiamondLedgerCore.xcframework"
if [[ ! -d "${XCF}/ios-arm64_x86_64-simulator" ]]; then
    info "Building the core XCFramework (simulator slice missing)…"
    rm -rf "${XCF}"
    bash "${REPO_ROOT}/scripts/build-xcframework.sh" || { fail "XCFramework build failed."; exit 1; }
fi

# ── Simulator: first available iPhone on iOS 26+ ───────────────────────────────────────────────
SIM_ID="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in devices.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m or int(m.group(1)) < 26:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devs:
        if d.get("name", "").startswith("iPhone") and (best is None or version > best[0]):
            best = (version, d["udid"], d["name"])
print(best[1] if best else "")
')"
[[ -n "${SIM_ID}" ]] || { fail "no available iOS 26+ iPhone simulator on this machine."; exit 1; }
info "Simulator: ${SIM_ID}"

SCRATCH="$(mktemp -d)"; trap 'rm -rf "${SCRATCH}"' EXIT
DERIVED="${SCRATCH}/DerivedData"

# ── 2. Build the app target ────────────────────────────────────────────────────────────────────
info "Building the DiamondLedger app (XcodeGen project)…"
RC=0
( cd "${IOS_DIR}" && xcodebuild -project DiamondLedger.xcodeproj -scheme DiamondLedger \
    -destination "id=${SIM_ID}" -derivedDataPath "${DERIVED}" \
    CODE_SIGNING_ALLOWED=NO build > "${SCRATCH}/app-build.log" 2>&1 ) || RC=$?
if [[ "${RC}" -ne 0 ]]; then
    grep -E "error:|BUILD FAILED" "${SCRATCH}/app-build.log" | head -40 >&2
    fail "app build failed (exit ${RC})."; exit 1
fi

# ── 3. Run the package test target through a generated workspace ───────────────────────────────
WS="${SCRATCH}/DiamondLedgerTests.xcworkspace"
mkdir -p "${WS}"
cat > "${WS}/contents.xcworkspacedata" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version = "1.0">
   <FileRef location = "absolute:${IOS_DIR}"></FileRef>
</Workspace>
EOF
# SwiftPM auto-generates schemes only for products (dl-score, dl-bias), never for a bare test
# target, so declare a shared scheme that builds and tests `DiamondLedgerTests`.
mkdir -p "${WS}/xcshareddata/xcschemes"
cat > "${WS}/xcshareddata/xcschemes/DiamondLedgerTests.xcscheme" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2650" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "DiamondLedgerTests" BuildableName = "DiamondLedgerTests" BlueprintName = "DiamondLedgerTests" ReferencedContainer = "container:${IOS_DIR}"></BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "DiamondLedgerTests" BuildableName = "DiamondLedgerTests" BlueprintName = "DiamondLedgerTests" ReferencedContainer = "container:${IOS_DIR}"></BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES"></LaunchAction>
</Scheme>
EOF
info "Running the XCTest suite…"
RC=0
xcodebuild test -workspace "${WS}" -scheme DiamondLedgerTests \
    -destination "id=${SIM_ID}" -derivedDataPath "${DERIVED}" \
    CODE_SIGNING_ALLOWED=NO > "${SCRATCH}/test.log" 2>&1 || RC=$?

SUMMARY="$(grep -E "Executed [0-9]+ tests" "${SCRATCH}/test.log" | tail -1)"
FAILURES="$(grep -E "error: -\[" "${SCRATCH}/test.log" | head -40)"
EXECUTED="$(printf '%s' "${SUMMARY}" | sed -nE 's/.*Executed ([0-9]+) tests.*/\1/p')"

if [[ -n "${FAILURES}" ]]; then
    printf '%s\n' "${FAILURES}" >&2
fi
if [[ "${RC}" -ne 0 ]]; then
    [[ -z "${FAILURES}" ]] && grep -E "error:|TEST FAILED|BUILD FAILED" "${SCRATCH}/test.log" | head -40 >&2
    fail "XCTest run failed (exit ${RC}). ${SUMMARY}"; exit 1
fi
if [[ -z "${EXECUTED}" || "${EXECUTED}" -eq 0 ]]; then
    fail "zero tests executed — a vacuous run is never green."; exit 2
fi
info "PASS — ${SUMMARY# }"
