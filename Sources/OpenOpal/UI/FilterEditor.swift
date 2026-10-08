import SwiftUI

struct FilterEditor: View {
    @State private var model: FilterEditorModel

    init(settings: CameraSettings) {
        _model = State(initialValue: FilterEditorModel(settings: settings))
    }

    var body: some View {
        FilterEditorContent(model: model)
    }
}

private struct FilterEditorContent: View {
    @Bindable var model: FilterEditorModel
    @State private var expanded = false
    @State private var preview: CGImage?
    @State private var previewMessage = ""
    @State private var previewing = false


    var body: some View {
        DisclosureGroup("Generate & Edit", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Apple Foundation Models · On-device · Text only")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Generation selects existing looks and can misunderstand. Review the draft before applying.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let unavailable = model.availabilityMessage {
                    Text(unavailable).font(.caption)
                }
                TextField("Describe a look or refine this draft", text: $model.prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter prompt")
                HStack {
                    Button("Generate") { model.generate() }
                        .disabled(model.generating || model.availabilityMessage != nil || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.generating {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.invalidateGeneration() }
                    }
                }
                Divider()
                TextField("Draft title", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Draft title")
                Picker("Draft look", selection: $model.filter) {
                    ForEach(CameraFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                Text(model.filter.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Intensity")
                    Slider(value: $model.intensity, in: 0...1)
                        .accessibilityLabel("Draft intensity")
                    Text(model.intensity.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                if model.filter.isAnimated { Toggle("Animate", isOn: $model.animate) }
                Button(previewing ? "Rendering sample…" : "Preview on sample") {
                    guard let recipe = model.draft else { return }
                    previewing = true
                    preview = nil
                    previewMessage = ""
                    Task {
                        do {
                            let image = try await Task.detached(priority: .userInitiated) {
                                try FilterDraftPreview.render(recipe)
                            }.value
                            if model.draft == recipe { preview = image }
                        } catch { previewMessage = error.localizedDescription }
                        previewing = false
                    }
                }
                .disabled(model.draft == nil || previewing)
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable().scaledToFit()
                        .accessibilityLabel("Draft effect on a synthetic face")
                    Text("Synthetic face · Still sample, not live tracking")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !previewMessage.isEmpty { Text(previewMessage).font(.caption) }
                Text("Only Apply or Undo changes the active output.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Apply to output") { model.apply() }
                        .disabled(model.draft == nil)
                    Button("Revert draft") { model.revert() }
                    Button("Undo") { model.undo() }.disabled(model.previous == nil)
                }
                HStack {
                    Button("Save draft") { model.save() }.disabled(model.draft == nil)
                    Menu("Saved presets") {
                        ForEach(model.presets) { preset in
                            Button(preset.recipe.title) { model.load(preset.recipe) }
                        }
                        Divider()
                        Button("Reload presets") { model.reloadPresets() }
                    }
                }
                Text(model.message).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Editor status: \(model.message)")
            }
            .padding(.top, 8)
            .font(.system(size: 11))
        }
        .onChange(of: expanded) {
            if expanded { model.reloadPresets() }
        }
        .onChange(of: model.draft) { preview = nil }
        .onDisappear { model.invalidateGeneration() }
    }
}
