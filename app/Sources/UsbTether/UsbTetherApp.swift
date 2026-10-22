import AppKit
import SwiftUI
import UsbTetherCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel(client: SocketDaemonClient())
    private var window: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateOtherInstance() { exit(0) }
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.refresh() }
    }

    /// Closing the window ends the app; the daemon launches it again when a phone is pending.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: PreferencesView(model: model))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "UsbTether"
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.refresh() }
    }

    /// True if another instance of this app is already running (and was activated).
    private func activateOtherInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard let first = others.first else { return false }
        first.activate(options: [.activateIgnoringOtherApps])
        return true
    }
}
