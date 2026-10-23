import SwiftUI

@main
struct TwinfoldApp: App {
    @State private var model = AppModel()

    init() { Snapshot.runIfRequested() }

    var body: some Scene {
        Window("Twinfold", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
