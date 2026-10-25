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

    @Test func proofSeesIdenticalFilesGoFromTwoStoredCopiesToOne() throws {
        let box = Sandbox()
        let data = random(300_000)
        let a = box.file("a.bin", data)
        let b = box.file("b.bin", data)
        let before = Proof.check([a, b], size: 300_000)
        #expect(before.allIdentical)
        #expect(before.storedCopies == 2)

        let group = try #require(box.scan().actionable.first)
        _ = Reclaimer(journal: nil).reclaim([group])
        let after = Proof.check([a, b], size: 300_000)
        #expect(after.allIdentical)
        #expect(after.missing == 0)
        #expect(after.storedCopies == 1)
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

@Suite struct LicensingTests {
    @Test func aLicenseUnlocksPro() {
        var e = Entitlement()
        #expect(!e.unlocked)
        e.license = License(key: "k", instanceID: "i", email: "a@b.c", activatedAt: Date())
        #expect(e.unlocked)
    }

    @Test func activationAcceptsOnlyThisProduct() throws {
        func body(_ product: String) -> Data {
            Data("""
            {"id":"lki_1","business_id":"b","name":"Mac","license_key_id":"lk","created_at":"2026-10-24T00:00:00Z",
             "product":{"product_id":"\(product)","name":"Twinfold Pro"},
             "customer":{"customer_id":"c","name":"A","email":"a@example.com"}}
            """.utf8)
        }
        let license = try Activation.parse(body(Store.productID), status: 201, key: " KEY-1 \n")
        #expect(license.key == "KEY-1")
        #expect(license.email == "a@example.com")
        #expect(throws: ActivationError.wrongProduct) { try Activation.parse(body("pdt_other"), status: 201, key: "k") }
        #expect(throws: ActivationError.notFound) { try Activation.parse(Data(), status: 404, key: "k") }
        #expect(throws: ActivationError.limitReached) { try Activation.parse(Data(), status: 422, key: "k") }
    }
}

/// Talks to the real Dodo Payments license server; run with TWINFOLD_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TWINFOLD_NETWORK_TESTS"] == "1"))
struct LicenseServerTests {
    @Test func unknownKeyIsRejectedByTheServer() async {
        await #expect(throws: ActivationError.notFound) { try await Activation.activate(key: "twinfold-not-a-real-key") }
    }

    /// Needs a key from a test-mode purchase in TWINFOLD_TEST_LICENSE.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TWINFOLD_TEST_LICENSE"] != nil))
    func realKeyActivates() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["TWINFOLD_TEST_LICENSE"])
        let license = try await Activation.activate(key: key, machine: "twinfold test")
        #expect(!license.instanceID.isEmpty)
    }
}

@Suite(.serialized) struct AutomationTests {
    @Test func automaticRunSkipsFoldersLeftAloneAndCanBeUndoneFromHistory() throws {
        let box = Sandbox()
        setenv("TWINFOLD_SUPPORT_DIR", "\(box.root)/.support", 1)
        defer { unsetenv("TWINFOLD_SUPPORT_DIR") }
        let data = random(200_000)
        box.file("work/a.bin", data)
        let b = box.file("work/b.bin", data)
        box.file("keep/c.bin", data)

        var settings = Settings()
        settings.watched = [box.root]
        settings.leaveAlone = ["\(box.root)/keep"]
        let summary = AutoRun.run(settings: &settings)
        #expect(summary.folded.count == 1)
        #expect(settings.lastAutoSaved == 200_000)
        #expect(settings.lastAutoRun != nil)
        settings.save()
        #expect(Settings.load() == settings)

        let runs = Run.all()
        #expect(runs.count == 1)
        #expect(runs.first?.bytes == 200_000)
        #expect(runs.first?.undo().restored == 1)
        #expect(Run.all().isEmpty)
        #expect(read(b) == Data(data))
        #expect(box.scan().reclaimableBytes == 400_000)
    }

    @Test func launchAgentRunsTheAppWithAutoOnSchedule() throws {
        let box = Sandbox()
        setenv("TWINFOLD_LAUNCH_AGENTS", "\(box.root)/agents", 1)
        defer { unsetenv("TWINFOLD_LAUNCH_AGENTS") }
        try LaunchAgent.install(executable: "/Applications/Twinfold.app/Contents/MacOS/Twinfold", frequency: .weekly)
        let plist = try #require(NSDictionary(contentsOf: LaunchAgent.url))
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/Twinfold.app/Contents/MacOS/Twinfold", "--auto"])
        #expect((plist["StartCalendarInterval"] as? [String: Int])?["Weekday"] == 0)
        try LaunchAgent.install(executable: "/x", frequency: .off)
        #expect(!FileManager.default.fileExists(atPath: LaunchAgent.url.path))
    }
}

@Suite struct UndoTests {
    @Test func undoSkipsFilesDeletedSinceAndFinishesTheRun() throws {
        let box = Sandbox()
        let data = random(150_000)
        box.file("a.bin", data)
        let b = box.file("b.bin", data)
        let c = box.file("c.bin", data)
        let journal = Journal(url: URL(fileURLWithPath: "\(box.root)/run.jsonl"))
        _ = Reclaimer(journal: journal).reclaim(box.scan().actionable)
        try FileManager.default.removeItem(atPath: b)

        let result = Run(journal: journal.url, date: Date(), files: 2, bytes: 300_000).undo()
        #expect(result.restored == 1)
        #expect(result.gone == 1)
        #expect(!result.stoppedForSpace)
        #expect(read(c) == Data(data))
        #expect(!FileManager.default.fileExists(atPath: journal.url.path))
    }
}

/// Times the folder detail work on a real saved scan; run with TWINFOLD_PERF_REPORT=<scan.json>.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TWINFOLD_PERF_REPORT"] != nil))
struct PerformanceTests {
    @Test func folderDetailIsFastOnARealScan() throws {
        let path = try #require(ProcessInfo.processInfo.environment["TWINFOLD_PERF_REPORT"])
        let report = try #require(ScanReport.load(from: URL(fileURLWithPath: path)))
        var clock = ContinuousClock.now
        let breakdown = Breakdown(report: report)
        let tree = breakdown.tree(breakdown.copies)
        print("perf: breakdown+tree \(ContinuousClock.now - clock), \(breakdown.groups.count) sets")
        for folder in tree.children.prefix(5) {
            clock = .now
            let g = breakdown.groups(in: folder.path)
            print("perf: groups(in: \(folder.name)) \(g.count) sets in \(ContinuousClock.now - clock)")
        }
    }
}

@Suite struct FindTests {
    @Test func searchMatchesNamesAndFoldersAndSorts() {
        var report = ScanReport()
        report.groups = [
            DuplicateGroup(size: 100, clusters: [["/h/a/torch.dylib"], ["/h/b/torch.dylib"]]),
            DuplicateGroup(size: 10, clusters: [["/h/x/node_modules/zod.js"], ["/h/y/node_modules/zod.js"], ["/h/z/zod.js"]]),
            DuplicateGroup(size: 50, clusters: [["/h/photos/Beach.jpg"], ["/h/backup/Beach.jpg"]]),
        ]
        let b = Breakdown(report: report, root: "/h")
        let all = Array(b.groups.indices)
        #expect(b.find("", among: all, sort: .saved).map { b.groups[$0].size } == [100, 50, 10])
        #expect(b.find("NODE_modules", among: all, sort: .saved).map { b.groups[$0].size } == [10])
        #expect(b.find("backup", among: all, sort: .saved).map { b.groups[$0].size } == [50])
        #expect(b.find("", among: all, sort: .copies).first.map { b.groups[$0].size } == 10)
        #expect(b.find("", among: all, sort: .name).map { (b.groups[$0].keeper as NSString).lastPathComponent }
            == ["Beach.jpg", "torch.dylib", "zod.js"])
    }
}

@Suite struct UpdateSafetyTests {
    /// 0.7.0 wrote settings without `openAtLogin`; reading them must keep everything the user chose.
    @Test func settingsFrom070StillLoad() throws {
        let box = Sandbox()
        let url = URL(fileURLWithPath: "\(box.root)/settings.json")
        try #"{"automatic":"weekly","lastAutoSaved":5,"leaveAlone":["/a"],"watched":["/w"]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let s = Settings.load(from: url)
        #expect(s.automatic == .weekly && s.leaveAlone == ["/a"] && s.watched == ["/w"] && s.lastAutoSaved == 5)
        #expect(s.openAtLogin == nil && s.livesInMenuBar)
    }

    /// The app may have been open since before the overnight run; saving its older copy keeps the newer result.
    @Test func savingKeepsTheNewerAutomaticResult() {
        let box = Sandbox()
        let url = URL(fileURLWithPath: "\(box.root)/settings.json")
        var overnight = Settings()
        overnight.lastAutoRun = Date()
        overnight.lastAutoSaved = 900
        var app = Settings()
        app.lastAutoRun = Date(timeIntervalSinceNow: -86400)
        app.lastAutoSaved = 100
        overnight.save(to: url)
        app.leaveAlone = ["/new"]
        app.save(to: url)
        let s = Settings.load(from: url)
        #expect(s.lastAutoSaved == 900 && s.leaveAlone == ["/new"])
    }

    @Test func versionsCompareByNumber() {
        #expect(Updates.isNewer("0.7.2", than: "0.7.1"))
        #expect(Updates.isNewer("0.10.0", than: "0.9.9"))
        #expect(!Updates.isNewer("0.7.1", than: "0.7.1"))
        #expect(!Updates.isNewer("0.7.0", than: "0.7.1"))
        #expect(Updates.isNewer("1.0", than: "0.9.9"))
    }

    @Test func loginItemOpensTheAppHiddenThroughOpen() throws {
        let box = Sandbox()
        setenv("TWINFOLD_LAUNCH_AGENTS", "\(box.root)/agents", 1)
        defer { unsetenv("TWINFOLD_LAUNCH_AGENTS") }
        try LaunchAgent.setOpenAtLogin(app: "/Applications/Twinfold.app", true)
        let plist = try #require(NSDictionary(contentsOf: LaunchAgent.menuBarURL))
        #expect(plist["ProgramArguments"] as? [String]
            == ["/usr/bin/open", "-g", "-j", "-a", "/Applications/Twinfold.app", "--args", "--menubar"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        try LaunchAgent.setOpenAtLogin(app: "/Applications/Twinfold.app", false)
        #expect(!LaunchAgent.opensAtLogin)
        try LaunchAgent.install(executable: "/Applications/Twinfold.app/Contents/MacOS/Twinfold", frequency: .daily)
        #expect(LaunchAgent.installedExecutable == "/Applications/Twinfold.app/Contents/MacOS/Twinfold")
    }
}

@Suite struct OwnerTestFindings {
    /// Opened from Downloads, macOS ran a temporary copy; the schedule was pointed there and would have died.
    @Test func scheduleOnlyFromApplications() {
        #expect(InstallLocation.isStable("/Applications/Twinfold.app", home: "/Users/a"))
        #expect(InstallLocation.isStable("/Users/a/Applications/Twinfold.app", home: "/Users/a"))
        #expect(!InstallLocation.isStable("/Users/a/Downloads/Twinfold.app", home: "/Users/a"))
        #expect(!InstallLocation.isStable(
            "/private/var/folders/y2/x/T/AppTranslocation/E0E5/d/Twinfold.app", home: "/Users/a"))
    }

    /// Two copies of an app in Downloads made Twinfold try to change app bundles, which macOS blocks.
    @Test func appBundlesAreLeftAlone() {
        let box = Sandbox()
        let data = random(150_000)
        box.file("Downloads/One/Twinfold.app/Contents/Resources/font.ttf", data)
        box.file("Downloads/Two/Twinfold.app/Contents/Resources/font.ttf", data)
        box.file("Downloads/notes-a.bin", data)
        box.file("Downloads/notes-b.bin", data)
        let report = box.scan()
        #expect(report.groups.count == 1)
        #expect(report.groups.first?.files.allSatisfy { !$0.contains(".app/") } == true)
    }
}

@Suite struct UpdateInstallTests {
    @Test func readsTheChecksumForTheDownload() {
        let listing = """
            3e571d35b4e45c279c07a067ef1eca1189f5fb539299907c6a8b98d707933461  dist/Twinfold-0.7.1.zip
            0c0a4fd57e75cc38b9c13d501fecd274261fd574c19679bb618d6423209d0c46  dist/twinfold-0.7.1-macos.tar.gz
            """
        #expect(Updates.checksum(for: "Twinfold-0.7.1.zip", in: listing)
            == "3e571d35b4e45c279c07a067ef1eca1189f5fb539299907c6a8b98d707933461")
        #expect(Updates.checksum(for: "Twinfold-0.7.2.zip", in: listing) == nil)
    }
}

@Suite struct ScheduleTimeTests {
    @Test func runsAtTheChosenHourAndDefaultsToThree() throws {
        #expect(Settings().runHour == 3)
        var s = Settings()
        s.hour = 22
        #expect(s.runHour == 22)
        s.hour = 99
        #expect(s.runHour == 23)
        let plist = LaunchAgent.plist(executable: "/x", frequency: .daily, hour: 22)
        #expect((plist["StartCalendarInterval"] as? [String: Int])?["Hour"] == 22)
    }
}
