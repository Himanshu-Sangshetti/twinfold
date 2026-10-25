import Foundation

/// What the user chose once and Twinfold remembers: folders to leave alone and the automatic schedule.
public struct Settings: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable, CaseIterable { case off, daily, weekly }

    public var watched: [String] = [NSHomeDirectory()]
    public var leaveAlone: [String] = []
    public var automatic: Frequency = .off
    public var lastAutoRun: Date?
    public var lastAutoSaved: Int64 = 0
    /// Start in the menu bar at login while Automatic is on. Optional so settings from 0.7.0 and earlier still
    /// load; nil means on.
    public var openAtLogin: Bool?
    /// Hour of the automatic run, 0–23. Optional so older settings still load; nil means 3 am.
    public var hour: Int?
    public var runHour: Int { min(max(hour ?? 3, 0), 23) }

    /// Twinfold stays in the menu bar when its window closes, and starts there at login.
    public var livesInMenuBar: Bool { automatic != .off && openAtLogin != false }

    public init() {}

    public static var url: URL { Support.directory.appendingPathComponent("settings.json") }

    public static func load(from url: URL = Settings.url) -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    /// Keeps the newest automatic-run result on disk: the overnight run is a separate process, so an app that
    /// was open the whole time must not write back its older copy.
    public func save(to url: URL = Settings.url) {
        var settings = self
        let disk = Settings.load(from: url)
        if let saved = disk.lastAutoRun, saved > (lastAutoRun ?? .distantPast) {
            settings.lastAutoRun = saved
            settings.lastAutoSaved = disk.lastAutoSaved
        }
        settings.write(to: url)
    }

    private func write(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Every past run, read back from its journal, so any of them can be undone later.
public struct Run: Identifiable, Sendable {
    public let journal: URL
    public let date: Date
    public let files: Int
    public let bytes: Int64

    public var id: URL { journal }

    public init(journal: URL, date: Date, files: Int, bytes: Int64) {
        self.journal = journal
        self.date = date
        self.files = files
        self.bytes = bytes
    }

    public static func all(in directory: URL = Journal.directory) -> [Run] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }.compactMap { url in
            let entries = Journal(url: url).entries()
            guard !entries.isEmpty else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return Run(journal: url, date: date ?? .distantPast, files: entries.count,
                       bytes: entries.reduce(0) { $0 + $1.freedBytes })
        }
        .sorted { $0.date > $1.date }
    }

    /// Free space kept in hand while undoing; `TWINFOLD_UNDO_RESERVE` overrides it (tests).
    static var reserve: Int64 {
        ProcessInfo.processInfo.environment["TWINFOLD_UNDO_RESERVE"].flatMap(Format.parseSize) ?? 200_000_000
    }

    public struct UndoResult: Sendable, Equatable {
        public var restored = 0
        /// Files deleted or moved since the run; nothing to restore.
        public var gone = 0
        public var failed = 0
        /// Undo un-shares data, which takes space; it stops before the disk fills and keeps the rest for later.
        public var stoppedForSpace = false
        public var remaining = 0
        public var remainingBytes: Int64 = 0
    }

    /// Puts every file in the run back the way it was, in order, while there's room: its own copy again, or,
    /// for a file that already shared storage with another before (an earlier clone), sharing with that file
    /// again, which needs no space. Files restored (or gone) leave the journal. If space runs out, or a file
    /// can't be restored now, the journal keeps the rest so the run can be finished later.
    @discardableResult
    public func undo(progress: ((Int, Int) -> Void)? = nil) -> UndoResult {
        RunLock.withLock { undoLocked(progress: progress) }
    }

    private func undoLocked(progress: ((Int, Int) -> Void)?) -> UndoResult {
        let entries = Journal(url: journal).entries()
        var result = UndoResult()
        var pending = Set(entries.map(\.path))
        var kept: [FoldResult] = []
        let openFiles = OpenFiles()  // one shared, refreshed every two seconds
        let resharer = Reclaimer(journal: nil, openFiles: openFiles)
        for (i, entry) in entries.enumerated() {
            defer { progress?(i + 1, entries.count) }
            guard FileSystem.lstat(entry.path) != nil else {
                result.gone += 1
                pending.remove(entry.path)
                continue
            }
            // Its partner has its own storage again (or never lost it): share with it, as before the run.
            if let partner = entry.partner, !pending.contains(partner), FileSystem.lstat(partner) != nil,
               resharer.fold(entry.path, into: partner, size: entry.size, waitForQuiet: false)
                   .outcome == .folded {
                result.restored += 1
                pending.remove(entry.path)
                continue
            }
            if FileSystem.freeBytes(entry.path) < entry.size + Self.reserve {
                let rest = kept + Array(entries[i...])
                result.stoppedForSpace = true
                result.remaining = rest.count
                result.remainingBytes = rest.reduce(0) { $0 + $1.freedBytes }
                Journal.rewrite(journal, with: rest)
                return result
            }
            if Unfolder.unfold(entry.path, openFiles: openFiles) {
                result.restored += 1
                pending.remove(entry.path)
            } else {
                result.failed += 1
                kept.append(entry)
            }
        }
        if kept.isEmpty { try? FileManager.default.removeItem(at: journal) } else { Journal.rewrite(journal, with: kept) }
        return result
    }
}

/// The unattended run behind Automatic mode: scan the watched folders, skip the ones left alone, fold the rest.
public enum AutoRun {
    @discardableResult
    public static func run(settings: inout Settings, now: Date = Date()) -> ReclaimSummary {
        var options = ScanOptions(roots: settings.watched)
        options.excludes = settings.leaveAlone
        let report = Scanner(options: options).run()
        let summary = report.actionable.isEmpty ? ReclaimSummary() : Reclaimer().reclaim(report.actionable)
        settings.lastAutoRun = now
        settings.lastAutoSaved = summary.foldedBytes
        return summary
    }
}

/// Schedules `<executable> --auto` with launchd. `TWINFOLD_LAUNCH_AGENTS` overrides the folder (tests), and
/// then launchctl isn't called.
public enum LaunchAgent {
    public static let label = "app.twinfold.automatic"

    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["TWINFOLD_LAUNCH_AGENTS"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    public static var url: URL { directory.appendingPathComponent("\(label).plist") }
    static var managed: Bool { ProcessInfo.processInfo.environment["TWINFOLD_LAUNCH_AGENTS"] == nil }

    /// The plist: every day, or on Sundays, at `hour`. launchd runs a job missed while the Mac was asleep as soon
    /// as it wakes; one missed while it was shut down waits for the next time.
    public static func plist(executable: String, frequency: Settings.Frequency, hour: Int = 3) -> [String: Any] {
        var interval: [String: Int] = ["Hour": hour, "Minute": 0]
        if frequency == .weekly { interval["Weekday"] = 0 }
        return [
            "Label": label,
            "ProgramArguments": [executable, "--auto"],
            "StartCalendarInterval": interval,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
        ]
    }

    public static func install(executable: String, frequency: Settings.Frequency, hour: Int = 3) throws {
        remove()
        guard frequency != .off else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(executable: executable, frequency: frequency, hour: hour), format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        if managed { launchctl("bootstrap", "gui/\(getuid())", url.path) }
    }

    public static func remove() {
        if managed, FileManager.default.fileExists(atPath: url.path) {
            launchctl("bootout", "gui/\(getuid())/\(label)")
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Starts Twinfold in the menu bar (no window) when the user logs in, while Automatic is on. Opened through
    /// `open` so a Twinfold that's already running isn't started twice. Only written, not loaded now: launchd
    /// picks it up at the next login.
    public static let menuBarLabel = "app.twinfold.menubar"
    public static var menuBarURL: URL { directory.appendingPathComponent("\(menuBarLabel).plist") }

    public static func menuBarPlist(app: String) -> [String: Any] {
        ["Label": menuBarLabel, "RunAtLoad": true,
         "ProgramArguments": ["/usr/bin/open", "-g", "-j", "-a", app, "--args", "--menubar"]]
    }

    public static func setOpenAtLogin(app: String, _ on: Bool) throws {
        try? FileManager.default.removeItem(at: menuBarURL)
        guard on else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: menuBarPlist(app: app), format: .xml, options: 0)
        try data.write(to: menuBarURL, options: .atomic)
    }

    /// The app the 3 am schedule currently runs, if it's set up.
    public static var installedExecutable: String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (plist["ProgramArguments"] as? [String])?.first
    }

    public static var opensAtLogin: Bool { FileManager.default.fileExists(atPath: menuBarURL.path) }

    private static func launchctl(_ args: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
