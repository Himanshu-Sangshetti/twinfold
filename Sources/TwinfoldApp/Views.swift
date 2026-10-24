import AppKit
import SwiftUI
import TwinfoldCore
import UniformTypeIdentifiers

extension Color {
    static let fold = Color(red: 0.12, green: 0.62, blue: 0.54)
    static let quiet = Color.secondary
}

extension Kind {
    /// One calm colour per kind; the biggest kinds get the strongest colours.
    var color: Color {
        switch self {
        case .node: Color(red: 0.12, green: 0.62, blue: 0.54)
        case .python: Color(red: 0.25, green: 0.47, blue: 0.85)
        case .build: Color(red: 0.93, green: 0.62, blue: 0.22)
        case .apps: Color(red: 0.58, green: 0.42, blue: 0.86)
        case .images: Color(red: 0.89, green: 0.40, blue: 0.47)
        case .video: Color(red: 0.84, green: 0.30, blue: 0.30)
        case .audio: Color(red: 0.95, green: 0.78, blue: 0.25)
        case .archives: Color(red: 0.55, green: 0.55, blue: 0.40)
        case .documents: Color(red: 0.35, green: 0.70, blue: 0.85)
        case .other: Color.gray.opacity(0.55)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .idle: IdleView()
            case .scanning: ScanningView()
            case .results: ResultsView()
            case .folding: FoldingView()
            case .done: DoneView()
            case .nothing: NothingView()
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 600, idealHeight: 700)
        .background(.background)
        .animation(.smooth(duration: 0.35), value: model.phase)
    }
}

// MARK: - Shared pieces

struct PrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 26)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Color.fold.opacity(disabled ? 0.4 : 1), in: Capsule())
                .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }
}

struct QuietButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.quiet)
    }
}

struct Centered<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 14) { content }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Headline: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Lede: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Color.quiet)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The breakdown: one bar where every segment is a kind of identical file, sized by the space it frees.
/// While folding, the bar drains from the left as space comes back.
struct KindBar: View {
    let kinds: [(kind: Kind, bytes: Int64)]
    var drained: Double = 0
    var highlight: Kind? = nil

    var body: some View {
        let total = max(1, kinds.reduce(0) { $0 + $1.bytes })
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(kinds, id: \.kind) { item in
                    Rectangle()
                        .fill(item.kind.color.opacity(highlight == nil || highlight == item.kind ? 1 : 0.25))
                        .frame(width: max(2, (geo.size.width - CGFloat(kinds.count - 1) * 2)
                            * CGFloat(item.bytes) / CGFloat(total)))
                }
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: geo.size.width * drained)
                    .background(.background)
                    .animation(.smooth(duration: 0.6), value: drained)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(height: 14)
    }
}

/// File-type icons, cached per extension so long lists stay fast.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if let hit = cache[ext] { return hit }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = image
        return image
    }

    static let folder = NSWorkspace.shared.icon(for: .folder)
}

// MARK: - Screens

struct IdleView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Centered {
            AppIcon().frame(width: 112, height: 112)
            Headline(text: "Free up space.\nDelete nothing.")
            Lede(text: "Twinfold finds identical files and lets them share one copy on disk. Every file stays exactly where it is, and you see everything before anything changes.")
            Spacer().frame(height: 8)
            PrimaryButton(title: "Scan \(model.rootName)") { model.scan() }
            QuietButton(title: "Choose Folders…") { model.chooseFolders() }
        }
    }
}

struct ScanningView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Centered {
            AppIcon().frame(width: 112, height: 112)
            Headline(text: model.toCompare > 0 ? "Comparing files" : "Looking through files")
            Text(model.toCompare > 0
                ? "\(model.compared.formatted()) of \(model.toCompare.formatted()) possible matches"
                : "\(model.filesSeen.formatted()) files so far")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(Color.quiet)
                .contentTransition(.numericText())
                .animation(.snappy, value: model.filesSeen)
            ProgressView(value: model.toCompare > 0 ? Double(model.compared) / Double(model.toCompare) : 0)
                .progressViewStyle(.linear)
                .tint(.fold)
                .frame(width: 280)
                .opacity(model.toCompare > 0 ? 1 : 0)
            Lede(text: "Nothing is changed while scanning.")
                .font(.system(size: 13))
        }
    }
}

struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let kinds = model.breakdown?.byKind(model.selected) ?? []
        VStack(alignment: .leading, spacing: 0) {
            // Summary
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Format.bytes(model.selectedBytes))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.selectedBytes)
                    Text("can be freed by letting \(model.selected.count.formatted()) identical files share space. Every file stays.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.quiet)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    PrimaryButton(title: "Free \(Format.bytes(model.selectedBytes))",
                                  disabled: model.selectedBytes == 0) { model.fold() }
                    HStack(spacing: 6) {
                        if let date = model.scannedAt {
                            Text("Scanned \(date.formatted(.relative(presentation: .named)))")
                                .foregroundStyle(.tertiary)
                        }
                        QuietButton(title: "Rescan") { model.scan() }
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)

            // Breakdown by kind
            KindBar(kinds: kinds, highlight: model.kindFilter)
                .padding(.horizontal, 28)
                .padding(.top, 22)
            KindLegend(kinds: kinds)
                .padding(.horizontal, 28)
                .padding(.top, 12)

            // Where
            HStack {
                Picker("", selection: $model.tab) {
                    ForEach(AppModel.Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("Untick anything you'd rather leave alone.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                HowItWorksButton()
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 10)

            Divider()
            switch model.tab {
            case .folders: FolderList()
            case .files: FileList()
            }
        }
    }
}

struct KindLegend: View {
    @Environment(AppModel.self) private var model
    let kinds: [(kind: Kind, bytes: Int64)]

    var body: some View {
        FlowLayout(spacing: 18, lineSpacing: 8) {
            ForEach(kinds, id: \.kind) { item in
                Button {
                    model.kindFilter = model.kindFilter == item.kind ? nil : item.kind
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(item.kind.color).frame(width: 8, height: 8)
                        Text(item.kind.rawValue)
                            .foregroundStyle(model.kindFilter == nil || model.kindFilter == item.kind
                                ? Color.primary : Color.quiet)
                        Text(Format.bytes(item.bytes)).foregroundStyle(Color.quiet).monospacedDigit()
                    }
                    .font(.system(size: 12, weight: model.kindFilter == item.kind ? .semibold : .regular))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.kindFilter != nil {
                QuietButton(title: "Show all") { model.kindFilter = nil }.font(.system(size: 12))
            }
        }
    }
}

struct FolderList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tree = model.breakdown?.tree(model.visibleCopies)
        let total = max(1, tree?.bytes ?? 1)
        List {
            if let tree {
                OutlineGroup(tree.children, children: \.childrenOrNil) { node in
                    FolderRow(node: node, total: total)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let node: FolderNode
    let total: Int64

    var body: some View {
        let included = model.isIncluded(folder: node.path)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { included }, set: { _ in model.toggle(folder: node.path) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(nsImage: Icons.folder).resizable().frame(width: 18, height: 18)
            Text(node.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(included ? Color.primary : Color.quiet)
            Spacer(minLength: 16)
            Text("\(node.copies.formatted()) copies")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            SizeBar(fraction: Double(node.bytes) / Double(total), muted: !included)
            Text(Format.bytes(node.bytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(included ? Color.primary : Color.quiet)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu { Button("Show in Finder") { model.reveal([node.path]) } }
    }
}

struct SizeBar: View {
    let fraction: Double
    var muted = false
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.07))
            Capsule().fill(Color.fold.opacity(muted ? 0.25 : 0.85))
                .frame(width: max(3, 90 * min(1, fraction)))
        }
        .frame(width: 90, height: 5)
    }
}

struct FileList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let visibleGroups = Set(model.visibleCopies.map(\.group))
        let groups = (model.breakdown?.groups ?? []).enumerated().filter { visibleGroups.contains($0.offset) }
        List {
            ForEach(groups, id: \.offset) { index, group in
                FileGroupRow(index: index, group: group)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

struct FileGroupRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let group: DuplicateGroup
    @State private var open = false

    var body: some View {
        let included = !model.excludedGroups.contains(index)
        DisclosureGroup(isExpanded: $open) {
            ForEach(Array(group.files.enumerated()), id: \.offset) { i, path in
                HStack(spacing: 8) {
                    Text(Format.path((path as NSString).deletingLastPathComponent))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.quiet)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 12)
                    if path == group.keeper {
                        Text("kept as the original").font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else if group.clusters[0].contains(path) {
                        Text("already shares its space").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Button { model.reveal([path]) } label: {
                        Image(systemName: "arrow.up.forward.square").foregroundStyle(Color.quiet)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
                .padding(.leading, 30)
            }
        } label: {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { included }, set: { _ in model.toggle(group: index) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Image(nsImage: Icons.icon(for: group.keeper)).resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text((group.keeper as NSString).lastPathComponent)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(places)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .foregroundStyle(included ? Color.primary : Color.quiet)
                Spacer(minLength: 16)
                Text("\((group.clusters.count - 1).formatted()) \(group.clusters.count == 2 ? "copy" : "copies") × \(Format.bytes(group.size))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(Format.bytes(group.reclaimableBytes))
                    .font(.system(size: 13).monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(included ? Color.primary : Color.quiet)
            }
            .padding(.vertical, 2)
        }
    }

    private var places: String {
        let p = model.breakdown?.places(group) ?? []
        let shown = p.prefix(3).joined(separator: ", ")
        return p.count > 3 ? "in \(shown) and \(p.count - 3) more" : "in \(shown)"
    }
}

struct FoldingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let kinds = model.breakdown?.byKind(model.selected) ?? []
        Centered {
            Headline(text: "Sharing space")
            Text("\(model.foldedCount.formatted()) of \(model.foldTotal.formatted()) files")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(Color.quiet)
                .contentTransition(.numericText())
            KindBar(kinds: kinds,
                    drained: model.foldTotal > 0 ? Double(model.foldedCount) / Double(model.foldTotal) : 0)
                .frame(width: 420)
                .padding(.top, 8)
            Lede(text: "Each copy is checked byte for byte before it's folded. Safe to keep working.")
                .font(.system(size: 13))
        }
    }
}

struct DoneView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Centered {
            Text(Format.bytes(model.freedBytes))
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.fold)
            Lede(text: "freed. Every file is still where it was.")
            if model.problems > 0 {
                Lede(text: "\(model.problems.formatted()) files changed while we worked, so we left them alone.")
                    .font(.system(size: 13))
            }
            Spacer().frame(height: 10)
            PrimaryButton(title: "Done") { model.reset() }
            QuietButton(title: "Undo") { model.undo() }
        }
    }
}

struct NothingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Centered {
            Headline(text: "Nothing to fold")
            Lede(text: "\(model.filesSeen.formatted()) files checked. No identical files are taking extra space here.")
            Spacer().frame(height: 10)
            PrimaryButton(title: "Done") { model.reset() }
        }
    }
}

/// Wraps items onto new lines when they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// The one place that explains what folding actually does, in plain words.
struct HowItWorksButton: View {
    @State private var shown = false
    var body: some View {
        Button("How does this work?") { shown.toggle() }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.fold)
            .padding(.leading, 10)
            .popover(isPresented: $shown, arrowEdge: .bottom) { HowItWorks().padding(22).frame(width: 380) }
    }
}

struct HowItWorks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing is removed").font(.system(size: 15, weight: .semibold))
            Text("Twinfold only touches files that are identical, byte for byte. Each one stays in its folder with its own name, dates and permissions. They simply stop storing the same data on disk twice.")
            Text("If you change one later, only that one changes. macOS gives it its own copy of the edited parts automatically.")
            Text("Good to know: after sharing, deleting one copy frees less space than Finder shows, because its twins still use that data.")
                .foregroundStyle(Color.quiet)
            Text("Changed your mind? Undo gives every file its own copy again.")
                .foregroundStyle(Color.quiet)
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }
}
