#!/bin/bash
# Everything that must pass before a commit: tests, both app builds, and the linter.
#
# Both platforms are built because nothing in a Mac build catches an iPad-only
# break, and the shared package is most of the code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED="${DERIVED_DATA:-$ROOT/.build/xcode}"

# Prefer Apple Silicon Homebrew. An x86_64 SwiftLint cannot load Xcode's arm64
# SourceKit, and /usr/local may still hold an Intel copy earlier in PATH.
[ -d /opt/homebrew/bin ] && PATH="/opt/homebrew/bin:$PATH"

say() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }

say "Tests (SklandusCore)"
swift test --package-path SklandusCore

say "Build: Mac"
xcodebuild -project Sklandus.xcodeproj -scheme "Sklandus (Mac)" \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    -quiet build

say "Build: iPad"
# A generic destination builds against the simulator SDK without naming a device,
# so the check cannot pick an iPad whose iOS predates the deployment target.
xcodebuild -project Sklandus.xcodeproj -scheme "Sklandus (iPad)" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
    -quiet build

say "Lint"
if command -v swiftlint >/dev/null 2>&1; then
    # SwiftLint loads Xcode's SourceKit, so an x86_64 build cannot run against an
    # arm64 toolchain. Fail loudly rather than skipping silently.
    if ! swiftlint lint --quiet --strict; then
        echo "SwiftLint reported problems." >&2
        exit 1
    fi
else
    echo "swiftlint not installed; skipping (see README)."
fi

say "All checks passed"
