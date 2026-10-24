import Foundation

/// What the user chose once and Twinfold remembers: folders to leave alone and the automatic schedule.
public struct Settings: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable, CaseIterable { case off, daily, weekly }

    public var watched: [String] = [NSHomeDirectory()]
    public var leaveAlone: [String] = []
    public var automatic: Frequency = .off
    public var lastAutoRun: Date?
    public var lastAutoSaved: Int64 = 0

    public init() {}

    public static var url: URL { Support.directory.appendingPathComponent("settings.json") }

    public static func load(from url: URL = Settings.url) -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    public func save(to url: URL = Settings.url) {
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
        let entries = Journal(url: journal).entries()
        var result = UndoResult()
        var pending = Set(entries.map(\.path))
        var kept: [FoldResult] = []
        for (i, entry) in entries.enumerated() {
            defer { progress?(i + 1, entries.count) }
            guard FileSystem.lstat(entry.path) != nil else {
                result.gone += 1
                pending.remove(entry.path)
                continue
            }
            // Its partner has its own storage again (or never lost it): share with it, as before the run.
            if let partner = entry.partner, !pending.contains(partner), FileSystem.lstat(partner) != nil,
               Reclaimer(journal: nil).fold(entry.path, into: partner, size: entry.size, waitForQuiet: false)
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
            if Unfolder.unfold(entry.path) {
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

    /// The plist: 3 am every day, or 3 am on Sundays.
    public static func plist(executable: String, frequency: Settings.Frequency) -> [String: Any] {
        var interval: [String: Int] = ["Hour": 3, "Minute": 0]
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

    public static func install(executable: String, frequency: Settings.Frequency) throws {
        remove()
        guard frequency != .off else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(executable: executable, frequency: frequency), format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        if managed { launchctl("bootstrap", "gui/\(getuid())", url.path) }
    }

    public static func remove() {
        if managed, FileManager.default.fileExists(atPath: url.path) {
            launchctl("bootout", "gui/\(getuid())/\(label)")
        }
        try? FileManager.default.removeItem(at: url)
    }

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
