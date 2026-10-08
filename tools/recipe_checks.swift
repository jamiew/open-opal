import Foundation

// Standalone executable: compile with CameraFilter.swift, FilterRecipe.swift, and FilterPresetStore.swift.
// Uses only temporary local files; never constructs a camera, renderer, or virtual-camera feeder.
@main
struct RecipeChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            return
        }
        fatalError("Accepted invalid input: \(message)")
    }

    static func data(_ json: String) -> Data { Data(json.utf8) }

    static func checkRecipeBoundaries() throws {
        let recipe = try FilterRecipe(title: "  Subtle beard  ", filter: .beard, intensity: 0.3, animate: false)
        require(recipe.title == "Subtle beard", "Titles must be trimmed")
        let encoded = try recipe.encoded()
        let decoded = try FilterRecipe.decode(encoded)
        let reencoded = try decoded.encoded()
        require(decoded == recipe && reencoded == encoded, "Validated recipes must round-trip stably")

        let wire = #"{"schemaVersion":1,"title":"Off","filter":"none","intensity":0,"animate":false}"#
        let off = try FilterRecipe.decode(data(wire))
        require(off.filter == .none && off.intensity == 0, "Off is a valid recipe")
        let strongest = try FilterRecipe(title: String(repeating: "a", count: 64),
                                         filter: .glitch, intensity: 1, animate: true)
        let strongestReloaded = try FilterRecipe.decode(strongest.encoded())
        require(strongestReloaded == strongest, "Inclusive title and intensity bounds must survive persistence")

        let fields: [String: Any] = ["schemaVersion": 1, "title": "Off", "filter": "none", "intensity": 0, "animate": false]
        for key in fields.keys {
            var missing = fields
            missing.removeValue(forKey: key)
            let input = try JSONSerialization.data(withJSONObject: missing)
            rejects("missing \(key)") { _ = try FilterRecipe.decode(input) }
        }
        var extra = fields
        extra["shader"] = "untrusted code"
        let extraData = try JSONSerialization.data(withJSONObject: extra)
        rejects("unknown field") { _ = try FilterRecipe.decode(extraData) }

        let badFields: [(String, Any)] = [
            ("schemaVersion", true), ("schemaVersion", "1"), ("schemaVersion", 1.5), ("schemaVersion", 2),
            ("title", 1), ("title", NSNull()), ("filter", 0), ("filter", "unknownEffect"),
            ("intensity", true), ("intensity", "0.5"), ("intensity", NSNull()),
            ("intensity", -0.001), ("intensity", 1.001),
            ("animate", 0), ("animate", 1), ("animate", "false"), ("animate", true),
        ]
        for (key, value) in badFields {
            var invalid = fields
            invalid[key] = value
            let input = try JSONSerialization.data(withJSONObject: invalid)
            rejects("invalid \(key): \(value)") { _ = try FilterRecipe.decode(input) }
        }
        for malformed in ["[]", "null", "{", wire + wire, wire.replacingOccurrences(of: "\"intensity\":0", with: "\"intensity\":1e999")] {
            rejects("malformed or nonfinite JSON") { _ = try FilterRecipe.decode(data(malformed)) }
        }
        for title in ["", "   ", String(repeating: "a", count: 65), "bad\nname", "bad\u{0}name", "\tname"] {
            rejects("invalid title") { _ = try FilterRecipe(title: title, filter: .none, intensity: 0, animate: false) }
        }
        for intensity in [Double.nan, Double.infinity, -Double.infinity, -0.001, 1.001] {
            rejects("invalid direct intensity") {
                _ = try FilterRecipe(title: "Off", filter: .none, intensity: intensity, animate: false)
            }
        }
        for filter in CameraFilter.allCases {
            if filter.isAnimated {
                let animated = try FilterRecipe(title: "Animated", filter: filter, intensity: 0.5, animate: true)
                let reloaded = try FilterRecipe.decode(animated.encoded())
                require(reloaded == animated, "Animated catalog effects must round-trip")
            } else {
                rejects("static animation for \(filter.rawValue)") {
                    _ = try FilterRecipe(title: "Static", filter: filter, intensity: 0.5, animate: true)
                }
            }
        }

        var atLimit = data(wire)
        atLimit.append(Data(repeating: 0x20, count: FilterRecipe.maximumEncodedBytes - atLimit.count))
        let atLimitRecipe = try FilterRecipe.decode(atLimit)
        require(atLimitRecipe == off, "An exactly 8 KiB JSON payload must be accepted")
        atLimit.append(0x20)
        rejects("more than 8 KiB") { _ = try FilterRecipe.decode(atLimit) }
        let oversizedGrapheme = "a" + String(repeating: "\u{301}", count: 5000)
        require(oversizedGrapheme.count == 1, "Fixture must exercise bytes rather than character count")
        rejects("encoded byte limit applies to direct construction") {
            _ = try FilterRecipe(title: oversizedGrapheme, filter: .none, intensity: 0, animate: false)
        }
    }

    static func checkStoreBoundaries() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("opal-recipe-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let store = FilterPresetStore(directory: root)
        let absent = try store.load()
        require(absent.isEmpty && !manager.fileExists(atPath: root.path), "Loading an absent store must not create files")

        let first = try FilterRecipe(title: "Beard", filter: .beard, intensity: 0.2, animate: false)
        let second = try FilterRecipe(title: "Animated glitch", filter: .glitch, intensity: 0.8, animate: true)
        let savedFirst = try store.save(first)
        let savedSecond = try store.save(second)
        let firstURL = root.appendingPathComponent(savedFirst.id.uuidString).appendingPathExtension("json")
        let firstBytes = try Data(contentsOf: firstURL)
        let unrelated = root.appendingPathComponent("notes.json")
        let unrelatedBytes = data("not a recipe")
        try unrelatedBytes.write(to: unrelated)
        let ignoredExtension = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        try unrelatedBytes.write(to: ignoredExtension)
        let loaded = try FilterPresetStore(directory: root).load()
        require(loaded.count == 2 && loaded.contains(where: { $0.id == savedFirst.id && $0.recipe == first })
                && loaded.contains(where: { $0.id == savedSecond.id && $0.recipe == second }),
                "A fresh store must reload both saved presets, ignoring unrelated files")

        // A non-directory destination is a deterministic write failure, even when running as root.
        let blockedStore = FilterPresetStore(directory: firstURL.appendingPathComponent("blocked"))
        rejects("failed save") { _ = try blockedStore.save(second) }
        let preserved = try Data(contentsOf: firstURL)
        require(preserved == firstBytes, "Failed saves must preserve prior preset bytes")
        let afterFailure = try store.load()
        require(afterFailure.count == 2, "Failed saves must not add presets")

        let malformedURL = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try data("{}").write(to: malformedURL)
        rejects("malformed owned preset must fail visibly") { _ = try store.load() }
        try manager.removeItem(at: malformedURL)
        try manager.createSymbolicLink(at: malformedURL, withDestinationURL: firstURL)
        rejects("owned preset must not follow symbolic links") { _ = try store.load() }
        try manager.removeItem(at: malformedURL)
        let untouched = try Data(contentsOf: unrelated)
        let finalFirst = try Data(contentsOf: firstURL)
        require(untouched == unrelatedBytes && finalFirst == firstBytes, "Loading failures must never mutate stored or unrelated data")
    }

    static func main() throws {
        try checkRecipeBoundaries()
        try checkStoreBoundaries()
        print("Recipe checks passed: strict validation, bounded stable encoding, atomic saves, reloads, and failure preservation.")
    }
}
