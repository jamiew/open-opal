import Foundation
import Observation

/// Draft work never mutates the shared renderer settings until Apply or Undo.
@MainActor @Observable
final class FilterEditorModel {
    var prompt = "" { didSet { invalidateGeneration() } }
    var title: String { didSet { invalidateGeneration() } }
    var filter: CameraFilter { didSet { invalidateGeneration() } }
    var intensity: Double { didSet { invalidateGeneration() } }
    var animate: Bool { didSet { invalidateGeneration() } }
    private(set) var generating = false
    private(set) var message = "Draft changes do not affect the virtual camera."
    private(set) var presets: [FilterPreset] = []
    private(set) var previous: FilterRecipe?
    private var applied: FilterRecipe?
    private let settings: CameraSettings
    private let store: FilterPresetStore
    private var requestID = UUID()
    private var request: Task<Void, Never>?
    private let provider = FilterRecipeProvider()

    init(settings: CameraSettings, directory: URL = FilterPresetStore.defaultDirectory) {
        self.settings = settings
        store = FilterPresetStore(directory: directory)
        title = settings.filter.title
        filter = settings.filter
        intensity = settings.filterIntensity
        animate = settings.filter.isAnimated && settings.animateFilters
    }

    var availabilityMessage: String? { provider.availabilityMessage }
    var draft: FilterRecipe? { try? validatedDraft() }

    private func validatedDraft() throws -> FilterRecipe {
        try FilterRecipe(title: title, filter: filter, intensity: intensity,
                         animate: filter.isAnimated && animate)
    }

    private func activeRecipe() throws -> FilterRecipe {
        if let applied, applied.filter == settings.filter,
           applied.intensity == settings.filterIntensity,
           applied.animate == (settings.filter.isAnimated && settings.animateFilters) {
            return applied
        }
        return try FilterRecipe(title: settings.filter.title, filter: settings.filter,
                         intensity: settings.filterIntensity,
                         animate: settings.filter.isAnimated && settings.animateFilters)
    }

    func invalidateGeneration() {
        requestID = UUID()
        request?.cancel()
        request = nil
        if generating { message = "Generation canceled. Active output is unchanged." }
        generating = false
    }

    func generate() {
        invalidateGeneration()
        guard availabilityMessage == nil else {
            message = availabilityMessage ?? "Local model unavailable."
            return
        }
        do {
            let current = try validatedDraft()
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { message = "Describe the look you want."; return }
            let id = requestID
            generating = true
            message = "Generating locally…"
            let provider = provider
            request = Task { [weak self] in
                do {
                    let proposal = try await provider.generate(prompt: text, current: current)
                    guard let self, self.requestID == id, !Task.isCancelled else { return }
                    self.generating = false
                    self.request = nil
                    switch proposal {
                    case .recipe(let recipe):
                        self.load(recipe)
                        self.message = "Generated a draft. Review it before applying."
                    case .unsupported(let explanation): self.message = explanation
                    }
                } catch {
                    guard let self, self.requestID == id, !Task.isCancelled else { return }
                    self.generating = false
                    self.request = nil
                    self.message = error.localizedDescription
                }
            }
        } catch { message = error.localizedDescription }
    }

    func load(_ recipe: FilterRecipe) {
        invalidateGeneration()
        title = recipe.title
        filter = recipe.filter
        intensity = recipe.intensity
        animate = recipe.animate
        message = "Loaded a draft. Active output is unchanged."
    }

    func apply() {
        do {
            let recipe = try validatedDraft()
            let old = try activeRecipe()
            invalidateGeneration()
            previous = old
            publish(recipe)
            message = "Applied to preview and virtual camera."
        } catch { message = error.localizedDescription }
    }

    /// All three writes occur without suspension on the renderer snapshot's main actor.
    private func publish(_ recipe: FilterRecipe) {
        settings.filter = recipe.filter
        settings.filterIntensity = recipe.intensity
        settings.animateFilters = recipe.animate
        applied = recipe
    }

    func revert() {
        do { load(try activeRecipe()) }
        catch { message = error.localizedDescription }
    }

    func undo() {
        guard let previous else { return }
        invalidateGeneration()
        publish(previous)
        load(previous)
        self.previous = nil
        message = "Restored the previous active look."
    }

    func save() {
        do {
            let preset = try store.save(validatedDraft())
            presets.append(preset)
            message = "Saved locally without applying."
        } catch { message = error.localizedDescription }
    }

    func reloadPresets() {
        do { presets = try store.load() }
        catch { message = "Could not load presets: \(error.localizedDescription)" }
    }
}
