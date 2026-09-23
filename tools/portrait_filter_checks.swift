import Foundation
import Metal

extension FilterChecks {
    static func checkPortraitLooks() {
        let probe = MediaProbe(width: 401, height: 301)
        let frameSize = SIMD2<Float>(Float(probe.width), Float(probe.height))
        func face(angle: Float = 0, center: SIMD2<Float> = SIMD2(200.5, 135.5)) -> FaceGeometry {
            let right = SIMD2<Float>(cos(angle), sin(angle))
            let down = SIMD2<Float>(-right.y, right.x)
            return FaceGeometry(eyeCenter: center / frameSize, right: right,
                                nose: (center + down * 22) / frameSize,
                                mouth: (center + down * 40) / frameSize,
                                faceWidth: 100, faceHeight: 120, eyeDistance: 43.48, mouthWidth: 28)
        }
        func offset(_ point: SIMD2<Float>, _ geometry: FaceGeometry) -> Int {
            let down = SIMD2<Float>(-geometry.right.y, geometry.right.x)
            let position = geometry.eyeCenter * frameSize
                + (geometry.right * point.x + down * point.y) * geometry.faceWidth
            return (Int(position.y) * probe.width + Int(position.x)) * 4
        }
        func color(_ bytes: [UInt8], _ point: SIMD2<Float>, _ geometry: FaceGeometry) -> ArraySlice<UInt8> {
            let start = offset(point, geometry)
            return bytes[start..<(start + 3)]
        }
        let upright = face()
        var input = [UInt8](repeating: 200, count: probe.width * probe.height * 4)
        for row in 0..<probe.height {
            for column in 0..<probe.width {
                let start = (row * probe.width + column) * 4
                let horizontal = Float(column) + 0.5 - 200.5
                let vertical = Float(row) + 0.5 - 135.5
                let eyeDelta = abs(horizontal) - 21.74
                if eyeDelta * eyeDelta + vertical * vertical < 4.2 * 4.2 {
                    input[start] = 20
                    input[start + 1] = 20
                    input[start + 2] = 20
                }
                if abs(horizontal) < 13 && abs(vertical - 40) < 4 {
                    input[start] = 60
                    input[start + 1] = 60
                    input[start + 2] = 160
                }
                input[start + 3] = 255
            }
        }
        input.withUnsafeBytes {
            probe.source.replace(region: MTLRegionMake2D(0, 0, probe.width, probe.height), mipmapLevel: 0,
                                 withBytes: $0.baseAddress!, bytesPerRow: probe.width * 4)
        }
        let looks: [CameraFilter] = [.babyFace, .animeFace, .beard, .glamHair, .sunglasses, .beardedCowboy]
        for look in looks {
            let full = probe.render(look, face: upright)!
            require(full == probe.render(look, time: 42, face: upright), "Static portrait must not animate: \(look)")
            require(stride(from: 3, to: full.count, by: 4).allSatisfy { full[$0] == 255 },
                    "Portrait must write every pixel opaquely: \(look)")
            for corner in [0, (probe.width - 1) * 4, (probe.height - 1) * probe.width * 4, full.count - 4] {
                require(full[corner..<(corner + 4)] == input[corner..<(corner + 4)],
                        "Portrait altered distant background: \(look)")
            }
            var expired = upright
            expired.opacity = 0
            require(probe.render(look, face: expired) == nil, "Expired face must remove portrait: \(look)")
        }
        func darkEyePixels(_ bytes: [UInt8]) -> Int {
            (163...193).filter { bytes[(135 * probe.width + $0) * 4 + 2] < 100 }.count
        }
        for look in [CameraFilter.babyFace, .animeFace] {
            let full = probe.render(look, face: upright)!
            let gentle = probe.render(look, intensity: 0.3, face: upright)!
            let originalEye = darkEyePixels(input)
            require(darkEyePixels(full) >= originalEye + 2, "\(look) must enlarge the actual eye")
            require(darkEyePixels(gentle) >= originalEye && darkEyePixels(gentle) < darkEyePixels(full),
                    "\(look) strength must control eye enlargement")
            if look == .babyFace {
                require(zip(color(full, SIMD2(0, 0.4), upright), color(input, SIMD2(0, 0.4), upright))
                    .allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "Baby Face must preserve lip detail")
            }
        }
        for geometry in [upright, face(angle: 0.47)] {
            let beard = probe.render(.beard, face: geometry)!
            let hair = probe.render(.glamHair, face: geometry)!
            let glasses = probe.render(.sunglasses, face: geometry)!
            let cowboy = probe.render(.beardedCowboy, face: geometry)!
            let mouth = SIMD2<Float>(0, 0.4)
            require(color(beard, mouth, geometry) == color(input, mouth, geometry), "Beard covered the mouth")
            for point in [SIMD2<Float>(0.10, 0.66), SIMD2<Float>(0.43, 0.10)] {
                require(color(beard, point, geometry) != color(input, point, geometry), "Beard missed chin or sideburn")
                require(color(cowboy, point, geometry) == color(beard, point, geometry), "Cowboy lost beard geometry")
            }
            require(color(cowboy, SIMD2(0, -0.72), geometry) != color(input, SIMD2(0, -0.72), geometry),
                    "Bearded Cowboy must retain its hat")
            for point in [SIMD2<Float>(0.56, 0.72), SIMD2<Float>(0, -0.78)] {
                require(color(hair, point, geometry) != color(input, point, geometry), "Hair missed crown or side lock")
            }
            for point in [SIMD2<Float>(0, 0), SIMD2<Float>(0, 0.22), mouth] {
                require(color(hair, point, geometry) == color(input, point, geometry), "Hair covered the face opening")
            }
            for side: Float in [-1, 1] {
                let lens = color(glasses, SIMD2(side * 0.2174, 0), geometry)
                require(lens.allSatisfy { $0 < 100 }, "Sunglasses lens missed the rolled eye")
                require(lens != color(input, SIMD2(side * 0.2174, 0), geometry), "Sunglasses must cover both eyes")
            }
        }
        let clipped = face(angle: -0.5, center: SIMD2(1, 1))
        for look in looks {
            let output = probe.render(look, face: clipped)!
            require(stride(from: 3, to: output.count, by: 4).allSatisfy { output[$0] == 255 },
                    "Clipped face left incomplete output: \(look)")
        }
        let tiny = MediaProbe(width: 1, height: 1)
        for look in looks {
            let output = tiny.render(look, face: tiny.face)!
            require(output[3] == 255, "Tiny portrait output must remain opaque: \(look)")
        }
        print("PASS: portrait eye enlargement, strength, lip/face openings, props, roll/aspect, composite hat/beard, expiry, clipped/tiny output")
    }
}
