import CoreFoundation
import Foundation

/// A complete, validated single-look recipe. No model-supplied executable content is accepted.
struct FilterRecipe: Equatable, Sendable {
    let schemaVersion: Int
    let title: String
    let filter: CameraFilter
    let intensity: Double
    let animate: Bool

    static let maximumEncodedBytes = 8 * 1024
    private static let keys: Set<String> = ["schemaVersion", "title", "filter", "intensity", "animate"]
    private let encodedData: Data

    init(title: String, filter: CameraFilter, intensity: Double, animate: Bool) throws {
        guard !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ValidationError.invalidTitle
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 64 else { throw ValidationError.invalidTitle }
        guard intensity.isFinite, (0...1).contains(intensity) else {
            throw ValidationError.invalidIntensity
        }
        guard !animate || filter.isAnimated else { throw ValidationError.staticAnimation }

        let encodedData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "title": title,
            "filter": filter.rawValue,
            "intensity": intensity,
            "animate": animate,
        ], options: [.sortedKeys])
        guard encodedData.count <= Self.maximumEncodedBytes else { throw ValidationError.tooLarge }

        self.schemaVersion = 1
        self.title = title
        self.filter = filter
        self.intensity = intensity
        self.animate = animate
        self.encodedData = encodedData
    }

    static func decode(_ data: Data) throws -> FilterRecipe {
        guard data.count <= maximumEncodedBytes else { throw ValidationError.tooLarge }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ValidationError.invalidJSON
        }
        guard let values = object as? [String: Any], Set(values.keys) == keys else {
            throw ValidationError.invalidKeys
        }
        guard let version = values["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID() else {
            throw ValidationError.invalidTypes
        }
        guard version == NSNumber(value: 1) else { throw ValidationError.unsupportedVersion }
        guard let title = values["title"] as? String,
              let filterName = values["filter"] as? String,
              let intensity = values["intensity"] as? NSNumber,
              CFGetTypeID(intensity) != CFBooleanGetTypeID(),
              let animate = values["animate"] as? NSNumber,
              CFGetTypeID(animate) == CFBooleanGetTypeID() else {
            throw ValidationError.invalidTypes
        }
        guard let filter = CameraFilter(rawValue: filterName) else {
            throw ValidationError.unsupportedFilter
        }
        return try FilterRecipe(title: title, filter: filter,
                                intensity: intensity.doubleValue, animate: animate.boolValue)
    }

    /// Encoding cannot introduce invalid state: the immutable bytes were validated at construction.
    func encoded() throws -> Data { encodedData }

    static func == (lhs: FilterRecipe, rhs: FilterRecipe) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.title == rhs.title
            && lhs.filter == rhs.filter && lhs.intensity == rhs.intensity && lhs.animate == rhs.animate
    }

    enum ValidationError: LocalizedError {
        case tooLarge
        case invalidJSON
        case invalidKeys
        case invalidTypes
        case unsupportedVersion
        case invalidTitle
        case unsupportedFilter
        case invalidIntensity
        case staticAnimation

        var errorDescription: String? {
            switch self {
            case .tooLarge: "Recipe JSON must be no larger than 8 KiB."
            case .invalidJSON: "The recipe is not valid JSON."
            case .invalidKeys: "A recipe must contain exactly schemaVersion, title, filter, intensity, and animate."
            case .invalidTypes: "Recipe fields have incorrect JSON types. Numbers and Booleans are not interchangeable."
            case .unsupportedVersion: "Only recipe schema version 1 is supported."
            case .invalidTitle: "A recipe title must contain 1–64 characters after trimming and no control characters."
            case .unsupportedFilter: "The recipe names an unsupported filter."
            case .invalidIntensity: "Recipe intensity must be a finite number from 0 through 1."
            case .staticAnimation: "This filter does not support animation."
            }
        }
    }
}

enum FilterProposal: Sendable {
    case recipe(FilterRecipe)
    case unsupported(String)
}
