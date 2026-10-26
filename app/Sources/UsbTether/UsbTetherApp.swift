import AppKit
import SwiftUI
import UsbTetherCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel(client: SocketDaemonClient())
    private var window: NSWindow?
    /// The phone last rendered in the approval prompt; never re-read at close time.
    private var displayedPrompt: PendingPhone?
    /// When the system last announced logout, restart or shutdown. A logout can be cancelled
    /// and nothing announces that, so the announcement only counts for `powerOffWindow`.
    private var powerOffAnnounced: Date?
    private static let powerOffWindow: TimeInterval = 60

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateOtherInstance() { exit(0) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willPowerOff(_:)), name: NSWorkspace.willPowerOffNotification, object: nil)
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.refresh() }
    }

    @objc private func willPowerOff(_ notification: Notification) {
        powerOffAnnounced = Date()
    }

    /// Closing the window quits. If a prompt is on screen the close counts as "Not now" for
    /// that phone: it stays declined until the phone is replugged, and only then can it be
    /// approved. The decline gets at most one second so a stuck daemon cannot block quitting.
    /// A quit for logout, restart or shutdown is not a "Not now": the daemon asks again at
    /// the next login.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch closeAction(displayedPrompt: displayedPrompt, isSystemQuit: isSystemQuit()) {
        case .quit:
            return .terminateNow
        case .declineThenQuit(let phone):
            var replied = false
            let reply = {
                guard !replied else { return }
                replied = true
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            Task {
                await model.decline(phone)
                reply()
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                reply()
            }
            return .terminateLater
        }
    }

    /// Whether this quit comes from logout, restart or shutdown (the quit Apple event's
    /// `kAEQuitReason`, or the workspace's power-off notification).
    private func isSystemQuit() -> Bool {
        let why = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: kAEQuitReason)
        let poweringOff = powerOffAnnounced.map { -$0.timeIntervalSinceNow < Self.powerOffWindow } ?? false
        return poweringOff
            || isSystemQuitReason(why?.typeCodeValue)
            || isSystemQuitReason(why?.enumCodeValue)
    }

    private func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: PreferencesView(
                model: model,
                onPromptShown: { [weak self] in self?.displayedPrompt = $0 }))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "UsbTether"
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
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
