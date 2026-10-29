import SwiftUI
import Darwin

@main
struct OpenOpalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var camera: CameraModel?
    private var controls: MenuBarPanelController?
    private var diagnosticTask: Task<Void, Never>?
    private var diagnosticSignals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CameraDiagnostics.requested {
            diagnosticTask = Task {
                let result = await CameraDiagnostics.run()
                // Exiting this executable also releases a timed-out native open.
                // CameraDiagnostics finishes owned-state cleanup before returning.
                Darwin.exit(result)
            }
            for number in [SIGINT, SIGTERM] {
                Darwin.signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in
                    Task { @MainActor in self?.diagnosticTask?.cancel() }
                }
                source.resume()
                diagnosticSignals.append(source)
            }
            return
        }
        let camera = CameraModel()
        self.camera = camera
        let controls = MenuBarPanelController()
        self.controls = controls
        controls.install(
            content: NSHostingController(
                rootView:
                    MenuBarFlyout(controller: controls).environment(camera)))
        // An accessory app rarely becomes active, so refresh when shown instead.
        controls.onShow = { [camera] in camera.autoLaunch.refresh() }
        Task { await camera.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        controls?.shutdown()
        camera?.stop()
    }
}
