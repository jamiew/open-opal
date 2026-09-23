import CoreVideo
import Foundation
import Metal

// Standalone executable. Never constructs OpalDevice, CameraModel, or a CMIO feeder.
@main
struct FilterChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func nv12(width: Int = 320, height: Int = 180, luma: UInt8 = 120) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        require(CVPixelBufferCreate(nil, width, height,
                                   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   attributes as CFDictionary, &result) == kCVReturnSuccess,
                "Cannot allocate synthetic NV12 input")
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let bytes = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rows {
                for x in 0..<stride {
                    bytes[y * stride + x] = plane == 0 ? luma : (x % 2 == 0 ? 100 : 155)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func pixel(_ buffer: CVPixelBuffer, x: Int = 0, y: Int = 0) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }

    static func pixels(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = CVPixelBufferGetWidth(buffer) * 4
        return (0..<CVPixelBufferGetHeight(buffer)).flatMap { row in
            Array(UnsafeBufferPointer(start: bytes + row * stride, count: rowBytes))
        }
    }

    static func checkAnchoredEffects() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let effects = CameraEffects(device: device, library: library),
              let queue = device.makeCommandQueue() else { fatalError("Effect encoder unavailable") }
        let width = 640, height = 480
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let source = device.makeTexture(descriptor: descriptor)!
        let destination = device.makeTexture(descriptor: descriptor)!
        var image = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let noise = (x + y) % 2 == 0 ? 8 : -8
                let offset = (y * width + x) * 4
                image[offset] = UInt8(140 + noise)
                image[offset + 1] = UInt8(170 + noise)
                image[offset + 2] = UInt8(195 + noise)
            }
        }
        image.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        var face = FaceGeometry(eyeCenter: SIMD2(0.5, 260.0 / 480.0), right: SIMD2(1, 0),
                                nose: SIMD2(0.5, 302.0 / 480.0), mouth: SIMD2(0.5, 335.0 / 480.0),
                                faceWidth: 160, faceHeight: 210, eyeDistance: 70, mouthWidth: 60)
        func render(_ filter: CameraFilter) -> [UInt8] {
            let command = queue.makeCommandBuffer()!
            require(effects.encode(commandBuffer: command, source: source, destination: destination,
                                   filter: filter, intensity: 1, face: face), "Could not encode \(filter)")
            command.commit()
            command.waitUntilCompleted()
            require(command.status == .completed, "Effect GPU command failed")
            var output = image
            output.withUnsafeMutableBytes {
                destination.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return output
        }
        func changed(_ output: [UInt8], x: Int, y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return output[offset..<(offset + 4)] != image[offset..<(offset + 4)]
        }
        let hat = render(.cowboy)
        require(changed(hat, x: 320, y: 145), "Hat crown must follow the eye anchor")
        require(!changed(hat, x: 320, y: 350), "Hat must not paint below the face")
        let cat = render(.cat)
        require(changed(cat, x: 320, y: 305), "Cat nose must follow the nose landmark")
        require(changed(cat, x: 373, y: 166), "Cat ear must sit above the eye anchor")
        require(!changed(cat, x: 0, y: 0), "Cat must leave background unchanged")
        let beauty = render(.beauty)
        require(changed(beauty, x: 360, y: 300), "Beauty must soften cheek detail")
        require(!changed(beauty, x: 0, y: 0), "Beauty must not soften background")
        require(!changed(beauty, x: 285, y: 260), "Beauty must protect eye detail")

        // Roll is measured in pixels, not normalized coordinates on this 4:3 frame.
        face.right = SIMD2(cos(Float.pi / 6), sin(Float.pi / 6))
        let tilted = render(.cowboy)
        require(changed(tilted, x: 377, y: 160), "Hat must rotate around the eye anchor")
        require(!changed(tilted, x: 0, y: 0), "Tilted hat must leave background unchanged")
        print("PASS: synthetic face hat/cat anchors, pixel-aspect roll, beauty region and eye protection")
    }

    @MainActor
    static func checkStoppedEffectMotion(renderer: BokehRenderer, settings: CameraSettings, input: CVPixelBuffer) {
        settings.filter = .hologram
        settings.animateFilters = false
        autoreleasepool {
            guard let first = renderer.render(pixelBuffer: input, settings: RenderSettings(settings)) else {
                fatalError("Stopped-motion frame failed")
            }
            Thread.sleep(forTimeInterval: 0.05)
            guard let second = renderer.render(pixelBuffer: input, settings: RenderSettings(settings)),
                  let changedVideo = renderer.render(
                    pixelBuffer: nv12(luma: 70), settings: RenderSettings(settings)) else {
                fatalError("Stopped-motion follow-up frame failed")
            }
            require(pixels(first.pixelBuffer) == pixels(second.pixelBuffer),
                    "Disabled effect motion must keep time-based artwork fixed")
            require(pixels(first.pixelBuffer) != pixels(changedVideo.pixelBuffer),
                    "Disabling effect motion must not freeze video")
        }
        settings.animateFilters = true
    }

    @MainActor
    static func main() {
        checkAnchoredEffects()
        checkCreativeMedia()
        checkPortraitLooks()
        require(CameraFilter.matching(query: "  CYBER  ") == [.cyberWarrior],
                "Search must ignore case and surrounding whitespace")
        require(CameraFilter.matching(query: "", category: .portrait).contains(.cyberWarrior),
                "Face armor must be discoverable in Portrait")
        require(CameraFilter.matching(query: "cyber", category: .art).isEmpty,
                "Search must intersect, not override, the selected category")
        require(CameraFilter.matching(query: "digital") == CameraFilter.matching(query: "", category: .digital),
                "Category names must be searchable")
        require(!CameraFilter.matching(query: "").contains(.none),
                "Off remains a separate always-reachable action")
        guard let renderer = BokehRenderer() else { fatalError("Metal renderer unavailable") }
        let settings = CameraSettings()
        settings.bokehEnabled = false
        settings.meterOnSubject = false
        let input = nv12()
        guard let original = renderer.render(pixelBuffer: input, settings: RenderSettings(settings)) else {
            fatalError("Original frame failed")
        }
        let originalPixel = pixel(original.pixelBuffer)
        let originalPixels = pixels(original.pixelBuffer)
        require(originalPixel[3] == 255, "Output must be opaque BGRA")
        require(originalPixel[2] > originalPixel[0], "Synthetic red-biased frame must retain channel order")

        settings.filter = .monochrome
        settings.filterIntensity = 1
        guard let mono = renderer.render(pixelBuffer: input, settings: RenderSettings(settings)) else {
            fatalError("Monochrome frame failed")
        }
        let gray = pixel(mono.pixelBuffer)
        require(abs(Int(gray[0]) - Int(gray[1])) <= 1 && abs(Int(gray[1]) - Int(gray[2])) <= 1,
                "Full-strength monochrome must remove chroma")
        require(pixels(original.pixelBuffer) == originalPixels, "Later renders overwrote retained original frame")

        settings.filter = .warm
        guard let warm = renderer.render(pixelBuffer: input, settings: RenderSettings(settings)) else {
            fatalError("Warm frame failed")
        }
        let golden = pixel(warm.pixelBuffer)
        require(Int(golden[2]) - Int(golden[0]) > Int(originalPixel[2]) - Int(originalPixel[0]),
                "Warm grade must increase red relative to blue")

        for filter in CameraFilter.allCases {
            settings.filter = filter
            settings.filterIntensity = 0
            autoreleasepool {
                guard let frame = renderer.render(pixelBuffer: input, settings: RenderSettings(settings)) else {
                    fatalError("Zero-strength frame failed for \(filter)")
                }
                require(pixels(frame.pixelBuffer) == originalPixels, "Zero strength must bypass \(filter)")
            }
        }
        settings.filterIntensity = 1
        checkStoppedEffectMotion(renderer: renderer, settings: settings, input: input)
        for filter in CameraFilter.allCases where filter.requiresFace {
            settings.filter = filter
            autoreleasepool {
                guard let frame = renderer.render(pixelBuffer: input, settings: RenderSettings(settings)) else {
                    fatalError("No-face frame failed")
                }
                require(pixels(frame.pixelBuffer) == originalPixels, "No face must not paint an attachment")
            }
        }

        // Exhaust a separate renderer's bounded pool while consumers retain frames.
        guard let bounded = BokehRenderer() else { fatalError("Second renderer unavailable") }
        settings.filter = .none
        var held: [RenderedFrame] = []
        for value in 40..<50 {
            if let frame = bounded.render(pixelBuffer: nv12(luma: UInt8(value)), settings: RenderSettings(settings)) {
                held.append(frame)
            } else { break }
        }
        require(!held.isEmpty && held.count <= 6, "Slow consumers must bound output allocation")
        let retainedPixel = pixel(held[0].pixelBuffer)
        require(bounded.render(pixelBuffer: input, settings: RenderSettings(settings)) == nil,
                "Exhausted pool must drop instead of overwrite")
        require(pixel(held[0].pixelBuffer) == retainedPixel, "Pool exhaustion corrupted a retained frame")
        held.removeAll()
        autoreleasepool {
            require(bounded.render(pixelBuffer: input, settings: RenderSettings(settings)) != nil,
                    "Pool must recover after consumers release frames")
        }
        print("PASS: native renderer colors, bypass, no-face, retained-frame ownership, pool bounds")
    }
}
