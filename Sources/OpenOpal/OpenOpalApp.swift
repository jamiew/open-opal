import SwiftUI

@main
struct OpenOpalApp: App {
    @State private var camera = CameraModel()

    /// When on, the app lives entirely in the menu bar: no Dock icon, no main
    /// window. The camera and the virtual camera keep running either way — this
    /// only changes where the controls live.
    @AppStorage("menuBarMode") private var menuBarMode = false

    var body: some Scene {
        Window("Open Opal", id: "main") {
            ContentView()
                .environment(camera)
                .frame(minWidth: 940, minHeight: 620)
                .task { await camera.start() }
            // Deliberately no .onDisappear { camera.stop() }. Closing the
            // window used to tear the camera down, which is right for a
            // single-window app and wrong the moment a menu bar flyout can
            // outlive it. Teardown happens on quit instead.
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Camera") {
                Button("Reconnect") {
                    Task { await camera.reconnect() }
                }
                .keyboardShortcut("r")

                Button("Trigger Autofocus") { camera.device.triggerAutofocus() }
                    .keyboardShortcut("f")
                    .disabled(!camera.device.state.isLive)

                Divider()

                Toggle("Menu Bar Only", isOn: $menuBarMode)

                Divider()

                Button("Reset All Settings") { camera.settings.reset(); camera.push() }

                Button("Toggle Advanced Settings") { camera.settings.showAdvanced.toggle() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])

                Button(camera.previewFrozen ? "Unfreeze Preview" : "Freeze Preview") {
                    camera.previewFrozen.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Open Opal", systemImage: "camera.aperture") {
            MenuBarFlyout(menuBarMode: $menuBarMode)
                .environment(camera)
        }
        // .window hosts arbitrary SwiftUI, unlike .menu which is limited to menu
        // items. That is what makes a live preview and real sliders possible.
        .menuBarExtraStyle(.window)
    }
}
