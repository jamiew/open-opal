import CoreVideo
import Foundation
import ImageIO
import simd
import Vision

/// All positions are normalized image coordinates, origin TOP left, unmirrored.
/// `right` is a unit vector in pixel space, not normalized-image space: computing
/// roll after scaling by image size keeps a tilted face correct at any aspect.
struct FaceGeometry: Sendable {
    var eyeCenter: SIMD2<Float>
    var right: SIMD2<Float>
    var nose: SIMD2<Float>
    var mouth: SIMD2<Float>
    var faceWidth: Float
    var faceHeight: Float
    var eyeDistance: Float
    var mouthWidth: Float
    var opacity: Float = 1

    static func make(from observation: VNFaceObservation,
                     width: Int, height: Int) -> FaceGeometry? {
        guard width > 0, height > 0, observation.confidence >= 0.5,
              let landmarks = observation.landmarks else { return nil }
        let bounds = observation.boundingBox
        let imageSize = SIMD2(Float(width), Float(height))

        func imagePoint(_ point: CGPoint) -> SIMD2<Float> {
            SIMD2(Float(bounds.minX + point.x * bounds.width),
                  Float(1 - (bounds.minY + point.y * bounds.height)))
        }
        func center(_ region: VNFaceLandmarkRegion2D?) -> SIMD2<Float>? {
            guard let region, region.pointCount > 0 else { return nil }
            var sum = SIMD2<Float>.zero
            for point in region.normalizedPoints { sum += imagePoint(point) }
            return sum / Float(region.pointCount)
        }
        guard var left = center(landmarks.leftEye),
              var rightEye = center(landmarks.rightEye),
              let nose = center(landmarks.nose),
              let mouth = center(landmarks.outerLips),
              let lips = landmarks.outerLips else { return nil }
        if left.x > rightEye.x { swap(&left, &rightEye) }
        let eyeVector = (rightEye - left) * imageSize
        let distance = simd_length(eyeVector)
        guard distance.isFinite, distance >= 8,
              bounds.height.isFinite, bounds.height > 0 else { return nil }
        let axis = eyeVector / distance
        var mouthMin = Float.greatestFiniteMagnitude
        var mouthMax = -Float.greatestFiniteMagnitude
        for point in lips.normalizedPoints {
            let x = simd_dot((imagePoint(point) - mouth) * imageSize, axis)
            mouthMin = min(mouthMin, x)
            mouthMax = max(mouthMax, x)
        }
        guard left.x.isFinite, left.y.isFinite, rightEye.x.isFinite, rightEye.y.isFinite,
              nose.x.isFinite, nose.y.isFinite, mouth.x.isFinite, mouth.y.isFinite else { return nil }
        return FaceGeometry(eyeCenter: (left + rightEye) * 0.5, right: axis,
                            nose: nose, mouth: mouth,
                            faceWidth: distance * 2.3,
                            faceHeight: Float(bounds.height) * Float(height),
                            eyeDistance: distance,
                            mouthWidth: max(mouthMax - mouthMin, distance * 0.35))
    }
}

/// A lossy, single-inference lane. The render worker never waits for Vision.
/// State is lock-protected; the reusable request is confined to `worker`.
final class FaceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.openopal.face-landmarks", qos: .userInitiated)
    private let request = VNDetectFaceLandmarksRequest()
    private var enabled = false
    private var size = (width: 0, height: 0)
    private var generation: UInt64 = 0
    private var busy = false
    private var lastStart = -Double.infinity
    private var result: (face: FaceGeometry, capturedAt: TimeInterval)?

    /// At most 15 starts/second, and never a queue of waiting camera frames.
    static let inferenceInterval: TimeInterval = 1.0 / 15.0
    /// Age is measured from the SOURCE frame, not inference completion. A slow
    /// result cannot resurrect a face which has already left the picture.
    static let expiry: TimeInterval = 0.25

    private struct BufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    func reset() {
        lock.withLock {
            generation &+= 1
            enabled = false
            result = nil
            lastStart = -Double.infinity
            // Do not clear busy: an old generation may still be in Vision.
        }
    }

    func update(pixelBuffer: CVPixelBuffer, enabled shouldEnable: Bool) -> FaceGeometry? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let now = ProcessInfo.processInfo.systemUptime
        var startGeneration: UInt64?
        let face: FaceGeometry? = lock.withLock {
            if enabled != shouldEnable || size != (width, height) {
                generation &+= 1
                enabled = shouldEnable
                size = (width, height)
                result = nil
                lastStart = -Double.infinity
            }
            guard enabled else { return nil }
            if !busy && now - lastStart >= Self.inferenceInterval {
                busy = true
                lastStart = now
                startGeneration = generation
            }
            guard let latest = result else { return nil }
            let age = now - latest.capturedAt
            guard age >= 0, age < Self.expiry else {
                result = nil
                return nil
            }
            var snapshot = latest.face
            // Brief hold for normal inference jitter, then fade instead of a pop.
            snapshot.opacity = Float(min(1, (Self.expiry - age) / 0.1))
            return snapshot
        }
        if let startGeneration {
            let box = BufferBox(buffer: pixelBuffer)
            worker.async { [self] in
                let detected: FaceGeometry? = autoreleasepool {
                    do {
                        let handler = VNImageRequestHandler(cvPixelBuffer: box.buffer,
                                                            orientation: .up, options: [:])
                        try handler.perform([request])
                        // Exactly one face is rendered: the largest, not whichever
                        // happens to appear first in Vision's result ordering.
                        guard let largest = request.results?.max(by: {
                            $0.boundingBox.width * $0.boundingBox.height <
                                $1.boundingBox.width * $1.boundingBox.height
                        }) else { return nil }
                        return FaceGeometry.make(from: largest, width: width, height: height)
                    } catch {
                        return nil
                    }
                }
                lock.withLock {
                    busy = false
                    guard enabled, generation == startGeneration else { return }
                    if let detected, ProcessInfo.processInfo.systemUptime - now < Self.expiry {
                        result = (detected, now)
                    } else {
                        // Both a no-face result and a failed request clear old art.
                        result = nil
                    }
                }
            }
        }
        return face
    }
}
