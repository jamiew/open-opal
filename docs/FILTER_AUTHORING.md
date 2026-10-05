# Filter authoring and native generation

## Status and goal

Open Opal renders local Swift/Metal effects into the same owned frame used by
its preview and virtual camera. The browser ships built-in looks, not a general
lens runtime. Generate & Edit uses the on-device Foundation Models provider to
select a validated single-look draft. Manual editing works without that model.

The design is **text -> validated recipe -> compiled Metal effects**. The LLM
runs when someone generates or edits a look, not once per video frame. It never
writes executable shaders into the running capture process.

Simple props, palettes, print styles, and bounded facial warps are good agent
coding tasks. Photorealistic de-aging, convincing replacement hair, or a full
anime character are substantially harder: they need dedicated image models,
training/assets, temporal consistency, identity handling, and latency work. A
text LLM alone does not implement those transformations.

## Nonnegotiable operating rules

- Do not launch Open Opal, enumerate/open a camera, send USB commands, install or
  activate an extension, sign/replace the installed app, or interrupt another
  agent's live session without a new explicit user handoff. Never flash the C1.
- Preserve unrelated working changes. No commits, pushes, or PR changes without
  separate approval. Do not change bundle IDs or signing as part of filters.
- Validate with generated buffers and offline, licensed stills first. Build in
  isolated staging using copied native libraries. Disable signing. Do not run
  the bridge prebuild under the live app. Xcode 27 still registers temporary
  apps with Launch Services despite `REGISTER_APP_WITH_LAUNCH_SERVICES=NO`.
  Remove only your own temporary app's registration afterward with
  `lsregister -u <exact-temporary-app-path>` and verify it is absent. Never
  reset the registration database. If even temporary registration is forbidden,
  use an isolated user/VM for the full app build; shader/standalone checks do not
  need an app bundle.
- Keep output ownership and bounded queues intact. No preview-only effect that
  disappears from virtual output. Mirroring is display-only.
- Do not infer gender or age. Beard and hair are optional looks for anyone.
  Describe Baby Face as a playful warp, not a photorealistic age transformation.
- No downloaded Snap art, unlicensed assets, hidden network calls, camera uploads,
  arbitrary scripts, or arbitrary Metal compilation from model output.

## Current source map and rendering contract

| Area | Source |
| --- | --- |
| Stable IDs, names, capabilities, categories, search | `Sources/OpenOpal/Render/CameraFilter.swift` |
| Host settings and reset | `Sources/OpenOpal/Camera/CameraSettings.swift` |
| Main-actor snapshot and owned frame publication | `Sources/OpenOpal/Render/BokehRenderer.swift`, `Sources/OpenOpal/CameraModel.swift` |
| Bounded matte/depth backing storage | `Sources/OpenOpal/Render/AnalysisTexturePool.swift` |
| GPU encoder and uniform layout | `Sources/OpenOpal/Render/CameraEffects.swift` |
| Kernel dispatch, common geometry, original props | `Sources/OpenOpal/Render/CameraEffects.metal` |
| Global media styles | `Sources/OpenOpal/Render/CreativeMedia.h` |
| Cyber armor | `Sources/OpenOpal/Render/CyberWarrior.h` |
| Baby/anime face sampling | `Sources/OpenOpal/Render/PortraitWarp.h` |
| Beard, hair, glasses | `Sources/OpenOpal/Render/PortraitAccessories.h` |
| Local landmarks and freshness | `Sources/OpenOpal/Render/FaceTracker.swift` |
| Categorized browser | `Sources/OpenOpal/UI/FilterBrowser.swift` |
| Recipe validation and local presets | `Sources/OpenOpal/Filters/FilterRecipe.swift`, `FilterPresetStore.swift` |
| Local generation and draft state | `Sources/OpenOpal/Filters/FilterRecipeProvider.swift`, `FilterEditorModel.swift` |
| Editor and synthetic preview | `Sources/OpenOpal/UI/FilterEditor.swift`, `Sources/OpenOpal/Filters/FilterDraftPreview.swift` |
| Camera-free regression entry point | `scripts/check-filters.sh`, `tools/analysis_checks.swift`, `tools/*filter_checks.swift`, `tools/recipe_checks.swift` |

The encoder consumes equal-size, distinct `bgra8Unorm` textures with display-
encoded RGB values. It rejects off/invalid intensity, required-but-missing faces,
and incompatible targets. Do not read and write the same storage in one pass.
The output is opaque. None/zero strength skips analysis and the effect pass.

Analysis results reserve a reusable texture slot until every reader finishes.
Keep the full result alive through GPU completion, not just its texture.
Exhausting the bounded pool drops analysis instead of overwriting retained pixels.
Depth inference is serialized. Synchronous rendering takes the `FrameAnalysis`
returned for that exact input buffer, not the latest asynchronous result.

Pass the captured `captureGeneration` to analysis and rendering.
`resetCaptureState()` invalidates old work, callbacks, and temporal history.
Mode changes also invalidate delayed results. Matte and depth history read prior
storage and write separate output storage before swapping after GPU completion.
The color-transfer functions use matching 2.4 exponents; unfiltered video must
round-trip a neutral video-range ramp without darkening it.

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

String IDs are the future external identifiers; numeric IDs are internal dispatch.
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
7. Update README/PLAN and this catalog contract when capabilities change. Record
   exactly what was verified; an offline image is not sustained camera proof.

Use `bash scripts/check-filters.sh`. Compile `CameraEffects.metal` with
`-Wall -Wextra -Werror` as an additional shader check. Existing default SwiftLint
rules do not match all coordinate-name/function-size conventions; report that
separately from scoped correctness lint rather than claiming a clean full repo.

### Copyable coding-agent assignment

> Implement [specific look] in [owned helper file] using this document's existing
> shader ABI and [assigned unused ID]. Preserve all existing IDs and unrelated
> work. Describe the look's input, anchors, support bounds, strength behavior,
> sample budget, and limitations before editing. Do not access the camera, launch
> the app, sign/install extensions, or modify capture lifecycle. Main owns shared
> dispatch/catalog integration unless explicitly assigned otherwise. If working
> concurrently, skip all validation and hand off exact APIs plus synthetic test
> invariants. The integration owner runs the camera-free checks, inspects actual
> offline output, and builds the isolated app after the batch finishes. Deliver a
> complete effect, not a placeholder, fake fallback, or unimplemented TODO.

## Generate & Edit: first implementation specification

This is the implemented single-look contract, not an arbitrary shader graph or
an import/sharing UI. Preset files use the same validator as generated recipes.

### Recipe version 1

A validated recipe selects one supported look and its existing controls:

```json
{
  "schemaVersion": 1,
  "title": "Bearded cowboy",
  "filter": "beardedCowboy",
  "intensity": 0.8,
  "animate": false
}
```

Generation uses the selected catalog title instead of inventing one. You can
rename the draft manually. Strength and motion refinements can keep the current
look without choosing another catalog effect.

Validation rules:

- Accept exactly these keys; reject unknown keys and unsupported schema versions.
  Limit encoded JSON to 8 KiB. Reject nonfinite/out-of-range numbers instead of
  silently clamping the model's intent.
- `title`: trimmed, nonempty, at most 64 characters, no control characters.
- `filter`: one existing `CameraFilter.rawValue`. Never deserialize numeric shader
  IDs, code, URLs, paths, prompts-as-instructions, or unknown operation names.
- `intensity`: finite 0...1. `animate`: Boolean and false for static effects.
- Decode once into a typed `Sendable` value off the render path. Unknown enum
  values fail. One validator serves model output, saved presets, and imports.
- Treat `none` as a valid off recipe. Derive tracking requirements and resource
  use from trusted catalog metadata, never from the model.

Use a discriminated proposal: either a recipe or an unsupported explanation.
Do not substitute a different look silently. Examples:

- "Give me a beard and cowboy hat" -> `beardedCowboy`.
- "Make those sunglasses subtler" -> retain `sunglasses`, lower intensity.
- "Make me a photorealistic baby" -> explain the limitation and offer the
  stylized Baby Face option for explicit selection.
- "Put a blue hat on my anime face" -> unsupported until color/stack parameters
  exist. Version 1 must not pretend that changing intensity achieves this.

### Native UI and state

Add a compact SwiftUI Generate & Edit section alongside the existing browser:

- Multiline prompt, Generate, Cancel, provider/status label, generated title and
  honest limitation text, and typed draft controls for look/intensity/animation.
- Keep `active` and `draft` separate. Generation and slider edits affect the draft
  only. Preview uses an offscreen sample or an explicitly requested in-memory
  still, not a hidden change to the virtual camera.
- Apply is the sole atomic update of active settings. Label that it changes the
  virtual output. Revert restores the last applied state; undo restores the prior
  recipe. Save stores the draft without secretly applying it.
- States: idle -> generating -> validated draft or visible error. Cancel or a
  newer request invalidates older results using a generation ID. Never apply
  partial streamed JSON or a response to an outdated edit.
- Generation runs outside the main actor and render queue. One request maximum.
  Preserve active video through cancellation, unavailable model, refusal,
  malformed output, context overflow, and provider failure.
- Manual editing works even without a model. Do not expose a working-looking
  Generate button until a real provider is connected and available.
- Persist only validated JSON under Application Support with app-generated UUID
  filenames and atomic writes. The model never chooses filesystem paths. Cloud
  synchronization/sharing is a separate, explicitly authorized feature.

### Native/local providers

**Recommended first provider: Apple Foundation Models.** The app already targets
macOS 26. Check `SystemLanguageModel.default.availability` and supported locale.
Explicitly use the on-device system model; never silently fall back to Private
Cloud Compute or a remote provider. Apple Intelligence must be supported/enabled
and its model ready. Explain unavailable states and retain the manual editor.
Use guided generation or a dynamic schema derived from the trusted catalog,
then the same semantic recipe validator. Structured generation guarantees shape,
not artistic correctness or safe resource use. Apple's own guidance lists code
creation among weak uses of its on-device model, reinforcing the recipe approach.

**Optional provider: MLX Swift LM.** This offers native Swift integration and
Apple-silicon local inference with selectable model weights. Start by evaluating
small quantized instruction models, not declaring one best without measurements.
Require explicit consent before downloading weights; show license, size, disk
and memory needs, progress, cancel, and removal. Once installed, support offline
operation. Inference shares GPU/unified memory with video, so measure concurrent
rendering, cap generation length, allow cancellation, and release idle models.
Pin a tested release. Current MLX `main` documents a FoundationModels bridge
requiring the macOS 27 SDK/runtime path; do not accidentally raise this app's
macOS 26 minimum just to use that bridge. Direct MLX integration is a separate
option subject to the chosen release's requirements.

Keep provider-specific generated types behind a small provider boundary returning
a validated proposal. Do not add provider infrastructure until there is a real
provider implementation. Do not send live frames to either provider by default:
text plus the current recipe and compact capability list is sufficient. A future
remote provider must be explicit opt-in with separate credential/privacy work.
No automatic fallback from local to remote is permitted.

### Agent work packages and acceptance

1. Recipe core owner: typed recipe/proposal, one decoder/validator, atomic local
   store, and boundary tests. Test unsupported versions/keys/effects, invalid
   numbers, oversized payloads, and failed writes preserving prior presets.
2. Renderer owner: adapt a validated single-look recipe to existing snapshots.
   Preserve zero-cost off and frame ownership. Prove changing a recipe reaches
   preview and virtual output through the existing shared path, not UI overlays.
3. Provider owner: real Foundation Models adapter, availability/errors,
   cancellation, request-generation isolation, and guided output. Evaluate a
   separate MLX adapter only after the first provider works. No dummy completion
   service or hardcoded keyword-to-filter routine labeled as an LLM.
4. Editor owner: real native draft/apply/revert/save flow and honest provider
   status. Provider and editor work can run concurrently after the recipe core
   contract is settled; shared files have one integration owner.
5. Integration owner: offline recipe behavior checks, malformed-response and
   stale-result tests, offscreen UI review, isolated build, and user-approved live
   scheduling. Tests must prove active settings survive errors/cancellation.

Do not declare Generate & Edit complete until natural-language generation and
editing work through a real available provider, saved presets reload, cancel
cannot apply stale results, and the user can apply/revert a validated look.

## Recipe version 2 and harder looks

Only add stacking after version 1 works. Start with at most four allowlisted
nodes: a face warp, a color treatment, and bounded props. Validate order and
capabilities; use ping-pong scratch on the existing command buffer and publish
one completed output. A warp that changes anchor positions must transform those
anchors for downstream props. Never stack independent warps against stale
original landmarks. Expose genuinely supported color/scale parameters before
promising natural-language edits to them.

Realistic baby/age, hair replacement, or full anime avatars should be a separate
model-backed project with licensed weights, explicit downloads, temporal tests,
identity/privacy review, and measured 1080p latency/memory. Keep today's native
filters available when a model is absent or too slow. Do not label the 2D styles
as equivalent to those harder transformations.

## Feasibility proof and remaining work

A camera-free standalone Swift executable checked the on-device system model's
availability on this Mac and called `LanguageModelSession(model:
SystemLanguageModel.default)` with an `@Generable` enum of supported portrait
looks. For \"Give me a beard and a cowboy hat together,\" it returned
`beardedCowboy`. The model reported available. No extra weights were downloaded,
no cloud provider was selected, and no camera frame was provided.

The provider adapter, local recipe persistence, draft editor, and synthetic
preview now exist. Manual editing, Apply, Revert, Undo, and Save use validated
recipes. Generation and edits stay separate from active camera settings.
Model selection remains fallible: users must review the selected effect and its
trusted catalog description. See PLAN.md for current verification and limits.
Concurrent video/LLM performance and live output still need an approved handoff.

## Primary references

- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [On-device availability and capabilities](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)
