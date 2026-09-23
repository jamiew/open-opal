# Filter authoring

Open Opal ships 21 compiled local Swift/Metal effects plus None. This document
covers the implemented catalog, shader ABI, and shared-frame rendering path.
There is no runtime shader import, downloadable lens system, or generation UI.

## Current source map and rendering contract

| Area | Source |
| --- | --- |
| Stable IDs, names, capabilities, categories, search | `Sources/OpenOpal/Render/CameraFilter.swift` |
| Host settings and reset | `Sources/OpenOpal/Camera/CameraSettings.swift` |
| Main-actor snapshot and owned frame publication | `Sources/OpenOpal/Render/BokehRenderer.swift`, `Sources/OpenOpal/CameraModel.swift` |
| GPU encoder and uniform layout | `Sources/OpenOpal/Render/CameraEffects.swift` |
| Kernel dispatch, common geometry, original props | `Sources/OpenOpal/Render/CameraEffects.metal` |
| Global media styles | `Sources/OpenOpal/Render/CreativeMedia.h` |
| Cyber armor | `Sources/OpenOpal/Render/CyberWarrior.h` |
| Baby/anime face sampling | `Sources/OpenOpal/Render/PortraitWarp.h` |
| Beard, hair, glasses | `Sources/OpenOpal/Render/PortraitAccessories.h` |
| Local landmarks and freshness | `Sources/OpenOpal/Render/FaceTracker.swift` |
| Categorized browser | `Sources/OpenOpal/UI/FilterBrowser.swift` |
| Camera-free regression entry point | `scripts/check-filters.sh`, `tools/*filter_checks.swift` |

The encoder consumes equal-size, distinct `bgra8Unorm` textures with display-
encoded RGB values. It rejects off/invalid intensity, required-but-missing faces,
and incompatible targets. Do not read and write the same storage in one pass.
The output is opaque. None/zero strength skips analysis and the effect pass.

The Swift/Metal ABI is five 16-byte vectors, 80 bytes total:

| Vector | Components |
| --- | --- |
| `frame` | width, height, intensity, explicit shader ID |
| `pose` | normalized eye midpoint x/y, pixel-space right-axis x/y |
| `features` | normalized nose x/y, mouth x/y |
| `dimensions` | face width, face height, eye separation, mouth width, all in pixels |
| `visibility` | face freshness opacity, bounded animation seconds, two reserved zeros |

Coordinates are top-left, unmirrored. Vision coordinates are converted once in
`FaceGeometry.make`. `effectLocal(uv, u)` projects pixel-space displacement onto
right/down axes and divides by face width. Rotate in pixel space, not normalized
UV space; otherwise head roll is wrong on a widescreen frame. New helpers must
preserve this ABI or update both sides and every synthetic fixture together.

Time comes explicitly from the encoder, is sanitized, and wraps at 3600 seconds.
Static styles ignore it. Animated styles must be repeatable for the same
input/time and avoid whole-frame strobing. Disabling animation fixes shader time;
video and tracking still update.

The current face policy is one largest detected face, one asynchronous Vision
request at a time, at most 15 starts/second, and a 250 ms source-age limit. Do not
create a separate tracker for each prop. Pose and occlusion remain approximate.

## Stable catalog IDs

String IDs identify catalog entries; numeric IDs select internal shader dispatch.
Never renumber an existing entry to reorder the browser.

| Shader ID | String ID | Requirement |
| --- | --- | --- |
| 0 | `none` | no effect |
| 1, 2, 3 | `cowboy`, `cat`, `beauty` | face |
| 4, 5 | `monochrome`, `warm` | global |
| 6, 7 | `pointCloud`, `glitch` | global, animated |
| 8 | `anime` | global Anime Ink |
| 9 | `cyberWarrior` | face, animated |
| 10, 11, 12, 13 | `halftone`, `blueprint`, `thermal`, `pixelate` | global |
| 14 | `hologram` | global, animated |
| 15 | `risograph` | global |
| 16, 17 | `babyFace`, `animeFace` | face warp |
| 18, 19, 20 | `beard`, `glamHair`, `sunglasses` | face prop |
| 21 | `beardedCowboy` | beard then hat, one built-in composite |

Bearded Cowboy is a deliberately supported composite. The app does not yet
support arbitrary combinations. Baby Face and Anime Face preserve identity
through stylized sampling; Glam Hair is illustrated 2D artwork without real
hair occlusion. Thermal is false color and Point Cloud is a 2D dot visualization.

## Adding a compiled effect

1. Read the complete encoder, target helper, catalog, and relevant tests. Use
   LSP references if a server is configured; otherwise use compiler diagnostics
   and explicit callsite searches. Do not assume a language server exists.
2. Add a descriptive string ID and unused shader ID in `CameraFilter`. Add title,
   truthful description, symbol, category, face requirement, and animation flag.
   Browser cards/search use this catalog automatically.
3. Put the implementation in the closest existing helper file. Create a header
   only for a genuinely distinct family. Do not add a protocol/plugin hierarchy
   for one effect. Headers use include guards and uniquely named inline helpers.
4. Wire the kernel dispatch. Global styles return full-strength color and blend
   once with the source. Layered props apply intensity/freshness to every layer.
   Warps change inverse-sampling coordinates continuously with intensity, rather
   than cross-fading two displaced faces and producing ghost eyes.
5. Clamp sampling, feather support boundaries, preserve untouched regions, and
   cap taps. Reuse the existing source/output and scratch textures. Add no
   history, model, file IO, network IO, or per-frame CPU pixel conversion unless
   the feature genuinely requires it and its budget is explicitly approved.
6. Test visible behavior: placement at known landmarks, roll/aspect, missing and
   expired faces, intensity zero, edge clipping, tiny/odd images, deterministic
   time, and output ownership. Inspect offline images at several intensities.
   Existing tests must continue to pass.
7. Update README and this catalog contract when capabilities change. Record
   exactly what was verified; an offline image is not sustained camera proof.

## Frame ownership

`BokehRenderer.render` publishes a completed `RenderedFrame` containing its
BGRA texture, IOSurface-backed pixel buffer, and Core Video texture wrapper.
The renderer retains source plane wrappers through GPU completion. The preview
retains the whole output frame through completion of its separate command queue;
the virtual-camera feeder receives that same frame's pixel buffer. Mirroring is
only a preview transform.

Output allocation is bounded to six buffers per size. When consumers retain all
buffers, rendering drops an incoming frame instead of overwriting published
pixels or growing a queue. None, zero intensity, and missing face detections
bypass the effect pass; the extra effect input texture is allocated lazily.

## Camera-free checks

```sh
bash scripts/check-filters.sh
```

The standalone harness uses generated pixels and synthetic face landmarks. It
does not create `CameraModel`, open capture hardware, or connect a CMIO feeder.
It checks effects, search, animation, intensity, image boundaries, retained-frame
ownership, pool exhaustion, and recovery. It does not test virtual-output format
conversion, real Vision tracking, sustained frame rate, or receiving applications.

For visual examples without personal imagery, render generated BGRA pixels and
explicit `FaceGeometry` through `CameraEffects`, as the fixtures in
`tools/creative_filter_checks.swift` and `tools/portrait_filter_checks.swift` do.
The browser can be hosted on its own with `CameraSettings` and `FilterBrowser`;
no camera model is needed. The harness itself does not write image files.

Do not launch a camera build, install or activate an extension, or interrupt a
live camera session without explicit user approval. Never flash the C1. Keep
shader and standalone checks separate from full application builds; Xcode can
register even a temporary unsigned app with Launch Services. Do not treat
`REGISTER_APP_WITH_LAUNCH_SERVICES=NO` as a guarantee against registration.
