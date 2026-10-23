import AppKit
import SwiftUI
import TwinfoldCore

/// `TWINFOLD_SNAPSHOT=<dir> Twinfold` renders every screen and the app icon to PNGs, then quits.
/// Used to review the design and to make the README images.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["TWINFOLD_SNAPSHOT"] else { return }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let groups = [
            ("node", 108_000_000, 12), ("next-swc.darwin-arm64.node", 131_000_000, 5),
            ("libtorch_cpu.dylib", 386_000_000, 4), ("libvips-cpp.8.17.3.dylib", 16_000_000, 22),
        ].map { name, size, n in
            DuplicateGroup(size: Int64(size), clusters: (0..<n).map { ["/Users/me/copy\($0)/\(name)"] })
        }
        var report = ScanReport()
        report.groups = groups
        report.filesScanned = 1_204_331

        let phases: [(String, AppModel.Phase, (AppModel) -> Void)] = [
            ("1-idle", .idle, { _ in }),
            ("2-scanning", .scanning, { $0.filesSeen = 412_880; $0.compared = 5_300; $0.toCompare = 14_150 }),
            ("3-results", .results, { $0.report = report }),
            ("4-folding", .folding, { $0.report = report; $0.foldTotal = 47_214; $0.foldedCount = 21_000 }),
            ("5-done", .done, { $0.report = report; $0.freedBytes = 35_300_000_000 }),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, phase, setup) in phases {
                let model = AppModel()
                model.phase = phase
                setup(model)
                let view = ContentView().environment(model).environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.985))
                write(view, to: out.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        write(AppIcon().frame(width: 1024, height: 1024), to: out.appendingPathComponent("icon-1024.png"), scale: 1)
        exit(0)
    }

    static func write(_ view: some View, to url: URL, scale: CGFloat = 2) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The icon: two tiles, the top one folding over onto its twin.
struct AppIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.42, blue: 0.37))
                    .frame(width: s * 0.82, height: s * 0.82)
                    .shadow(color: .black.opacity(0.25), radius: s * 0.02, y: s * 0.012)
                // The twin underneath.
                RoundedRectangle(cornerRadius: s * 0.06, style: .continuous)
                    .fill(Color.white.opacity(0.28))
                    .frame(width: s * 0.30, height: s * 0.30)
                    .offset(x: s * 0.10)
                // The copy, folding onto it.
                RoundedRectangle(cornerRadius: s * 0.06, style: .continuous)
                    .fill(Color.white)
                    .frame(width: s * 0.30, height: s * 0.30)
                    .rotation3DEffect(.degrees(-38), axis: (x: 0, y: 1, z: 0), anchor: .trailing, perspective: 0.5)
                    .offset(x: -s * 0.20)
            }
            .frame(width: s, height: s)
        }
    }
}
