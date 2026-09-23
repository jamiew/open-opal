# Open Opal

A native macOS app for the Opal C1 webcam. Opal has discontinued the C1 and its
Composer software; this project keeps the camera working.

The C1 is built on Luxonis' [DepthAI](https://github.com/luxonis/depthai-core)
platform, so it can be driven with open-source tools. Open Opal talks to the
camera directly over USB.

<img width="820" alt="Open Opal" src="docs/screenshot.png">

## Features

- Exposure: auto, or manual shutter and ISO, with EV compensation and AE lock
- Focus: autofocus modes, manual lens position, click anywhere to focus
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
switches between docked and floating controls. Clicking away or pressing Escape
hides the panel without disconnecting the camera. Click the icon to reopen it.
Quit ends the camera session.

Frames are downscaled on the camera's own ISP before crossing USB, which keeps
glass-to-screen latency around 45 ms at 1080p30. The toolbar shows the live
number.

## Building

Needs an Apple silicon Mac on macOS 26 or later, Xcode 26, and
`brew install cmake ninja xcodegen`.

```sh
./scripts/bootstrap.sh     # fetches and builds depthai-core
./scripts/fetch-models.sh  # downloads the Core ML depth model
xcodegen generate
open OpenOpal.xcodeproj    # then build & run from Xcode (⌘R)
```

To build from the command line and install to /Applications:

```sh
xcodebuild -project OpenOpal.xcodeproj -scheme OpenOpal \
  -configuration Release -derivedDataPath build/DerivedData build
cp -R build/DerivedData/Build/Products/Release/OpenOpal.app /Applications/
```

Use Release builds for day-to-day use — Debug builds noticeably stutter in UI
animations.

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

Portrait effects use Apple's Vision face landmarks locally, tracking one face.
The other effects need no face tracking. Missing or stale detections remove face
attachments. Intensity zero bypasses the filter pass and face analysis. Disabling
animation holds shader time fixed; video and face tracking continue.

All artwork is procedural. Cat and Cyber Warrior are 2D face decorations, not
full avatars. Anime Ink is cel shading and edge drawing, not generative face
replacement. Point Cloud is a 2D dot visualization, not reconstructed depth.
Thermal maps brightness to false color and cannot measure temperature.
Beauty softens the face without geometric reshaping. Baby Face and Anime Face
enlarge facial features with local warps, not photorealistic age or character
replacement. Beard and Glam Hair are illustrated accessories for anyone, not
gender transformations. Bearded Cowboy combines the beard and existing hat;
arbitrary effect stacking is not supported.

Effects run after background blur in one Metal pass and reach both the preview
and virtual-camera feeder. Only the preview is mirrored. Spatial patterns scale
with resolution; animated effects use bounded, explicit time rather than frame
counts. No downloaded lenses, extra models, cloud calls, or camera uploads are
involved. See [Filter authoring](docs/FILTER_AUTHORING.md) for the compiled shader
contract.

Camera-free regression checks:

```sh
bash scripts/check-filters.sh
```

This compiles the Metal shaders and a standalone Swift executable, then checks
generated frames, synthetic face anchors, portrait warps and mouth protection,
catalog search, time determinism, animation-off behavior, intensity, tiny/odd
image sizes, retained-frame ownership, and bounded output-pool recovery. It
never starts Open Opal, opens a capture device, or connects to the virtual-camera
extension. Synthetic checks do not establish live tracking quality, sustained
frame rate, or receiving-app output.

## Virtual camera

Open Opal installs a CoreMediaIO system extension that publishes **"Open Opal
Camera"** to every app on the Mac — Zoom, Meet, FaceTime, anything. It carries
the processed image, background blur and filters included. When the app isn't
running it shows a placard rather than a frozen frame.

Virtual-camera output is always 1920×1080 BGRA, matching the extension's
advertised format. Other input sizes are scaled to fit with black bars rather
than stretched; native 1080p BGRA frames pass through without an extra copy.

Installing it requires a signed and notarized build; see
[docs/SIGNING.md](docs/SIGNING.md). The app itself runs fine unsigned.

## Status

Working: camera control, live preview, background blur, local filters, virtual camera.

## License

MIT. Not affiliated with Opal Camera Inc. Thanks to Luxonis for DepthAI, and
to Opal for building the C1 on an open platform in the first place.
