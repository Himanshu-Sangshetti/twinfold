import SwiftUI
import TwinfoldCore
import UserNotifications

@main
struct TwinfoldApp: App {
    @State private var model = AppModel()

    init() {
        Snapshot.runIfRequested()
        Self.runAutomaticIfRequested()
    }

    var body: some Scene {
        Window("Twinfold", id: "main") {
            ContentView()
                .environment(model)
                .task {
                    await Snapshot.capture(model)
                    await Snapshot.autopilot(model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 800)

        MenuBarExtra("Twinfold", systemImage: "square.on.square",
                     isInserted: .constant(model.settings.automatic != .off)) {
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
