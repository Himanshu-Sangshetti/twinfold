import AppKit
import Foundation
import Observation
import TwinfoldCore

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, scanning, results, folding, done, nothing
    }

    enum Tab: String, CaseIterable { case folders = "Folders", files = "Files" }

    var phase: Phase = .idle
    var roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    var filesSeen = 0
    var compared = 0
    var toCompare = 0

    var report: ScanReport?
    var scannedAt: Date?
    private(set) var breakdown: Breakdown?

    // Review state.
    var tab: Tab = .folders
    var kindFilter: Kind?
    var excludedFolders: Set<String> = [] { didSet { recompute() } }
    var excludedGroups: Set<Int> = [] { didSet { recompute() } }
    private(set) var selected: [Copy] = []
    private(set) var selectedBytes: Int64 = 0

    // Folding state.
    var foldedCount = 0
    var foldTotal = 0
    var freedBytes: Int64 = 0
    var problems = 0
    var journal: URL?

    init() {
        if let saved = ScanReport.load(), saved.reclaimableBytes > 0 {
            let date = (try? ScanReport.savedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            show(saved, at: date ?? Date())
        }
    }

    var rootName: String {
        roots.count == 1
            ? (roots[0].path == NSHomeDirectory() ? "Home Folder" : roots[0].lastPathComponent)
            : "\(roots.count) Folders"
    }

    var totalBytes: Int64 { breakdown?.copies.reduce(0) { $0 + $1.size } ?? 0 }

    // MARK: Scanning

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
            report.save()
            await MainActor.run {
                self.filesSeen = report.filesScanned
                if report.reclaimableBytes > 0 { self.show(report, at: Date()) } else { self.phase = .nothing }
            }
        }
    }

    func show(_ report: ScanReport, at date: Date) {
        self.report = report
        scannedAt = date
        let common = roots.count == 1 ? roots[0].path : NSHomeDirectory()
        breakdown = Breakdown(report: report, root: common)
        kindFilter = nil
        excludedFolders = []
        excludedGroups = []
        recompute()
        phase = .results
    }

    // MARK: Review

    private func recompute() {
        guard let breakdown else { return }
        let folders = excludedFolders.map { $0 + "/" }
        selected = breakdown.copies.filter { c in
            !excludedGroups.contains(c.group) && !folders.contains { c.path.hasPrefix($0) }
        }
        selectedBytes = selected.reduce(0) { $0 + $1.size }
    }

    func isIncluded(folder path: String) -> Bool {
        !excludedFolders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func toggle(folder path: String) {
        if let ancestor = excludedFolders.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            excludedFolders.remove(ancestor)
        } else {
            excludedFolders = excludedFolders.filter { !$0.hasPrefix(path + "/") }.union([path])
        }
    }

    func toggle(group: Int) {
        if excludedGroups.contains(group) { excludedGroups.remove(group) } else { excludedGroups.insert(group) }
    }

    /// Copies visible under the current kind filter.
    var visibleCopies: [Copy] {
        guard let breakdown else { return [] }
        guard let kindFilter else { return breakdown.copies }
        return breakdown.copies.filter { $0.kind == kindFilter }
    }

    // MARK: Folding

    func fold() {
        guard let breakdown else { return }
        let groups = breakdown.groupsToFold(selected)
        foldTotal = groups.reduce(0) { $0 + $1.clusters.dropFirst().reduce(0) { $0 + $1.count } }
        foldedCount = 0
        phase = .folding
        Task.detached(priority: .userInitiated) {
            let summary = Reclaimer { done, _, _ in
                if done % 25 == 0 { Task { @MainActor [weak self] in self?.foldedCount = done } }
            }.reclaim(groups)
            try? FileManager.default.removeItem(at: ScanReport.savedURL)
            await MainActor.run {
                self.foldedCount = self.foldTotal
                self.freedBytes = max(summary.freeAfter - summary.freeBefore, 0)
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
                if i % 25 == 0 { await MainActor.run { self.foldedCount = i } }
            }
            await MainActor.run {
                self.journal = nil
                self.reset()
            }
        }
    }

    func reset() {
        report = nil
        breakdown = nil
        phase = .idle
    }

    func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.prefix(20).map { URL(fileURLWithPath: $0) })
    }
}
