import AppKit
import Foundation
import Observation
import TwinfoldCore

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, scanning, results, folding, done, nothing
    }

    var phase: Phase = .idle
    var roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    var filesSeen = 0
    var compared = 0
    var toCompare = 0
    var report: ScanReport?
    var foldedCount = 0
    var foldTotal = 0
    var freedBytes: Int64 = 0
    var problems = 0
    var journal: URL?

    var reclaimable: Int64 { report?.reclaimableBytes ?? 0 }
    var groups: [DuplicateGroup] { report?.actionable ?? [] }
    var rootName: String {
        roots.count == 1
            ? (roots[0].path == NSHomeDirectory() ? "Home folder" : roots[0].lastPathComponent)
            : "\(roots.count) folders"
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Scan"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            roots = panel.urls
            scan()
        }
    }

    func scan() {
        phase = .scanning
        filesSeen = 0
        compared = 0
        toCompare = 0
        let options = ScanOptions(roots: roots.map(\.path))
        Task.detached(priority: .userInitiated) {
            let report = Scanner(options: options) { phase, done, total in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch phase {
                    case .walking: self.filesSeen = done
                    case .comparing: self.compared = done; self.toCompare = total
                    case .done: break
                    }
                }
            }.run()
            await MainActor.run {
                self.report = report
                self.filesSeen = report.filesScanned
                self.phase = report.reclaimableBytes > 0 ? .results : .nothing
            }
        }
    }

    func fold() {
        let groups = self.groups
        foldTotal = groups.reduce(0) { $0 + $1.clusters.count - 1 }
        foldedCount = 0
        phase = .folding
        Task.detached(priority: .userInitiated) {
            let summary = Reclaimer { done, _, _ in
                Task { @MainActor [weak self] in self?.foldedCount = done }
            }.reclaim(groups)
            await MainActor.run {
                self.freedBytes = max(summary.foldedBytes > 0 ? summary.freeAfter - summary.freeBefore : 0, 0)
                self.problems = summary.results.count - summary.folded.count
                self.journal = summary.journal
                self.phase = .done
            }
        }
    }

    func undo() {
        guard let journal else { return }
        let entries = Journal(url: journal).entries()
        phase = .folding
        foldTotal = entries.count
        foldedCount = 0
        Task.detached(priority: .userInitiated) {
            for (i, entry) in entries.enumerated() {
                _ = Unfolder.unfold(entry.path)
                if i % 20 == 0 { await MainActor.run { self.foldedCount = i } }
            }
            await MainActor.run {
                self.journal = nil
                self.reset()
            }
        }
    }

    func reset() {
        report = nil
        phase = .idle
    }

    func reveal(_ group: DuplicateGroup) {
        NSWorkspace.shared.activateFileViewerSelecting(group.files.prefix(20).map { URL(fileURLWithPath: $0) })
    }
}
