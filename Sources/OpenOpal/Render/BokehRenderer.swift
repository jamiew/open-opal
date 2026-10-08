import CoreVideo
import Metal
import MetalKit
import OSLog
import simd

private let log = Logger(subsystem: "com.openopal", category: "render")

/// The GPU side of the frame path.
///
/// A frame arrives as NV12 in an IOSurface-backed CVPixelBuffer and is turned
/// into Metal textures via CVMetalTextureCache — no copy, no CPU colour
/// conversion. From there:
///
///     NV12 ──► linear RGB ──► [depth + matte] ──► CoC ──► gather ──► composite ──► filters
///
/// The neural nets are deliberately *not* in that chain. They run asynchronously
/// at their own pace on the Neural Engine, and the render loop always uses the
/// most recent result it has. A 25ms inference therefore costs zero frame-time:
/// the worst case is that the depth map is one frame stale, which is invisible
/// at conversational motion but would be very visible as dropped frames.
/// A value snapshot of everything the render path needs from CameraSettings.
///
/// The renderer must not read the live @Observable settings object: rendering
/// runs OFF the main actor (encoding Metal on the main thread 30x/sec was
/// starving SwiftUI animations into a slideshow), and the settings object is
/// main-actor state. Main takes this snapshot in microseconds; the render
/// worker gets an immutable copy it can read from any thread.
struct RenderSettings: Sendable {
    var bokehEnabled: Bool
    var syncBokeh: Bool
    var uniformBlur: Bool
    var meterOnSubject: Bool
    var autoFocusSubject: Bool
    var focusOnSubject: Bool
    var focusDistance: Double
    var aperture: Double
    var hexIris: Bool
    var highlightBloom: Double
    var filter: CameraFilter
    var filterIntensity: Double
    var animateFilters: Bool

    @MainActor
    init(_ s: CameraSettings) {
        bokehEnabled = s.bokehEnabled
        syncBokeh = s.syncBokeh
        uniformBlur = s.uniformBlur
        meterOnSubject = s.meterOnSubject
        autoFocusSubject = s.autoFocusSubject
        // Focus tracking consumes the same subject analysis, so it has to be in
        // the snapshot too — otherwise "Follow face" silently does nothing
        // whenever bokeh and subject metering are both off.
        focusOnSubject = s.focusOnSubject
        focusDistance = s.focusDistance
        aperture = s.aperture
        hexIris = s.apertureShape == .hexagonal
        highlightBloom = s.highlightBloom
        filter = s.filter
        filterIntensity = s.filterIntensity
        animateFilters = s.animateFilters
    }
}

/// Immutable published pixels. Keeping the pixel buffer and its Core Video
/// texture wrapper alive prevents the pool from recycling a preview's storage.
struct RenderedFrame: @unchecked Sendable {
    let texture: MTLTexture
    let pixelBuffer: CVPixelBuffer
    fileprivate let backing: CVMetalTexture
}

/// `@unchecked Sendable`: render() serializes itself with a lock, the analysis
/// path is lock-guarded (AnalysisStore), and the providers are Sendable.
final class BokehRenderer: @unchecked Sendable {

    /// Serializes render() — with several frames in flight, two could otherwise
    /// race on the shared intermediate textures.
    private let renderLock = NSLock()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!

    private let nv12Pipeline: MTLComputePipelineState
    private let cocPipeline: MTLComputePipelineState
    private let gatherPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let smoothPipeline: MTLComputePipelineState
    private let depthSmoothPipeline: MTLComputePipelineState
    private let matteRefinePipeline: MTLComputePipelineState
    private let matteStabilizePipeline: MTLComputePipelineState
    private let effects: CameraEffects
    private let faceTracker = FaceTracker()
    private let effectsEpoch = ProcessInfo.processInfo.systemUptime

    // Intermediates, reallocated only when the frame size changes.
    private var linearTex: MTLTexture?
    private var cocTex: MTLTexture?
    private var blurTex: MTLTexture?
    /// Allocated lazily only when an effect actually has something to draw.
    private var effectInput: MTLTexture?
    private var depthTex: MTLTexture?
    private var matteTex: MTLTexture?
    // Ping-pong: depth_smooth reads one and writes the other, because it now
    // samples neighbours (and reading + writing the same texture in one dispatch
    // is undefined).
    private var depthHistory: MTLTexture?
    private var depthHistoryPrev: MTLTexture?
    private var matteHistory: MTLTexture?
    private var matteHistoryPrev: MTLTexture?
    /// Last frame's luma, at mask resolution. Lets us ask "did the picture change
    /// here?" — which is how we tell a genuinely moving subject apart from a
    /// static object whose mask is merely flickering.
    private var prevLuma: MTLTexture?
    private var prevLumaNext: MTLTexture?
    /// The matte after the guided upsample — full resolution, edges snapped to
    /// the image. This is the one everything downstream actually uses.
    private var matteRefined: MTLTexture?
    private var size = (w: 0, h: 0)

    /// Latest neural results, written by the analysis task and read by the
    /// render loop. Never blocks the render loop.
    private let analysis = AnalysisStore()

    struct Uniforms {
        var texelSize: SIMD2<Float>
        var focusDepth: Float
        var aperture: Float
        var maxCoCPixels: Float
        var highlightBloom: Float
        var highlightThresh: Float
        var apertureBlades: Int32
        var matteStrength: Float
        var useDepth: Int32
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        guard let library = device.makeDefaultLibrary() else {
            log.error("no default Metal library")
            return nil
        }

        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else {
                log.error("missing kernel \(name, privacy: .public)")
                return nil
            }
            return try? device.makeComputePipelineState(function: fn)
        }

        guard let a = pipeline("nv12_to_linear"),
              let b = pipeline("compute_coc"),
              let c = pipeline("bokeh_gather"),
              let d = pipeline("composite"),
              let e = pipeline("temporal_smooth"),
              let f = pipeline("depth_smooth"),
              let g = pipeline("matte_refine"),
              let i = pipeline("matte_stabilize"),
              let effects = CameraEffects(device: device, library: library) else { return nil }

        nv12Pipeline = a; cocPipeline = b; gatherPipeline = c
        compositePipeline = d; smoothPipeline = e; depthSmoothPipeline = f
        matteRefinePipeline = g; matteStabilizePipeline = i
        self.effects = effects

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    // MARK: - Analysis handoff

    /// Thread-safe latest-value box. The analysis task publishes here whenever a
    /// neural pass finishes; the render loop samples it. Deliberately lossy —
    /// stale is fine, stalling is not.
    private final class AnalysisStore: @unchecked Sendable {
        private let lock = NSLock()
        private var _depth: MTLTexture?
        private var _matte: MTLTexture?
        private var _matteBusy = false
        private var _depthBusy = false
        private var _subject: SubjectInfo?
        private var _lastDepth: [Float] = []
        private var _lastDepthSize = (w: 0, h: 0)

        /// Depth and segmentation are scheduled INDEPENDENTLY.
        ///
        /// They have completely different dynamics. Your outline moves every
        /// frame; the wall behind you does not. Running them as one unit meant
        /// the cheap, fast thing (segmentation, ~5ms) was pinned to the rate of
        /// the expensive, slow thing (depth, ~20ms), and then both were smoothed
        /// together — which is what made the bokeh visibly trail your head.
        func tryBeginMatte() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if _matteBusy { return false }
            _matteBusy = true
            return true
        }
        func endMatte() { lock.lock(); _matteBusy = false; lock.unlock() }

        func tryBeginDepth() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if _depthBusy { return false }
            _depthBusy = true
            return true
        }
        func endDepth() { lock.lock(); _depthBusy = false; lock.unlock() }

        /// Keep the last depth values so a matte-only pass can still work out how
        /// far away the subject is.
        func storeDepthValues(_ v: [Float], w: Int, h: Int) {
            lock.lock(); defer { lock.unlock() }
            _lastDepth = v
            _lastDepthSize = (w, h)
        }
        func depthValues() -> ([Float], Int, Int) {
            lock.lock(); defer { lock.unlock() }
            return (_lastDepth, _lastDepthSize.w, _lastDepthSize.h)
        }

        /// Where the subject is and how far away, smoothed. Drives both the focal
        /// plane and exposure metering.
        var subject: SubjectInfo? {
            get { lock.withLock { _subject } }
        }

        func publishSubject(_ s: SubjectInfo?) {
            lock.lock(); defer { lock.unlock() }
            guard let s else { return }
            if var prev = _subject {
                // Ease toward the new estimate. The depth model is noisy frame to
                // frame, and letting the focal plane jump around would make the
                // whole scene visibly breathe in and out of focus.
                prev.depth += 0.15 * (s.depth - prev.depth)
                prev.bounds = s.bounds
                prev.coverage = s.coverage
                _subject = prev
            } else {
                _subject = s
            }
        }

        func publish(depth: MTLTexture?, matte: MTLTexture?) {
            lock.lock(); defer { lock.unlock() }
            if let depth { _depth = depth }
            if let matte { _matte = matte }
        }
        func latest() -> (MTLTexture?, MTLTexture?) {
            lock.lock(); defer { lock.unlock() }
            return (_depth, _matte)
        }
    }

    /// CVPixelBuffer isn't Sendable, but this one is safe to hand to the analysis
    /// task: it came from a pool, nothing else holds it, and the neural providers
    /// only read it.
    private struct BufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    var depthProvider: DepthProvider?
    var matteProvider: MatteProvider?

    // MARK: - Frame

    /// Renders into an owned, pool-backed BGRA frame shared by preview and sink.
    /// Completion is awaited on the render worker, never on the main actor.
    /// `nil` drops a frame rather than publishing incomplete or recycled pixels.
    func render(pixelBuffer: CVPixelBuffer, settings: RenderSettings) -> RenderedFrame? {
        renderLock.lock()
        defer { renderLock.unlock() }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let face = faceTracker.update(
            pixelBuffer: pixelBuffer,
            enabled: settings.filter.requiresFace && settings.filterIntensity.isFinite &&
                settings.filterIntensity > 0)

        guard let luma = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm),
              let chroma = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm) else { return nil }
        if size != (w, h) { allocate(w: w, h: h) }
        guard let linearTex, let output = makeOutputFrame(w: w, h: h),
              let cmd = queue.makeCommandBuffer() else { return nil }

        let filtering = CameraEffects.isActive(filter: settings.filter,
                                                intensity: settings.filterIntensity, face: face)
        let compositeTarget: MTLTexture
        if filtering {
            if effectInput == nil {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .private
                effectInput = device.makeTexture(descriptor: descriptor)
            }
            guard let effectInput else { return nil }
            compositeTarget = effectInput
        } else {
            // Off, zero strength, or absent face: no new full-frame filter pass
            // or intermediate allocation; composite directly into owned output.
            compositeTarget = output.texture
        }

        guard encode(cmd, nv12Pipeline, textures: [luma.texture, chroma.texture, linearTex],
                     size: (w, h)) else { return nil }

        let syncing = settings.bokehEnabled && settings.syncBokeh
        if !syncing && (settings.bokehEnabled || settings.meterOnSubject || settings.focusOnSubject) {
            kickOffAnalysisIfIdle(pixelBuffer: pixelBuffer,
                                  needsDepth: settings.bokehEnabled && !settings.uniformBlur)
        }

        var compositeBlur = linearTex
        var compositeCoC = blackTexture()
        var updatedDepthHistory = false
        let (depth, matte) = analysis.latest()
        let u = uniforms(settings, w: w, h: h)
        // One common composite and filter exit handles bokeh off, missing neural
        // results, missing bokeh intermediates, and the complete bokeh path.
        if settings.bokehEnabled, let matte, let cocTex, let blurTex,
           let depthHistory, let depthHistoryPrev, let matteHistory, let matteRefined,
           let depth = depth ?? (settings.uniformBlur ? blackTexture() : nil) {
            var matteAlpha: Float = 0.6
            guard encode(cmd, smoothPipeline, textures: [matte, matteHistory, matteHistory],
                         buffer: &matteAlpha,
                         size: (matteHistory.width, matteHistory.height)),
                  encode(cmd, matteRefinePipeline,
                         textures: [matteHistory, linearTex, matteRefined], size: (w, h)) else { return nil }
            var depthAlpha: Float = 0.35
            guard encode(cmd, depthSmoothPipeline,
                         textures: [depth, matteRefined, depthHistory, depthHistoryPrev],
                         buffer: &depthAlpha,
                         size: (depthHistory.width, depthHistory.height)),
                  encode(cmd, cocPipeline, textures: [depthHistoryPrev, matteRefined, cocTex],
                         uniforms: u, size: (w, h)),
                  encode(cmd, gatherPipeline, textures: [linearTex, cocTex, blurTex],
                         uniforms: u, size: (w, h)) else { return nil }
            updatedDepthHistory = true
            compositeBlur = blurTex
            compositeCoC = cocTex
        }
        guard encode(cmd, compositePipeline,
                     textures: [linearTex, compositeBlur, compositeCoC, compositeTarget],
                     uniforms: u, size: (w, h)) else { return nil }
        if filtering {
            guard effects.encode(commandBuffer: cmd, source: compositeTarget,
                                 destination: output.texture, filter: settings.filter,
                                 intensity: settings.filterIntensity, face: face,
                                 time: settings.animateFilters && settings.filter.isAnimated
                                    ? ProcessInfo.processInfo.systemUptime - effectsEpoch : 0) else { return nil }
        }

        // Core Video's texture wrappers and source buffer must outlive GPU use.
        // The wait also prevents shared bokeh/effect scratch textures from being
        // mutated by the next frame while this frame still uses them.
        withExtendedLifetime((pixelBuffer, luma, chroma, output)) {
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        guard cmd.status == .completed else {
            log.error("frame render failed: \(cmd.error?.localizedDescription ?? "unknown GPU error", privacy: .public)")
            return nil
        }
        if updatedDepthHistory { swap(&self.depthHistory, &self.depthHistoryPrev) }
        return output
    }

    /// Invalidates an in-flight landmark result when capture stops/restarts.
    func resetFaceTracking() {
        faceTracker.reset()
    }

    /// Runs depth + segmentation off the render path. If a previous pass is
    /// still in flight we simply skip this frame — the render loop keeps using
    /// the last good result, so frame rate never depends on inference speed.
    /// How often to re-run depth, in frames.
    ///
    /// Was 6 (~5Hz) on the theory that "the background doesn't move". That's only
    /// half true — the *subject* is in the depth map too, and running depth this
    /// slowly meant the geometry revealed behind a moving person took a third of
    /// a second to appear. Now ~15Hz, with the background-masked history
    /// (depth_smooth) doing the real work of killing the trail.
    private static let depthInterval = 2
    private var frameIndex = 0

    private func kickOffAnalysisIfIdle(pixelBuffer: CVPixelBuffer, needsDepth: Bool) {
        let box = BufferBox(buffer: pixelBuffer)
        let store = analysis
        let onSubject = self.onSubject

        frameIndex &+= 1

        // --- segmentation: every frame. It's what tracks you. ---
        if let matteProvider, store.tryBeginMatte() {
            Task.detached(priority: .userInitiated) {
                if let m = await matteProvider.matte(from: box.buffer) {
                    store.publish(depth: nil, matte: m.texture)

                    // Use the most recent depth map (a few frames old at worst —
                    // the background hasn't moved) to work out how far away the
                    // subject is.
                    let (values, dw, dh) = store.depthValues()
                    let subject: SubjectInfo? = values.isEmpty
                        ? SubjectAnalysis.locate(matte: m)
                        : SubjectAnalysis.analyze(matte: m, depth: values,
                                                  depthWidth: dw, depthHeight: dh)
                    if let subject {
                        store.publishSubject(subject)
                        if let s = store.subject { onSubject?(s) }
                    }
                }
                store.endMatte()
            }
        }

        // --- depth: occasionally, and only when bokeh actually needs it. ---
        guard needsDepth, let depthProvider else { return }
        guard frameIndex % Self.depthInterval == 0, store.tryBeginDepth() else { return }

        Task.detached(priority: .userInitiated) {
            if let d = await depthProvider.depth(from: box.buffer) {
                store.publish(depth: d.texture, matte: nil)
                store.storeDepthValues(d.values, w: d.width, h: d.height)
            }
            store.endDepth()
        }
    }

    /// Fired whenever we get a fresh read on the subject. CameraModel uses it to
    /// meter exposure on the person rather than the whole frame.
    var onSubject: (@Sendable (SubjectInfo) -> Void)?

    /// Compute the mask (and optionally depth) for THIS frame, and wait for it.
    ///
    /// Costs latency, buys exact alignment: the mask describes the frame we're
    /// about to composite, not one from 60ms ago. This is the whole point of
    /// "sync" mode — the trailing edge is a synchronisation problem, not a
    /// filtering one.
    func analyzeNow(pixelBuffer: CVPixelBuffer, needsDepth: Bool) async {
        let box = BufferBox(buffer: pixelBuffer)

        async let matteTask = matteProvider?.matte(from: box.buffer)
        async let depthTask = needsDepth ? depthProvider?.depth(from: box.buffer) : nil
        let (m, d) = await (matteTask, depthTask)

        analysis.publish(depth: d?.texture, matte: m?.texture)
        if let d { analysis.storeDepthValues(d.values, w: d.width, h: d.height) }

        if let m {
            let (values, dw, dh) = analysis.depthValues()
            let subject: SubjectInfo? = values.isEmpty
                ? SubjectAnalysis.locate(matte: m)
                : SubjectAnalysis.analyze(matte: m, depth: values,
                                          depthWidth: dw, depthHeight: dh)
            if let subject {
                analysis.publishSubject(subject)
                if let s = analysis.subject { onSubject?(s) }
            }
        }
    }

    // MARK: - Owned frame output

    private var outputPool: CVPixelBufferPool?
    private var outputSize = (w: 0, h: 0)
    private let outputAllocationOptions = [
        kCVPixelBufferPoolAllocationThresholdKey as String: 6
    ] as CFDictionary
    private let outputTextureAttributes = [
        kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.union(.shaderWrite).rawValue
    ] as CFDictionary

    private func makeOutputFrame(w: Int, h: Int) -> RenderedFrame? {
        if outputPool == nil || outputSize != (w, h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess
            else { return nil }
            outputPool = pool
            outputSize = (w, h)
        }
        guard let outputPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            nil, outputPool, outputAllocationOptions, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        var backing: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, outputTextureAttributes, .bgra8Unorm,
            w, h, 0, &backing) == kCVReturnSuccess,
              let backing, let texture = CVMetalTextureGetTexture(backing) else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return RenderedFrame(texture: texture, pixelBuffer: buffer, backing: backing)
    }

    // MARK: - Plumbing

    private func uniforms(_ s: RenderSettings, w: Int, h: Int) -> Uniforms {
        // Scale the blur with resolution so f/2.8 looks the same at 720p as at
        // 4K, instead of getting weaker as pixels get smaller.
        let maxCoC = Float(h) * 0.025

        // THE focal plane. With "track subject" on, this is the subject's own
        // median depth — so blur is measured as distance from *you*. It used to
        // be the UI's fixed 0.35 no matter where you actually were, which meant
        // "track subject" tracked precisely nothing and the blur was measuring
        // distance from an arbitrary plane in space.
        let focus: Float = s.autoFocusSubject
            ? (analysis.subject?.depth ?? Float(s.focusDistance))
            : Float(s.focusDistance)

        return Uniforms(
            texelSize: SIMD2(1.0 / Float(w), 1.0 / Float(h)),
            focusDepth: focus,
            aperture: Float(s.aperture),
            maxCoCPixels: maxCoC,
            highlightBloom: Float(s.highlightBloom),
            highlightThresh: 0.75,
            apertureBlades: s.hexIris ? 6 : 0,
            matteStrength: s.autoFocusSubject ? 0.9 : 0.0,
            useDepth: s.uniformBlur ? 0 : 1
        )
    }

    private struct PlaneTexture {
        let backing: CVMetalTexture
        let texture: MTLTexture
    }

    private func makeTexture(_ pb: CVPixelBuffer, plane: Int,
                             format: MTLPixelFormat) -> PlaneTexture? {
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        guard w > 0, h > 0 else { return nil }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, nil, format, w, h, plane, &cvTex)
        guard status == kCVReturnSuccess, let cvTex,
              let texture = CVMetalTextureGetTexture(cvTex) else { return nil }
        return PlaneTexture(backing: cvTex, texture: texture)
    }

    private func allocate(w: Int, h: Int) {
        size = (w, h)
        func make(_ fmt: MTLPixelFormat, _ tw: Int, _ th: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: tw, height: th, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        // Half-float: we're working in linear light, where 8 bits banding is
        // very visible in smooth out-of-focus gradients.
        linearTex = make(.rgba16Float, w, h)
        blurTex   = make(.rgba16Float, w, h)
        cocTex    = make(.r16Float, w, h)
        effectInput = nil

        // Depth Anything V2 has a FIXED 518x392 output — not square, and not
        // resizable. Match it exactly or the history won't line up.
        depthHistory = make(.r16Float, 518, 392)
        depthHistoryPrev = make(.r16Float, 518, 392)

        // The matte gets a higher-resolution history than the depth map. It's
        // what defines the visible edge around you — hair, shoulders, the gap
        // under your chin — and squeezing it down to the depth model's grid threw
        // away exactly the detail that makes the cutout look convincing.
        let mw = min(w, 960), mh = min(h, 540)
        matteHistory     = make(.r16Float, mw, mh)
        matteHistoryPrev = make(.r16Float, mw, mh)
        prevLuma         = make(.r16Float, mw, mh)
        prevLumaNext     = make(.r16Float, mw, mh)
        matteRefined     = make(.r16Float, w, h)
        log.info("allocated \(w)x\(h)")
    }

    private var _black: MTLTexture?
    private func blackTexture() -> MTLTexture {
        if let _black { return _black }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        var zero: UInt16 = 0
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                  withBytes: &zero, bytesPerRow: MemoryLayout<UInt16>.stride)
        _black = t
        return t
    }

    private func encode(_ cmd: MTLCommandBuffer, _ pipeline: MTLComputePipelineState,
                        textures: [MTLTexture], uniforms: Uniforms? = nil,
                        buffer: UnsafeMutableRawPointer? = nil,
                        bufferLength: Int = MemoryLayout<Float>.stride,
                        size: (w: Int, h: Int)) -> Bool {
        guard let enc = cmd.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(pipeline)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        if var u = uniforms {
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        } else if let buffer {
            enc.setBytes(buffer, length: bufferLength, index: 0)
        }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (size.w + 15) / 16,
                             height: (size.h + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        return true
    }
}
