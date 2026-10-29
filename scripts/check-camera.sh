#!/bin/bash
# Invoke production checks inside the actual app, preserving producer identity.
# Does not build/sign/install the app, grant permissions, or save frames.
# Camera-free regression fixtures are compiled into an isolated temporary folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != "--live-takeover" && "$2" != "--request-camera-access" ) ]]; then
    echo "Usage: bash scripts/check-camera.sh /path/to/OpenOpal.app [--live-takeover|--request-camera-access]" >&2
    exit 1
fi
APP="$1"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
BINARY="$APP/Contents/MacOS/$EXECUTABLE"
if [[ ! -x "$BINARY" ]]; then
    echo "App executable is unavailable: $BINARY" >&2
    exit 1
fi
# Never compete with a user's running producer or inherit its USB connection.
if /usr/bin/pgrep -x "$EXECUTABLE" >/dev/null; then
    echo "Quit $EXECUTABLE before running camera checks." >&2
    exit 1
fi
if [[ "${2:-}" == "--request-camera-access" ]]; then
    /usr/bin/codesign --verify --strict "$APP"
    exec "$BINARY" --camera-checks-request-access
fi
if [[ $# -eq 1 ]]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/openopal-camera-checks.XXXXXX")"
    trap 'rm -rf "$WORK"' EXIT
    HOST_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
    TEAM_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :OpenOpalSigningTeam' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -z "$TEAM_IDENTIFIER" || "$TEAM_IDENTIFIER" == *'$('* ]]; then
        # Explicit synthetic team for an unsigned build's rejection fixture.
        TEAM_IDENTIFIER="TESTTEAM01"
    fi
    compile_fixture() {
        local name="$1"
        local production="$2"
        xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" -parse-as-library \
            "$ROOT/$production" "$ROOT/Tests/$name.swift" -o "$WORK/$name"
    }
    run_fixture() {
        compile_fixture "$1" "$2"
        "$WORK/$1"
    }
    run_fixture CameraSettingsPersistenceTests Sources/OpenOpal/Camera/CameraSettings.swift
    run_fixture SubjectMeteringSessionTests Sources/OpenOpal/Camera/SubjectMeteringSession.swift
    run_fixture CameraLaunchPolicyTests Sources/OpenOpalLauncher/CameraLaunchPolicy.swift
    run_fixture MenuBarDockingTests Sources/OpenOpal/UI/MenuBarPanelController.swift
    run_fixture CameraSinkSessionTests Sources/OpenOpalCameraExtension/SinkSession.swift
    run_fixture CameraSinkTimingTests Sources/OpenOpalCameraExtension/SinkTiming.swift
    compile_fixture CameraSinkAuthorizationTests Sources/OpenOpalCameraExtension/SinkClientAuthorizer.swift
    /usr/bin/codesign --force --sign - --identifier "$HOST_IDENTIFIER" "$WORK/CameraSinkAuthorizationTests"
    "$WORK/CameraSinkAuthorizationTests" "$HOST_IDENTIFIER" "$TEAM_IDENTIFIER"
    bash "$ROOT/scripts/check-render.sh"
    "$BINARY" --camera-checks
    exit 0
fi
/usr/bin/codesign --verify --strict "$APP"
echo "WARNING: explicit live camera takeover; close other camera clients first. No TCC prompt will be requested. Exit 2 means unverified, not passed." >&2
"$BINARY" --camera-checks-live --allow-camera-takeover &
PID=$!
trap 'kill -TERM "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true' INT TERM
set +e
wait "$PID"
STATUS=$?
trap - INT TERM
exit "$STATUS"
