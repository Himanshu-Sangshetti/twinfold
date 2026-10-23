import SwiftUI

@main
struct TwinfoldApp: App {
    @State private var model = AppModel()

    init() { Snapshot.runIfRequested() }

    var body: some Scene {
        Window("Twinfold", id: "main") {
            ContentView()
                .environment(model)
                .task { await Snapshot.capture(model) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 880, height: 720)
    }
}
