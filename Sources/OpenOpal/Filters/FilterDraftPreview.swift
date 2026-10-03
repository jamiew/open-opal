import CoreGraphics
import Foundation
import Metal

/// A fixed synthetic face, never a camera still. Uses the production effect encoder.
enum FilterDraftPreview {
    static func render(_ recipe: FilterRecipe) throws -> CGImage {
        let width = 320, height = 240
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let effects = CameraEffects(device: device, library: library),
              let queue = device.makeCommandQueue(),
              let command = queue.makeCommandBuffer() else { throw PreviewError.unavailable }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let source = device.makeTexture(descriptor: descriptor),
              let destination = device.makeTexture(descriptor: descriptor) else { throw PreviewError.unavailable }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x - 160) / 54, dy = Double(y - 146) / 71
                let face = dx * dx + dy * dy < 1
                let eye = ((x - 142) * (x - 142) + (y - 129) * (y - 129) < 20)
                    || ((x - 178) * (x - 178) + (y - 129) * (y - 129) < 20)
                let mouth = abs(x - 160) < 16 && abs(y - 172) < 3
                let noise = (x + y) % 2 == 0 ? 5 : -5
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(eye || mouth ? 45 : face ? 150 + noise : 90 + x / 4)
                pixels[offset + 1] = UInt8(eye || mouth ? 45 : face ? 180 + noise : 70 + y / 3)
                pixels[offset + 2] = UInt8(eye || mouth ? 45 : face ? 210 + noise : 55 + x / 5)
            }
        }
        pixels.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        let face = FaceGeometry(eyeCenter: SIMD2(0.5, 129.0 / 240), right: SIMD2(1, 0),
                                nose: SIMD2(0.5, 151.0 / 240), mouth: SIMD2(0.5, 172.0 / 240),
                                faceWidth: 108, faceHeight: 142, eyeDistance: 36, mouthWidth: 32)
        if CameraEffects.isActive(filter: recipe.filter, intensity: recipe.intensity, face: face) {
            guard effects.encode(commandBuffer: command, source: source, destination: destination,
                                 filter: recipe.filter, intensity: recipe.intensity, face: face,
                                 time: recipe.animate ? 1 : 0) else { throw PreviewError.unavailable }
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { throw PreviewError.unavailable }
            pixels.withUnsafeMutableBytes {
                destination.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw PreviewError.unavailable }
        return image
    }

    private enum PreviewError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The sample preview could not be rendered with Metal." }
    }
}
