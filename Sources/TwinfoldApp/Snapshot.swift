import AppKit
import SwiftUI
import TwinfoldCore

/// `TWINFOLD_SNAPSHOT=<dir> Twinfold` renders the app icon to a PNG and quits (used by scripts/bundle.sh).
///
/// `TWINFOLD_CAPTURE=<dir> TWINFOLD_REPORT=<scan.json> Twinfold` opens the real window with a saved
/// `twinfold scan --json` report, captures each screen, and quits. Used to review the design.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["TWINFOLD_SNAPSHOT"] else { return }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        write(AppIcon().frame(width: 1024, height: 1024), to: out.appendingPathComponent("icon-1024.png"), scale: 1)
        exit(0)
    }

    static func capture(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["TWINFOLD_CAPTURE"] else { return }
        let look = env["TWINFOLD_APPEARANCE"] ?? "dark"
        if env["TWINFOLD_APPEARANCE"] != nil {
            NSApp.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua)
        }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let path = env["TWINFOLD_REPORT"], let report = ScanReport.load(from: URL(fileURLWithPath: path)) {
            model.show(report, at: Date().addingTimeInterval(-3 * 3600))
        }
        func shot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(2000))
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
        }
        write(HowItWorks().padding(22).frame(width: 380).background(Color(white: 0.16))
                .environment(\.colorScheme, .dark), to: out.appendingPathComponent("7-how-it-works.png"))
        write(AutomaticSheet().environment(model).background(Color(white: look == "light" ? 0.97 : 0.16))
                .environment(\.colorScheme, look == "light" ? .light : .dark), to: out.appendingPathComponent("8-automatic.png"))
        write(FoldAnimation(folded: true).padding(20).background(Color(white: look == "light" ? 0.97 : 0.16))
                .environment(\.colorScheme, look == "light" ? .light : .dark), to: out.appendingPathComponent("9-folded.png"))
        await shot("1-folders")
        model.tab = .files
        await shot("2-files")
        if let kind = model.breakdown?.byKind(model.selected).dropFirst().first?.kind { model.kindFilter = kind }
        await shot("3-files-filtered")
        model.kindFilter = nil
        model.tab = .folders
        let top = model.breakdown?.tree(model.visibleCopies).children ?? []
        if let first = top.first { model.toggle(folder: first.path) }
        if let next = top.dropFirst().first { model.focus = .folder(next.path) }
        await shot("4-folders-unticked")
        model.foldTotal = model.selected.count
        model.foldedCount = model.selected.count / 2
        model.phase = .folding
        await shot("5-folding")
        model.freedBytes = model.selectedBytes
        model.example = model.breakdown?.groups.first { $0.size * Int64($0.files.count) <= 400_000_000 }
        model.phase = .done
        await shot("6-done")
        model.phase = .idle
        try? await Task.sleep(for: .milliseconds(800))
        await shot("0-idle")
        exit(0)
    }

    /// `TWINFOLD_AUTOPILOT=<dir> TWINFOLD_ROOTS=<folder>` drives the real window through the same actions the
    /// buttons call: scan, untick the biggest folder, free, then (once `<dir>/continue` exists) undo.
    /// Between steps it writes `<dir>/<step>.json` and a screenshot so scripts/app-e2e.sh can check the disk.
    static func autopilot(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["TWINFOLD_AUTOPILOT"], let roots = env["TWINFOLD_ROOTS"] else { return }
        let out = URL(fileURLWithPath: dir)
        func wait(for phase: AppModel.Phase) async {
            for _ in 0..<1200 where model.phase != phase { try? await Task.sleep(for: .milliseconds(100)) }
        }
        func step(_ name: String, _ info: [String: Any]) async {
            try? await Task.sleep(for: .milliseconds(700))
            if let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            }
            var info = info
            info["phase"] = "\(model.phase)"
            try? JSONSerialization.data(withJSONObject: info).write(to: out.appendingPathComponent("\(name).json"))
        }

        model.reset()
        model.roots = roots.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        model.scan()
        await wait(for: .results)
        await step("1-scanned", ["reclaimable": model.selectedBytes, "copies": model.selected.count])

        let biggest = model.breakdown?.tree(model.visibleCopies).children.first?.path ?? ""
        model.toggle(folder: biggest)
        await step("2-unticked", ["unticked": biggest, "selected": model.selectedBytes])

        model.fold()
        await wait(for: .done)
        // The done screen re-reads its example set from disk on its own.
        for _ in 0..<300 where model.check == nil { try? await Task.sleep(for: .milliseconds(100)) }
        await step("3-freed", ["freed": model.freedBytes, "problems": model.problems,
                               "journal": model.journal?.path ?? "",
                               "proofStored": model.check?.storedCopies ?? -1,
                               "proofIdentical": model.check?.allIdentical == true ? 1 : 0,
                               "proofMissing": model.check?.missing ?? -1])

        let go = out.appendingPathComponent("continue")
        for _ in 0..<600 where !FileManager.default.fileExists(atPath: go.path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        model.undo()
        await wait(for: .history)
        await step("4-undone", ["message": model.undoMessage ?? ""])
        model.removeLeaveAlone(biggest)
        await step("5-settings", ["leaveAlone": model.settings.leaveAlone.count,
                                  "stillUnticked": model.isIncluded(folder: biggest) ? 0 : 1])
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

/// The icon: two tiles, the left one folding over onto its twin. Flat paths only, so it renders the
/// same in the app, in the Dock icon and in exported PNGs.
struct AppIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.42, blue: 0.37))
                    .frame(width: s * 0.82, height: s * 0.82)
                    .shadow(color: .black.opacity(0.25), radius: s * 0.02, y: s * 0.012)
                // The twin, lying flat on the right of the hinge.
                RoundedRectangle(cornerRadius: s * 0.05, style: .continuous)
                    .fill(Color.white.opacity(0.30))
                    .frame(width: s * 0.28, height: s * 0.34)
                    .offset(x: s * 0.15)
                // The copy, swinging over the hinge toward it.
                FoldedTile()
                    .fill(Color.white)
                    .overlay(FoldedTile().stroke(Color.white, style: StrokeStyle(lineWidth: s * 0.03, lineJoin: .round)))
                    .frame(width: s * 0.24, height: s * 0.34)
                    .offset(x: -s * 0.11)
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A tile seen in perspective: full height at the hinge (right edge), shorter at the far edge.
struct FoldedTile: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let inset = r.height * 0.11
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - inset))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + inset))
        p.closeSubpath()
        return p
    }
}
