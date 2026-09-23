import SwiftUI

/// Catalog controls only: filtering happens in the shared frame renderer, not in this view.
struct FilterBrowser: View {
    @Bindable var settings: CameraSettings
    @State private var search = ""
    @State private var category: CameraFilter.Category?
    @State private var page = 0

    private let pageSize = 6

    private var intensityLabel: String {
        settings.filterIntensity.formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Off and the selected effect controls stay above the bounded catalog.
            Button {
                settings.resetFilters()
            } label: {
                HStack(spacing: 6) {
                    Label("None", systemImage: CameraFilter.none.symbol)
                    Spacer(minLength: 0)
                    if settings.filter == .none {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text("Turn off")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("None, turn filters off")
            .accessibilityValue(settings.filter == .none ? "Selected" : "Not selected")
            .accessibilityAddTraits(settings.filter == .none ? .isSelected : [])
            .help("Turn filters off and reset intensity and motion. Background and image settings stay unchanged.")

            selectedControls

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search filters", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search built-in filters")
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear filter search")
                    .help("Clear search")
                }
            }
            .padding(8)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))

            Picker("Category", selection: $category) {
                Text("All").tag(Optional<CameraFilter.Category>.none)
                ForEach(CameraFilter.Category.allCases) { option in
                    Text(option.title).tag(Optional(option))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Filter category")

            let filters = CameraFilter.matching(query: search, category: category)
            let start = min(page, max(0, (filters.count - 1) / pageSize)) * pageSize
            let end = min(start + pageSize, filters.count)

            if filters.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No matching filters")
                        .fontWeight(.medium)
                    Text("Try another search or category. Your selected filter stays active.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
            } else {
                Text("\(filters.count) \(filters.count == 1 ? "filter" : "filters") · Showing \(start + 1)-\(end)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(filters[start..<end]) { filter in
                        filterCard(filter)
                    }
                }

                if filters.count > pageSize {
                    HStack {
                        Button("Previous") {
                            page = start / pageSize - 1
                        }
                        .disabled(start == 0)
                        .accessibilityLabel("Previous filters")
                        Spacer(minLength: 4)
                        Text("\(start / pageSize + 1) of \((filters.count + pageSize - 1) / pageSize)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Next") {
                            page = start / pageSize + 1
                        }
                        .disabled(end == filters.count)
                        .accessibilityLabel("Next filters")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("Preview and virtual camera share this filter. Mirroring is preview-only.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: search) { page = 0 }
        .onChange(of: category) { page = 0 }
    }

    private var selectedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.filter.title)
                    .fontWeight(.semibold)
                Text(settings.filter.detail)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            VStack(spacing: 3) {
                HStack {
                    Text("Intensity").foregroundStyle(.secondary)
                    Spacer()
                    Text(intensityLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                Slider(value: $settings.filterIntensity, in: 0...1, step: 0.01) {
                    Text("Filter intensity")
                }
                .labelsHidden()
                .accessibilityValue(intensityLabel)
                .disabled(settings.filter == .none)
            }

            if settings.filter.isAnimated {
                Toggle(isOn: $settings.animateFilters) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Animate filter")
                        Text("Off stops effect motion, not live video.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Animate filter")
                .accessibilityHint("Turning off animation stops effect motion. Live video continues.")
            }

            Group {
                if settings.filter.requiresFace {
                    Label("Tracks one face locally. The effect disappears when tracking is lost.",
                          systemImage: "person.crop.rectangle")
                } else if settings.filter != .none {
                    Label("Applies to the whole image. No face tracking needed.",
                          systemImage: "photo")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func filterCard(_ filter: CameraFilter) -> some View {
        let isSelected = settings.filter == filter
        return Button {
            settings.filter = filter
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: filter.symbol)
                        .font(.system(size: 16))
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.system(size: 11))
                }
                Text(filter.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(filter.category.title)
                    if filter.isAnimated {
                        Image(systemName: "play.circle")
                            .help("Animated effect")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(filter.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("\(filter.category.title). \(filter.isAnimated ? "Animated effect. " : "")\(filter.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(filter.detail)
    }
}
