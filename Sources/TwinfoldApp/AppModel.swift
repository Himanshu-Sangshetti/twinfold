import AppKit
import Foundation
import Observation
import TwinfoldCore

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, scanning, results, folding, done, nothing, history
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
    // Remembered choices, past runs, and Pro (Automatic mode).
    private(set) var settings = Settings.load()
    private(set) var runs: [Run] = Run.all()
    private(set) var autoRunning = false
    /// What the last undo did, shown on the History screen.
    var undoMessage: String?
    private(set) var entitlement = Entitlement.load()
    var showingAutomatic = false
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
        // Folders left alone last time stay unticked.
        let root = breakdown?.root ?? common
        excludedFolders = Set(settings.leaveAlone.filter { $0 == root || $0.hasPrefix(root + "/") })
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
        // Remember: this folder stays left alone in future scans and automatic runs.
        let root = breakdown?.root ?? NSHomeDirectory()
        settings.leaveAlone = settings.leaveAlone.filter { !($0 == root || $0.hasPrefix(root + "/")) }
            + excludedFolders.sorted()
        settings.save()
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

    var totalSaved: Int64 { runs.reduce(0) { $0 + $1.bytes } }

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

    // MARK: Automatic (Pro)

    /// Turns the schedule on or off; on means launchd runs this app with --auto at 3 am.
    func setAutomatic(_ frequency: Settings.Frequency) {
        guard entitlement.unlocked || frequency == .off else { return }
        settings.automatic = frequency
        settings.save()
        if let exe = Bundle.main.executablePath, Bundle.main.bundlePath.hasSuffix(".app") {
            try? LaunchAgent.install(executable: exe, frequency: frequency)
        }
    }

    func addWatchedFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.watched.contains(url.path) { settings.watched.append(url.path) }
        settings.save()
    }

    func removeWatched(_ path: String) {
        settings.watched.removeAll { $0 == path }
        settings.save()
    }

    /// Stops leaving a folder alone (it can be shared again in scans and automatic runs).
    func removeLeaveAlone(_ path: String) {
        settings.leaveAlone.removeAll { $0 == path }
        excludedFolders.remove(path)
        settings.save()
    }

    func runAutomaticNow() {
        guard !autoRunning else { return }
        autoRunning = true
        var settings = settings
        Task.detached(priority: .utility) {
            AutoRun.run(settings: &settings)
            settings.save()
            await MainActor.run {
                self.settings = settings
                self.runs = Run.all()
                self.autoRunning = false
            }
        }
    }

    // MARK: History

    func showHistory() {
        runs = Run.all()
        phase = .history
    }

    func undo(_ run: Run) {
        phase = .folding
        foldTotal = run.files
        foldedCount = 0
        Task.detached(priority: .userInitiated) {
            let result = run.undo { done, _ in
                if done % 25 == 0 { Task { @MainActor [weak self] in self?.foldedCount = done } }
            }
            await MainActor.run {
                self.undoMessage = Self.describe(result)
                self.runs = Run.all()
                self.phase = .history
            }
        }
    }

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
                self.runs = Run.all()
                self.phase = .done
            }
        }
    }

    func undo() {
        guard let journal else { return }
        let run = Run(journal: journal, date: Date(), files: Journal(url: journal).entries().count, bytes: 0)
        phase = .folding
        foldTotal = run.files
        foldedCount = 0
        Task.detached(priority: .userInitiated) {
            let result = run.undo { done, _ in
                if done % 25 == 0 { Task { @MainActor [weak self] in self?.foldedCount = done } }
            }
            await MainActor.run {
                self.journal = nil
                self.undoMessage = Self.describe(result)
                self.report = nil
                self.breakdown = nil
                self.runs = Run.all()
                self.phase = .history
            }
        }
    }

    nonisolated static func describe(_ r: Run.UndoResult) -> String {
        var parts = ["\(Format.count(r.restored, "file has its", "files have their")) own copy again."]
        if r.gone > 0 { parts.append("\(Format.count(r.gone, "file was", "files were")) deleted or moved since, so there was nothing to restore.") }
        if r.failed > 0 { parts.append("\(Format.count(r.failed, "file", "files")) couldn't be restored and stayed as they were.") }
        if r.stoppedForSpace {
            parts.append("Stopped before your disk got too full: \(Format.count(r.remaining, "file needs", "files need")) \(Format.bytes(r.remainingBytes)) more. Free some space and press Undo on this run again to finish.")
        }
        return parts.joined(separator: " ")
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
