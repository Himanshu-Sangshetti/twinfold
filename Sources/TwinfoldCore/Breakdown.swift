import Foundation

/// What a duplicate is, in words people use.
public enum Kind: String, CaseIterable, Sendable, Codable {
    case node = "Node packages"
    case python = "Python packages"
    case build = "Build files"
    case apps = "Apps"
    case images = "Images"
    case video = "Videos"
    case audio = "Audio"
    case archives = "Archives"
    case documents = "Documents"
    case other = "Other"

    public static func of(_ path: String) -> Kind {
        let parts = path.split(separator: "/")
        func has(_ names: Set<Substring>) -> Bool { parts.contains { names.contains($0) } }
        if has(["node_modules", "_npx", ".pnpm-store", ".bun"]) { return .node }
        if has(["site-packages", ".venv", "venv", "uv", ".conda", "conda", ".pyenv", "__pycache__", "pip"]) {
            return .python
        }
        if parts.contains(where: { $0.hasSuffix(".app") }) { return .apps }
        if has([".next", "DerivedData", ".build", "target", ".gradle", "PlayerDataCache", "ScriptAssemblies", "Bee",
                "ShaderCache", "Artifacts", "build", "dist", ".turbo", ".parcel-cache"]) {
            return .build
        }
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "raf",
             "psd", "exr", "hdr", "avif", "svg":
            return .images
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "mts", "prores":
            return .video
        case "mp3", "wav", "m4a", "aac", "flac", "aiff", "aif", "ogg", "opus", "caf":
            return .audio
        case "zip", "dmg", "pkg", "tar", "gz", "tgz", "7z", "rar", "iso", "xip", "xz", "zst", "bz2", "whl":
            return .archives
        case "pdf", "doc", "docx", "key", "pages", "numbers", "ppt", "pptx", "xls", "xlsx", "epub", "rtf":
            return .documents
        default:
            return .other
        }
    }
}

/// One copy that folding would free: a cluster of files that will be pointed at the keeper.
public struct Copy: Sendable, Identifiable {
    public let id: Int
    public let group: Int
    /// The file the space is attributed to (the cluster's first file).
    public let path: String
    public let size: Int64
    public let kind: Kind
}

/// A folder in the "where is the space" tree. Chains of single folders are merged ("a/b/c").
public final class FolderNode: Identifiable, @unchecked Sendable {
    public let path: String
    public var name: String
    public var bytes: Int64 = 0
    public var copies = 0
    public var children: [FolderNode] = []
    var index: [String: FolderNode] = [:]

    public var id: String { path }
    public var childrenOrNil: [FolderNode]? { children.isEmpty ? nil : children }

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// Everything the results screen needs, derived once from a scan.
public struct Breakdown: Sendable {
    public let groups: [DuplicateGroup]
    public let copies: [Copy]
    public let root: String

    public init(report: ScanReport, root: String = NSHomeDirectory()) {
        groups = report.actionable
        self.root = FileSystem.realPath(root)
        var copies: [Copy] = []
        for (g, group) in groups.enumerated() {
            for cluster in group.clusters.dropFirst() {
                copies.append(Copy(id: copies.count, group: g, path: cluster[0], size: group.size,
                                   kind: Kind.of(cluster[0])))
            }
        }
        self.copies = copies
    }

    /// Bytes per kind among the given copies, biggest first.
    public func byKind(_ copies: [Copy]) -> [(kind: Kind, bytes: Int64)] {
        var totals: [Kind: Int64] = [:]
        for c in copies { totals[c.kind, default: 0] += c.size }
        return totals.map { ($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }
    }

    /// Folder tree of where the freeable space sits, relative to `root`.
    public func tree(_ copies: [Copy]) -> FolderNode {
        let top = FolderNode(path: root, name: (root as NSString).lastPathComponent)
        for c in copies {
            let rel = c.path.hasPrefix(root + "/") ? String(c.path.dropFirst(root.count + 1)) : c.path
            var node = top
            node.bytes += c.size
            node.copies += 1
            var current = root
            for part in rel.split(separator: "/").dropLast() {
                current += "/" + part
                let child = node.index[String(part)] ?? {
                    let n = FolderNode(path: current, name: String(part))
                    node.index[String(part)] = n
                    node.children.append(n)
                    return n
                }()
                child.bytes += c.size
                child.copies += 1
                node = child
            }
        }
        Self.finish(top)
        return top
    }

    private static func finish(_ node: FolderNode) {
        for child in node.children {
            // Merge a -> b -> c when each holds exactly the next.
            while child.children.count == 1, child.children[0].bytes == child.bytes {
                let only = child.children[0]
                child.name += "/" + only.name
                child.children = only.children
                child.index = only.index
            }
            finish(child)
        }
        node.children.sort { $0.bytes > $1.bytes }
        node.index = [:]
    }

    /// The groups to fold, keeping only the copies that are selected.
    public func groupsToFold(_ selected: [Copy]) -> [DuplicateGroup] {
        var byGroup: [Int: Set<String>] = [:]
        for c in selected { byGroup[c.group, default: []].insert(c.path) }
        return byGroup.keys.sorted().map { g in
            let group = groups[g]
            let keep = group.clusters.dropFirst().filter { byGroup[g]!.contains($0[0]) }
            return DuplicateGroup(size: group.size, clusters: [group.clusters[0]] + keep)
        }
    }

    /// Groups (indices, biggest first) with at least one file inside `folder`, among `visible` groups.
    public func groups(in folder: String, visible: Set<Int>? = nil) -> [Int] {
        let prefix = folder + "/"
        return groups.indices.filter { g in
            (visible?.contains(g) ?? true) && groups[g].files.contains { $0.hasPrefix(prefix) }
        }
    }

    public enum Sort: String, CaseIterable, Sendable { case saved = "Space saved", copies = "Copies", name = "Name" }

    /// Group indices matching `query` (in the file name or any path, case-insensitive), in the given order.
    public func find(_ query: String, among indices: [Int], sort: Sort) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = q.isEmpty ? indices : indices.filter { g in groups[g].files.contains { $0.lowercased().contains(q) } }
        switch sort {
        case .saved: return hits  // groups are already biggest first
        case .copies: return hits.sorted { groups[$0].files.count > groups[$1].files.count }
        case .name:
            return hits.sorted {
                (groups[$0].keeper as NSString).lastPathComponent.localizedStandardCompare(
                    (groups[$1].keeper as NSString).lastPathComponent) == .orderedAscending
            }
        }
    }

    /// Short "where" for a group: the distinct top-level folders its files live in.
    public func places(_ group: DuplicateGroup) -> [String] {
        var seen: [String] = []
        for path in group.files {
            let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
            let first = rel.split(separator: "/").first.map(String.init) ?? rel
            if !seen.contains(first) { seen.append(first) }
        }
        return seen
    }
}
