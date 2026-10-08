# Camera filters

## Goal

A native Mac camera playground: describe a look, see it on your face, refine it,
and use it in any app through Open Opal Camera. Start with a complete local
filter browser and a small set of original effects, not a Snap runtime clone.

## Safety boundary

Another agent is live-testing the camera. This branch must not interfere.
Do not launch Open Opal, enumerate or open capture devices, send USB commands,
install/activate an extension, sign or replace the installed app, or interrupt
any running process. Build only in an isolated directory. Verification uses
generated pixels, an offscreen standalone browser view, and compiler checks.
Live camera, face alignment, in-app UI review, latency, and receiving-app checks
require a new explicit handoff from the user. Never flash the C1.

## Research and decision

- Snap lenses are proprietary, not an open portable effects standard.
  [Reverse engineering](https://github.com/ptrumpis/snap-lens-file-format)
  documents the `.lns` archive and Zstandard payload. Extracting assets does not
  implement Snap's scene graph, tracking, shaders, scripting, or runtime.
- [Snap Camera Server](https://github.com/ptrumpis/snap-camera-server) preserves
  service access but explicitly requires the original Snap Camera client. It is
  not an embeddable open-source lens renderer.
- [Camera Kit](https://developers.snap.com/camera-kit/home) officially targets
  iOS, Android, and web. It offers lens compatibility at the cost of Snap's
  platform and distribution requirements, not a native macOS Metal integration.
- [Vision face landmarks](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest)
  run on macOS. Use these with the existing Metal renderer, SwiftUI browser,
  and CoreMediaIO extension. Reuse the app's rendering/export infrastructure.
  Efficiency is a design goal, not a measured comparison with Snap Camera.
- glTF/USD can transport future 3D assets, but neither defines a complete face
  filter runtime. A future small documented recipe format should compose our
  supported primitives rather than execute arbitrary downloaded scripts.

Do not redistribute extracted Snap lenses or copy unlicensed artwork. The
initial hat and cat decorations are original procedural shaders. No added
third-party runtime or downloaded model is needed for these filters.

### Alternate path: actual Snap lenses

Keep real Snap Lens support as an alternate to the native filter playground,
not a replacement for it. The goal would be to run compatible Snap lenses,
rather than approximate them with our built-in effects.

Two integration candidates need separate feasibility checks:

- **Snap Camera client bridge:** use the original client with a compatible
  service such as Snap Camera Server. Establish whether it still runs on the
  target macOS version and can consume Open Opal Camera without a feedback loop.
  This would be a separate-app workflow, not an embedded lens engine.
- **Camera Kit for web:** investigate an embedded web renderer receiving frames
  from our native pipeline and returning processed output. Verify current Mac
  embedding support, lens availability, credentials, licensing, distribution
  rules, and frame-transfer overhead before choosing this architecture.

Neither route is implemented or proven here. A `.lns` extractor alone cannot
provide rendering compatibility. Do not redistribute the original client,
proprietary runtime, or lens assets without the required rights.

Any prototype must first render a permitted lens on synthetic or prerecorded
input, then demonstrate bounded frame ownership, acceptable latency, and output
delivery. Camera access and extension changes still require the explicit live
handoff above. Keep downloads, network access, and account requirements visible;
never silently replace the local/offline path with a Snap service dependency.

The selected implementation remains the native playground and its Generate &
Edit flow. Revisit this alternate only as a separately chosen integration track.

## First release

1. Six browser entries: Original, Cowboy, Cat, Beauty, Monochrome, Warm.
   Search, explicit selected state, accessible controls, intensity, and a
   permanently reachable off action. Effects are hot host settings, not a
   camera reboot or firmware change.
2. One face: asynchronously detect facial landmarks, normalize coordinates,
   account for roll/aspect ratio, bound inference concurrency, and expire old
   results. No-face and errors clear attachments. No new inference when off.
3. Metal effect pass after the existing bokeh/composite path. Cowboy is a 2D
   hat; Cat is ears, nose, and whiskers, not a full animated cat avatar. Beauty
   is subtle face-local smoothing, not a face reshaper. Global grades work
   without a detected face. Zero strength bypasses the new effect pass.
4. Preview and virtual camera consume the same owned, completed, unmirrored
   processed frame. Preview mirroring remains display-only. Use a bounded pool
   so asynchronous consumers cannot observe overwritten intermediate textures.
5. Compile all Swift and Metal sources and the app/extension without launching
   them. Exercise generated frames, shader output, off/zero behavior, no-face
   behavior, and frame ownership without accessing hardware. Record exact
   verification and limitations below.

## Creative-media toolbox

Expand the initial set with Point Cloud, Glitch, Anime Ink, Cyber Warrior,
Halftone, Blueprint, Thermal, Pixel Art, Hologram, and Risograph. Keep them
local and single-pass where possible. Point Cloud is a 2D sampled-dot look,
Anime Ink is cel shading rather than neural character replacement, and Thermal
is false color rather than temperature measurement. Cyber Warrior is tracked
2D face armor. None of these modes needs an extra model download.

Group the catalog into Portrait, Color, Art, and Digital. Search and categories
must not bury the selected effect, intensity, motion switch, or off action.
Motion can be disabled without freezing the actual video.

Extension boundaries:

- Stable string filter identifiers and explicit shader IDs, independent of
  browser ordering. Category, face requirements, and animation metadata live in
  one Swift catalog. Shader IDs are an internal dispatch contract, not an
  external recipe format.
- Pass time explicitly to the encoder. Fixed input plus fixed time is
  reproducible; animated styles do not need mutable random generators or
  per-frame texture allocation. Bound clock precision for long-running sessions.
- Reject in-place output and mismatched texture dimensions/formats. Every pass
  reads immutable input and writes a separately owned target. Future filter
  stacks should use bounded ping-pong scratch, not overwrite published frames.
- Keep global styles independent of Vision. Face effects alone request facial
  analysis. Real depth-point clouds would explicitly request depth, carry its
  age/quality, and need an additional geometry renderer; do not imply the dot
  effect reconstructs a 3D scene.
- Future recipes should compose allowlisted typed operations and parameter
  ranges with a maximum pass/sample/memory budget. Avoid arbitrary downloaded
  Metal, JavaScript, or Swift. Prompt generation should produce that validated
  data, not code executed in the capture process.
- Possible later families: optical-flow trails with bounded history, slit-scan,
  kaleidoscope, motion-reactive ink, person-only print styles, and real depth
  particles. Add analysis/history only when a filter needs it, and never retain
  unbounded camera frames.

Verification stays camera-free: synthetic geometry, photographic stills for
offline visual review if needed, odd/tiny dimensions, fixed-time repeatability,
animation changes, intensity blending, and inherited frame-ownership checks.

### Toolbox verification

Implemented all ten additions and the categorized, paginated browser. The
single pass still serves preview and virtual output; no capture or extension
lifecycle changes were needed for these additions.

Camera-free checks passed:

- Synthetic GPU checks cover all new styles, distinct output, fixed-time
  repeatability, changing animated output, stable static output, intensity
  blending, no-face armor bypass, tiny/odd dimensions, and invalid/in-place
  texture rejection. The full renderer also checks that animation-off keeps
  the pattern still while changing video pixels continue through.
- Catalog checks cover case/whitespace handling, category intersection, category
  search, and keeping None outside filtered results.
- Offline Vision landmarks from scikit-image's public astronaut sample aligned
  the armor to the still photograph. A contact sheet of all new effects and an
  offscreen 330-point browser snapshot were visually inspected. The photograph
  is a temporary verification input, not a bundled app asset.
- An isolated Release build of the app and extension succeeded with signing
  disabled. Existing bridge libraries were copied into staging rather than
  rebuilt under the running app. See the registration correction below.
- Creative shaders compile with `-Wall -Wextra -Werror`. Scoped SwiftLint
  correctness rules and shell syntax checks pass. Unconfigured default SwiftLint
  also ran and reports coordinate-name/function-size/line-style findings in the
  test harness and a six-parameter encoder warning. These are not a clean
  project-wide lint result; no source suppressions or repo-wide restyling were
  added. The pre-existing bokeh shader has an unused-uniform warning under
  `-Wextra`; the full build also reports existing SDK/CMIO concurrency warnings.

One short 1080p, effect-only GPU microbenchmark on this machine measured five
post-warmup frames per style. Mean times: Point Cloud 0.27 ms, Glitch 0.32 ms,
Anime Ink 0.92 ms, Cyber Warrior 0.19 ms, Halftone 0.28 ms, Blueprint 2.21 ms,
Thermal 0.22 ms, Pixel Art 0.51 ms, Hologram 0.94 ms, Risograph 1.73 ms.
The maximum single sample was 3.92 ms. These exclude capture, tracking, bokeh,
readback, display, and virtual-camera delivery, and are not sustained frame-rate
or thermal guarantees.

No live test, app replacement, signing, extension activation, or camera access
was performed for this expansion. Live motion/alignment and receiving-app
validation still require the explicit handoff described above.

## Portrait looks and agent handoff

Added Baby Face, Anime Face, Beard, Glam Hair, Sunglasses, and Bearded Cowboy.
The catalog now has 21 effects plus None. Baby/anime use face-local inverse
warps; beard, hair, glasses, and the existing hat use original 2D artwork.
These are playful stylized looks, not photorealistic age/gender transformation
or replacement characters. Hair does not infer gender or model real occlusion.

[FILTER_AUTHORING.md](docs/FILTER_AUTHORING.md) is the agent handoff: existing
files, stable IDs, the Swift/Metal ABI, coordinate/ownership rules, offline
acceptance checks, and copyable agent assignments. It also specifies a native
Generate & Edit panel, validated single-look recipes, local providers, atomic
draft/apply/revert flow, cancellation, persistence, and later bounded stacking.
The single-look editor is now implemented; see its verification section below.
Arbitrary combinations remain unsupported. Bearded Cowboy is one explicit
built-in composite.

Camera-free verification passed:

- The full synthetic renderer suite, including actual eye enlargement and
  strength, protected lips, hair face openings, beard/hat composition, sunglasses
  at rolled eye anchors, distant-background preservation, expired faces, clipped
  faces, and one-pixel output.
- Offline Vision detection and photographic output for every new look. Reviewed
  the contact sheet and reduced Anime Face's ink strength after visual review.
- The actual SwiftUI browser rendered offscreen at 330 points with Baby Face
  selected, all 21 effects counted, and its description and controls visible.
  All catalog SF Symbols resolved. This is not live app interaction.
- A fresh isolated Release app/extension build, strict Metal warnings, scoped
  Swift correctness lint, and regression-runner shell syntax. The previously
  documented project-wide style and SDK warnings remain separate limitations.
- A real on-device Foundation Models probe reported available and generated the
  typed selection `beardedCowboy` for a beard-and-cowboy-hat prompt. It used no
  camera image or additional model download. This proves native/local selection,
  not a full editor, broad prompt quality, or concurrent video/LLM performance.

### Build-registration correction

Xcode 27 ignores `REGISTER_APP_WITH_LAUNCH_SERVICES=NO`: the full build log showed
`RegisterWithLaunchServices` for the temporary product. The earlier claim that
this flag disabled registration was incorrect. Unregistered this and the two
earlier owned temporary app paths, then checked that none remained in the
Launch Services registry. No installed/running bundle was replaced or launched,
no extension was activated, and no camera was accessed.

Future agents must inspect build output and remove only their own temporary
registration. Use an isolated user/VM if even transient registration is forbidden.
Do not reset shared registration state or guess another undocumented build flag.

## Later milestones

- User-approved live review: hat placement, cat movement, face loss/re-entry,
  glasses/beards, multiple faces, profile turns, low light, mirror behavior,
  bokeh combinations, filter switching, and receiving-app output at 720p/1080p.
  Measure render/inference cost, latency, thermal behavior, and dropped frames.
- Better expressive assets: original/licensed 3D hats and cat avatars, occlusion,
  mouth/eye animation, and a stable tracked-face policy. Do not claim this from
  2D decorations alone.
- Portable recipes: versioned JSON with typed primitives, face anchors, colors,
  intensity ranges, asset references and licenses, resource limits, and local
  preview. Validate before loading; no executable scripts or arbitrary shaders.
- Richer prompt-to-filter: extend the current catalog-selection editor with
  validated parameters and licensed assets. Keep any paid/cloud generation
  explicit and opt-in. Do not upload camera frames by default.
- Sharing: export/import recipes with assets and attribution. Compatibility
  means our documented schema, not arbitrary `.lns` compatibility.

## Verification status

The first local filter implementation is complete on `camera-filters`.
Camera-free checks passed:

- `bash scripts/check-filters.sh`: Metal compilation and Swift 6 compilation;
  synthetic hat/cat landmark placement and roll; beauty cheek smoothing with
  eye/background protection; monochrome and warm pixel output; all-filter
  zero-strength bypass; no-face passthrough; retained-frame immutability;
  bounded pool exhaustion/recovery; fixed 1080p virtual-output conversion,
  native-size no-copy behavior, and aspect-preserving letterboxing.
- Release app and camera-extension build succeeded in a temporary source copy,
  using existing bridge/depthai libraries and the existing compiled depth model.
  Signing was disabled. No installed or running app bundle was replaced.
- The browser rendered offscreen at its actual 330-point inspector width in a
  standalone executable containing only settings, catalog, and browser code.
  Selected Cat, off action, cards, descriptions, and intensity fit. Synthetic
  cowboy/cat PNGs were also visually inspected. Neither check constructed the
  app's camera model or connected to a device.

No language server is configured; Swift compiler diagnostics were used.
The selected Xcode was missing its Metal compiler component, which was installed
with `xcodebuild -downloadComponent MetalToolchain`. The app build still emitted
local Xcode CoreDevice/CoreSimulator compatibility warnings, an existing
`String(cString:)` deprecation, and a duplicate-rpath warning, but succeeded.

Not verified: real-face detection/alignment, face loss/re-entry under movement,
UI interaction in the running app, live CMIO delivery to a receiving app,
sustained frame rate, thermal behavior, or latency. The new single-in-flight
capture policy favors frame ownership and bounded latency over concurrent mask
throughput; measure the bokeh frame-rate tradeoff during the approved live pass.

No live test is authorized yet. The output is ready for that handoff, not a
claim that the new filters have been proven in a real video call. Generating new
artwork, arbitrary combinations, and full 3D avatars remain later milestones.

## Generate & Edit verification

Implemented a native draft editor with real on-device Foundation Models,
strict version-1 recipes, local atomic preset storage, and a synthetic-face
preview using the production Metal encoder. Generation selects an existing
catalog look; it does not generate new artwork. Apply and Undo are explicit
active-output changes. Editing, generation, sample previews, and Save stay local
to the draft. Presets reload into the draft without applying.

Camera-free checks passed:

- `bash scripts/check-filters.sh`: existing synthetic GPU/ownership/output
  regressions plus strict recipe validation, persistence, malformed-file
  handling, and failed-write preservation.
- Standalone Swift 6 compilation targeting macOS 26 included the production
  editor, provider, catalog, settings, and renderer. The Xcode project was
  regenerated. No full app/extension build was performed for this editor change.
- A real-model smoke selected Bearded Cowboy from both a sunglasses draft and
  a warm draft, reduced sunglasses intensity from 0.8 to 0.4, and rejected
  photorealistic-baby and blue-hat-on-anime requests in the final run.
- Editor actions preserved active settings during generation, cancellation,
  edits invalidating in-flight work, unsupported requests, invalid drafts, and
  a real model context-overflow error. Save/reload, Apply, Revert, and Undo
  passed. Synthetic output pixels stayed unchanged during draft editing and
  became monochrome only after Apply through the shared renderer.
- Opened only a standalone native filter-browser harness, expanded Generate &
  Edit through accessibility, and visually reviewed its 350-point window.
  Reviewed the synthetic cowboy preview too. This was not the running camera
  app or a full UI interaction test of every editor control.

Earlier real-model probes produced partial matches, unsupported substitutions,
and false rejections. The provider now separates selection, a candidate-only
capability check, and controls into serial guided calls. The final smoke passed,
but prompt compliance is not guaranteed. The UI warns users to review the
selected look and its trusted catalog description before applying it. Manual
editing remains available when generation fails or misunderstands.

Xcode 27 reports Foundation Models `GenerationOptions(sampling:)` deprecations;
the initializer is retained for the macOS 26 API. No camera access, app
replacement, signing, extension activation, or live receiving-app verification
was performed. Concurrent video/model performance remains unmeasured.

## Integrated dev build

The dev build combines current main, the native filters, and Generate & Edit.
Main includes the merged dependency, saved-control, playback-stream, and
automatic-startup fixes. The original dirty filter checkout stays unchanged.

Camera-free verification passed:

- Synthetic Metal effects, frame ownership, bounded pools, and virtual-output
  conversion; strict recipes and local preset persistence.
- Camera, blur, filter, and focus-limit persistence, reset, invalid-data handling,
  and startup-policy transitions.
- Two boot-safety checks, seven dependency-packaging checks, and serialized
  autofocus controls against the freshly rebuilt DepthAI library.
- Light-mode production browser/editor rendering, synthetic preview, and
  draft/Apply/Revert/Undo/Save/reload transitions with isolated preferences.
- Unsigned Release builds of the app, extension, and login helper. Packaging
  validated seven Mach-O binaries with no dependency outside the app or macOS.

The real local model first rejected a supported combined look, returned an
invalid title, and changed looks during a refinement. Generation now uses catalog
titles, an explicit current-look choice, and a capability decision before its
explanation. The final three-case smoke selected Bearded Cowboy, reduced its
intensity from 0.8 to 0.4 without changing looks, and rejected unsupported
photorealism and a custom hat color. This is not a general semantic guarantee.

Repeated packaging after an incremental rebuild exposed an old rewritten
library collision. Releases now use `clean build`; the fresh build packaged
successfully without weakening collision checks.

The local app has ad-hoc signatures, not a Developer ID signature. The packaged
Homebrew library needed its signature restored after load-path rewriting.
Offline controls then ran against the final bundled libraries successfully.
No account keys, camera, USB, or installed extension were used. Installing the
bundled extension or login helper still needs the release signing workflow.
Live tracking, concurrent model/video performance, and receiving-app output
remain for the user's test.

## Upstream refresh

`filter-effects` now includes upstream `8d47cfb` and preserves the native filters
and editor. Main and develop remain unchanged. This branch still requires
macOS 26; upstream's macOS 14 target does not cover Foundation Models.

Camera-free checks passed:

- Synthetic Metal effects, owned frames, bounded pools, output conversion,
  strict recipes, and preset persistence.
- Ten Python boot-safety and dependency-packaging checks; saved camera settings,
  one-shot focus restoration, and startup-policy transitions.
- Actual on-device generation selected Bearded Cowboy at 0.8, kept it at 0.4
  during refinement, and rejected photorealism with a custom hat color.
- The production panel and filter browser ran in a standalone light-mode host.
  Floating, docking, resizing, focus-loss dismissal, close, reopen hooks, and
  shutdown passed. Isolated draft/save/reload/Apply/Undo/Revert actions and
  synthetic output pixels passed.
- Release app, extension, and helper built in an isolated tree. Seven packaged
  Mach-O binaries passed dependency and minimum-OS validation. Local ad-hoc
  signatures verified; serialized autofocus controls ran against those libraries.
  Owned temporary Launch Services registrations were removed and verified absent.

No camera, USB discovery, real app launch, or extension activation occurred.
The full inspector, mirrored click-focus reticle, live unplug/reconnect,
tracking quality, and Zoom/Meet delivery remain unverified.
Pending discovery/open and rendering are not cancelled on teardown; native close
can outlast its timeout. Late work can still finish after shutdown.
These lifecycle gaps and real Snap Lens compatibility remain unfinished.
