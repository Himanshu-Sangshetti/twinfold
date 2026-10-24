import Darwin
import Foundation

public struct FoldResult: Sendable, Codable {
    public enum Outcome: String, Sendable, Codable {
        case folded, changed, failed, skipped
    }

    public let path: String
    public let keeper: String
    public let size: Int64
    public let outcome: Outcome
    public let reason: String?
}

public struct ReclaimSummary: Sendable {
    public var results: [FoldResult] = []
    public var freeBefore: Int64 = 0
    public var freeAfter: Int64 = 0
    public var journal: URL?

    public var folded: [FoldResult] { results.filter { $0.outcome == .folded } }
    public var foldedBytes: Int64 { folded.reduce(0) { $0 + $1.size } }
}

/// Replaces duplicate files with clones of a single keeper, one file at a time.
///
/// For every file: clone the keeper next to it, compare the clone with the file byte for byte,
/// copy the file's own metadata onto the clone, make sure the file hasn't changed meanwhile,
/// then atomically rename the clone over it. Any surprise leaves the original untouched.
public struct Reclaimer {
    public typealias Progress = @Sendable (_ done: Int, _ total: Int, _ path: String) -> Void

    let journal: Journal?
    let progress: Progress?
    let openFiles = OpenFiles()

    public init(journal: Journal? = .standard(), progress: Progress? = nil) {
        self.journal = journal
        self.progress = progress
    }

    public func reclaim(_ groups: [DuplicateGroup]) -> ReclaimSummary {
        Safety.cleanUpInterrupted()
        var summary = ReclaimSummary()
        let volume = groups.first?.keeper ?? NSHomeDirectory()
        summary.freeBefore = FileSystem.freeBytes(volume)
        let work = groups.flatMap { group in
            group.clusters.dropFirst().flatMap { $0 }.map { (path: $0, keeper: group.keeper, size: group.size) }
        }
        for (i, item) in work.enumerated() {
            progress?(i, work.count, item.path)
            let result = fold(item.path, into: item.keeper, size: item.size)
            if result.outcome == .folded { journal?.record(result) }
            summary.results.append(result)
        }
        progress?(work.count, work.count, "")
        summary.freeAfter = FileSystem.freeBytes(volume)
        summary.journal = journal?.url
        return summary
    }

    public func fold(_ path: String, into keeper: String, size: Int64) -> FoldResult {
        func done(_ outcome: FoldResult.Outcome, _ reason: String? = nil) -> FoldResult {
            FoldResult(path: path, keeper: keeper, size: size, outcome: outcome, reason: reason)
        }
        guard let before = FileSystem.lstat(path), let keeperStat = FileSystem.lstat(keeper) else {
            return done(.skipped, "file is gone")
        }
        guard before.device == keeperStat.device else { return done(.skipped, "different volume") }
        guard before.links == 1, before.flags & FileSystem.untouchableFlags == 0, before.uid == getuid(),
              !FileSystem.hasDenyRule(path) else {
            return done(.skipped, "protected file")
        }
        guard before.size == size, keeperStat.size == size else { return done(.changed, "size changed") }
        let settled = Date().timeIntervalSince1970 - Safety.quietSeconds
        guard Double(max(before.mtime.tv_sec, before.ctime.tv_sec)) < settled else {
            return done(.skipped, "changed in the last few minutes")
        }
        guard !openFiles.isOpenForWriting(before), !openFiles.isOpenForWriting(keeperStat) else {
            return done(.skipped, "open in another app")
        }
        guard let original = FileSystem.metadata(path) else { return done(.failed, "could not read metadata") }

        let dir = (path as NSString).deletingLastPathComponent
        let temp = "\(dir)/.twinfold-\(UUID().uuidString.prefix(8))"
        Safety.inFlight(temp)
        defer { Safety.inFlight(nil) }
        guard clonefile(keeper, temp, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
            return done(.failed, "clone failed: \(String(cString: strerror(errno)))")
        }
        var keepTemp = false
        defer { if !keepTemp { FileSystem.removeTemp(temp) } }

        // Everything is checked on the finished replacement, right before it takes the file's place.
        guard FileSystem.copyMetadata(from: path, to: temp) else { return done(.failed, "could not copy metadata") }
        guard let copied = FileSystem.metadata(temp), copied == original else {
            let what = FileSystem.metadata(temp).map { FileSystem.difference(original, $0) } ?? "unreadable"
            return done(.skipped, "metadata could not be kept exactly (\(what))")
        }
        guard FileSystem.contentsEqual(temp, path) else { return done(.changed, "contents differ") }
        guard FileSystem.lstat(path) == before, !openFiles.isOpenForWriting(before) else {
            return done(.changed, "file changed during fold")
        }
        guard rename(temp, path) == 0 else {
            return done(.failed, "rename failed: \(String(cString: strerror(errno)))")
        }
        keepTemp = true
        return done(.folded)
    }
}

/// The checks that keep a fold from ever losing anything.
public enum Safety {
    /// A file must have been left alone this long before it is folded, so nothing mid-write is touched.
    /// `TWINFOLD_QUIET_SECONDS` overrides it (tests use 0).
    public static var quietSeconds: Double {
        ProcessInfo.processInfo.environment["TWINFOLD_QUIET_SECONDS"].flatMap(Double.init) ?? 300
    }

    static var inFlightURL: URL { Support.directory.appendingPathComponent("in-flight") }

    /// Remembers the temporary clone being made, so one left by a crash or power cut is removed next time.
    static func inFlight(_ temp: String?) {
        if let temp {
            try? FileManager.default.createDirectory(at: Support.directory, withIntermediateDirectories: true)
            try? temp.write(to: inFlightURL, atomically: false, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: inFlightURL)
        }
    }

    /// Removes a temporary clone left behind by an interrupted run. Only ever a `.twinfold-` file.
    public static func cleanUpInterrupted() {
        guard let temp = try? String(contentsOf: inFlightURL, encoding: .utf8) else { return }
        FileSystem.removeTemp(temp)
        try? FileManager.default.removeItem(at: inFlightURL)
    }
}

/// Which files are open for writing, refreshed at most every two seconds during a run.
final class OpenFiles: @unchecked Sendable {
    private var files = Set<FileSystem.FileID>()
    private var checked = Date.distantPast
    private let lock = NSLock()

    func isOpenForWriting(_ stat: FileSystem.Stat) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(checked) > 2 {
            files = FileSystem.filesOpenForWriting()
            checked = Date()
        }
        return files.contains(FileSystem.FileID(device: Int64(stat.device), inode: UInt64(stat.inode)))
    }
}

/// Append-only record of every fold, so `twinfold undo` can give each file its own storage back.
public struct Journal: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard() -> Journal {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return Journal(url: dir.appendingPathComponent("\(stamp).jsonl"))
    }

    public static var directory: URL { Support.directory.appendingPathComponent("journal", isDirectory: true) }

    func record(_ result: FoldResult) {
        guard var line = try? JSONEncoder().encode(result) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    static func rewrite(_ url: URL, with entries: [FoldResult]) {
        var data = Data()
        for e in entries {
            guard let line = try? JSONEncoder().encode(e) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
    }

    public func entries() -> [FoldResult] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(FoldResult.self, from: Data($0.utf8)) }
    }
}

/// Gives a folded file its own private copy of its data again. Costs the space back.
public enum Unfolder {
    public static func unfold(_ path: String) -> Bool {
        guard let before = FileSystem.lstat(path), let original = FileSystem.metadata(path) else { return false }
        let open = OpenFiles()
        guard !open.isOpenForWriting(before) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        let temp = "\(dir)/.twinfold-\(UUID().uuidString.prefix(8))"
        Safety.inFlight(temp)
        defer { Safety.inFlight(nil) }
        // COPYFILE_DATA without COPYFILE_CLONE writes real, unshared blocks.
        guard copyfile(path, temp, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_NOFOLLOW)) == 0 else {
            FileSystem.removeTemp(temp)
            return false
        }
        guard FileSystem.copyMetadata(from: path, to: temp), FileSystem.metadata(temp) == original,
            FileSystem.contentsEqual(temp, path), FileSystem.lstat(path) == before, rename(temp, path) == 0
        else {
            FileSystem.removeTemp(temp)
            return false
        }
        return true
    }
}

/// Where Twinfold keeps its journal and last scan. `TWINFOLD_SUPPORT_DIR` overrides it (used by tests).
public enum Support {
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["TWINFOLD_SUPPORT_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Twinfold", isDirectory: true)
    }
}
