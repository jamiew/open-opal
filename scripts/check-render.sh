#!/bin/bash
# Production renderer checks without app launch, USB, or CMIO connections.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/openopal-render-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for source in "$ROOT"/Sources/OpenOpal/Render/*.metal; do
    name="$(basename "$source" .metal)"
    xcrun -sdk macosx metal -mmacosx-version-min=26.0 -c "$source" -o "$WORK/$name.air"
done
xcrun -sdk macosx metallib "$WORK"/*.air -o "$WORK/default.metallib"
xcrun swiftc -swift-version 6 -target arm64-apple-macosx26.0 -parse-as-library \
    "$ROOT"/Sources/OpenOpal/Render/*.swift \
    "$ROOT/Sources/OpenOpal/Camera/CameraSettings.swift" \
    "$ROOT/tools/render_checks.swift" \
    -o "$WORK/render-checks"
"$WORK/render-checks"
