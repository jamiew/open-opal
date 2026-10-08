import CoreVideo
import Foundation
import Metal

// No camera, device bridge, app model, or virtual-camera connection.
@main
struct RenderChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func nv12(width: Int = 320, height: Int = 180, luma: UInt8 = 120,
                     cb: UInt8 = 128, cr: UInt8 = 128) -> CVPixelBuffer {
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
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let bytes = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rows {
                for x in 0..<stride {
                    bytes[y * stride + x] = plane == 0 ? luma : (x % 2 == 0 ? cb : cr)
                }
            }
        }
        return buffer
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

    static func texturePixels(_ texture: MTLTexture) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }

    @MainActor
    static func checkOwnedOutput(settings: CameraSettings) {
        let renderer = BokehRenderer()!
        let snapshot = RenderSettings(settings)
        let input = nv12(cb: 100, cr: 155)
        let first = renderer.render(pixelBuffer: input, settings: snapshot)!
        let original = pixels(first.pixelBuffer)
        require(original[3] == 255 && original[2] > original[0],
                "GPU output must preserve opaque BGRA channel order")
        require(texturePixels(first.texture) == original, "Preview and sink must share completed GPU pixels")
        autoreleasepool {
            let second = renderer.render(pixelBuffer: nv12(luma: 200), settings: snapshot)!
            require(pixels(second.pixelBuffer) != original, "A new input must produce new pixels")
            let resized = renderer.render(pixelBuffer: nv12(width: 160, height: 90, luma: 235),
                                          settings: snapshot)!
            require(pixels(resized.pixelBuffer).allSatisfy { $0 == 255 }, "White input must render opaque white")
        }
        require(pixels(first.pixelBuffer) == original && texturePixels(first.texture) == original,
                "Subsequent renders or resizing overwrote retained output")

        let bounded = BokehRenderer()!
        autoreleasepool {
            var retained: [RenderedFrame] = []
            for _ in 0..<6 { retained.append(bounded.render(pixelBuffer: input, settings: snapshot)!) }
            require(bounded.render(pixelBuffer: input, settings: snapshot) == nil,
                    "Retained output must be bounded rather than overwritten")
            retained.removeAll()
        }
        autoreleasepool {
            require(bounded.render(pixelBuffer: input, settings: snapshot) != nil,
                    "Released output storage must recover")
        }
        print("PASS: production GPU pixels, shared preview/sink pixels, retained output, bounded output recovery")
    }

    @MainActor
    static func main() async {
        let domain = "com.openopal.render-checks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let settings = CameraSettings(preferences: preferences)
        settings.bokehEnabled = false
        settings.meterOnSubject = false
        settings.focusOnSubject = false
        checkOwnedOutput(settings: settings)
    }
}
