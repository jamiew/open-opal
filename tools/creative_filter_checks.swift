import Foundation
import Metal

extension FilterChecks {
    /// An offscreen GPU fixture. Owns only generated pixels, never capture hardware.
    final class MediaProbe {
        let device: MTLDevice
        let source: MTLTexture
        let destination: MTLTexture
        let effects: CameraEffects
        let queue: MTLCommandQueue
        let input: [UInt8]
        let width: Int
        let height: Int

        init(width: Int, height: Int) {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let library = device.makeDefaultLibrary(),
                  let effects = CameraEffects(device: device, library: library),
                  let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
            self.device = device
            self.effects = effects
            self.queue = queue
            self.width = width
            self.height = height
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite]
            source = device.makeTexture(descriptor: descriptor)!
            destination = device.makeTexture(descriptor: descriptor)!
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    pixels[offset] = UInt8((x * 191 / max(width - 1, 1) + y * 31 / max(height - 1, 1)) % 256)
                    pixels[offset + 1] = UInt8(y * 220 / max(height - 1, 1))
                    pixels[offset + 2] = UInt8((x / 13 + y / 11) % 2 == 0 ? 215 : 65)
                }
            }
            input = pixels
            pixels.withUnsafeBytes {
                source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                               withBytes: $0.baseAddress!, bytesPerRow: width * 4)
            }
        }

        var face: FaceGeometry {
            FaceGeometry(eyeCenter: SIMD2(0.5, 0.48), right: SIMD2(1, 0),
                         nose: SIMD2(0.5, 0.62), mouth: SIMD2(0.5, 0.73),
                         faceWidth: Float(height) * 0.45, faceHeight: Float(height) * 0.59,
                         eyeDistance: Float(height) * 0.2, mouthWidth: Float(height) * 0.16)
        }

        func render(_ filter: CameraFilter, intensity: Double = 1, time: Double = 1.25,
                    face: FaceGeometry? = nil) -> [UInt8]? {
            let command = queue.makeCommandBuffer()!
            guard effects.encode(commandBuffer: command, source: source, destination: destination,
                                 filter: filter, intensity: intensity, face: face, time: time) else { return nil }
            command.commit()
            command.waitUntilCompleted()
            require(command.status == .completed, "GPU failed for \(filter): \(String(describing: command.error))")
            var output = input
            output.withUnsafeMutableBytes {
                destination.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return output
        }
    }

    static func checkCreativeMedia() {
        let probe = MediaProbe(width: 257, height: 145)
        let globalStyles: [CameraFilter] = [
            .pointCloud, .glitch, .anime, .halftone, .blueprint,
            .thermal, .pixelate, .hologram, .risograph,
        ]
        var priorOutputs: [[UInt8]] = []
        for filter in globalStyles {
            guard let full = probe.render(filter),
                  let repeated = probe.render(filter),
                  let quarter = probe.render(filter, intensity: 0.25),
                  let later = probe.render(filter, time: 2.75) else { fatalError("Missing \(filter) output") }
            require(full == repeated, "Fixed input/time must reproduce \(filter)")
            require(full != probe.input, "\(filter) must visibly transform the image")
            require(stride(from: 3, to: full.count, by: 4).allSatisfy { full[$0] == 255 },
                    "\(filter) left odd-dimension pixels unwritten or transparent")
            require(!priorOutputs.contains(full), "\(filter) duplicated another creative style")
            priorOutputs.append(full)
            for offset in full.indices where offset % 4 != 3 {
                let expected = Double(probe.input[offset]) * 0.75 + Double(full[offset]) * 0.25
                require(abs(Double(quarter[offset]) - expected) <= 2,
                        "\(filter) intensity must blend between original and complete effect")
            }
            if filter.isAnimated {
                require(full != later, "Animated \(filter) must respond to time")
            } else {
                require(full == later, "Static \(filter) must not flicker over time")
            }
        }

        let hologram = probe.render(.hologram)!
        let blue = stride(from: 0, to: hologram.count, by: 4).reduce(0) { $0 + Int(hologram[$1]) }
        let red = stride(from: 2, to: hologram.count, by: 4).reduce(0) { $0 + Int(hologram[$1]) }
        require(blue > red * 2, "Hologram must produce a cyan/blue display, not a generic color grade")
        let blueprint = probe.render(.blueprint)!
        let blueprintBlue = stride(from: 0, to: blueprint.count, by: 4).reduce(0) { $0 + Int(blueprint[$1]) }
        let blueprintRed = stride(from: 2, to: blueprint.count, by: 4).reduce(0) { $0 + Int(blueprint[$1]) }
        require(blueprintBlue > blueprintRed, "Blueprint must retain its blue-paper palette")

        let pixelated = probe.render(.pixelate)!
        var equalNeighbors = 0
        for y in 0..<probe.height {
            for x in 1..<probe.width {
                let offset = (y * probe.width + x) * 4
                if pixelated[offset..<(offset + 3)] == pixelated[(offset - 4)..<(offset - 1)] {
                    equalNeighbors += 1
                }
            }
        }
        require(equalNeighbors > probe.width * probe.height / 2, "Pixel Art must form actual constant-color blocks")

        for invalid in [Double.nan, .infinity, -1, 0] {
            require(probe.render(.glitch, intensity: invalid) == nil, "Invalid/off intensity must not encode work")
        }
        require(probe.render(.glitch, time: .nan) == probe.render(.glitch, time: 0),
                "Invalid time must not send NaN into shader sampling")
        require(probe.render(.cyberWarrior) == nil, "Face armor must not appear without tracking")
        let armor = probe.render(.cyberWarrior, face: probe.face)!
        require(armor[0..<4] == probe.input[0..<4], "Face armor must preserve the background")
        require(armor != probe.input, "Face armor must alter a detected face")
        require(armor != probe.render(.cyberWarrior, time: 2.75, face: probe.face),
                "Face armor animation must respond to time")
        var faded = probe.face
        faded.opacity = 0
        require(probe.render(.cyberWarrior, face: faded) == nil, "Expired face must not leave armor behind")

        let tiny = MediaProbe(width: 1, height: 1)
        for filter in globalStyles {
            require(tiny.render(filter)?[3] == 255, "\(filter) must support a tiny image without invalid sampling")
        }
        let command = probe.queue.makeCommandBuffer()!
        require(!probe.effects.encode(commandBuffer: command, source: probe.source,
                                      destination: probe.source, filter: .anime, intensity: 1, face: nil),
                "In-place writes must be rejected instead of racing texture reads")
        require(!probe.effects.encode(commandBuffer: command, source: probe.source,
                                      destination: tiny.destination, filter: .anime, intensity: 1, face: nil),
                "Mismatched dimensions must be rejected")
        print("PASS: nine media styles, deterministic animation, static stability, intensity blending, cyber armor, tiny/odd sizes, pass validation")
    }
}
