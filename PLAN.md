# Production integration

## Branch contract

`develop` contains upstream and all production PRs, without experimental filters.
`filter-effects` must contain current `develop` plus filters and Generate & Edit.
The local `experiments` branch at `aa78f95` preserves the earlier combined code.
Review upstream submissions individually; do not submit the integration wholesale.
Apple silicon and macOS 26 remain required.

## Camera and privacy boundary

Keep the C1 takeover RAM-only. Never flash firmware, guess LED GPIO pins, weaken
producer authorization, disable SIP, or substitute another device after losing
the selected camera's identity. The physical indicator can remain off during
live capture with this pipeline. Its electrical cause and safe control command
are not established; unplug the camera for a hardware privacy guarantee.

Warn camera users before launching a new app or running live takeover. Software
reconnect is not a substitute for physically unplugging and reconnecting the C1.

## Output contract

- Camera controls and capture size/frame rate configure sensor acquisition.
  The virtual camera advertises 1920×1080 BGRA at 30 fps, with aspect-preserving
  scaling. Actual delivery depends on capture and rendering speed.
- Mirror output defaults to off, persists with camera settings, and applies once
  in the final Metal composite. Preview and virtual camera share that result;
  there is no second preview-only flip.
- Window docking stays available. Background blur and the existing camera
  controls remain production features. Reset All restores production defaults.

## Build identity

`Config/BuildIdentity.xcconfig` contains unsigned development defaults. The ignored
`Config/BuildIdentity.local.xcconfig` holds the local team, host bundle ID, and
App Group matching existing provisioning profiles. Derived extension and helper
identifiers, Mach service, and signing entitlements must agree. Build version 7
replaces version 6 for the host, camera extension, and launcher together.

Keep the sealed host Info.plist in the camera extension and fail-closed dynamic
process validation against the exact host ID and signing team. A Developer ID
build must be notarized before installation; see [SIGNING.md](docs/SIGNING.md).

All six open PRs received a static review. Their existing CI checks pass, but
those checks do not cover the current production integration.

| PR | Before upstream submission |
| --- | --- |
| [#18](https://github.com/jamiew/open-opal/pull/18) | Carry the configurable identity and certificate/profile preflight; verify a clean release build. |
| [#19](https://github.com/jamiew/open-opal/pull/19) | Carry dynamic producer validation, sealed host metadata, portable rejection fixture, and synchronized build versions. |
| [#28](https://github.com/jamiew/open-opal/pull/28) | Carry the concurrent-connect guard, stale-frame reset, and tracked close/restart safety. |
| [#31](https://github.com/jamiew/open-opal/pull/31) | No static blocker found; calibrated live color comparison remains. |
| [#35](https://github.com/jamiew/open-opal/pull/35) | No static blocker found; multi-display and auto-hidden-menu-bar interaction remains. |
| [#9](https://github.com/jamiew/open-opal/pull/9) | Keep experimental and separate; do not include in the production submission. |

## Acceptance evidence

Run deterministic camera-free checks against the built app:

```sh
bash scripts/check-camera.sh /Applications/OpenOpal.app
```

With explicit permission to take over the camera, warn users and run:

```sh
bash scripts/check-camera.sh /Applications/OpenOpal.app --live-takeover
```

The live path uses RAM-only capture and numeric JSON-lines evidence, not saved
frames. Check capture modes/frame rates, hot-control churn, orientation, software
reconnect/restart, and virtual-camera readback where prior permission exists.
Exit 1 is failure; exit 2 means required evidence remains unverified. Physical
reconnect, optical/chart-based control effects, GUI behavior, and missing camera
permission require separate observation. Neither synthetic checks nor the prior
signed QuickTime session prove these behaviors in the replacement build.

Build 7 passed the Release build, signing/profile preflight, 30 Python safety and
packaging tests, both offline CTest cases, all seven Swift regression fixtures,
and the real-GPU checks for shared pixels, mirror orientation, blur history,
color output, frame lifetime, and virtual-output conversion. The signed executable
also passed its isolated-preferences mode without opening the camera.

Live optical, physical-reconnect, and GUI acceptance remains separate; do not call
the integration release-ready from these camera-free results.
