# Open Opal

A native macOS app for the Opal C1 webcam. Opal discontinued the C1 and its
Composer software; Open Opal keeps the camera working, and adds a few things.

<img width="440" alt="Open Opal in the menu bar" src="docs/screenshot.png">

- Full camera control: exposure, focus, white balance, image tuning, 4K/1080p/720p
- Background blur
- A virtual camera, **Open Opal Camera**, for Zoom, Meet, FaceTime and the rest
- Lives in the menu bar; drag the panel off to float it
- About 45 ms from lens to screen

## Fork branches

`main` includes the current upstream camera fixes and this fork's signing settings.
`filter-effects` builds on `main` for filters and Generate & Edit.

`filter-effects` includes the native filters, Generate & Edit, and current
upstream camera fixes. It requires macOS 26, including when editing manually.
Upstream's macOS 14 support does not cover this experimental editor.
Live tracking, camera reconnection, signing, and Zoom/Meet output still need testing.

## Features

- Exposure: auto, or manual shutter and ISO, with EV compensation and AE lock
- Focus: autofocus modes, manual lens position, click anywhere to focus, optional person-based tracking and lens search limits
- White balance: presets or manual Kelvin
- Anti-banding for 50/60 Hz lighting
- Sharpness, denoise, brightness, contrast, saturation
- 4K / 1080p / 720p, up to 42 fps
- Background blur, rendered in Metal with Apple's Vision segmentation
- Optional exposure metering on your face instead of the whole frame
- 21 local Metal effects plus None, with categorized search, intensity, and
  optional effect animation; face-tracked looks use Apple's Vision landmarks
- Menu bar controls with a live preview and an icon-aligned pointer
- Drag the header to float and resize; drop near the menu bar icon to dock

The app starts in the menu bar without a Dock icon or a separate main window.
Click the camera-aperture icon to open the controls. The header button also
switches between docked and floating controls. Clicking away hides docked controls;
floating controls stay open. Escape hides either without disconnecting the camera.
Click the icon to reopen them. Right-click the icon to quit.

Camera controls, capture size, blur, and autofocus limits survive app restarts.
Reset All also clears saved autofocus choices. Existing saved settings inherit
defaults for fields they do not contain.

Download the latest DMG from [Releases](https://github.com/alii/open-opal/releases)
and drag Open Opal to Applications. Click the lens icon in the menu bar to
open it, and right-click the icon to quit.

To use the virtual camera, click **Install virtual camera** and allow it in
System Settings if asked.

### Autofocus

“Follow face” uses the upper-middle of the segmented person's box as an estimate
of where a face is, not a face detector. It refocuses when that area's size changes
by more than 40%, with a one-second cooldown. This works best with one person
facing the camera; raised arms or multiple people can confuse the estimate.

“Limit range” restricts autofocus to the Far and Near lens positions you choose
(0–255). The limit is restored after switching from manual to automatic focus,
changing autofocus mode, or focusing on a region. Turning the limit off restores
the full 0–255 range. Exposure and other unrelated control changes do not restart
autofocus. Entering manual focus clears the tracking history immediately, so
returning to automatic focus can refocus even if the person's size has not changed.

Without an explicit limit, autofocus mode changes preserve the camera's tuned
range. Saved one-shot autofocus restores as Continuous on the next app start.
Subject-based exposure and autofocus are opt-in; saved choices still restore.

## Building

```sh
brew install cmake ninja xcodegen
./scripts/bootstrap.sh
./scripts/fetch-models.sh
xcodegen generate
open OpenOpal.xcodeproj
```

Building needs Xcode 26 or newer. See [TECHNICAL.md](TECHNICAL.md) for details,
tests, and how the camera takeover works.

Use Release builds for day-to-day use — Debug builds noticeably stutter in UI
animations.

First-generation IMX378 C1s use a RAM-only bootloader handoff. The pinned
DepthAI SDK patch allows only `GetBootloaderVersion` and `UsbRomBoot` to bypass
the version check when the bootloader reports exactly `0.0.0`; unrelated
requests keep their version checks. Existing SDK libraries must be rebuilt
with `./scripts/bootstrap.sh` after updating this patch, then the app rebuilt.
Bootstrap refuses SDK source with the older unrestricted `OPAL_C1_PATCH`:
restore only its two request-version checks to upstream v2.30.0, preserving any
other SDK edits, before rerunning bootstrap.

The camera-free safety regressions compile isolated C++ harnesses without
linking DepthAI or accessing USB:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_boot_safety.py'
```

The autofocus regressions inspect real serialized commands without opening a
camera. Build and run only this offline target; `bridge_test` and `region_test`
access the camera.

```sh
cmake -S Sources/OpalBridge -B build/control-tests -DOPAL_BRIDGE_TEST=ON
cmake --build build/control-tests --target control_delta_test
ctest --test-dir build/control-tests -R '^control_delta$' --output-on-failure
```

## The hardware

Little of this is documented elsewhere, so for the record:

- The C1 is a Luxonis DepthAI device: an Intel Movidius **Myriad X** VPU
  (USB VID `0x03E7`) paired with a Sony **IMX582** 48MP sensor (module name
  `LCM48`) and a real autofocus lens.
- The sensor has **no native 1080p mode**. Its readout modes are
  3840×2160 (2–42 fps), 4000×3000 (2–30 fps), and 5312×6000 (1–10 fps).
  That's also why the app caps out at 42 fps.
- Full 4K NV12 at 30 fps is ~370 MB/s, which saturates USB 3 and costs
  ~300 ms of latency. So the app always captures 4K and downscales on the
  camera's ISP before the frame crosses the wire — that's the ~45 ms figure.
- The sensor is mounted upside down in the housing; the stock firmware
  compensates silently. A custom pipeline has to rotate on the ISP itself
  (`setImageOrientation`), or everything arrives inverted.
- Autofocus/auto-exposure regions are specified in **sensor** coordinates
  (3840×2160), not output coordinates — the depthai docs mention this, and
  getting it wrong pins every region into the top-left quadrant.
- The 3A loops (autofocus, auto-exposure, auto-white-balance) run on the
  camera, not the host.

## How it works

The C1's flash holds firmware that presents it as a standard UVC webcam —
that's why it works in any app with nothing installed. Open Opal takes the
camera over instead: it resets the VPU into its ROM bootloader, uploads the
~26 MB DepthAI firmware into the camera's **RAM**, and sends over a small
pipeline graph that the firmware instantiates on the VPU. Quitting reboots
the camera back to its stock firmware within a few seconds. Nothing is ever
written to flash, so the takeover can't brick anything. The app narrates
each stage live while connecting, with real sizes and timings.

For first-generation IMX378 C1s, the stock camera must present both video and
audio interfaces before Open Opal attempts the handoff. Every reconnect must
report the selected camera's MxID. If that ID disappears or changes, Open Opal
fails safely without uploading the pipeline, even if only one unbooted device
is attached. A USB address change is allowed; an unidentified device is not.

```
Myriad X (IMX582)
  ColorCamera ── ISP downscale ── NV12 ──► XLink/USB ──► OpalBridge (C shim over depthai-core)
  3A control  ◄─ XLinkIn ◄──────────────────────────────  CameraControl messages
                                                              │
                              IOSurface CVPixelBuffer ◄───────┘  (the only copy)
                                        │
              Metal: NV12 → linear RGB → mask → blur → composite → filter
                                        │
                    owned BGRA frame → preview + virtual camera
```

The background blur uses Vision person segmentation, computed for the same
frame it masks, then blurred in linear light so highlights bloom instead of
graying out. Capture drops incoming frames while processing is busy instead
of queuing latency. An optional depth-graded mode uses
[Depth Anything V2](https://huggingface.co/apple/coreml-depth-anything-v2-small)
for distance-based falloff.

## Camera filters

The inspector's Filters browser has 21 effects plus None, grouped into four
categories. Search or page through six cards at a time. Selected-effect controls
stay above the catalog, including intensity and an animation switch where useful.
Changing a filter never reboots the camera.

| Category | Effects |
| --- | --- |
| Portrait | Cowboy, Cat, Beauty, Cyber Warrior, Baby Face, Anime Face, Beard, Glam Hair, Sunglasses, Bearded Cowboy |
| Color | Monochrome, Warm, Thermal |
| Art | Anime Ink, Halftone, Blueprint, Risograph |
| Digital | Point Cloud, Glitch, Pixel Art, Hologram |

Portrait effects use Apple's Vision face landmarks locally. The other effects
need no face tracking. Missing or stale detections remove face attachments.
Intensity zero bypasses the filter pass and face analysis. Disabling animation
holds shader time fixed; video and face tracking continue.

All artwork is procedural. Cat and Cyber Warrior are 2D face decorations, not
full avatars. Anime Ink is cel shading and edge drawing, not generative face
replacement. Point Cloud is a 2D dot visualization, not reconstructed depth.
Thermal maps brightness to false color and cannot measure temperature.
Beauty softens the face without geometric reshaping. Baby Face and Anime Face
enlarge facial features with local warps, not photorealistic age or character
replacement. Beard and Glam Hair are illustrated accessories for anyone, not
gender transformations. Bearded Cowboy combines the beard and existing hat.

Effects run after background blur in one Metal pass and reach both the preview
and virtual camera. Only the preview is mirrored. Spatial patterns scale with
resolution; animated effects use bounded, explicit time rather than frame counts.

No Snap lenses, extra downloaded models, cloud calls, or camera uploads are
involved. Snap's proprietary lens archive is not a portable renderer format.
See [PLAN.md](PLAN.md) for compatibility research. The
[agent authoring spec](docs/FILTER_AUTHORING.md) documents shader contracts,
acceptance checks, and the native Generate & Edit panel. Describe a look using
Apple's on-device Foundation Models, or edit a draft manually when the model is
unavailable. Generation selects existing effects, not new shaders or artwork.

Review the draft's look, intensity, and motion, or preview it on a synthetic face.
**Apply to output** updates preview and virtual camera together. Revert discards
draft edits; Undo restores the previous active look. Save draft writes validated
JSON presets locally under `~/Library/Application Support/OpenOpal/FilterPresets`
without applying them. Saved presets load into the draft for review.

Model output can misunderstand a request. Review the selected look and its
catalog description before applying. Arbitrary stacking, custom colors, and
photorealistic transformations are not supported. Generation never uploads
camera frames, downloads extra weights, or falls back to a remote model.

This branch requires a user-approved live review before release. Camera-free
compiler and synthetic-frame checks do not establish tracking quality, sustained
frame rate, or output in Zoom/Meet. Do not launch a new build while another app
is using the C1.

Camera-free regression checks:

```sh
bash scripts/check-filters.sh
```

This compiles the Metal shaders and a standalone Swift executable, then checks
generated frames, synthetic face anchors, portrait warps and mouth protection,
catalog search, time determinism, animation-off behavior, intensity, tiny/odd
image sizes, output ownership, and virtual-output conversion. It never starts Open Opal, opens a
capture device, or connects to the virtual-camera extension.

## Virtual camera

Open Opal installs a CoreMediaIO system extension that publishes **"Open Opal
Camera"** to every app on the Mac — Zoom, Meet, FaceTime, anything. It carries
the processed image, background blur and filters included. When the app isn't running it
shows a camera-off symbol rather than a frozen frame. The fallback contains no
text, so it stays understandable in mirrored self-views and in the normal video
other participants receive.

Virtual-camera output is always 1920×1080 BGRA, matching the extension's
advertised format. Other input sizes are scaled to fit with black bars rather
than stretched; native 1080p BGRA frames pass through without an extra copy.

Installing it requires a signed and notarized build; see
[docs/SIGNING.md](docs/SIGNING.md). The app itself runs fine unsigned.

Enable **Start OpenOpal automatically** in the Virtual Camera section to launch
OpenOpal when a video app starts using **Open Opal Camera**. A small login helper
listens for capture requests; it does not open the camera or process video.
If macOS requests approval, allow OpenOpal Launcher in **System Settings →
General → Login Items & Extensions**. Disable the same toggle to remove the helper.

OpenOpal starts quietly in the menu bar without opening the controls or taking
focus from your meeting. Hiding or closing controls leaves the camera running;
quit OpenOpal to release it. While the helper observes the same capture session,
quitting does not immediately relaunch it. Turn the meeting's camera off and on,
or reopen OpenOpal, to start again. Camera startup still takes a few seconds.

## Status

Working: camera control, live preview, background blur, local filters, virtual camera.

## License

MIT. Not affiliated with Opal Camera Inc. Thanks to Luxonis for DepthAI, and
to Opal for building the C1 on an open platform in the first place.
