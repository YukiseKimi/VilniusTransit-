#!/bin/bash
# Type-checks the cross-platform targets against the iOS SDK.
#
# Nothing in a macOS build catches an accidental AppKit dependency, and the app
# target is Mac-only, so without this the shared code silently stops compiling for
# iPad. Fast enough to run on every change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="arm64-apple-ios17.0"
MODULES="$(mktemp -d)"
trap 'rm -rf "$MODULES"' EXIT

echo "Checking VilniusTransitKit for iPadOS…"
xcrun --sdk iphoneos swiftc -target "$TARGET" -swift-version 6 \
    -emit-module -module-name VilniusTransitKit \
    Sources/VilniusTransitKit/*.swift \
    -o "$MODULES/VilniusTransitKit.swiftmodule"

echo "Checking VilniusTransitUI for iPadOS…"
xcrun --sdk iphoneos swiftc -target "$TARGET" -swift-version 6 \
    -typecheck -I "$MODULES" \
    Sources/VilniusTransitUI/*.swift

echo "Both targets compile for iPadOS."
