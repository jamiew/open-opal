import Metal
import simd

/// Encodes one post-composite pass into the renderer's existing command buffer.
/// Input and output are display-encoded BGRA; no preview-only overlay exists.
final class CameraEffects {
    private let pipeline: MTLComputePipelineState

    /// Float4 fields keep the Swift/Metal layout explicit (80 bytes, 16-aligned).
    private struct Uniforms {
        var frame: SIMD4<Float>       // image width, height, intensity, effect ID
        var pose: SIMD4<Float>        // normalized eye center, pixel-space right axis
        var features: SIMD4<Float>    // normalized nose and mouth centers
        var dimensions: SIMD4<Float> // face width/height, eye/mouth width, in pixels
        var visibility: SIMD4<Float>  // freshness opacity, animation seconds, reserved
    }

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let function = library.makeFunction(name: "camera_effect"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.pipeline = pipeline
    }

    static func isActive(filter: CameraFilter, intensity: Double, face: FaceGeometry?) -> Bool {
        filter != .none && intensity.isFinite && intensity > 0 &&
            (!filter.requiresFace || (face?.opacity ?? 0) > 0)
    }

    /// False means no output was encoded; callers must not publish destination.
    func encode(commandBuffer: MTLCommandBuffer, source: MTLTexture,
                destination: MTLTexture, filter: CameraFilter,
                intensity: Double, face: FaceGeometry?, time: Double = 0) -> Bool {
        guard Self.isActive(filter: filter, intensity: intensity, face: face),
              source !== destination,
              source.width == destination.width, source.height == destination.height,
              source.pixelFormat == .bgra8Unorm, destination.pixelFormat == .bgra8Unorm,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        // Bound Float time precision for sessions that stay open for days.
        let seconds = time.isFinite ? Float(max(time, 0).truncatingRemainder(dividingBy: 3600)) : 0
        var uniforms = Uniforms(
            frame: SIMD4(Float(source.width), Float(source.height), Float(min(intensity, 1)), Float(filter.shaderID)),
            pose: SIMD4(face?.eyeCenter.x ?? 0, face?.eyeCenter.y ?? 0,
                        face?.right.x ?? 1, face?.right.y ?? 0),
            features: SIMD4(face?.nose.x ?? 0, face?.nose.y ?? 0,
                            face?.mouth.x ?? 0, face?.mouth.y ?? 0),
            dimensions: SIMD4(face?.faceWidth ?? 1, face?.faceHeight ?? 1,
                              face?.eyeDistance ?? 1, face?.mouthWidth ?? 1),
            visibility: SIMD4(face?.opacity ?? 1, seconds, 0, 0))
        encoder.label = "Camera filter"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (destination.width + 15) / 16,
                             height: (destination.height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        encoder.endEncoding()
        return true
    }
}
