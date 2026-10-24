import SwiftUI
import TwinfoldCore

/// The right-hand pane: shows exactly which files are identical, where each one is, what changes on disk, and
/// live proof read from the files themselves.
struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            Group {
                switch model.focus {
                case .group(let index):
                    if let group = model.breakdown?.groups[safe: index] { GroupDetail(group: group) }
                case .folder(let path):
                    FolderDetail(path: path)
                case nil:
                    Text("Select a folder or a file to see its identical copies.")
                        .foregroundStyle(Color.quiet)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.025))
    }
}

struct GroupDetail: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: Icons.icon(for: group.keeper)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text((group.keeper as NSString).lastPathComponent)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Text("\(group.files.count) identical files · \(Format.bytes(group.size)) each")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.quiet)
                }
            }

            StorageDiagram(group: group)

            ProofSection(group: group)

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Where they are")
                ForEach(group.files, id: \.self) { path in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Format.path(path))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.quiet)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { model.reveal([path]) } label: {
                            Image(systemName: "arrow.up.forward.square").foregroundStyle(Color.quiet)
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                    }
                }
            }
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

/// Now vs after, per file: today each copy has its own block of disk; afterwards every file is still listed,
/// all pointing at one block.
struct StorageDiagram: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup
    private let rowHeight: CGFloat = 22
    private let shown = 5

    /// Row of the first file in each cluster: those own a block today; the rest already share it.
    private var owners: Set<Int> {
        var rows: Set<Int> = []
        var i = 0
        for cluster in group.clusters {
            rows.insert(i)
            i += cluster.count
        }
        return rows
    }

    var body: some View {
        let color = Kind.of(group.keeper).color
        let rows = Array(group.files.prefix(shown).enumerated())
        let extra = group.files.count - rows.count

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                SectionTitle(text: "File")
                Spacer()
                SectionTitle(text: "On disk now").frame(width: 84)
                SectionTitle(text: "After").frame(width: 70)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.offset) { _, path in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill").font(.system(size: 10)).foregroundStyle(Color.quiet)
                            Text(model.place(of: path))
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(height: rowHeight)
                    }
                    if extra > 0 {
                        Text("and \(Format.count(extra, "more file", "more files"))")
                            .font(.system(size: 11)).foregroundStyle(Color.quiet).frame(height: rowHeight)
                    }
                }
                Spacer(minLength: 8)
                VStack(spacing: 4) {
                    ForEach(rows, id: \.offset) { i, _ in
                        let owns = owners.contains(i)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.opacity(owns ? 0.9 : 0))
                            .strokeBorder(color.opacity(owns ? 0 : 0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .frame(width: 56, height: rowHeight)
                            .help(owns ? "Its own \(Format.bytes(group.size)) on disk" : "Already shares space with the file above")
                    }
                    if extra > 0 { Text("…").foregroundStyle(Color.quiet).frame(height: rowHeight) }
                }
                .frame(width: 84)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.9))
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                    .frame(width: 70)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                Text("Space used").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(Format.bytes(group.size * Int64(group.clusters.count)))
                    .frame(width: 84)
                Text(Format.bytes(group.size)).foregroundStyle(Color.fold)
                    .frame(width: 70)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text("Every file in the list stays where it is, with its own name. Afterwards they all read the same data from one place on disk. If one is ever changed, only that file gets its own copy again.")
                .font(.system(size: 12))
                .foregroundStyle(Color.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// "Don't trust the scan, check now": reads every file again and reports what's on disk this second.
struct ProofSection: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup
    /// Small sets are checked as soon as they're shown; big ones wait for a click.
    private var automatic: Bool {
        group.size * Int64(group.files.count) <= 400_000_000
            && ProcessInfo.processInfo.environment["TWINFOLD_CAPTURE"] == nil  // screenshots use made-up paths
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Checked on disk just now")
            if let check = model.check {
                ProofLine(ok: check.missing == 0,
                          text: check.missing == 0
                            ? "All \(check.files.count) files are in place"
                            : "\(Format.count(check.missing, "file has", "files have")) changed or gone since the scan; Twinfold will skip it")
                ProofLine(ok: check.allIdentical,
                          text: check.allIdentical
                            ? "Identical byte for byte (SHA-256 \(check.files.first?.sha256?.prefix(12) ?? "")…)"
                            : "Not all identical any more; Twinfold re-checks and skips these")
                ProofLine(ok: true, neutral: check.storedCopies > 1,
                          text: check.storedCopies == 1
                            ? "Stored once on disk"
                            : "Stored \(check.storedCopies) separate times on disk")
            } else if model.checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading all \(group.files.count) files…").foregroundStyle(Color.quiet)
                }
                .font(.system(size: 12))
            } else {
                Button("Check these \(group.files.count) files now (reads \(Format.bytes(group.size * Int64(group.files.count))))") {
                    model.runCheck(group)
                }
                .controlSize(.small)
            }
        }
        .task(id: group.keeper) {
            if automatic, model.check == nil, !model.checking { model.runCheck(group) }
        }
    }
}

struct ProofLine: View {
    let ok: Bool
    var neutral = false
    let text: String
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: neutral ? "circle.fill" : ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(neutral ? Color.quiet : ok ? Color.fold : Color.orange)
                .font(.system(size: neutral ? 6 : 12))
                .frame(width: 14)
        }
        .font(.system(size: 12))
    }
}

struct FolderDetail: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        let groups = model.groups(in: path)
        let all = model.breakdown?.groups ?? []
        let prefix = path + "/"
        // Where the twins of this folder's files live, outside it.
        var places: [String: Int] = [:]
        var here = 0, inside = 0
        for g in groups {
            let mine = all[g].files.filter { $0.hasPrefix(prefix) }.count
            here += mine
            if mine > 1 { inside += 1 }
            for p in Set(all[g].files.filter { !$0.hasPrefix(prefix) }.map { model.place(of: $0) }) {
                places[p, default: 0] += 1
            }
        }
        let topPlaces = places.sorted { $0.value > $1.value }.prefix(8)

        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: Icons.folder).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent).font(.system(size: 15, weight: .semibold))
                    Text(Format.path(path)).font(.system(size: 11)).foregroundStyle(Color.quiet)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { model.reveal([path]) } label: {
                    Image(systemName: "arrow.up.forward.square").foregroundStyle(Color.quiet)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }

            Text("\(Format.count(here, "file in this folder has", "files in this folder have")) an exact copy somewhere else.")
                .font(.system(size: 13))

            if !topPlaces.isEmpty || inside > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: "Files here have an exact copy in")
                    if inside > 0 {
                        PlaceRow(name: "inside this folder", count: inside)
                    }
                    ForEach(topPlaces, id: \.key) { place, count in PlaceRow(name: place, count: count) }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(text: "Biggest ones · click to see each copy").padding(.bottom, 4)
                ForEach(groups.prefix(40), id: \.self) { g in
                    let group = all[g]
                    Button { model.focus = .group(g) } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: Icons.icon(for: group.keeper)).resizable().frame(width: 16, height: 16)
                            Text((group.keeper as NSString).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text("\(group.files.count)×").foregroundStyle(.tertiary)
                            Text(Format.bytes(group.size)).foregroundStyle(Color.quiet).frame(width: 64, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12).monospacedDigit())
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if groups.count > 40 {
                    Text("and \(groups.count - 40) more in the Files tab").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct PlaceRow: View {
    let name: String
    let count: Int
    var body: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(Color.quiet).font(.system(size: 11))
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Format.count(count, "match", "matches")).foregroundStyle(Color.quiet)
        }
        .font(.system(size: 12).monospacedDigit())
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
