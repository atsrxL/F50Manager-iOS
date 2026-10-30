#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' "iOS targets require macOS and Xcode." >&2
  exit 1
fi
# This is an iOS-only build: the documented macOS-only exception applies.
# Agents must read the user's remote-work-and-compilation.md before invoking.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEVELOPER_DIR" ]] || { printf '%s\n' "Set DEVELOPER_DIR to your full Xcode Developer directory." >&2; exit 1; }
if command -v xcodegen >/dev/null; then xcodegen generate; fi
mkdir -p build
args=(-project F50Manager.xcodeproj -scheme F50Manager -derivedDataPath build/DerivedData
      -clonedSourcePackagesDirPath build/SourcePackages -jobs "${BUILD_JOBS:-6}"
      -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO)
case "${1:-build}" in
  build) xcodebuild "${args[@]}" -destination 'generic/platform=iOS Simulator' build ;;
  test) xcodebuild "${args[@]}" -destination "${DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}" -parallel-testing-enabled NO test ;;
  device) xcodebuild "${args[@]}" -destination 'generic/platform=iOS' build ;;
  *) printf '%s\n' "Usage: $0 [build|test|device]"; exit 2 ;;
esac
du -sh build
