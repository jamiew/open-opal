# Open Opal: technical notes

How Open Opal works, how to build and test it, and what we know about the
hardware. For signing and releases, see [docs/SIGNING.md](docs/SIGNING.md) and
[docs/RELEASING.md](docs/RELEASING.md).

## Building

The production-only `develop` branch runs on Apple silicon Macs with macOS 26
or later. Filters and Generate & Edit are kept on the local `experiments`
branch, not in this build. Window docking remains supported.

Building needs Xcode 26 or newer and `brew install cmake ninja xcodegen`.

```sh
./scripts/bootstrap.sh     # fetches and builds depthai-core
./scripts/fetch-models.sh  # downloads the Core ML depth model
xcodegen generate
open OpenOpal.xcodeproj    # then build & run from Xcode (⌘R)
```

For an unsigned command-line build:

```sh
xcodebuild -project OpenOpal.xcodeproj -scheme OpenOpal \
  -configuration Release -derivedDataPath build/DerivedData clean build
```

`Config/BuildIdentity.xcconfig` holds safe unsigned defaults. An optional ignored
`Config/BuildIdentity.local.xcconfig` sets the team, host bundle ID, and App Group.
The extension ID/product name, launcher ID, Mach service and entitlements derive
from those settings. See [SIGNING.md](docs/SIGNING.md) for the signed build and
notarization workflow; do not install an unsigned replacement over a signed app.

Use Release builds for day-to-day use — Debug builds noticeably stutter in UI
animations.

The virtual camera only installs from a signed build in /Applications; see
[docs/SIGNING.md](docs/SIGNING.md). The app itself runs fine unsigned.

Bootstrap disables network-camera discovery and connections inside DepthAI.
The C1 uses USB only. Rebuild the SDK and app to update existing copies.

Bootstrap pairs curl's TLS headers with Hunter's libraries, not Homebrew's.

### First-generation C1s

First-generation IMX378 C1s use a RAM-only bootloader handoff. The pinned
DepthAI SDK patch allows only `GetBootloaderVersion` and `UsbRomBoot` to bypass
the version check when the bootloader reports exactly `0.0.0`; unrelated
requests keep their version checks. Existing SDK libraries must be rebuilt
with `./scripts/bootstrap.sh` after updating this patch, then the app rebuilt.
Bootstrap refuses SDK source with the older unrestricted `OPAL_C1_PATCH`:
restore only its two request-version checks to upstream v2.30.0, preserving any
other SDK edits, before rerunning bootstrap.

## Tests

The camera-free safety regressions compile isolated C++ harnesses without
linking DepthAI or accessing USB:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_boot_safety.py'
```

The native regressions inspect serialized autofocus commands and check USB-only
discovery. Discovery hides USB devices and blocks Internet socket calls. It
calibrates socket observation before checking for zero discovery attempts.
CI runs both regressions. Do not run `bridge_test` or `region_test` without a
camera: those are manual hardware probes.

```sh
cmake -S Sources/OpalBridge -B build/control-tests \
  -DOPAL_BRIDGE_TEST=ON
cmake --build build/control-tests --target control_delta_test usb_only_test
ctest --test-dir build/control-tests --output-on-failure
```

The camera-free Metal checks cover frame ownership, analysis storage, capture
resets, and temporal history. An absolute neutral video-range ramp also catches
unwanted darkening:

```sh
./scripts/check-render.sh
```

The integrated checks use the installed app and isolated preferences:

```sh
bash scripts/check-camera.sh /Applications/OpenOpal.app
```

This path does not access USB or CMIO. With explicit camera takeover permission,
the live path exercises real capture and virtual-camera readback:

```sh
bash scripts/check-camera.sh /Applications/OpenOpal.app --live-takeover
```

Warn other camera users first. Live takeover remains RAM-only and does not
change saved user controls or record pixels. JSON-lines results distinguish
failure (exit 1) from unverified evidence (exit 2). Missing prior camera
permission does not trigger a headless TCC prompt. Optical/chart checks, physical
unplug/replug, and GUI behavior need separate observation; software reconnect
does not prove them. No result for the replacement build is implied here.

## The hardware

Little of this is documented elsewhere, so for the record:

- The C1 is a Luxonis DepthAI device: an Intel Movidius **Myriad X** VPU
  (USB VID `0x03E7`) paired with a Sony **IMX582** 48MP sensor (module name
  `LCM48`) and a real autofocus lens. Early units use a Sony **IMX378**.
- The sensor has **no native 1080p mode**. Its readout modes are
  3840×2160 (2–42 fps), 4000×3000 (2–30 fps), and 5312×6000 (1–10 fps).
  That's also why the app caps out at 42 fps.
- Full 4K NV12 at 30 fps is ~370 MB/s, which saturates USB 3 and costs
  ~300 ms of latency. So the app always captures 4K and downscales on the
  camera's ISP before the frame crosses the wire, which keeps
  glass-to-screen latency around 45 ms at 1080p30.
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

The physical C1 light can remain off while this RAM-loaded pipeline captures.
Its electrical cause and a safe LED-control command are not established. The
light is not a privacy guarantee; unplug the camera for hardware assurance.

For first-generation IMX378 C1s, the stock camera must present both video and
audio interfaces before Open Opal attempts the handoff. Every reconnect must
report the selected camera's MxID. If that ID disappears or changes, Open Opal
fails safely without uploading the pipeline, even if only one unbooted device
is attached. A USB address change is allowed; an unidentified device is not.

Boots acknowledge captured settings only after success. Failed boots keep changes pending.
Frame width and height change together under one lock.

```
Myriad X (IMX582)
  ColorCamera ── ISP downscale ── NV12 ──► XLink/USB ──► OpalBridge (C shim over depthai-core)
  3A control  ◄─ XLinkIn ◄──────────────────────────────  CameraControl messages
                                                              │
                              IOSurface CVPixelBuffer ◄───────┘  (the only copy)
                                        │
              Metal: NV12 → linear RGB → mask → blur → composite + optional mirror
                                        │
                       shared owned frame → preview + virtual camera
```

The background blur uses Vision person segmentation. Synchronous bokeh pairs
analysis with the exact input frame; asynchronous mode reuses the latest current
analysis without waiting for inference. Frames are blurred in linear light so
highlights bloom instead of greying out. An
optional depth-graded mode uses
[Depth Anything V2](https://huggingface.co/apple/coreml-depth-anything-v2-small)
for distance-based falloff.

Depth analysis runs one inference at a time, including switches between
background and frame-paired analysis. Matte quality changes take effect when
an idle analysis lane starts its next frame, not during a running Vision request.

Preview and virtual-camera consumers retain the same completed render output.
Later frames, including a resolution change, cannot overwrite pixels still
owned by a reader. When all output slots are retained, rendering drops a frame
instead of recycling live storage.

Mirror output defaults to false. The final Metal composite applies the optional
horizontal flip once, before preview and virtual-camera consumers receive the
same frame. The preview has no extra display-only flip. This setting does not
alter the sensor's physical upside-down orientation correction.

Matte and depth results keep their storage until every analysis or GPU reader
finishes. Capture resets and sync-mode changes reject earlier results and
subject callbacks; they do not recycle a lane while Vision is still using it.
Synchronous rendering rejects analysis for any other input buffer rather than
silently falling back to the latest asynchronous mask.

Temporal smoothing reads the previous matte without changing it. A fresh
capture, resolution change, analysis-mode change, or interrupted bokeh path
starts from the current matte instead of blending with old or uninitialized
history. The check compares GPU history pixels and fresh-versus-warm rendering,
then checks that capture, mode, and resolution resets match a fresh renderer.
Linear-light decoding and display encoding use matching sRGB transfer curves.
With bokeh off, the neutral video-range ramp must round-trip to its absolute
display levels within one 8-bit step; comparison only against another processed
frame would miss unwanted darkening.

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

Reconnects clear saved face-metering regions and tap holds.
Without a user limit, autofocus mode changes preserve the camera's tuned range.
Saved one-shot autofocus restores as Continuous when the app starts again.

### Tuning files

Put one `.bin` ISP tuning file in `~/Library/Application Support/OpenOpal/tuning/`
to use it instead of DepthAI's defaults. It controls exposure, white balance,
colour and noise for one sensor and lens, so use one that matches your camera.
With several files, or none, the defaults are used.

### Virtual camera

Open Opal installs a CoreMediaIO system extension that publishes **"Open Opal
Camera"** to every app on the Mac. It carries the processed image, blur and all.
When the app isn't running it shows a camera-off symbol. The fallback contains
no text, so it stays understandable in mirrored self-views and in the normal
video other participants receive.

The virtual camera advertises 1920×1080 BGRA at 30 fps independently of sensor
capture settings; actual frame delivery depends on capture and rendering speed.
Other input sizes are scaled to fit with black bars rather than stretched;
native 1080p BGRA frames pass through without an extra conversion copy.
The feeder uses the device's output scope and playback stream. The capture
stream serves camera clients and is not a queue for sending our frames.

Invalid sink timestamps are dropped. Only this team's signed host may produce frames.
Stops discard pending callbacks.
Failed feeder starts release the copied queue.

**Start OpenOpal automatically** registers a small login helper that listens
for capture requests on "Open Opal Camera" and opens OpenOpal without taking
focus. It does not open the camera or process video. If macOS asks, allow
OpenOpal Launcher in **System Settings → General → Login Items & Extensions**.
Deliberately quitting during a call will not immediately relaunch it: turn the
meeting's camera off and on, or reopen OpenOpal, to start again.
