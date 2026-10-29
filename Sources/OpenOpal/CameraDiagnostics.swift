import AVFoundation
import CoreVideo
import CoreMedia
import Darwin
import Foundation
import Security

/// Runs inside the shipped executable, not an impersonating test producer.
/// Only scalar evidence is printed; image buffers and signatures stay in RAM.
@MainActor
enum CameraDiagnostics {
    static var requested: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--camera-checks") }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    private final class Completion {
        var finished = false
    }

    static func run() async -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let live = arguments.contains("--camera-checks-live")
        let allowed = Set(["--camera-checks", "--camera-checks-live", "--allow-camera-takeover"])
        guard arguments.allSatisfy(allowed.contains),
              arguments.filter({ $0.hasPrefix("--camera-checks") }).count == 1,
              live == arguments.contains("--allow-camera-takeover") else {
            emit("invocation", "failed", ["reason": "Use --camera-checks, or --camera-checks-live --allow-camera-takeover."])
            return 1
        }
        let suiteName = "CameraDiagnostics.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            emit("preferences", "failed", ["reason": "Cannot create isolated preferences."])
            return 1
        }
        preferences.removePersistentDomain(forName: suiteName)
        // Shadow inherited search domains before constructing any settings.
        // Empty data takes the production decoder's clean-default path.
        preferences.set(Data(), forKey: CameraSettings.persistenceKey)
        defer { preferences.removePersistentDomain(forName: suiteName) }

        do {
            try checkPreferences(preferences)
            if !live {
                emit("summary", "passed", ["scope": "Isolated production settings only; run scripts/check-render.sh for renderer checks. No camera was opened."])
                return 0
            }
            try requireSignedExecutable()
            let camera = CameraModel(preferences: preferences)
            let reader = VirtualCameraReadback()
            defer {
                reader.stop()
                // Restore diagnostic controls before releasing our RAM pipeline.
                // These are isolated defaults, never the user's preferences.
                camera.settings.reset()
                camera.settings.outputMode = .fhd1080
                camera.settings.fps = 30
                camera.settings.rotate180 = true
                camera.settings.mirrorOutput = false
                camera.settings.bokehEnabled = false
                camera.push()
                camera.stop()
            }
            emit("safety", "information", ["scope": "Explicit RAM-only takeover; no permission request, installation, recording, firmware flash or GPIO access."])
            let virtualAvailable = try await reader.startIfAuthorized()
            try await bounded("start", camera: camera) { await camera.start() }
            try await observe("baseline", camera: camera, reader: reader, seconds: 3)
            try await bounded("duplicate-start", camera: camera) { await camera.start() }
            try await observe("duplicate-start", camera: camera, reader: reader)

            // Exercise all hot device controls through the same push path as UI.
            // Continued frames prove transport survival, NOT optical correctness.
            for step in 0..<12 {
                configureHot(camera.settings, step: step)
                camera.push()
                try await observe("hot-churn-\(step)", camera: camera, reader: reader)
            }
            try await exerciseActiveControls(camera: camera, reader: reader)
            camera.focus(at: CGPoint(x: 0.5, y: 0.5))
            camera.device.triggerAutofocus()
            camera.device.meterExposure(on: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
            try await observe("focus-and-meter-regions", camera: camera, reader: reader)
            camera.settings.reset()
            camera.settings.mirrorOutput = false
            camera.push()

            // Exercise each actual sensor/ISP output mode, FPS endpoints, and
            // both orientations. 4K is allowed to be slow, never called 30fps.
            for mode in CameraSettings.OutputMode.allCases {
                for fps in [15, mode.maxFps] {
                    camera.settings.outputMode = mode
                    camera.settings.fps = fps
                    camera.settings.rotate180 = fps == 15
                    try await bounded("cold-\(mode.rawValue)-\(fps)", camera: camera) {
                        await camera.applyColdChanges()
                    }
                    guard !camera.settings.coldDirty else { throw Failure("Cold configuration was not acknowledged.") }
                    try await observe("cold-\(mode.rawValue)-\(fps)", camera: camera, reader: reader, seconds: 3)
                }
            }
            camera.settings.outputMode = .fhd1080
            camera.settings.fps = 30
            camera.settings.rotate180 = true
            try await bounded("restore-pipeline", camera: camera) { await camera.applyColdChanges() }

            // Uniform modes do not require external assets. Depth-graded modes
            // are exercised separately only if the production provider loads.
            for quality in CameraSettings.MatteQuality.allCases {
                camera.settings.matteQuality = quality
                for synchronous in [false, true] {
                    camera.settings.bokehEnabled = true
                    camera.settings.uniformBlur = true
                    camera.settings.syncBokeh = synchronous
                    camera.settings.blurAmount = synchronous ? 0.8 : 0.2
                    camera.settings.apertureShape = synchronous ? .hexagonal : .circular
                    camera.settings.highlightBloom = synchronous ? 0.8 : 0
                    camera.settings.autoFocusSubject = synchronous
                    camera.settings.focusDistance = synchronous ? 0.7 : 0.2
                    try await observe("bokeh-\(quality.rawValue)-sync-\(synchronous)", camera: camera, reader: reader, seconds: 3)
                }
            }
            let depthExercised = try await exerciseDepthModes(camera: camera, reader: reader)
            camera.settings.bokehEnabled = false
            for cycle in 1...3 {
                try await bounded("reconnect-\(cycle)", camera: camera) { await camera.reconnect() }
                try await observe("reconnect-\(cycle)", camera: camera, reader: reader)
            }
            var closeCompleted = false
            try await bounded("stop-for-restart", camera: camera, requireLive: false) {
                closeCompleted = await camera.stopForRestart()
            }
            guard closeCompleted else {
                throw Failure("Native close timed out; refusing a competing reopen.")
            }
            guard camera.latestFrame == nil, !camera.feeder.connected, !camera.device.state.isLive else {
                throw Failure("Stop retained active capture or feeder state.")
            }
            try await bounded("stop-start", camera: camera) { await camera.start() }
            try await observe("stop-start", camera: camera, reader: reader, seconds: 3)
            if virtualAvailable {
                let evidence = reader.evidence()
                guard evidence.frames >= 10, evidence.matched >= 3, evidence.unique >= 3,
                      evidence.stageUnique >= 3, evidence.matchAgeSeconds <= 2,
                      evidence.timestampRegressions == 0 else {
                    throw Failure("Virtual readback did not prove fresh, timed, content-matched producer frames: \(evidence).")
                }
                emit("virtual-camera-readback", "passed", evidence.fields)
            }
            emitControlCoverage(depthExercised: depthExercised)
            emit("optical-controls", "unverified", ["reason": "Exposure/ISO/EV/AE lock, lens/AF/range, WB/presets/lock, anti-banding and ISP tuning need a controlled chart/light and optical measurements. Live churn proves only stream survival; telemetry is not optical proof."])
            emit("orientation-and-effects", "unverified", ["reason": "Live orientation/mirroring, subject tracking, bokeh edge quality and depth-graded blur require a known scene, human observation or depth assets. Deterministic pixel transforms belong to existing renderer checks."])
            emit("physical-reconnect-and-gui", "unverified", ["reason": "Software reconnect is not cable removal; physical replug, privacy indicator, GUI docking, external client/TCC approval and user-visible controls were not exercised."])
            emit("summary", "unverified", ["reason": "Automated lifecycle evidence collected; full setting/optical acceptance is intentionally incomplete. Exit 2 is not a pass."])
            return 2
        } catch {
            emit("summary", "failed", ["reason": String(describing: error)])
            return 1
        }
    }

    private static func checkPreferences(_ preferences: UserDefaults) throws {
        let settings = CameraSettings(preferences: preferences)
        guard !settings.mirrorOutput, !settings.coldDirty else { throw Failure("Unexpected clean defaults.") }
        settings.brightness = 3
        settings.mirrorOutput = true
        settings.outputMode = .hd720
        settings.fps = 15
        let pending = settings.coldConfiguration
        settings.completeColdConfiguration(pending, opened: false)
        guard settings.coldDirty else { throw Failure("Failed boot cleared pending settings.") }
        settings.fps = 30
        settings.completeColdConfiguration(pending, opened: true)
        guard settings.coldDirty else { throw Failure("Stale boot cleared newer settings.") }
        settings.completeColdConfiguration(settings.coldConfiguration, opened: true)
        let restored = CameraSettings(preferences: preferences)
        guard !settings.coldDirty, restored.brightness == 3, restored.mirrorOutput,
              restored.outputMode == .hd720, restored.fps == 30 else {
            throw Failure("Isolated production settings round-trip failed.")
        }
        preferences.set(Data(), forKey: CameraSettings.persistenceKey)
        emit("isolated-preferences-and-cold-revisions", "passed")
    }

    private static func requireSignedExecutable() throws {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw Failure("Live checks require a valid signed app executable.")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw Failure("Cannot resolve signed app code.")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty,
              let team = Bundle.main.object(forInfoDictionaryKey: "OpenOpalSigningTeam") as? String,
              !team.isEmpty, !team.contains("$("),
              values[kSecCodeInfoIdentifier as String] as? String == identifier,
              values[kSecCodeInfoTeamIdentifier as String] as? String == team else {
            throw Failure("Producer signature does not match the built host identifier and signing team.")
        }
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let expression = "anchor apple generic and identifier \(quoted(identifier)) "
            + "and certificate leaf[subject.OU] = \(quoted(team))"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw Failure("Producer failed the exact Apple anchor, built host identifier and built team requirement.")
        }
        emit("signed-producer", "passed", ["scope": "Exact Apple anchor, built host identifier and built signing team; extension independently rechecks its sealed producer requirement."])
    }

    private static func bounded(_ name: String, camera: CameraModel, requireLive: Bool = true,
                                operation: @escaping @MainActor () async -> Void) async throws {
        let completion = Completion()
        let task = Task { await operation(); completion.finished = true }
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while !completion.finished {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                task.cancel()
                throw Failure("\(name) exceeded 90 seconds; process will release any blocked USB open on exit.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !requireLive || camera.device.state.isLive else { throw Failure("\(name): \(camera.device.state)") }
    }

    private static func observe(_ name: String, camera: CameraModel, reader: VirtualCameraReadback,
                                seconds: Double = 1.5) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        reader.beginObservation()
        let initialReadback = reader.evidence()
        let deadline = start + seconds + 12
        var firstTime: Double?
        var lastTime: Double?
        var previous: CVPixelBuffer? = camera.latestFrame?.pixelBuffer
        var signatures = Set<UInt64>()
        var count = 0
        var maxGap = 0.0
        var maxVariance = 0.0
        let expected = camera.settings.outputMode.pixelSize
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard camera.device.state.isLive else { throw Failure("\(name): capture stopped: \(camera.device.state)") }
            let now = ProcessInfo.processInfo.systemUptime
            if let frame = camera.latestFrame, previous !== frame.pixelBuffer {
                let buffer = frame.pixelBuffer
                guard CVPixelBufferGetWidth(buffer) == expected.w,
                      CVPixelBufferGetHeight(buffer) == expected.h,
                      CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                      let sample = CameraFrameSample(buffer) else {
                    throw Failure("\(name): missing or incorrect rendered BGRA format/dimensions.")
                }
                previous = buffer
                if let lastTime { maxGap = max(maxGap, now - lastTime) }
                firstTime = firstTime ?? now
                lastTime = now
                count += 1
                signatures.insert(sample.hash)
                maxVariance = max(maxVariance, sample.variance)
                reader.expect(sample)
                if now - (firstTime ?? now) >= seconds { break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let firstTime, let lastTime, count >= 10, lastTime - firstTime >= seconds,
              maxGap <= 3, signatures.count > 1, maxVariance > 1 else {
            throw Failure("\(name): insufficient fresh/non-flat frames (count=\(count), unique=\(signatures.count), variance=\(maxVariance), maxGap=\(maxGap)). A dark or static fixture is unverified, not a pass.")
        }
        if reader.enabled {
            let received = reader.evidence()
            guard received.frames - initialReadback.frames >= 3,
                  received.stageMatched >= 3, received.stageUnique >= 3,
                  received.matchAgeSeconds <= 2,
                  received.timestampRegressions == initialReadback.timestampRegressions,
                  received.width > 0, received.height > 0 else {
                throw Failure("\(name): virtual consumer did not receive fresh content-correlated frames.")
            }
        }
        emit(name, "passed", ["scope": "Stream survival, not optical correctness", "frames": count,
                              "uniqueContentSamples": signatures.count, "width": expected.w, "height": expected.h,
                              "pixelFormat": "BGRA", "observedPublicationFPS": Double(count - 1) / (lastTime - firstTime),
                              "maxPublicationGapSeconds": maxGap, "sampleVariance": maxVariance,
                              "deviceTelemetryFPS": camera.device.telemetry.fps,
                              "deviceTelemetryLatencyMs": camera.device.telemetry.latencyMs])
    }

    private static func configureHot(_ s: CameraSettings, step: Int) {
        let high = step % 2 == 1
        s.autoExposure = high; s.exposureUs = high ? 12_000 : 4_000; s.iso = high ? 800 : 200
        s.evCompensation = high ? 2 : -2; s.aeLock = step % 3 == 0; s.meterOnSubject = high
        s.manualFocus = !high; s.lensPosition = high ? 160 : 90
        s.afMode = CameraSettings.AFMode.allCases[step % CameraSettings.AFMode.allCases.count]
        s.focusOnSubject = high; s.limitAfRange = high
        s.afRangeInfinity = high ? 90 : 80; s.afRangeMacro = high ? 160 : 170
        s.manualWhiteBalance = !high; s.whiteBalanceK = high ? 6500 : 3500
        s.awbMode = CameraSettings.AWBMode.allCases[step % CameraSettings.AWBMode.allCases.count]
        s.awbLock = step % 3 == 0
        s.antiBanding = CameraSettings.AntiBanding.allCases[step % CameraSettings.AntiBanding.allCases.count]
        s.sharpness = step % 5; s.lumaDenoise = (step + 1) % 5; s.chromaDenoise = (step + 2) % 5
        s.brightness = high ? 2 : -2; s.contrast = high ? 2 : -2; s.saturation = high ? 2 : -2
        s.mirrorOutput = high
    }

    private static func exerciseActiveControls(camera: CameraModel, reader: VirtualCameraReadback) async throws {
        let s = camera.settings
        s.focusOnSubject = false
        s.meterOnSubject = false
        s.manualFocus = false
        s.limitAfRange = false
        for mode in CameraSettings.AFMode.allCases {
            s.afMode = mode
            camera.push()
            if mode == .auto { camera.device.triggerAutofocus() }
            try await observe("active-af-\(mode.rawValue)", camera: camera, reader: reader)
        }
        s.manualFocus = true
        for position in [90, 160] {
            s.lensPosition = position
            camera.push()
            try await observe("active-manual-focus-\(position)", camera: camera, reader: reader)
        }
        s.manualFocus = false
        s.manualWhiteBalance = false
        s.awbLock = false
        for mode in CameraSettings.AWBMode.allCases {
            s.awbMode = mode
            camera.push()
            try await observe("active-awb-\(mode.rawValue)", camera: camera, reader: reader)
        }
        s.manualWhiteBalance = true
        for temperature in [3500, 6500] {
            s.whiteBalanceK = temperature
            camera.push()
            try await observe("active-manual-wb-\(temperature)", camera: camera, reader: reader)
        }
        s.manualWhiteBalance = false
        for locked in [false, true] {
            s.awbLock = locked
            camera.push()
            try await observe("active-awb-lock-\(locked)", camera: camera, reader: reader)
        }
        s.awbLock = false
        s.autoExposure = false
        s.aeLock = false
        for (exposure, iso) in [(4000, 200), (12000, 800)] {
            s.exposureUs = exposure
            s.iso = iso
            camera.push()
            try await observe("active-manual-exposure-\(exposure)-iso-\(iso)", camera: camera, reader: reader)
        }
        s.autoExposure = true
        for ev in [-2, 2] {
            s.evCompensation = ev
            s.aeLock = false
            camera.push()
            try await observe("active-ae-ev-\(ev)", camera: camera, reader: reader)
        }
        for locked in [true, false] {
            s.aeLock = locked
            camera.push()
            try await observe("active-ae-lock-\(locked)", camera: camera, reader: reader)
        }
        for mode in CameraSettings.AntiBanding.allCases {
            s.antiBanding = mode
            camera.push()
            try await observe("active-ae-antibanding-\(mode.rawValue)", camera: camera, reader: reader)
        }
    }

    private static func exerciseDepthModes(camera: CameraModel, reader: VirtualCameraReadback) async throws -> Bool {
        let s = camera.settings
        s.bokehEnabled = true
        s.uniformBlur = false
        camera.syncRenderer()
        guard camera.renderer?.depthProvider != nil else {
            s.bokehEnabled = false
            s.uniformBlur = true
            emit("depth-provider", "unverified", ["reason": "Production bundled depth model is missing or failed to load; no download or fallback depth pass was claimed."])
            return false
        }
        emit("depth-provider", "passed", ["scope": "Bundled production model loaded, not optical depth correctness."])
        for synchronous in [false, true] {
            s.syncBokeh = synchronous
            for followsSubject in [false, true] {
                s.autoFocusSubject = followsSubject
                for distance in [0.2, 0.7] {
                    s.focusDistance = distance
                    try await observe("depth-sync-\(synchronous)-follow-\(followsSubject)-focus-\(distance)",
                                      camera: camera, reader: reader, seconds: 3)
                }
            }
        }
        return true
    }

    private static func emitControlCoverage(depthExercised: Bool) {
        let hot = ["autoExposure", "exposureUs", "iso", "evCompensation", "aeLock",
                   "meterOnSubject", "manualFocus", "lensPosition", "afMode", "focusOnSubject",
                   "limitAfRange", "afRangeInfinity", "afRangeMacro", "manualWhiteBalance",
                   "whiteBalanceK", "awbMode", "awbLock", "antiBanding", "sharpness",
                   "lumaDenoise", "chromaDenoise", "brightness", "contrast", "saturation"]
        for control in hot {
            emit("control-\(control)", "unverified",
                 ["automatedEvidence": "Production churn plus explicit active-mode AF/AWB/manual exposure/WB/AE scenarios retained fresh frames. Numeric controls use safe representative values, not exhaustive ranges.",
                  "missingEvidence": "Controlled physical chart/light and an independent optical measurement; forwarding and device telemetry are not proof."])
        }
        emit("control-outputMode", "passed", ["scope": "Actual rendered dimensions after each cold boot", "modes": ["720p", "1080p", "4K"]])
        emit("control-fps", "unverified", ["automatedEvidence": "15 and each mode's max requested; observed publication FPS and gaps printed per stage.",
                                         "missingEvidence": "Independent sensor cadence and end-to-end latency; 4K is not asserted to sustain its requested FPS."])
        for control in ["rotate180", "mirrorOutput"] {
            emit("control-\(control)", "unverified", ["automatedEvidence": "Both values exercised with fresh production output.",
                                                     "missingEvidence": "Known asymmetric physical chart; existing renderer checks independently cover synthetic mirror pixels."])
        }
        for control in ["bokehEnabled", "syncBokeh", "matteQuality", "blurAmount", "aperture",
                        "apertureShape", "highlightBloom", "autoFocusSubject", "focusDistance"] {
            emit("control-\(control)", "unverified", ["automatedEvidence": "Uniform bokeh on/off; all matte quality cases and sync modes; two blur, iris, bloom and focus settings retained fresh frames.",
                                                     "missingEvidence": "Known foreground/background fixture and human/optical edge-quality review; depth behavior is not established by stream survival."])
        }
        emit("control-uniformBlur", "unverified",
             ["automatedEvidence": depthExercised
                ? "Uniform and depth-graded production paths exercised; depth provider loaded."
                : "Uniform path exercised; production depth provider did not load.",
              "missingEvidence": "Known-depth fixture and independent optical correctness measurement; no model download was attempted."])
        for control in ["showAdvanced", "previewFreeze", "windowDocking", "launchAtLogin",
                        "extensionInstallation", "externalClientSelection", "physicalUSBReconnect",
                        "cameraPermission", "privacyIndicator"] {
            emit("control-\(control)", "unverified", ["missingEvidence": "Requires GUI, explicit system approval, physical action or human observation. Harness does not change these settings."])
        }
    }

    fileprivate static func emit(_ check: String, _ status: String, _ fields: [String: Any] = [:]) {
        var result = fields
        result["check"] = check
        result["status"] = status
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
    }
}

/// A small normalized grid; never emitted or saved. Used to reject blank/stale
/// output and match rescaled virtual-camera content to real rendered frames.
private struct CameraFrameSample: Sendable {
    let luma: [Double]
    let hash: UInt64
    let variance: Double

    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }
        var values = [Double]()
        values.reserveCapacity(96)
        var hash: UInt64 = 14695981039346656037
        for y in 0..<8 {
            for x in 0..<12 {
                let offset = ((2 * y + 1) * height / 16) * stride + ((2 * x + 1) * width / 24) * 4
                let value = (Double(bytes[offset]) + 2 * Double(bytes[offset + 1]) + Double(bytes[offset + 2])) / 4
                values.append(value)
                hash = (hash ^ UInt64(value)) &* 1099511628211
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        self.luma = values
        self.hash = hash
        self.variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    func difference(_ other: Self) -> Double {
        zip(luma, other.luma).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(luma.count)
    }
}

private final class VirtualCameraReadback: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Evidence: CustomStringConvertible {
        let frames: Int
        let matched: Int
        let unique: Int
        let timestampRegressions: Int
        let width: Int
        let height: Int
        let stageMatched: Int
        let stageUnique: Int
        let matchAgeSeconds: Double
        var fields: [String: Any] {
            ["frames": frames, "contentMatchedFrames": matched, "uniqueContentSamples": unique,
             "timestampRegressions": timestampRegressions, "width": width, "height": height,
             "stageMatchedFrames": stageMatched, "stageDistinctMatchedSignatures": stageUnique,
             "lastMatchAgeSeconds": matchAgeSeconds,
             "pixelFormat": "BGRA", "scope": "Actual AVFoundation consumer, no recorded frames"]
        }
        var description: String { String(describing: fields) }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera-checks.virtual-readback")
    private let sessionQueue = DispatchQueue(label: "camera-checks.virtual-session")
    private let lock = NSLock()
    private var expected: [(Double, CameraFrameSample)] = []
    private var frames = 0
    private var matched = 0
    private var signatures = Set<UInt64>()
    private var stageSignatures = Set<UInt64>()
    private var stageMatched = 0
    private var lastMatchTime: Double?
    private var regressions = 0
    private var lastTimestamp: CMTime?
    private var width = 0
    private var height = 0
    private var active = false
    var enabled: Bool { lock.withLock { active } }

    @MainActor
    func startIfAuthorized() async throws -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            CameraDiagnostics.emit("virtual-camera-readback", "unverified", ["reason": "Prior camera TCC authorization is absent. No permission prompt was requested."])
            return false
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == "7E671FBA-4A0A-4B0A-8F5D-3A1A1B4DE6F2" }) else {
            CameraDiagnostics.emit("virtual-camera-readback", "unverified", ["reason": "Installed virtual camera is unavailable; no extension activation or installation was attempted."])
            return false
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "CameraDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Virtual readback session cannot attach input/output."])
        }
        session.addInput(input)
        session.addOutput(output)
        // Never request access. AVFoundation start/stop may block, so bound the
        // wait without a structured task group that waits forever on cancel.
        let started = StartFlag()
        sessionQueue.async { [self] in session.startRunning(); started.finish() }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !started.finished {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NSError(domain: "CameraDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "Virtual consumer start exceeded 15 seconds."])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        lock.withLock { active = true }
        return true
    }

    func beginObservation() {
        lock.withLock {
            expected.removeAll(keepingCapacity: true)
            stageSignatures.removeAll(keepingCapacity: true)
            stageMatched = 0
            lastMatchTime = nil
        }
    }

    func expect(_ sample: CameraFrameSample) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            expected.removeAll { now - $0.0 > 2 }
            expected.append((now, sample))
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let sample = CameraFrameSample(buffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            frames += 1
            if !timestamp.isValid || (lastTimestamp.map { CMTimeCompare(timestamp, $0) <= 0 } ?? false) { regressions += 1 }
            lastTimestamp = timestamp
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
            // Only expectations created in the current observation exist here.
            // Consume each once; repeated held/splash frames cannot establish
            // distinct matched content, even if they resemble a static scene.
            if sample.variance > 1,
               let index = expected.firstIndex(where: { now - $0.0 <= 2 && sample.difference($0.1) < 6 }) {
                expected.remove(at: index)
                matched += 1
                stageMatched += 1
                signatures.insert(sample.hash)
                stageSignatures.insert(sample.hash)
                lastMatchTime = now
            }
        }
    }

    func evidence() -> Evidence {
        lock.withLock { Evidence(frames: frames, matched: matched, unique: signatures.count,
                                 timestampRegressions: regressions, width: width, height: height,
                                 stageMatched: stageMatched, stageUnique: stageSignatures.count,
                                 matchAgeSeconds: lastMatchTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .greatestFiniteMagnitude) }
    }

    func stop() {
        // Queue behind any pending start; do not block cleanup indefinitely.
        let stopped = DispatchSemaphore(value: 0)
        sessionQueue.async { [self] in session.stopRunning(); stopped.signal() }
        _ = stopped.wait(timeout: .now() + 3)
    }
}

private final class StartFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var finished: Bool { lock.withLock { value } }
    func finish() { lock.withLock { value = true } }
}
