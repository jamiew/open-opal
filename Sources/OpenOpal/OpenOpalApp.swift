import SwiftUI

@main
struct OpenOpalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let camera = CameraModel()
    private let controls = MenuBarPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controls.install(
            content: NSHostingController(
                rootView:
                    MenuBarFlyout(controller: controls).environment(camera)))
        Task { await camera.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        controls.shutdown()
        camera.stop()
    }
}
