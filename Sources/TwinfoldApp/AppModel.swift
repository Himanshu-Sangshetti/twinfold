import AppKit
import Foundation
import Observation
import UserNotifications
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
    private(set) var breakdown: Breakdown? {
        didSet {
            folderCache = [:]
            topFolders = breakdown.map { $0.tree($0.copies).children } ?? []
        }
    }
    /// The first level of the folder tree, for the simple view (computed once per scan).
    private(set) var topFolders: [FolderNode] = []
    @ObservationIgnored private var folderCache: [String: [Int]] = [:]

    // Review state.
    /// The simple view (number, Save, top folders) unless someone asks to review everything.
    var detailed = false
    var tab: Tab = .folders
    var kindFilter: Kind?
    var fileQuery = ""
    var fileSort: Breakdown.Sort = .saved
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
    /// Why files were left alone in the last save, in plain words, most common first.
    var leftAlone: [(reason: String, count: Int)] = []
    var foldedFiles = 0
    var foldedBytes: Int64 = 0
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
        // Reopen the last scan only while it's still true: not after any save since (which it doesn't know
        // about), and not after a week.
        let scanned = (try? ScanReport.savedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let lastSave = max(runs.map(\.date).max() ?? .distantPast, settings.lastAutoRun ?? .distantPast)
        if scanned > lastSave, scanned > Date(timeIntervalSinceNow: -7 * 86400),
           let saved = ScanReport.load(), saved.reclaimableBytes > 0 {
            show(saved, at: scanned)
        }
        // After an update (or a move), point the schedule and the login item at this copy of the app.
        if let exe = Bundle.main.executablePath, Install.canSchedule, settings.automatic != .off,
           LaunchAgent.installedExecutable != exe {
            try? LaunchAgent.install(executable: exe, frequency: settings.automatic)
        }
        applyOpenAtLogin()
        watchSupportFolder()
        Task { await checkForUpdatesDaily() }
    }

    /// A newer release, once the daily check finds one.
    private(set) var release: Updates.Release?
    var update: String? { release?.version }
    private(set) var updating = false
    private(set) var updateError: String?

    private func checkForUpdatesDaily() async {
        while !Task.isCancelled {
            if let newer = await Updates.latest() { release = newer }
            try? await Task.sleep(for: .seconds(24 * 3600))
        }
    }

    func downloadUpdate() { NSWorkspace.shared.open(Updates.download) }

    /// Downloads the new version, checks it, swaps it in and reopens. On any problem the app stays as it was.
    func installUpdate() {
        guard let release, !updating, Install.canSelfUpdate else { downloadUpdate(); return }
        updating = true
        updateError = nil
        Task {
            do {
                try await Updates.install(release, replacing: Install.path)
                Install.relaunch(Install.path)
            } catch {
                updateError = error.localizedDescription
                updating = false
            }
        }
    }

    /// Reloads when another process (the 3 am run, the CLI) writes settings, the license or a journal. Event
    /// driven, so it costs nothing while idle.
    private var watchers: [DispatchSourceFileSystemObject] = []
    private func watchSupportFolder() {
        for dir in [Support.directory, Journal.directory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, self.phase != .folding else { return }
                self.reloadFromDisk()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    var rootName: String {
        roots.count == 1
            ? (roots[0].path == NSHomeDirectory() ? "Home Folder" : roots[0].lastPathComponent)
            : "\(roots.count) Folders"
    }

    // The disk the scan is on, for the free-space bar.
    private(set) var diskTotal: Int64 = 0
    private(set) var diskFree: Int64 = 0

    func refreshDisk() {
        let url = roots.first ?? FileManager.default.homeDirectoryForCurrentUser
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        diskTotal = Int64(values?.volumeTotalCapacity ?? 0)
        diskFree = values?.volumeAvailableCapacityForImportantUsage ?? 0
        if Look.captured { (diskTotal, diskFree) = (494_000_000_000, 38_400_000_000) }  // screenshots: a made-up disk
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
        detailed = false
        refreshDisk()
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

    /// Sets with at least one file inside `folder`, biggest first. Cached: on a big scan this takes ~60 ms.
    func groups(in folder: String) -> [Int] {
        guard let breakdown else { return [] }
        let key = "\(kindFilter?.rawValue ?? "")|\(folder)"
        if let hit = folderCache[key] { return hit }
        let result = breakdown.groups(in: folder, visible: kindFilter == nil ? nil : Set(visibleCopies.map(\.group)))
        folderCache[key] = result
        return result
    }

    /// "cloudfluently/posy" style label for where a file lives, relative to the scanned folder.
    func place(of path: String, depth: Int = 2) -> String {
        let root = breakdown?.root ?? NSHomeDirectory()
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : Format.path(path)
        return rel.split(separator: "/").dropLast().prefix(depth).joined(separator: "/")
    }

    // MARK: Folding

    var totalSaved: Int64 { runs.reduce(0) { $0 + $1.bytes } }

    /// A cautious first step: just the biggest selected set, so people can see it work before saving everything.
    var trialBatch: [Copy] {
        guard let first = selected.first?.group else { return [] }
        return selected.filter { $0.group == first }
    }
    var trialName: String {
        guard let g = trialBatch.first?.group, let group = breakdown?.groups[g] else { return "" }
        return (group.keeper as NSString).lastPathComponent
    }

    func activate(_ key: String) {
        activating = true
        activationError = nil
        Task {
            do {
                let license = try await Activation.activate(key: key)
                entitlement.license = license
                entitlement.save()
                applyOpenAtLogin()
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
        // A schedule pointing at a temporary copy would silently stop working; move the app first.
        guard !Install.needsMove || frequency == .off else { return }
        settings.automatic = frequency
        settings.save()
        if frequency != .off, Bundle.main.bundlePath.hasSuffix(".app") {
            // Ask once, now, so the overnight run can say what it saved.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
        if let exe = Bundle.main.executablePath, Install.canSchedule {
            try? LaunchAgent.install(executable: exe, frequency: frequency)
        }
        applyOpenAtLogin()
    }

    func setOpenAtLogin(_ on: Bool) {
        settings.openAtLogin = on
        settings.save()
        applyOpenAtLogin()
    }

    /// Keeps the login item in step with Automatic (and with where the app now lives, after an update).
    func applyOpenAtLogin() {
        guard Install.canSchedule else { return }
        try? LaunchAgent.setOpenAtLogin(app: Bundle.main.bundlePath, settings.livesInMenuBar && entitlement.unlocked)
    }

    /// The overnight run and the CLI write to the same files from other processes; read them again.
    func reloadFromDisk() {
        settings = Settings.load()
        entitlement = Entitlement.load()
        runs = Run.all()
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
        guard entitlement.unlocked, !autoRunning else { return }
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
            Self.announce(saved: settings.lastAutoSaved)
        }
    }

    /// After Run Now: say what happened, including when there was nothing new.
    nonisolated static func announce(saved: Int64) {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let content = UNMutableNotificationContent()
        content.title = saved > 0 ? "Twinfold saved \(Format.bytes(saved))" : "Nothing new to save"
        content.body = saved > 0
            ? "New identical files now share space. Every file is still where it was; undo it any time in History."
            : "Twinfold checked your folders: every identical file already shares space."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
                self.leftAlone = Self.plain(summary.leftAlone)
                self.foldedFiles = summary.folded.count
                self.foldedBytes = summary.foldedBytes
                self.journal = summary.journal
                self.runs = Run.all()
                self.refreshDisk()
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

    /// The engine's reasons, grouped into what they mean for the user.
    nonisolated static func plain(_ reasons: [(reason: String, count: Int)]) -> [(reason: String, count: Int)] {
        var groups: [String: Int] = [:]
        for (reason, count) in reasons {
            let words: String
            switch reason {
            case "changed in the last few minutes": words = "were changed in the last few minutes (next run picks them up)"
            case "open in another app": words = "were open in another app"
            case "size changed", "contents differ", "file changed during fold": words = "changed while Twinfold worked"
            case "protected file": words = "are locked, hard-linked or belong to another user"
            case "different volume": words = "are on another disk than their twin"
            case let r where r.hasPrefix("metadata could not be kept"): words = "have settings macOS wouldn't let Twinfold keep exactly"
            default: words = "couldn't be changed (macOS didn't allow it)"
            }
            groups[words, default: 0] += count
        }
        return groups.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    nonisolated static func describe(_ r: Run.UndoResult) -> String {
        var parts = ["\(Format.count(r.restored, "file has its", "files have their")) own copy again."]
        if r.gone > 0 { parts.append("\(Format.count(r.gone, "file was", "files were")) deleted or moved since, so there was nothing to restore.") }
        if r.failed > 0 { parts.append("\(Format.count(r.failed, "file", "files")) couldn't be restored right now and stay in History to try again.") }
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
