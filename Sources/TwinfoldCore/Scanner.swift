import CryptoKit
import Darwin
import Foundation

public struct ScanOptions: Sendable {
    public var roots: [String]
    /// Files smaller than this are ignored; the space they'd free is tiny.
    public var minSize: Int64 = 64 * 1024
    /// Scan inside ~/Library (app data, caches). Off by default.
    public var includeLibrary = false
    /// Extra paths to leave out.
    public var excludes: [String] = []

    public init(roots: [String]) { self.roots = roots }
}

/// A set of files with identical contents.
public struct DuplicateGroup: Sendable, Codable {
    public let size: Int64
    /// Files grouped by where their data lives. Files in the same cluster already share storage.
    public let clusters: [[String]]

    public init(size: Int64, clusters: [[String]]) {
        self.size = size
        self.clusters = clusters
    }

    public var files: [String] { clusters.flatMap { $0 } }
    /// The copy every other file will be folded into: the one already shared most widely.
    public var keeper: String { clusters[0][0] }
    public var reclaimableBytes: Int64 { size * Int64(clusters.count - 1) }
    public var alreadySharedBytes: Int64 { size * Int64(files.count - clusters.count) }
}

public struct ScanReport: Sendable, Codable {
    public var groups: [DuplicateGroup] = []
    public var filesScanned = 0
    public var bytesScanned: Int64 = 0
    public var skipped = 0
    public var seconds = 0.0

    public init() {}

    enum CodingKeys: String, CodingKey { case groups, filesScanned, bytesScanned, skipped, seconds }

    // Lenient, so `twinfold scan --json` output can be loaded back.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decode([DuplicateGroup].self, forKey: .groups)
        filesScanned = try c.decodeIfPresent(Int.self, forKey: .filesScanned) ?? 0
        bytesScanned = try c.decodeIfPresent(Int64.self, forKey: .bytesScanned) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
    }

    /// Where the app keeps the last scan, so results survive a relaunch.
    public static var savedURL: URL {
        Support.directory.appendingPathComponent("last-scan.json")
    }

    public func save(to url: URL = ScanReport.savedURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL = ScanReport.savedURL) -> ScanReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScanReport.self, from: data)
    }

    public var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    public var alreadySharedBytes: Int64 { groups.reduce(0) { $0 + $1.alreadySharedBytes } }
    /// Only the groups that would free space.
    public var actionable: [DuplicateGroup] {
        groups.filter { $0.reclaimableBytes > 0 }.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }
}

public enum ScanPhase: String, Sendable { case walking, comparing, done }

public struct Scanner {
    public typealias Progress = @Sendable (ScanPhase, _ done: Int, _ total: Int) -> Void

    let options: ScanOptions
    let progress: Progress?

    public init(options: ScanOptions, progress: Progress? = nil) {
        self.options = options
        self.progress = progress
    }

    /// What the walk collects, shared by the walker threads under `lock`.
    final class Found: @unchecked Sendable {
        let lock = NSLock()
        var buckets: [String: [Entry]] = [:]
        var inodes = Set<String>()
        var files = 0
        var bytes: Int64 = 0
        var skipped = 0
    }

    struct Entry {
        let path: String
        let stat: FileSystem.Stat
    }

    public func run() -> ScanReport {
        let start = Date()
        var report = ScanReport()

        // 1. Walk and bucket by (volume, size). Only same-size files can match.
        let found = Found()
        let uid = getuid()
        let walker = Walker(skip: skipSet(), threads: max(4, ProcessInfo.processInfo.activeProcessorCount))
        let minSize = options.minSize
        let progress = self.progress
        for root in options.roots {
            let rootPath = FileSystem.realPath(root)
            guard FileSystem.supportsClones(rootPath) else { continue }
            walker.walk(rootPath) { file in
                let st = file.stat
                found.lock.lock()
                defer { found.lock.unlock() }
                found.files += 1
                found.bytes += st.size
                if found.files % 5000 == 0 { progress?(.walking, found.files, 0) }
                guard st.size >= minSize else { return }
                guard st.flags & FileSystem.untouchableFlags == 0, st.links == 1, st.uid == uid else {
                    found.skipped += 1
                    return
                }
                guard found.inodes.insert("\(st.device):\(st.inode)").inserted else { return }
                found.buckets["\(st.device):\(st.size)", default: []].append(Entry(path: file.path, stat: st))
            }
        }
        report.filesScanned = found.files
        report.bytesScanned = found.bytes
        report.skipped = found.skipped

        // 2. Narrow with a cheap head+tail hash, then confirm with a full hash.
        let debug = ProcessInfo.processInfo.environment["TWINFOLD_DEBUG"] != nil
        func lap(_ name: String) {
            if debug { FileHandle.standardError.write(Data("\n[\(name)] \(String(format: "%.1f", Date().timeIntervalSince(start)))s\n".utf8)) }
        }
        lap("walk")
        let candidates = found.buckets.values.filter { $0.count > 1 }
        let quick = refine(candidates) { Hashing.edges($0.path, size: $0.stat.size) }
        lap("edges \(candidates.reduce(0) { $0 + $1.count }) files")
        let full = refine(quick, total: quick.reduce(0) { $0 + $1.count }) { Hashing.full($0.path) }
        lap("full \(quick.reduce(0) { $0 + $1.count }) files, \(quick.reduce(Int64(0)) { $0 + $1.reduce(0) { $0 + $1.stat.size } } / 1_000_000) MB")

        // 3. For each identical set, find which copies already share storage.
        let flat = full.enumerated().flatMap { i, set in set.map { (i, $0) } }
        var extents = [String?](repeating: nil, count: flat.count)
        extents.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: flat.count) { i in
                out[i] = FileSystem.extentKey(flat[i].1.path, size: flat[i].1.stat.size)
            }
        }
        var bySet = [[String: [String]]](repeating: [:], count: full.count)
        for (i, item) in flat.enumerated() {
            bySet[item.0][extents[i] ?? "solo:\(item.1.path)", default: []].append(item.1.path)
        }
        for (i, clusters) in bySet.enumerated() {
            let ordered = clusters.values.map { $0.sorted() }.sorted {
                $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0]
            }
            report.groups.append(DuplicateGroup(size: full[i][0].stat.size, clusters: ordered))
        }
        lap("extents")
        report.groups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
        report.seconds = Date().timeIntervalSince(start)
        progress?(.done, report.groups.count, report.groups.count)
        return report
    }

    /// Splits each bucket by a key computed in parallel, keeping only sub-buckets with 2+ files.
    private func refine(_ sets: [[Entry]], total: Int = 0, key: @escaping (Entry) -> String?) -> [[Entry]] {
        let flat = sets.enumerated().flatMap { i, set in set.map { (i, $0) } }
        var keys = [String?](repeating: nil, count: flat.count)
        let lock = NSLock()
        var done = 0
        keys.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: flat.count) { i in
                out[i] = key(flat[i].1)
                if total > 0 {
                    lock.lock(); done += 1; let d = done; lock.unlock()
                    if d % 50 == 0 || d == total { progress?(.comparing, d, total) }
                }
            }
        }
        var split: [String: [Entry]] = [:]
        for (i, item) in flat.enumerated() {
            guard let k = keys[i] else { continue }
            split["\(item.0)|\(k)", default: []].append(item.1)
        }
        return split.values.filter { $0.count > 1 }
    }

    /// Folders never entered: the user's exclusions plus places Twinfold must not touch.
    private func skipSet() -> Set<String> {
        let home = FileSystem.realPath(NSHomeDirectory())
        var skip = Set(options.excludes.map { FileSystem.realPath(($0 as NSString).expandingTildeInPath) })
        skip.formUnion([
            "\(home)/.Trash",
            "\(home)/Music/Music",  // Apple Music's media; reading it asks for media library access
            "\(home)/Movies/TV",  // the TV app's media
            "\(home)/Library/Mobile Documents",  // iCloud Drive
            "\(home)/Library/CloudStorage",  // Dropbox, Google Drive, OneDrive
            "/System", "/private/var/vm", "/dev", "/Volumes", "/Library", "/Applications", "/usr", "/bin", "/sbin",
        ])
        if !options.includeLibrary { skip.insert("\(home)/Library") }
        return skip
    }

    /// Libraries whose apps keep their own databases about the files inside, and apps themselves: macOS stops
    /// one app from changing another (Privacy & Security, App Management), so their files are left alone.
    static func isProtectedBundle(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "aplibrary", "backupdb", "sparsebundle",
                "app"]
            .contains(ext) || path.hasSuffix("/Backups.backupdb")
    }
}

enum Hashing {
    static func edges(_ path: String, size: Int64) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let chunk = 16 * 1024
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunk)
        for offset in [Int64(0), max(0, size - Int64(chunk))] {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, off_t(offset)) }
            guard n >= 0 else { return nil }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func full(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        while true {
            let n = FileSystem.readFully(fd, buffer, size)
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
