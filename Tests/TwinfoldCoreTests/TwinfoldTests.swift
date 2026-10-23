import Darwin
import Foundation
import Testing

@testable import TwinfoldCore

/// Each test gets its own folder on the boot (APFS) volume.
final class Sandbox {
    let root: String

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("twinfold-tests-\(UUID().uuidString)").path
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        root = FileSystem.realPath(dir)
    }

    deinit {
        // Unlock anything a test locked, then remove.
        if let e = FileManager.default.enumerator(atPath: root) {
            for case let p as String in e { chflags("\(root)/\(p)", 0) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func file(_ name: String, _ bytes: [UInt8]) -> String {
        let path = "\(root)/\(name)"
        try! FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
        return path
    }

    func scan(minSize: Int64 = 1) -> ScanReport {
        var options = ScanOptions(roots: [root])
        options.minSize = minSize
        return Scanner(options: options).run()
    }
}

func random(_ count: Int, seed: UInt8 = 0) -> [UInt8] {
    var g = SystemRandomNumberGenerator()
    var bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &g) }
    bytes[0] = seed
    return bytes
}

func read(_ path: String) -> Data { FileManager.default.contents(atPath: path)! }

@Suite struct ScanTests {
    @Test func findsIdenticalFiles() {
        let box = Sandbox()
        let data = random(200_000)
        box.file("a/one.bin", data)
        box.file("b/two.bin", data)
        box.file("c/three.bin", data)
        box.file("other.bin", random(200_000))

        let report = box.scan()
        #expect(report.actionable.count == 1)
        #expect(report.actionable[0].files.count == 3)
        #expect(report.reclaimableBytes == 400_000)
    }

    @Test func sameSizeDifferentTailIsNotADuplicate() {
        let box = Sandbox()
        var a = random(300_000)
        box.file("a.bin", a)
        a[150_000] ^= 0xFF  // differs only in the middle: edges hash matches, full hash doesn't
        box.file("b.bin", a)
        #expect(box.scan().actionable.isEmpty)
    }

    @Test func existingClonesCountAsShared() {
        let box = Sandbox()
        let a = box.file("a.bin", random(100_000))
        #expect(clonefile(a, "\(box.root)/b.bin", 0) == 0)
        let report = box.scan()
        #expect(report.reclaimableBytes == 0)
        #expect(report.alreadySharedBytes == 100_000)
    }

    @Test func ignoresSmallFilesAndHardLinks() {
        let box = Sandbox()
        let data = random(10_000)
        box.file("small1", data)
        box.file("small2", data)
        #expect(box.scan(minSize: 64 * 1024).actionable.isEmpty)

        let big = box.file("big", random(100_000))
        #expect(link(big, "\(box.root)/big-link") == 0)
        #expect(box.scan(minSize: 64 * 1024).actionable.isEmpty)
    }
}

@Suite struct FoldTests {
    @Test func foldSharesStorageAndKeepsEveryFile() throws {
        let box = Sandbox()
        let data = random(500_000)
        let a = box.file("a.bin", data)
        let b = box.file("b.bin", data)
        let group = try #require(box.scan().actionable.first)

        let summary = Reclaimer(journal: nil).reclaim([group])
        #expect(summary.folded.count == 1)
        #expect(read(a) == Data(data))
        #expect(read(b) == Data(data))
        #expect(FileSystem.extentKey(a, size: 500_000) == FileSystem.extentKey(b, size: 500_000))
        #expect(box.scan().reclaimableBytes == 0)
    }

    @Test func foldKeepsTheFilesOwnMetadata() throws {
        let box = Sandbox()
        let data = random(100_000)
        let keeper = box.file("keeper.bin", data)
        let copy = box.file("copy.bin", data)
        chmod(copy, 0o600)
        setxattr(copy, "com.example.tag", "red", 3, 0, 0)
        setxattr(keeper, "com.example.keeper-only", "x", 1, 0, 0)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: copy)

        let result = Reclaimer(journal: nil).fold(copy, into: keeper, size: 100_000)
        #expect(result.outcome == .folded)

        let attrs = try FileManager.default.attributesOfItem(atPath: copy)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect((attrs[.modificationDate] as? Date) == old)
        #expect((attrs[.creationDate] as? Date) == old)
        var buf = [UInt8](repeating: 0, count: 8)
        #expect(getxattr(copy, "com.example.tag", &buf, 8, 0, 0) == 3)
        #expect(getxattr(copy, "com.example.keeper-only", nil, 0, 0, 0) == -1)
        #expect(FileSystem.extentKey(copy, size: 100_000) == FileSystem.extentKey(keeper, size: 100_000))
    }

    @Test func refusesWhenContentsDiffer() {
        let box = Sandbox()
        let a = box.file("a.bin", random(100_000, seed: 1))
        let b = box.file("b.bin", random(100_000, seed: 2))
        let before = read(b)
        let result = Reclaimer(journal: nil).fold(b, into: a, size: 100_000)
        #expect(result.outcome == .changed)
        #expect(read(b) == before)
        let leftovers = try! FileManager.default.contentsOfDirectory(atPath: box.root).filter { $0.hasPrefix(".twinfold") }
        #expect(leftovers.isEmpty)
    }

    @Test func leavesLockedFilesAlone() {
        let box = Sandbox()
        let data = random(100_000)
        let a = box.file("a.bin", data)
        let b = box.file("b.bin", data)
        chflags(b, UInt32(UF_IMMUTABLE))
        let result = Reclaimer(journal: nil).fold(b, into: a, size: 100_000)
        #expect(result.outcome == .skipped)
    }

    @Test func editingOneCopyNeverTouchesTheOther() throws {
        let box = Sandbox()
        let data = random(100_000)
        let a = box.file("a.bin", data)
        let b = box.file("b.bin", data)
        _ = Reclaimer(journal: nil).fold(b, into: a, size: 100_000)
        let handle = try #require(FileHandle(forWritingAtPath: b))
        handle.write(Data([1, 2, 3]))
        try handle.close()
        #expect(read(a) == Data(data))
        #expect(read(b) != Data(data))
    }

    @Test func journalAndUndoGiveFilesTheirOwnCopyBack() throws {
        let box = Sandbox()
        let data = random(200_000)
        box.file("a.bin", data)
        let b = box.file("b.bin", data)
        let journal = Journal(url: URL(fileURLWithPath: "\(box.root)/journal.jsonl"))
        let summary = Reclaimer(journal: journal).reclaim(box.scan().actionable)
        #expect(summary.folded.count == 1)

        let entries = journal.entries()
        #expect(entries.count == 1)
        #expect(Unfolder.unfold(entries[0].path))
        #expect(read(b) == Data(data))
        #expect(box.scan().reclaimableBytes == 200_000)
    }
}

@Suite struct FormatTests {
    @Test func sizes() {
        #expect(Format.bytes(33_200_000_000) == "33.2 GB")
        #expect(Format.bytes(812_000_000) == "812 MB")
        #expect(Format.parseSize("64K") == 64_000)
        #expect(Format.parseSize("1.5GB") == 1_500_000_000)
        #expect(Format.parseSize("4096") == 4096)
    }
}

@Suite struct BreakdownTests {
    @Test func kinds() {
        #expect(Kind.of("/u/app/node_modules/x/index.js") == .node)
        #expect(Kind.of("/u/p/.venv/lib/python3.12/site-packages/torch/lib/a.dylib") == .python)
        #expect(Kind.of("/u/Movies/clip.MOV") == .video)
        #expect(Kind.of("/u/Downloads/setup.dmg") == .archives)
        #expect(Kind.of("/u/notes/readme") == .other)
    }

    @Test func treeAttributesSpaceToWhereTheCopiesAre() {
        let box = Sandbox()
        let data = random(100_000)
        box.file("keep/a.bin", data)
        box.file("projects/one/deep/a.bin", data)
        box.file("projects/two/a.bin", data)
        let breakdown = Breakdown(report: box.scan(), root: box.root)
        let tree = breakdown.tree(breakdown.copies)
        #expect(tree.bytes == 200_000)
        #expect(tree.children.map(\.name) == ["projects"])
        let projects = tree.children[0]
        #expect(projects.children.map(\.name).sorted() == ["one/deep", "two"])
    }

    @Test func untickedCopiesAreNeverFolded() throws {
        let box = Sandbox()
        let data = random(100_000)
        box.file("a/x.bin", data)
        let b = box.file("b/x.bin", data)
        let c = box.file("c/x.bin", data)
        let breakdown = Breakdown(report: box.scan(), root: box.root)
        let selected = breakdown.copies.filter { !$0.path.hasPrefix(box.root + "/c/") }
        let groups = breakdown.groupsToFold(selected)
        #expect(groups.count == 1)
        #expect(!groups[0].files.contains(c))

        _ = Reclaimer(journal: nil).reclaim(groups)
        let keeper = groups[0].keeper
        #expect(FileSystem.extentKey(b, size: 100_000) == FileSystem.extentKey(keeper, size: 100_000)
            || b == keeper)
        #expect(FileSystem.extentKey(c, size: 100_000) != FileSystem.extentKey(keeper, size: 100_000))
    }
}
