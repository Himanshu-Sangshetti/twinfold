import Foundation
import TwinfoldCore

let version = "0.6.0"

let help = """
    twinfold \(version): free disk space on your Mac without deleting anything.

    Twinfold finds files with identical contents and turns the copies into APFS clones:
    every file stays where it is, but the copies share one set of blocks on disk.

    USAGE
      twinfold scan    [PATH...]   Show how much space identical files could share (changes nothing)
      twinfold reclaim [PATH...]   Let identical files share space and free it
      twinfold undo    [JOURNAL]   Give every folded file its own copy again (uses the space back)
      twinfold mcp                 Run as an MCP server for AI agents (Claude Code, Cursor, Claude Desktop)

    OPTIONS
      --min-size SIZE     Ignore files smaller than SIZE (default 64K)
      --include-library   Also look inside ~/Library (off by default)
      --exclude PATH      Leave PATH out (repeatable)
      --top N             Show the N biggest groups (default 10)
      --json              Machine-readable output
      --dry-run           With reclaim: list what would change, change nothing
      -y, --yes           With reclaim: don't ask for confirmation

    PATH defaults to your home folder.
    """

struct Args {
    var command = "help"
    var paths: [String] = []
    var options = ScanOptions(roots: [])
    var top = 10
    var json = false
    var dryRun = false
    var yes = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("twinfold: \(message)\n".utf8))
    exit(2)
}

func parse(_ argv: [String]) -> Args {
    var args = Args()
    var it = argv.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) needs a value") }
        return v
    }
    if let first = it.next() { args.command = first }
    while let a = it.next() {
        switch a {
        case "--min-size":
            guard let s = Format.parseSize(value(a)) else { fail("can't read size") }
            args.options.minSize = max(1, s)
        case "--include-library": args.options.includeLibrary = true
        case "--exclude": args.options.excludes.append(value(a))
        case "--top": args.top = Int(value(a)) ?? 10
        case "--json": args.json = true
        case "--dry-run", "-n": args.dryRun = true
        case "-y", "--yes": args.yes = true
        case "-h", "--help": args.command = "help"
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)") }
            args.paths.append(a)
        }
    }
    return args
}

let isTTY = isatty(STDERR_FILENO) == 1

func status(_ text: String) {
    guard isTTY else { return }
    FileHandle.standardError.write(Data("\r\u{1B}[2K\(text)".utf8))
}

func clearStatus() { status("") }

func scan(_ args: Args) -> ScanReport {
    var options = args.options
    options.roots = args.paths.isEmpty ? [NSHomeDirectory()] : args.paths.map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
    }
    let report = Scanner(options: options) { phase, done, total in
        switch phase {
        case .walking: status("Looking at \(done.formatted()) files…")
        case .comparing: status("Comparing \(done.formatted()) of \(total.formatted()) possible matches…")
        case .done: clearStatus()
        }
    }.run()
    clearStatus()
    return report
}

func printReport(_ report: ScanReport, top: Int) {
    let actionable = report.actionable
    print("")
    if actionable.isEmpty {
        print("  Nothing to reclaim. \(report.filesScanned.formatted()) files checked, no identical files taking extra space.")
        if report.alreadySharedBytes > 0 {
            print("  \(Format.bytes(report.alreadySharedBytes)) of identical files already share space.")
        }
        print("")
        return
    }
    let copies = actionable.reduce(0) { $0 + $1.clusters.count - 1 }
    print("  \(Format.bytes(report.reclaimableBytes)) can be freed, nothing deleted.")
    print("  \(Format.count(copies, "identical file", "identical files")) can share space, in \(Format.count(actionable.count, "set", "sets"))"
        + " · \(report.filesScanned.formatted()) files checked in \(Int(report.seconds))s")
    if report.alreadySharedBytes > 0 {
        print("  (\(Format.bytes(report.alreadySharedBytes)) of identical files already share space)")
    }
    print("")
    for group in actionable.prefix(top) {
        let name = (group.keeper as NSString).lastPathComponent
        print("  \(Format.bytes(group.reclaimableBytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(name)"
            + "  ×\(group.files.count)")
        for path in group.files.prefix(4) { print("            \(Format.path(path))") }
        if group.files.count > 4 { print("            … and \(group.files.count - 4) more") }
    }
    if actionable.count > top { print("\n  … and \(actionable.count - top) more sets") }
    print("")
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try! encoder.encode(value), as: UTF8.self))
}

func confirm(_ question: String) -> Bool {
    print(question, terminator: " [y/N] ")
    guard let line = readLine() else { return false }
    return ["y", "yes"].contains(line.lowercased())
}

let args = parse(Array(CommandLine.arguments.dropFirst()))

switch args.command {
case "scan":
    let report = scan(args)
    if args.json {
        struct Out: Encodable {
            let reclaimableBytes: Int64, alreadySharedBytes: Int64, filesScanned: Int, seconds: Double
            let groups: [DuplicateGroup]
        }
        printJSON(Out(reclaimableBytes: report.reclaimableBytes, alreadySharedBytes: report.alreadySharedBytes,
                      filesScanned: report.filesScanned, seconds: report.seconds, groups: report.actionable))
    } else {
        printReport(report, top: args.top)
        if report.reclaimableBytes > 0 { print("  Run `twinfold reclaim` to free it.\n") }
    }

case "reclaim", "fold":
    let report = scan(args)
    let groups = report.actionable
    if args.dryRun {
        if args.json { printJSON(groups) } else {
            printReport(report, top: args.top)
            print("  Dry run: nothing changed.\n")
        }
        exit(0)
    }
    if !args.json { printReport(report, top: args.top) }
    guard !groups.isEmpty else { exit(0) }
    if !args.yes {
        guard isatty(STDIN_FILENO) == 1 else { fail("pass --yes to reclaim without a prompt") }
        guard confirm("  Let these files share space and free \(Format.bytes(report.reclaimableBytes))?") else {
            print("  Nothing changed.")
            exit(0)
        }
    }
    let summary = Reclaimer { done, total, _ in status("Folding \(done.formatted()) of \(total.formatted())…") }
        .reclaim(groups)
    clearStatus()
    let problems = summary.results.filter { $0.outcome != .folded }
    if args.json {
        printJSON(summary.results)
    } else {
        print("")
        print("  Freed \(Format.bytes(max(0, summary.freeAfter - summary.freeBefore))). "
            + "\(summary.folded.count.formatted()) files folded, nothing deleted.")
        if !problems.isEmpty {
            print("  \(problems.count) left as they were (changed or protected while we worked).")
        }
        if let journal = summary.journal, !summary.folded.isEmpty {
            print("  Undo any time: twinfold undo \"\(Format.path(journal.path))\"")
        }
        print("")
    }

case "undo":
    let url: URL
    if let path = args.paths.first {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else {
        let files = (try? FileManager.default.contentsOfDirectory(at: Journal.directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        guard let latest = files?.last else { fail("no journal found") }
        url = latest
    }
    let entries = Journal(url: url).entries()
    let cost = entries.reduce(Int64(0)) { $0 + $1.freedBytes }
    print("\n  Undoing \(entries.count) folds from \(url.lastPathComponent). This uses \(Format.bytes(cost)) again.")
    if !args.yes, isatty(STDIN_FILENO) == 1, !confirm("  Continue?") { exit(0) }
    let result = Run(journal: url, date: Date(), files: entries.count, bytes: cost).undo { done, total in
        status("Restoring \(done) of \(total)…")
    }
    clearStatus()
    print("  \(Format.count(result.restored, "file has its", "files have their")) own copy again.")
    if result.gone > 0 { print("  \(Format.count(result.gone, "file was", "files were")) deleted or moved since, nothing to restore.") }
    if result.failed > 0 { print("  \(Format.count(result.failed, "file", "files")) couldn't be restored right now (open or locked?). They stay in the journal; run undo again later.") }
    if result.stoppedForSpace {
        print("  Stopped to keep free space: \(Format.count(result.remaining, "file needs", "files need")) \(Format.bytes(result.remainingBytes)) more.")
        print("  Free some space, then run `twinfold undo \(url.path)` again to finish.")
    }
    print("")

case "mcp":
    MCPServer.run()

case "version", "--version", "-v":
    print("twinfold \(version)")

case "help", "-h", "--help":
    print(help)

default:
    fail("unknown command \(args.command). Try `twinfold help`.")
}
