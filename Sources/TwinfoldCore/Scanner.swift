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

    struct Entry {
        let path: String
        let stat: FileSystem.Stat
    }

    public func run() -> ScanReport {
        let start = Date()
        var report = ScanReport()

        // 1. Walk and bucket by (volume, size). Only same-size files can match.
        var buckets: [String: [Entry]] = [:]
        var seenInodes = Set<String>()
        let uid = getuid()
        for root in options.roots {
            let rootPath = (root as NSString).standardizingPath
            guard FileSystem.supportsClones(rootPath) else { continue }
            walk(rootPath) { path in
                guard let st = FileSystem.lstat(path) else { return }
                report.filesScanned += 1
                report.bytesScanned += st.size
                guard st.size >= options.minSize else { return }
                guard st.flags & FileSystem.untouchableFlags == 0, st.links == 1, st.uid == uid else {
                    report.skipped += 1
                    return
                }
                guard seenInodes.insert("\(st.device):\(st.inode)").inserted else { return }
                buckets["\(st.device):\(st.size)", default: []].append(Entry(path: path, stat: st))
                if report.filesScanned % 2000 == 0 { progress?(.walking, report.filesScanned, 0) }
            }
        }

        // 2. Narrow with a cheap head+tail hash, then confirm with a full hash.
        let candidates = buckets.values.filter { $0.count > 1 }
        let quick = refine(candidates) { Hashing.edges($0.path, size: $0.stat.size) }
        let full = refine(quick, total: quick.reduce(0) { $0 + $1.count }) { Hashing.full($0.path) }

        // 3. For each identical set, find which copies already share storage.
        for set in full {
            var clusters: [String: [String]] = [:]
            for entry in set {
                let key = FileSystem.extentKey(entry.path, size: entry.stat.size) ?? "solo:\(entry.path)"
                clusters[key, default: []].append(entry.path)
            }
            let ordered = clusters.values.map { $0.sorted() }.sorted {
                $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0]
            }
            report.groups.append(DuplicateGroup(size: set[0].stat.size, clusters: ordered))
        }
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

    private func walk(_ root: String, _ visit: (String) -> Void) {
        let home = NSHomeDirectory()
        var skip = Set(options.excludes.map { ($0 as NSString).standardizingPath })
        skip.formUnion([
            "\(home)/.Trash",
            "\(home)/Library/Mobile Documents",  // iCloud Drive
            "\(home)/Library/CloudStorage",  // Dropbox, Google Drive, OneDrive
            "/System", "/private", "/dev", "/Volumes", "/Library", "/Applications", "/usr", "/bin", "/sbin",
        ])
        if !options.includeLibrary { skip.insert("\(home)/Library") }
        let rootDevice: dev_t = {
            var st = Darwin.stat()
            return Darwin.lstat(root, &st) == 0 ? st.st_dev : 0
        }()

        let url = URL(fileURLWithPath: root)
        if FileSystem.lstat(root) != nil { visit(root); return }
        guard let it = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [],
            errorHandler: { _, _ in true })
        else { return }
        for case let item as URL in it {
            let path = item.path
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if path != root && (skip.contains(path) || Self.isProtectedBundle(path)) {
                    it.skipDescendants()
                    continue
                }
                var st = Darwin.stat()
                if Darwin.lstat(path, &st) == 0, st.st_dev != rootDevice { it.skipDescendants() }
                continue
            }
            visit(path)
        }
    }

    /// Libraries whose apps keep their own databases about the files inside.
    static func isProtectedBundle(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "aplibrary", "backupdb", "sparsebundle"]
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
