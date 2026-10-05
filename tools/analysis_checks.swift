import CoreVideo
import Foundation
import Metal

extension FilterChecks {
    static func analysisMatte(_ pool: AnalysisTexturePool, value: UInt8,
                              width: Int = 16, height: Int = 16) -> MatteResult {
        guard let backing = pool.acquire(width: width, height: height) else {
            fatalError("Analysis pool unexpectedly exhausted")
        }
        let mask = [UInt8](repeating: value, count: width * height)
        mask.withUnsafeBytes {
            backing.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                    withBytes: $0.baseAddress!, bytesPerRow: width)
        }
        return MatteResult(backing: backing, mask: mask, width: width, height: height)
    }

    static func firstMaskByte(_ texture: MTLTexture) -> UInt8 {
        var value: UInt8 = 0
        texture.getBytes(&value, bytesPerRow: 1, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return value
    }

    static func checkAnalysisStorage() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal unavailable") }
        let pool = AnalysisTexturePool(device: device, format: .r8Unorm, capacity: 2)
        let store = BokehRenderer.AnalysisStore()
        let token = store.tryBeginMatte()!
        var first: MatteResult? = analysisMatte(pool, value: 37)
        let originalStorage = ObjectIdentifier(first!.texture)
        _ = store.publishMatte(first!, subject: nil, generation: token)
        store.endMatte()
        first = nil
        var snapshot = store.latest()
        var second: MatteResult? = analysisMatte(pool, value: 211)
        require(firstMaskByte(snapshot.1!.texture) == 37, "Next analysis overwrote the latest matte")
        require(pool.acquire(width: 16, height: 16) == nil, "Retained results must bound analysis storage")
        _ = store.reset()
        require(pool.acquire(width: 16, height: 16) == nil, "Reset released a renderer's retained analysis")
        require(firstMaskByte(snapshot.1!.texture) == 37, "Reset mutated a retained matte")
        snapshot = (nil, nil, nil)
        autoreleasepool {
            let reused = pool.acquire(width: 16, height: 16)!
            require(ObjectIdentifier(reused.texture) == originalStorage, "Released storage must be reused")
            require(firstMaskByte(second!.texture) == 211, "Reusing another slot corrupted a result")
        }
        second = nil

        let depthPool = AnalysisTexturePool(device: device, format: .r32Float, capacity: 1)
        autoreleasepool {
            let depthToken = store.tryBeginDepth()!
            let backing = depthPool.acquire(width: 1, height: 1)!
            var value: Float = 0.25
            backing.texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                                    withBytes: &value, bytesPerRow: MemoryLayout<Float>.size)
            let depth = DepthProvider.Result(backing: backing, values: [value], width: 1, height: 1)
            store.publishDepth(depth, generation: depthToken)
            store.endDepth()
        }
        var depthSnapshot = store.latest()
        require(depthPool.acquire(width: 1, height: 1) == nil, "Latest depth lost its lease")
        _ = store.reset()
        require(depthPool.acquire(width: 1, height: 1) == nil, "Retained depth was released before its reader")
        var depthValue: Float = 0
        depthSnapshot.0!.texture.getBytes(&depthValue, bytesPerRow: MemoryLayout<Float>.size,
                                         from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        require(depthValue == 0.25 && depthSnapshot.0!.values == [0.25], "Retained depth changed")
        depthSnapshot = (nil, nil, nil)
        require(depthPool.acquire(width: 1, height: 1) != nil, "Depth storage did not recover")
        checkAnalysisGPUCompletion(device: device)
        checkMatteHistory(device: device)
        print("PASS: bounded matte/depth leases, retained latest results, GPU lifetime, independent matte history")
    }

    static func encodeAnalysisSmooth(_ command: MTLCommandBuffer, pipeline: MTLComputePipelineState,
                                     current: MTLTexture, history: MTLTexture, output: MTLTexture,
                                     alpha: Float) {
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(current, index: 0)
        encoder.setTexture(history, index: 1)
        encoder.setTexture(output, index: 2)
        var alpha = alpha
        encoder.setBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    static func analysisFloatTexture(_ device: MTLDevice, values: [Float], width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = device.makeTexture(descriptor: descriptor)!
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.size)
        }
        return texture
    }

    static func analysisFloats(_ texture: MTLTexture) -> [Float] {
        var values = [Float](repeating: 0, count: texture.width * texture.height)
        values.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * MemoryLayout<Float>.size,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return values
    }

    static func checkAnalysisGPUCompletion(device: MTLDevice) {
        let pool = AnalysisTexturePool(device: device, format: .r8Unorm, capacity: 1)
        let queue = device.makeCommandQueue()!
        let pipeline = try! device.makeComputePipelineState(
            function: device.makeDefaultLibrary()!.makeFunction(name: "temporal_smooth")!)
        autoreleasepool {
            var result: MatteResult? = analysisMatte(pool, value: 37)
            let output = analysisFloatTexture(device, values: [Float](repeating: 0, count: 256),
                                              width: 16, height: 16)
            let event = device.makeSharedEvent()!
            let command = queue.makeCommandBuffer()!
            command.encodeWaitForEvent(event, value: 1)
            encodeAnalysisSmooth(command, pipeline: pipeline, current: result!.texture,
                                 history: result!.texture, output: output, alpha: 1)
            let reader = BokehRenderer.AnalysisStore()
            let token = reader.tryBeginMatte()!
            _ = reader.publishMatte(result!, subject: nil, generation: token)
            reader.endMatte()
            let completed = DispatchSemaphore(value: 0)
            command.addCompletedHandler { [reader] _ in
                _ = reader.reset()
                completed.signal()
            }
            result = nil
            command.commit()
            require(pool.acquire(width: 16, height: 16) == nil, "GPU reader lost its analysis lease")
            event.signaledValue = 1
            command.waitUntilCompleted()
            completed.wait()
            require(command.status == .completed, "Analysis read failed on GPU")
            require(analysisFloats(output).allSatisfy { abs($0 - 37.0 / 255.0) < 0.00001 },
                    "GPU read recycled analysis pixels")
        }
        require(pool.acquire(width: 16, height: 16) != nil, "Completed GPU read did not release its lease")
    }

    static func checkMatteHistory(device: MTLDevice) {
        let width = 16, height = 16
        let queue = device.makeCommandQueue()!
        let pipeline = try! device.makeComputePipelineState(
            function: device.makeDefaultLibrary()!.makeFunction(name: "temporal_smooth")!)
        let prior = (0..<(width * height)).map { Float($0 % width) / Float(width - 1) }
        let currentValues = prior.map { 1 - $0 }
        let current = analysisFloatTexture(device, values: currentValues, width: width, height: height)
        var history = analysisFloatTexture(device, values: prior, width: width, height: height)
        var next = analysisFloatTexture(device, values: [Float](repeating: 0, count: prior.count),
                                        width: width, height: height)
        var expected = prior
        for _ in 0..<3 {
            let before = analysisFloats(history)
            let command = queue.makeCommandBuffer()!
            encodeAnalysisSmooth(command, pipeline: pipeline, current: current,
                                 history: history, output: next, alpha: 0.6)
            command.commit()
            command.waitUntilCompleted()
            require(command.status == .completed, "Matte history pass failed")
            expected = zip(expected, currentValues).map { old, new in
                let t = min(max((abs(new - old) - 0.15) / 0.35, 0), 1)
                let alpha: Float = 0.6 + 0.4 * t * t * (3 - 2 * t)
                return old + (new - old) * alpha
            }
            require(analysisFloats(history) == before, "Matte smoothing mutated its prior history")
            require(zip(analysisFloats(next), expected).allSatisfy { abs($0 - $1) < 0.00001 },
                    "Matte history differs from independent prior/output smoothing")
            swap(&history, &next)
        }
    }

    @MainActor
    static func checkNeutralRamp() {
        let width = 220, height = 2
        let input = nv12(width: width, height: height)
        CVPixelBufferLockBaseAddress(input, [])
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(input, 0)
        let yBytes = CVPixelBufferGetBaseAddressOfPlane(input, 0)!.assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(input, 1)
        let cBytes = CVPixelBufferGetBaseAddressOfPlane(input, 1)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width { yBytes[y * yStride + x] = UInt8(16 + x) }
        }
        for x in 0..<cStride { cBytes[x] = 128 }
        CVPixelBufferUnlockBaseAddress(input, [])
        let settings = CameraSettings(preferences: MemoryPreferences())
        settings.bokehEnabled = false
        settings.meterOnSubject = false
        settings.focusOnSubject = false
        let renderer = BokehRenderer()!
        let frame = renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                    captureGeneration: renderer.captureGeneration)!
        for x in 0..<width {
            let expected = Int((Double(x) * 255 / 219).rounded())
            for y in 0..<height {
                let sample = pixel(frame.pixelBuffer, x: x, y: y)
                require(sample[3] == 255 && sample.prefix(3).allSatisfy { abs(Int($0) - expected) <= 1 },
                        "Neutral NV12 ramp must round-trip absolute sRGB levels at \(x)")
            }
        }
        print("PASS: absolute neutral video-range ramp through linear-light rendering")
    }

    @MainActor
    static func checkAnalysisTransitions() async {
        let device = MTLCreateSystemDefaultDevice()!
        let mattePool = AnalysisTexturePool(device: device, format: .r8Unorm, capacity: 2)
        let store = BokehRenderer.AnalysisStore()
        let matteToken = store.tryBeginMatte()!
        let depthToken = store.tryBeginDepth()!
        let matte = analysisMatte(mattePool, value: 255)
        let subject = SubjectInfo(depth: 0.8, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), coverage: 1)
        let capture = store.currentCaptureGeneration
        let syncToken = store.setSynchronous(true, captureGeneration: capture)!
        require(store.publishMatte(matte, subject: subject, generation: matteToken) == nil,
                "Old asynchronous matte replaced frame-paired subject analysis")
        let depthPool = AnalysisTexturePool(device: device, format: .r32Float, capacity: 1)
        let depth = DepthProvider.Result(backing: depthPool.acquire(width: 1, height: 1)!,
                                         values: [0.8], width: 1, height: 1)
        store.publishDepth(depth, generation: depthToken)
        require(store.latest().0 == nil && store.latest().1 == nil && store.latest().2 == nil,
                "Mode transition admitted stale analysis")
        require(store.publishSynchronousSubject(subject, generation: syncToken)?.depth == 0.8,
                "Current synchronous subject was lost")
        _ = store.reset()
        require(!store.isCurrent(syncToken), "Queued subject callback survived capture reset")
        require(store.publishSynchronousSubject(subject, generation: syncToken) == nil,
                "Old synchronous subject repopulated a new capture session")
        require(store.setSynchronous(false, captureGeneration: capture) == nil,
                "Old capture work changed the new session's mode")
        _ = store.setSynchronous(false, captureGeneration: store.currentCaptureGeneration)
        require(store.tryBeginMatte() == nil && store.tryBeginDepth() == nil,
                "Reset reopened lanes while their old work was running")
        store.endMatte()
        store.endDepth()
        require(store.tryBeginMatte() != nil && store.tryBeginDepth() != nil,
                "Analysis lanes did not recover after old work finished")

        let renderer = BokehRenderer()!
        let settings = CameraSettings(preferences: MemoryPreferences())
        settings.bokehEnabled = false
        settings.meterOnSubject = false
        settings.focusOnSubject = false
        let input = nv12()
        CVPixelBufferLockBaseAddress(input, [])
        let stride = CVPixelBufferGetBytesPerRowOfPlane(input, 0)
        let bytes = CVPixelBufferGetBaseAddressOfPlane(input, 0)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<180 {
            for x in 0..<320 { bytes[y * stride + x] = (x / 3 + y / 3) % 2 == 0 ? 40 : 200 }
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        let generation = renderer.captureGeneration
        let original = renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                       captureGeneration: generation)!
        let originalPixels = pixels(original.pixelBuffer)
        settings.bokehEnabled = true
        settings.syncBokeh = true
        settings.uniformBlur = true
        settings.aperture = 1.4
        let prepared = await renderer.analyzeNow(pixelBuffer: input, needsDepth: false,
                                                  captureGeneration: generation)!
        let sharp = BokehRenderer.FrameAnalysis(pixelBuffer: input, generation: prepared.generation,
                                                depth: nil, matte: matte, subject: nil)
        let background = analysisMatte(mattePool, value: 0)
        let blurred = BokehRenderer.FrameAnalysis(pixelBuffer: input, generation: prepared.generation,
                                                  depth: nil, matte: background, subject: nil)
        require(renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                captureGeneration: generation) == nil,
                "Synchronous rendering must not fall back to latest asynchronous results")
        autoreleasepool {
            let frame = renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                        captureGeneration: generation, analysisForFrame: sharp)!
            require(pixels(frame.pixelBuffer) == originalPixels, "This frame's subject matte did not keep it sharp")
        }
        autoreleasepool {
            let frame = renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                        captureGeneration: generation, analysisForFrame: blurred)!
            require(pixels(frame.pixelBuffer) != originalPixels, "This frame's background matte did not blur it")
        }
        require(renderer.render(pixelBuffer: nv12(), settings: RenderSettings(settings),
                                captureGeneration: generation, analysisForFrame: sharp) == nil,
                "Synchronous analysis from a different frame must be rejected")
        renderer.resetCaptureState()
        require(renderer.render(pixelBuffer: input, settings: RenderSettings(settings),
                                captureGeneration: generation, analysisForFrame: sharp) == nil,
                "Capture reset must reject retained work from the previous session")
        let staleAnalysis = await renderer.analyzeNow(pixelBuffer: input, needsDepth: false,
                                                      captureGeneration: generation)
        require(staleAnalysis == nil,
                "Old capture work must not start inference after reset")
        print("PASS: async/sync transition fencing, exact-frame matte rendering, capture reset and callback generations")
    }
}
