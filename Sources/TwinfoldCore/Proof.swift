import Foundation

/// Live evidence for a set of identical files, read from disk right now: is each file still there, what are its
/// contents (SHA-256), and how many separate times is that data actually stored.
public struct GroupCheck: Sendable {
    public struct File: Sendable {
        public let path: String
        public let exists: Bool
        public let sha256: String?
        /// Where the data lives on disk; files with the same value share storage.
        public let storage: String?
    }

    public let files: [File]

    /// Every file is present and has exactly the same contents.
    public var allIdentical: Bool {
        guard let first = files.first?.sha256 else { return false }
        return files.allSatisfy { $0.exists && $0.sha256 == first }
    }

    public var missing: Int { files.filter { !$0.exists }.count }

    /// How many separate copies of the data the disk holds for these files.
    public var storedCopies: Int { Set(files.compactMap(\.storage)).count }
}

public enum Proof {
    /// Reads every file in full; runs in parallel. Safe to call any time, changes nothing.
    public static func check(_ paths: [String], size: Int64) -> GroupCheck {
        let results = Results(count: paths.count)
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let path = paths[i]
            let exists = FileSystem.lstat(path)?.size == size
            results.set(i, GroupCheck.File(
                path: path, exists: exists,
                sha256: exists ? Hashing.full(path) : nil,
                storage: exists ? FileSystem.extentKey(path, size: size) : nil))
        }
        return GroupCheck(files: results.all)
    }

    private final class Results: @unchecked Sendable {
        private var items: [GroupCheck.File?]
        private let lock = NSLock()
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ file: GroupCheck.File) { lock.withLock { items[i] = file } }
        var all: [GroupCheck.File] { items.compactMap { $0 } }
    }
}
