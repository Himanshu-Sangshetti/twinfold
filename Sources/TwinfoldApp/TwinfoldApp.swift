import SwiftUI
import TwinfoldCore

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
        }
        exit(0)
    }
}
