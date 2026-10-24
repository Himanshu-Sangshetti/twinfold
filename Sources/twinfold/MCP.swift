import Foundation
import TwinfoldCore

/// `twinfold mcp`: a Model Context Protocol server over stdio, so agents (Claude Code, Claude Desktop, Cursor) can
/// scan, explain, save and undo. Saving is two-step on purpose: a dry run first, then `confirm: true`.
enum MCPServer {
    static let tools: [[String: Any]] = [
        tool("scan", "Find identical files that could share storage (APFS clones). Changes nothing. Saves the result for the other tools.",
             ["paths": array("Folders to scan; defaults to the home folder"),
              "min_size": string("Ignore files smaller than this, like 64K or 10MB (default 64K)"),
              "exclude": array("Folders to leave out")]),
        tool("list_sets", "List sets of identical files from the last scan, biggest first. Each set has an id for show_set and save.",
             ["query": string("Only sets whose file name or path contains this"),
              "limit": integer("How many to return (default 20)")]),
        tool("show_set", "Every file in one set, where each copy lives, and what saving would change on disk.",
             ["id": integer("Set id from list_sets")], required: ["id"]),
        tool("check_set", "Re-read one set's files from disk now: all present, identical (SHA-256), and how many times the data is stored.",
             ["id": integer("Set id from list_sets")], required: ["id"]),
        tool("save", "Make identical files share storage. No file is removed, moved or renamed; it can be undone. Without confirm: true it only describes what would change. Ask the user before confirming.",
             ["ids": array("Set ids to save; omit for every set from the last scan", items: "integer"),
              "confirm": boolean("true to actually save; false or missing for a dry run")]),
        tool("history", "Past runs (from the app, the command line or Automatic), newest first, with what each saved.", [:]),
        tool("undo", "Give every file in a past run its own copy again (uses the space back). Needs confirm: true.",
             ["run": string("Run id from history"), "confirm": boolean("true to actually undo")], required: ["run"]),
    ]

    static func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = message["method"] as? String else { continue }
            let id = message["id"]
            guard id != nil else { continue }  // notifications need no answer
            let params = message["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                reply(id, ["protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
                           "capabilities": ["tools": [:]],
                           "serverInfo": ["name": "twinfold", "version": version],
                           "instructions": "Twinfold frees disk space on a Mac by letting identical files share storage. Start with scan, explain with list_sets/show_set, and always run save without confirm first and ask the user before save with confirm: true."])
            case "ping": reply(id, [:])
            case "tools/list": reply(id, ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let input = params["arguments"] as? [String: Any] ?? [:]
                let (text, isError) = call(name, input)
                reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
            default:
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Unknown method \(method)"]])
            }
        }
    }

    static func call(_ name: String, _ input: [String: Any]) -> (String, Bool) {
        switch name {
        case "scan": return (scanTool(input), false)
        case "list_sets": return withReport { listSets($0, input) }
        case "show_set": return withReport { showSet($0, input) }
        case "check_set": return withReport { checkSet($0, input) }
        case "save": return withReport { save($0, input) }
        case "history": return (history(), false)
        case "undo": return undo(input)
        default: return ("Unknown tool \(name).", true)
        }
    }

    // MARK: Tools

    static func scanTool(_ input: [String: Any]) -> String {
        let paths = (input["paths"] as? [String] ?? []).map { ($0 as NSString).expandingTildeInPath }
        var options = ScanOptions(roots: paths.isEmpty ? [NSHomeDirectory()] : paths)
        if let size = (input["min_size"] as? String).flatMap(Format.parseSize) { options.minSize = size }
        options.excludes = (input["exclude"] as? [String] ?? []).map { ($0 as NSString).expandingTildeInPath }
        options.excludes += Settings.load().leaveAlone
        let started = Date()
        let report = Scanner(options: options).run()
        report.save()
        let sets = report.actionable
        var lines = ["\(Format.bytes(report.reclaimableBytes)) could be saved: \(Format.count(sets.count, "set", "sets")) of identical files among \(report.filesScanned.formatted()) files (\(Int(Date().timeIntervalSince(started))) s). Nothing was changed."]
        if report.alreadySharedBytes > 0 { lines.append("\(Format.bytes(report.alreadySharedBytes)) already shares storage.") }
        let byKind = Breakdown(report: report).byKind(Breakdown(report: report).copies)
        if !byKind.isEmpty {
            lines.append("By kind: " + byKind.map { "\($0.kind.rawValue) \(Format.bytes($0.bytes))" }.joined(separator: ", ") + ".")
        }
        lines.append("Biggest sets:")
        lines += sets.prefix(10).enumerated().map { line(for: $1, id: $0) }
        return lines.joined(separator: "\n")
    }

    static func listSets(_ report: ScanReport, _ input: [String: Any]) -> String {
        let breakdown = Breakdown(report: report)
        let found = breakdown.find(input["query"] as? String ?? "", among: Array(breakdown.groups.indices), sort: .saved)
        let limit = input["limit"] as? Int ?? 20
        guard !found.isEmpty else { return "No sets match." }
        return (["\(Format.count(found.count, "set", "sets")) (showing \(min(limit, found.count))):"]
            + found.prefix(limit).map { line(for: breakdown.groups[$0], id: $0) }).joined(separator: "\n")
    }

    static func showSet(_ report: ScanReport, _ input: [String: Any]) -> String {
        guard let group = set(report, input) else { return "No set with that id. Run list_sets." }
        var lines = ["\((group.keeper as NSString).lastPathComponent): \(group.files.count) identical files, \(Format.bytes(group.size)) each.",
                     "On disk now: stored \(group.clusters.count) times (\(Format.bytes(group.size * Int64(group.clusters.count)))). After saving: stored once (\(Format.bytes(group.size))). Every file stays at its path."]
        lines += group.files.map { "- \(Format.path($0))" }
        return lines.joined(separator: "\n")
    }

    static func checkSet(_ report: ScanReport, _ input: [String: Any]) -> String {
        guard let group = set(report, input) else { return "No set with that id. Run list_sets." }
        let check = Proof.check(group.files, size: group.size)
        return [
            check.missing == 0 ? "All \(check.files.count) files are in place." : "\(check.missing) files changed or are gone since the scan.",
            check.allIdentical ? "Identical byte for byte (SHA-256 \(check.files.first?.sha256?.prefix(16) ?? "")…)." : "Not all identical any more; save would skip them.",
            check.storedCopies == 1 ? "Stored once on disk." : "Stored \(check.storedCopies) separate times on disk.",
        ].joined(separator: "\n")
    }

    static func save(_ report: ScanReport, _ input: [String: Any]) -> String {
        let breakdown = Breakdown(report: report)
        let ids = (input["ids"] as? [Int]) ?? Array(breakdown.groups.indices)
        let chosen = breakdown.copies.filter { ids.contains($0.group) }
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.size }
        guard !chosen.isEmpty else { return "Nothing to save for those ids." }
        guard input["confirm"] as? Bool == true else {
            return "Dry run: saving would let \(Format.count(chosen.count, "file", "files")) in \(Format.count(Set(chosen.map(\.group)).count, "set", "sets")) share storage with their twins, saving about \(Format.bytes(bytes)). No file is removed, moved or renamed, and it can be undone. Call save again with confirm: true once the user agrees."
        }
        let summary = Reclaimer().reclaim(breakdown.groupsToFold(chosen))
        try? FileManager.default.removeItem(at: ScanReport.savedURL)
        let skipped = summary.results.count - summary.folded.count
        return "Saved \(Format.bytes(max(summary.freeAfter - summary.freeBefore, 0))) (measured on disk). \(Format.count(summary.folded.count, "file now shares", "files now share")) storage; each was compared byte for byte first."
            + (skipped > 0 ? " \(skipped) changed meanwhile and were left alone." : "")
            + " Undo with run id \(summary.journal?.deletingPathExtension().lastPathComponent ?? "?")."
    }

    static func history() -> String {
        let runs = Run.all()
        guard !runs.isEmpty else { return "No runs yet." }
        return runs.map {
            "- \($0.journal.deletingPathExtension().lastPathComponent): \($0.date.formatted(date: .abbreviated, time: .shortened)), \(Format.count($0.files, "file", "files")), \(Format.bytes($0.bytes))"
        }.joined(separator: "\n")
    }

    static func undo(_ input: [String: Any]) -> (String, Bool) {
        guard let id = input["run"] as? String,
              let run = Run.all().first(where: { $0.journal.deletingPathExtension().lastPathComponent == id })
        else { return ("No run with that id. Call history.", true) }
        guard input["confirm"] as? Bool == true else {
            return ("Undoing \(id) gives \(Format.count(run.files, "file", "files")) its own copy again and needs about \(Format.bytes(run.bytes)) of free space. Call undo again with confirm: true once the user agrees.", false)
        }
        let r = run.undo()
        var text = "\(Format.count(r.restored, "file has its", "files have their")) own copy again."
        if r.gone > 0 { text += " \(r.gone) were deleted since." }
        if r.stoppedForSpace { text += " Stopped to keep free space; \(r.remaining) files (\(Format.bytes(r.remainingBytes))) remain. Free space and undo again." }
        return (text, false)
    }

    // MARK: Helpers

    static func withReport(_ body: (ScanReport) -> String) -> (String, Bool) {
        guard let report = ScanReport.load() else { return ("No scan yet. Call scan first.", true) }
        return (body(report), false)
    }

    static func set(_ report: ScanReport, _ input: [String: Any]) -> DuplicateGroup? {
        let groups = report.actionable
        guard let id = input["id"] as? Int, groups.indices.contains(id) else { return nil }
        return groups[id]
    }

    static func line(for group: DuplicateGroup, id: Int) -> String {
        "[\(id)] \((group.keeper as NSString).lastPathComponent): \(group.files.count)× \(Format.bytes(group.size)), saves \(Format.bytes(group.reclaimableBytes)), e.g. \(Format.path((group.keeper as NSString).deletingLastPathComponent))"
    }

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }
    static func string(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    static func integer(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    static func boolean(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    static func array(_ d: String, items: String = "string") -> [String: Any] {
        ["type": "array", "items": ["type": items], "description": d]
    }

    static func reply(_ id: Any?, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]) }

    static func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
