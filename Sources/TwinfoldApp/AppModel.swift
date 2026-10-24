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

    /// What the detail pane explains: one set of identical files, or one folder.
    enum Focus: Hashable { case group(Int), folder(String) }

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
    var focus: Focus? { didSet { if focus != oldValue { check = nil; checking = false; checkToken += 1 } } }

    // Live proof for the set in focus (or the example on the done screen).
    private(set) var check: GroupCheck?
    private(set) var checking = false
    private var checkToken = 0

    // Folding state.
    var foldedCount = 0
    var foldTotal = 0
    var freedBytes: Int64 = 0
    var problems = 0
    var journal: URL?
    // Paid tier.
    private(set) var entitlement = Entitlement.load()
    var showingUnlock = false
    private(set) var activating = false
    private(set) var activationError: String?

    /// The biggest set that was folded, shown on the done screen as evidence.
    var example: DuplicateGroup?

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
        let activity = Self.keepAwake("Scanning for identical files")
        Task.detached(priority: .userInitiated) {
            defer { ProcessInfo.processInfo.endActivity(activity) }
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
        focus = breakdown?.groups.isEmpty == false ? .group(0) : nil
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

    /// Re-reads every file in the group from disk: present? identical? stored how many times?
    func runCheck(_ group: DuplicateGroup) {
        checkToken += 1
        let token = checkToken
        checking = true
        check = nil
        Task.detached(priority: .userInitiated) {
            let result = Proof.check(group.files, size: group.size)
            await MainActor.run {
                guard token == self.checkToken else { return }
                self.check = result
                self.checking = false
            }
        }
    }

    /// Sets with at least one file inside `folder`, biggest first.
    func groups(in folder: String) -> [Int] {
        guard let breakdown else { return [] }
        let prefix = folder + "/"
        let visible = Set(visibleCopies.map(\.group))
        return breakdown.groups.indices.filter { g in
            visible.contains(g) && breakdown.groups[g].files.contains { $0.hasPrefix(prefix) }
        }
    }

    /// "cloudfluently/posy" style label for where a file lives, relative to the scanned folder.
    func place(of path: String, depth: Int = 2) -> String {
        let root = breakdown?.root ?? NSHomeDirectory()
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : Format.path(path)
        return rel.split(separator: "/").dropLast().prefix(depth).joined(separator: "/")
    }

    // MARK: Folding

    /// What the free allowance covers out of the current selection.
    var freeBatch: [Copy] { Entitlement.pick(selected, within: entitlement.remaining) }
    var freeBatchBytes: Int64 { freeBatch.reduce(0) { $0 + $1.size } }
    var needsUnlock: Bool { selectedBytes > entitlement.remaining }

    func activate(_ key: String) {
        activating = true
        activationError = nil
        Task {
            do {
                let license = try await Activation.activate(key: key)
                entitlement.license = license
                entitlement.save()
            } catch {
                activationError = error.localizedDescription
            }
            activating = false
        }
    }

    func buy() { NSWorkspace.shared.open(Store.checkoutURL) }

    func fold(_ copies: [Copy]? = nil) {
        guard let breakdown else { return }
        let groups = breakdown.groupsToFold(copies ?? selected)
        // The biggest set that's quick to re-read, so the done screen can prove it on its own.
        let quick = groups.filter { $0.size * Int64($0.files.count) <= 400_000_000 }
        example = (quick.isEmpty ? groups : quick).max { $0.reclaimableBytes < $1.reclaimableBytes }
        check = nil
        foldTotal = groups.reduce(0) { $0 + $1.clusters.dropFirst().reduce(0) { $0 + $1.count } }
        foldedCount = 0
        phase = .folding
        let activity = Self.keepAwake("Letting identical files share space")
        Task.detached(priority: .userInitiated) {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let summary = Reclaimer { done, _, _ in
                if done % 25 == 0 { Task { @MainActor [weak self] in self?.foldedCount = done } }
            }.reclaim(groups)
            try? FileManager.default.removeItem(at: ScanReport.savedURL)
            await MainActor.run {
                self.foldedCount = self.foldTotal
                self.freedBytes = max(summary.freeAfter - summary.freeBefore, 0)
                self.problems = summary.results.count - summary.folded.count
                self.journal = summary.journal
                self.entitlement.record(saved: summary.foldedBytes)
                self.entitlement.save()
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

    /// Keeps the Mac from idling to sleep (and the app from napping) while work is running.
    nonisolated static func keepAwake(_ reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
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
