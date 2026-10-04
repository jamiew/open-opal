import Foundation

/// Camera-free regression checks. Compile with CameraSettings.
@main
struct CameraSettingsPersistenceTests {
    static func main() throws {
        let preferences = MemoryPreferences()
        let initial = CameraSettings(preferences: preferences)
        let defaults = CameraSettings(preferences: MemoryPreferences())

        initial.manualFocus = true
        initial.lensPosition = 187
        initial.brightness = -3
        initial.autoExposure = false
        initial.exposureUs = 12_000
        initial.iso = 800
        initial.manualWhiteBalance = true
        initial.whiteBalanceK = 4200
        initial.antiBanding = .hz50
        initial.outputMode = .hd720
        initial.fps = 40
        initial.mirrorPreview = false
        initial.showAdvanced = true
        initial.meterOnSubject = true
        precondition(initial.coldDirty)

        let restored = CameraSettings(preferences: preferences)
        precondition(restored.manualFocus && restored.lensPosition == 187)
        precondition(restored.brightness == -3)
        precondition(!restored.autoExposure && restored.exposureUs == 12_000 && restored.iso == 800)
        precondition(restored.manualWhiteBalance && restored.whiteBalanceK == 4200)
        precondition(restored.antiBanding == .hz50 && restored.meterOnSubject)
        precondition(restored.outputMode == .hd720 && restored.fps == 40)
        precondition(!restored.mirrorPreview && restored.showAdvanced && !restored.coldDirty)

        restored.reset()
        precondition(!restored.meterOnSubject && restored.antiBanding == .hz60)
        let reset = CameraSettings(preferences: preferences)
        precondition(!reset.manualFocus && reset.lensPosition == 120 && reset.brightness == 0)
        precondition(reset.autoExposure && reset.exposureUs == 8000)
        precondition(!reset.meterOnSubject && reset.antiBanding == .hz60)

        // Blur-only changes must save immediately, without another camera
        // control change accidentally triggering the write for them.
        let blur = CameraSettings(preferences: preferences)
        blur.bokehEnabled = true
        precondition(CameraSettings(preferences: preferences).bokehEnabled)
        blur.blurAmount = 0.4
        precondition(abs(CameraSettings(preferences: preferences).blurAmount - 0.4) < 0.000001)
        blur.syncBokeh = false
        precondition(!CameraSettings(preferences: preferences).syncBokeh)
        blur.uniformBlur = false
        precondition(!CameraSettings(preferences: preferences).uniformBlur)
        blur.matteQuality = .fast
        precondition(CameraSettings(preferences: preferences).matteQuality == .fast)
        blur.focusDistance = 0.7
        precondition(CameraSettings(preferences: preferences).focusDistance == 0.7)
        blur.autoFocusSubject = false
        precondition(!CameraSettings(preferences: preferences).autoFocusSubject)
        blur.apertureShape = .hexagonal
        precondition(CameraSettings(preferences: preferences).apertureShape == .hexagonal)
        blur.highlightBloom = 0.2
        let restoredBlur = CameraSettings(preferences: preferences)
        precondition(restoredBlur.highlightBloom == 0.2 && restoredBlur.bokehEnabled)
        precondition(abs(restoredBlur.blurAmount - 0.4) < 0.000001)
        precondition(!restoredBlur.syncBokeh && !restoredBlur.uniformBlur && restoredBlur.matteQuality == .fast)
        precondition(restoredBlur.focusDistance == 0.7 && !restoredBlur.autoFocusSubject)
        precondition(restoredBlur.apertureShape == .hexagonal && !restoredBlur.coldDirty)

        restoredBlur.resetBokeh()
        let resetBlur = CameraSettings(preferences: preferences)
        precondition(abs(resetBlur.blurAmount - 0.7) < 0.000001)
        precondition(resetBlur.uniformBlur && resetBlur.syncBokeh && resetBlur.matteQuality == .accurate)
        resetBlur.bokehEnabled = false
        precondition(!CameraSettings(preferences: preferences).bokehEnabled)

        let effects = CameraSettings(preferences: preferences)
        effects.focusOnSubject = true
        precondition(CameraSettings(preferences: preferences).focusOnSubject)
        effects.limitAfRange = true
        precondition(CameraSettings(preferences: preferences).limitAfRange)
        effects.afRangeInfinity = 70
        precondition(CameraSettings(preferences: preferences).afRangeInfinity == 70)
        effects.afRangeMacro = 180
        precondition(CameraSettings(preferences: preferences).afRangeMacro == 180)
        effects.filter = .glitch
        effects.filterIntensity = 0.35
        effects.animateFilters = false
        let restoredFilter = CameraSettings(preferences: preferences)
        precondition(restoredFilter.filter == .glitch && restoredFilter.filterIntensity == 0.35)
        precondition(!restoredFilter.animateFilters && restoredFilter.limitAfRange)
        restoredFilter.resetFilters()
        let resetFilter = CameraSettings(preferences: preferences)
        precondition(resetFilter.filter == defaults.filter)
        precondition(resetFilter.filterIntensity == defaults.filterIntensity)
        precondition(resetFilter.animateFilters == defaults.animateFilters && resetFilter.limitAfRange)
        effects.reset()
        let resetEffects = CameraSettings(preferences: preferences)
        precondition(!resetEffects.focusOnSubject && !resetEffects.limitAfRange)
        precondition(resetEffects.afRangeInfinity == defaults.afRangeInfinity)
        precondition(resetEffects.afRangeMacro == defaults.afRangeMacro)

        // A tap or automatic subject focus leaves AUTO active for this session,
        // but a new session must scan again. Preserve manual focus and its lens
        // position independently, and keep explicitly selected persistent modes.
        for manual in [false, true] {
            let focusPreferences = MemoryPreferences()
            let focus = CameraSettings(preferences: focusPreferences)
            focus.manualFocus = manual
            focus.lensPosition = 187
            focus.focusOnSubject = true
            focus.limitAfRange = true
            focus.afRangeInfinity = 70
            focus.afRangeMacro = 180
            focus.afMode = .macro
            precondition(CameraSettings(preferences: focusPreferences).afMode == .macro)
            focus.afMode = .auto
            precondition(focus.afMode == .auto)
            let restarted = CameraSettings(preferences: focusPreferences)
            precondition(restarted.afMode == .continuousVideo && restarted.manualFocus == manual)
            precondition(restarted.lensPosition == 187 && restarted.focusOnSubject)
            precondition(restarted.limitAfRange && restarted.afRangeInfinity == 70 && restarted.afRangeMacro == 180)
            for mode in [CameraSettings.AFMode.continuousVideo, .macro, .edof] {
                focus.afMode = mode
                let selected = CameraSettings(preferences: focusPreferences)
                precondition(selected.afMode == mode && selected.manualFocus == manual)
                precondition(selected.lensPosition == 187)
            }
        }

        func restore(_ json: String) -> CameraSettings {
            preferences.set(Data(json.utf8), forKey: CameraSettings.persistenceKey)
            return CameraSettings(preferences: preferences)
        }
        let partial = restore(#"{"version":1,"brightness":4}"#)
        precondition(partial.brightness == 4 && partial.lensPosition == 120)
        precondition(!partial.bokehEnabled && partial.aperture == 2.8)
        precondition(partial.syncBokeh && partial.uniformBlur && partial.matteQuality == .accurate)
        precondition(partial.focusDistance == 0.35 && partial.autoFocusSubject)
        precondition(partial.apertureShape == .circular && partial.highlightBloom == 0.55)
        let invalid = restore(#"{"version":1,"brightness":999,"lensPosition":-1,"fps":0,"iso":99999,"exposureUs":-1,"contrast":2}"#)
        precondition(invalid.brightness == 0 && invalid.lensPosition == 120 && invalid.fps == 30)
        precondition(invalid.iso == 400 && invalid.exposureUs == 8000 && invalid.contrast == 2)
        let invalidBlur = restore(#"{"version":1,"bokehEnabled":true,"aperture":999,"focusDistance":-1,"highlightBloom":2,"brightness":4}"#)
        precondition(invalidBlur.bokehEnabled && invalidBlur.brightness == 4)
        precondition(invalidBlur.aperture == 2.8 && invalidBlur.focusDistance == 0.35 && invalidBlur.highlightBloom == 0.55)
        for range in ["\"afRangeInfinity\":200,\"afRangeMacro\":100",
                      "\"afRangeInfinity\":-1,\"afRangeMacro\":256",
                      "\"afRangeInfinity\":70"] {
            let invalidRange = restore("{\"version\":1,\(range),\"limitAfRange\":true,\"brightness\":3}")
            precondition(invalidRange.limitAfRange && invalidRange.brightness == 3)
            precondition(invalidRange.afRangeInfinity == defaults.afRangeInfinity)
            precondition(invalidRange.afRangeMacro == defaults.afRangeMacro)
        }
        let boundaryRange = restore(#"{"version":1,"afRangeInfinity":0,"afRangeMacro":255}"#)
        precondition(boundaryRange.afRangeInfinity == 0 && boundaryRange.afRangeMacro == 255)
        let removedFilter = restore(#"{"version":1,"filter":"removed-look","brightness":3}"#)
        precondition(removedFilter.filter == defaults.filter && removedFilter.brightness == 3)
        let invalidIntensity = restore(#"{"version":1,"filter":"warm","filterIntensity":2,"brightness":3}"#)
        precondition(invalidIntensity.filter == .warm && invalidIntensity.filterIntensity == defaults.filterIntensity)
        precondition(invalidIntensity.brightness == 3)
        for json in ["not JSON", #"{"version":1,"lensPosition":"wrong type"}"#,
                     #"{"version":1,"afMode":"unknown"}"#,
                     #"{"version":2,"brightness":4}"#] {
            let fallback = restore(json)
            precondition(fallback.brightness == 0 && fallback.lensPosition == 120 && !fallback.coldDirty)
        }
        print("Camera settings persistence: passed controls, blur, filters, focus limits, one-shot restore, reset, and invalid-data checks")
    }
}

/// Exercise real JSON persistence without changing the user's preference domain.
private final class MemoryPreferences: UserDefaults {
    private var stored: [String: Data] = [:]
    override func data(forKey defaultName: String) -> Data? { stored[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { stored[defaultName] = value as? Data }
}
