import Foundation

struct FilterPreset: Identifiable, Sendable {
    let id: UUID
    let recipe: FilterRecipe
}

/// Stores only validated recipes, separately from active camera settings.
struct FilterPresetStore: Sendable {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenOpal", isDirectory: true)
            .appendingPathComponent("FilterPresets", isDirectory: true)
    }

    func load() throws -> [FilterPreset] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let files = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        var presets: [FilterPreset] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard file.pathExtension == "json",
                  let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            do {
                let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else {
                    throw StoreError.notRegularFile
                }
                guard let size = metadata.fileSize, size <= FilterRecipe.maximumEncodedBytes else {
                    throw FilterRecipe.ValidationError.tooLarge
                }
                let recipe = try FilterRecipe.decode(Data(contentsOf: file))
                presets.append(FilterPreset(id: id, recipe: recipe))
            } catch {
                throw StoreError.unreadablePreset(file.lastPathComponent, error.localizedDescription)
            }
        }
        return presets
    }

    func save(_ recipe: FilterRecipe) throws -> FilterPreset {
        let data = try recipe.encoded()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var id = UUID()
        var file = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        while manager.fileExists(atPath: file.path) {
            id = UUID()
            file = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        }
        try data.write(to: file, options: [.atomic])
        return FilterPreset(id: id, recipe: recipe)
    }

    private enum StoreError: LocalizedError {
        case notRegularFile
        case unreadablePreset(String, String)

        var errorDescription: String? {
            switch self {
            case .notRegularFile: "A preset must be a regular JSON file, not a folder or symbolic link."
            case let .unreadablePreset(name, reason): "Cannot load preset \(name): \(reason)"
            }
        }
    }
}
