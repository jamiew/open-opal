import SwiftUI

/// The menu bar flyout: preview on top, controls below, in a fixed-width panel.
///
/// The main window floats the inspector *over* a full-bleed preview, which works
/// when there is room to spare. A menu bar panel has no such room, so the same
/// controls are stacked instead — preview at its natural 16:9, inspector
/// scrolling underneath. This is the shape the original Opal app used, and it
/// is the right one for a panel anchored to a status item.
struct MenuBarFlyout: View {
    @Environment(CameraModel.self) private var camera
    @Binding var menuBarMode: Bool
    @Environment(\.openWindow) private var openWindow

    /// Wide enough for the inspector's controls to keep their labels on one
    /// line, narrow enough to sit under a status item without dominating the
    /// screen.
    static let width: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            // Click-to-focus works here as it does in the main window. The
            // reticle is the window's own flourish and is left out — there is
            // no room for it at this size.
            MetalPreview(texture: camera.latestTexture,
                         mirrored: camera.settings.mirrorPreview,
                         paused: camera.previewPaused) { _, sensorPoint in
                camera.focus(at: sensorPoint)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(width: Self.width)
            .clipped()

            Divider()

            ScrollView {
                Inspector()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            // Cap the height so a tall inspector scrolls rather than running off
            // the bottom of the screen. The preview is above this, not inside it.
            .frame(maxHeight: 520)

            Divider()
            footer
        }
        .frame(width: Self.width)
        .task { await camera.start() }
        .onChange(of: menuBarMode, initial: true) { _, on in
            Self.apply(menuBarMode: on, openWindow: openWindow)
        }
    }

    /// Switch between windowed and menu-bar-only.
    ///
    /// `.accessory` only removes the Dock icon — it does not hide anything
    /// already on screen, so the main window would otherwise sit there in a
    /// mode whose whole point is not having one. Closing and reopening it is
    /// the part that has to be explicit.
    static func apply(menuBarMode on: Bool, openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(on ? .accessory : .regular)

        if on {
            // The scene's id is its window identifier, so this finds the one
            // window without disturbing panels or the flyout itself.
            NSApp.windows.first { $0.identifier?.rawValue == "main" }?.close()
        } else {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Menu bar only", isOn: $menuBarMode)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Hide the Dock icon and the main window. The camera keeps running.")

            Spacer()

            Button("Reconnect") { Task { await camera.reconnect() } }
                .controlSize(.small)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
