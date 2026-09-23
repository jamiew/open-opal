import SwiftUI

struct MenuBarFlyout: View {
    @Environment(CameraModel.self) private var camera
    let controller: MenuBarPanelController

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.grid.3x3.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open Opal")
                                .font(.headline)
                            Text(
                                controller.snapReady
                                    ? "Release to dock"
                                    : controller.isFloating ? "Drag to move or dock" : "Drag to float"
                            )
                            .font(.caption)
                            .foregroundStyle(controller.snapReady ? .primary : .secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
                    .overlay { PanelDragHandle(controller: controller) }
                    Button {
                        if controller.isFloating { controller.dock() } else { controller.detach() }
                    } label: {
                        Label(
                            controller.isFloating ? "Dock" : "Float",
                            systemImage: controller.isFloating
                                ? "menubar.dock.rectangle" : "arrow.up.left.and.arrow.down.right"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help(controller.isFloating ? "Dock to menu bar" : "Float and resize controls")
                    .accessibilityLabel(controller.isFloating ? "Dock to menu bar" : "Float controls")
                    Button {
                        controller.hide()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .help("Hide controls. The camera keeps running.")
                    .accessibilityLabel("Hide controls")
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(12)

                Color.black
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        MetalPreview(
                            frame: camera.latestFrame,
                            mirrored: camera.settings.mirrorPreview,
                            paused: camera.previewPaused
                        ) { _, sensorPoint in
                            camera.focus(at: sensorPoint)
                        }
                    }
                    .frame(height: min(geometry.size.width * 9 / 16, geometry.size.height * 0.4))
                    .clipped()

                status
                    .font(.caption)
                    .padding(8)
                Divider()
                Inspector()
                    .clipped()
                Divider()
                HStack {
                    Menu {
                        Button("Trigger Autofocus") { camera.device.triggerAutofocus() }
                            .disabled(!camera.device.state.isLive)
                        Button(camera.previewFrozen ? "Unfreeze Preview" : "Freeze Preview") {
                            camera.previewFrozen.toggle()
                        }
                        Button("Toggle Advanced Settings") { camera.settings.showAdvanced.toggle() }
                        Button("Reset All Settings") {
                            camera.settings.reset()
                            camera.push()
                        }
                        Divider()
                        Button("Quit Open Opal") { NSApp.terminate(nil) }
                            .keyboardShortcut("q")
                    } label: {
                        Label("Camera", systemImage: "camera.aperture")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    if controller.isFloating {
                        Text("Resize from any edge")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button("Reconnect") { Task { await camera.reconnect() } }
                }
                .controlSize(.small)
                .padding(12)
            }
        }
        .padding(.top, controller.isFloating ? 0 : 10)
        .background(.regularMaterial, in: outline)
        .clipShape(outline)
        .overlay { outline.strokeBorder(.primary.opacity(0.10), lineWidth: 1) }
    }

    private var outline: PanelOutline {
        PanelOutline(arrowX: controller.anchorOffset, floating: controller.isFloating)
    }

    @ViewBuilder
    private var status: some View {
        switch camera.device.state {
        case .searching, .connecting:
            HStack {
                ProgressView().controlSize(.small)
                Text(camera.isRebooting ? "Rebooting camera…" : "Connecting…")
            }
        case .notFound:
            Text("No Opal C1 found. Connect your camera over USB.")
        case .failed(let message):
            Text(message).foregroundStyle(.red).textSelection(.enabled)
                .lineLimit(3).help(message)
        case .streaming:
            Text(
                "\(camera.device.resolution.h)p · \(camera.device.telemetry.fps, specifier: "%.0f") fps · \(camera.device.telemetry.latencyMs, specifier: "%.0f") ms"
            )
            .monospacedDigit()
        }
    }
}

private struct PanelOutline: InsettableShape {
    let arrowX: CGFloat
    let floating: Bool
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let top = rect.minY + (floating ? 0 : 10)
        let radius: CGFloat = 12
        let arrow = max(rect.minX + radius + 10, min(arrowX, rect.maxX - radius - 10))
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + radius, y: top))
            if !floating {
                path.addLine(to: CGPoint(x: arrow - 10, y: top))
                path.addLine(to: CGPoint(x: arrow, y: rect.minY))
                path.addLine(to: CGPoint(x: arrow + 10, y: top))
            }
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius), control: CGPoint(x: rect.maxX, y: top))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top), control: CGPoint(x: rect.minX, y: top))
            path.closeSubpath()
        }
    }
}
