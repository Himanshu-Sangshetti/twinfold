import CoreGraphics
import Foundation
import IOKit.ps

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

    /// Twinfold stays in the menu bar when its window closes, and starts there at login.
    public var livesInMenuBar: Bool { automatic != .off && openAtLogin != false }

    public init() {}

    public static var url: URL { Support.directory.appendingPathComponent("settings.json") }

    public static func load(from url: URL = Settings.url) -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    /// Keeps the newest automatic-run result on disk: the scheduled run is a separate process, so an app that
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
    /// What the hourly check needs to know about the Mac right now.
    public struct Conditions: Sendable, Equatable {
        public var idleSeconds: Double
        public var onPower: Bool
        public var battery: Int?  // percent, nil without a battery

        public init(idleSeconds: Double, onPower: Bool, battery: Int?) {
            self.idleSeconds = idleSeconds
            self.onPower = onPower
            self.battery = battery
        }

        /// Read from the system: seconds since the last keyboard or mouse input, and the power source.
        /// `TWINFOLD_IDLE_SECONDS` and `TWINFOLD_ON_POWER` stand in for the readings (tests).
        public static func now() -> Conditions {
            let idle = ProcessInfo.processInfo.environment["TWINFOLD_IDLE_SECONDS"].flatMap(Double.init)
                ?? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            let onPower = ProcessInfo.processInfo.environment["TWINFOLD_ON_POWER"].map { $0 == "1" }
                ?? ((IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String) == kIOPMACPowerKey)
            var battery: Int?
            for source in IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array {
                if let d = IOPSGetPowerSourceDescription(info, source).takeUnretainedValue() as? [String: Any],
                   let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    battery = now * 100 / max
                }
            }
            return Conditions(idleSeconds: idle, onPower: onPower, battery: battery)
        }
    }

    /// Whether the hourly check should save now: it's been a day (or a week) since the last run, nobody has
    /// touched the Mac for 10 minutes, and it's plugged in or at least half charged.
    public static func isDue(_ settings: Settings, now: Date = Date(), conditions: Conditions) -> Bool {
        let period: TimeInterval
        switch settings.automatic {
        case .off: return false
        case .daily: period = 20 * 3600
        case .weekly: period = 6.5 * 86400
        }
        let due = now.timeIntervalSince(settings.lastAutoRun ?? .distantPast) >= period
        let idle = conditions.idleSeconds >= 600
        let power = conditions.onPower || (conditions.battery ?? 100) >= 50
        return due && idle && power
    }

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

    /// The plist: a quiet check every hour; `--auto` itself decides whether it's time (see `AutoRun.isDue`).
    public static func plist(executable: String, frequency: Settings.Frequency) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, "--auto"],
            "StartInterval": 3600,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
        ]
    }

    /// Whether the installed schedule is exactly the one this version would write (path and timing).
    public static func isCurrent(executable: String, frequency: Settings.Frequency) -> Bool {
        guard let installed = NSDictionary(contentsOf: url) else { return false }
        return installed.isEqual(to: plist(executable: executable, frequency: frequency))
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

    /// The app the schedule currently runs, if it's set up.
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
