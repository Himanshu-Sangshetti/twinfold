import SwiftUI
import TwinfoldCore
import UserNotifications

/// With Automatic on, Twinfold lives in the menu bar: closing the window keeps it running there (and drops the
/// Dock icon), and at login it starts with `--menubar`, no window. With Automatic off it's a plain app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let launchedForMenuBar = CommandLine.arguments.contains("--menubar") && Settings.load().livesInMenuBar

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.launchedForMenuBar { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // scripts/app-e2e.sh: report, a few seconds after launch, what a login start looks like.
        if let dir = ProcessInfo.processInfo.environment["TWINFOLD_LAUNCH_PROBE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let windows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count
                let info: [String: Any] = ["visibleWindows": windows,
                                           "inDock": NSApp.activationPolicy() == .regular]
                try? JSONSerialization.data(withJSONObject: info)
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("launch.json"))
                exit(0)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.canBecomeMain else { return }
            let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.canBecomeMain }
            if others.isEmpty, Settings.load().livesInMenuBar { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Settings.load().livesInMenuBar
    }
}

@main
struct TwinfoldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @MainActor static var startedHidden = false

    init() {
        Typography.register()
        Snapshot.runIfRequested()
        Self.runAutomaticIfRequested()
    }

    var body: some Scene {
        Window("Twinfold", id: "main") {
            ContentView()
                .environment(model)
                .task {
                    // Started at login: stay in the menu bar, no window.
                    if AppDelegate.launchedForMenuBar, !Self.startedHidden {
                        Self.startedHidden = true
                        NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.close() }
                    }
                    await Snapshot.capture(model)
                    await Snapshot.autopilot(model)
                    await Snapshot.proAutopilot(model)
                    await Snapshot.liveAutopilot(model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 800)

        MenuBarExtra("Twinfold", systemImage: "square.on.square",
                     isInserted: .constant(model.settings.livesInMenuBar)) {
            MenuBarContent().environment(model)
        }
    }

    /// `Twinfold --auto` is what launchd runs for Automatic mode: no window, scan, save, record, quit.
    static func runAutomaticIfRequested() {
        guard CommandLine.arguments.contains("--auto") else { return }
        var settings = Settings.load()
        if Entitlement.load().unlocked || ProcessInfo.processInfo.environment["TWINFOLD_FORCE_AUTO"] == "1" {
            AutoRun.run(settings: &settings)
            settings.save()
            if settings.lastAutoSaved > 0 { notify(saved: settings.lastAutoSaved) }
        }
        exit(0)
    }

    /// "Saved 1.2 GB overnight", only when something was saved. Waits briefly so the post goes out before exit.
    static func notify(saved: Int64) {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Twinfold saved \(Format.bytes(saved))"
        content.body = "New identical files now share space. Every file is still where it was; undo it any time in History."
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }
}
