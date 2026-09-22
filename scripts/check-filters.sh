#!/bin/bash
# Camera-free regression checks. No app launch, USB access, or CMIO connection.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/openopal-filter-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for source in "$ROOT"/Sources/OpenOpal/Render/*.metal; do
    name="$(basename "$source" .metal)"
    xcrun -sdk macosx metal -c "$source" -o "$WORK/$name.air"
done
xcrun -sdk macosx metallib "$WORK"/*.air -o "$WORK/default.metallib"
xcrun swiftc -swift-version 6 -parse-as-library \
    "$ROOT"/Sources/OpenOpal/Render/*.swift \
    "$ROOT/Sources/OpenOpal/Camera/CameraSettings.swift" \
    "$ROOT/tools/filter_checks.swift" \
    "$ROOT/tools/creative_filter_checks.swift" \
    "$ROOT/tools/portrait_filter_checks.swift" \
    -o "$WORK/filter-checks"
"$WORK/filter-checks"
