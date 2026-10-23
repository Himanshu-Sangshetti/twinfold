import SwiftUI
import TwinfoldCore

extension Color {
    static let fold = Color(red: 0.12, green: 0.62, blue: 0.54)
    static let ink = Color.primary
    static let quiet = Color.secondary
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            FoldField(phase: model.phase, progress: progress, copies: copies)
                .frame(height: 248)
                .padding(.horizontal, 36)
                .padding(.top, 44)

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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .transition(.opacity)
        }
        .frame(width: 560, height: 680)
        .background(.background)
        .animation(.smooth(duration: 0.4), value: model.phase)
    }

    private var copies: Int { model.groups.reduce(0) { $0 + $1.clusters.count - 1 } }
    private var progress: Double {
        switch model.phase {
        case .scanning: model.toCompare > 0 ? Double(model.compared) / Double(model.toCompare) : 0
        case .folding: model.foldTotal > 0 ? Double(model.foldedCount) / Double(model.foldTotal) : 0
        case .done: 1
        default: 0
        }
    }
}

/// The signature: a field of tiles. Duplicates light up as they're found, then fold away
/// into their twin, one by one, as space is freed.
struct FoldField: View {
    let phase: AppModel.Phase
    let progress: Double
    let copies: Int

    private let columns = 18
    private let rows = 8
    private var count: Int { columns * rows }

    var body: some View {
        TimelineView(.animation(paused: phase != .scanning && phase != .idle)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let gap: CGFloat = 6
                let side = (geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: gap) {
                            ForEach(0..<columns, id: \.self) { c in
                                tile(index: r * columns + c, row: r, column: c, time: t)
                                    .frame(width: side, height: side)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Which tiles stand for duplicate copies: spread across the field, stable between frames.
    private func isTwin(_ i: Int) -> Bool {
        let share = min(0.55, max(0.18, Double(copies) / 4000))
        return Self.noise(i) < share
    }

    /// Stable pseudo-random value in 0..<1 for a tile (splitmix64).
    static func noise(_ i: Int) -> Double {
        var z = UInt64(truncatingIfNeeded: i) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    @ViewBuilder
    private func tile(index i: Int, row: Int, column: Int, time: Double) -> some View {
        let twin = isTwin(i)
        let shape = RoundedRectangle(cornerRadius: 3.5, style: .continuous)
        switch phase {
        case .idle:
            let wave = 0.5 + 0.5 * sin(time * 1.1 - Double(column) * 0.35 - Double(row) * 0.2)
            shape.fill(Color.quiet.opacity(0.08 + 0.10 * wave))
        case .scanning:
            let sweep = (time * 0.9).truncatingRemainder(dividingBy: 1.6) * Double(columns) - Double(column)
            let lit = max(0, 1 - abs(sweep) / 2.5)
            let found = twin && Double(i) / Double(count) < progress
            shape.fill(found ? Color.fold.opacity(0.85) : Color.quiet.opacity(0.10 + 0.35 * lit))
        case .results, .nothing:
            shape.fill(twin && phase == .results ? Color.fold : Color.quiet.opacity(0.14))
        case .folding, .done:
            let order = Self.noise(i &+ 7919)
            let folded = twin && order < progress
            ZStack {
                shape.fill(Color.quiet.opacity(0.14))
                if twin {
                    shape.fill(Color.fold)
                        .rotation3DEffect(.degrees(folded ? 180 : 0), axis: (x: 0, y: 1, z: 0),
                                          anchor: .leading, perspective: 0.6)
                        .opacity(folded ? 0 : 1)
                        .animation(.spring(duration: 0.55, bounce: 0.15), value: folded)
                }
            }
        }
    }
}

struct Headline: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.ink)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

struct Lede: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Color.quiet)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity)
    }
}

struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 220)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(Color.fold, in: Capsule())
        }
        .buttonStyle(.plain)
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

struct IdleView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            Headline(text: "Free up space.\nDelete nothing.")
            Lede(text: "Twinfold finds identical files and lets them share one copy on disk. Every file stays exactly where it is.")
            Spacer().frame(height: 14)
            PrimaryButton(title: "Scan \(model.rootName)") { model.scan() }
            QuietButton(title: "Choose folders…") { model.chooseFolders() }
        }
    }
}

struct ScanningView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            Headline(text: model.toCompare > 0 ? "Comparing" : "Looking")
            Text(model.toCompare > 0
                ? "\(model.compared.formatted()) of \(model.toCompare.formatted()) possible twins"
                : "\(model.filesSeen.formatted()) files")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(Color.quiet)
                .contentTransition(.numericText())
                .animation(.snappy, value: model.filesSeen)
        }
    }
}

struct ResultsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 10) {
            Text(Format.bytes(model.reclaimable))
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.ink)
            Lede(text: "can be freed without deleting a single file")
            Spacer().frame(height: 10)
            PrimaryButton(title: "Free \(Format.bytes(model.reclaimable))") { model.fold() }
            Spacer().frame(height: 6)
            VStack(spacing: 0) {
                ForEach(Array(model.groups.prefix(4).enumerated()), id: \.offset) { _, group in
                    GroupRow(group: group).onTapGesture { model.reveal(group) }
                }
            }
            QuietButton(title: "Start over") { model.reset() }.padding(.top, 4)
        }
    }
}

struct GroupRow: View {
    let group: DuplicateGroup
    var body: some View {
        HStack(spacing: 12) {
            Text((group.keeper as NSString).lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text("\(group.files.count) copies")
                .font(.system(size: 13))
                .foregroundStyle(Color.quiet)
            Text(Format.bytes(group.reclaimableBytes))
                .font(.system(size: 13).monospacedDigit())
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help("Show in Finder")
    }
}

struct FoldingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            Headline(text: "Folding")
            Text("\(model.foldedCount.formatted()) of \(model.foldTotal.formatted())")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(Color.quiet)
                .contentTransition(.numericText())
        }
    }
}

struct DoneView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 10) {
            Text(Format.bytes(model.freedBytes))
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.fold)
            Lede(text: "freed. Every file is still where it was.")
            if model.problems > 0 {
                Lede(text: "\(model.problems) files changed while we worked, so we left them alone.")
            }
            Spacer().frame(height: 14)
            PrimaryButton(title: "Done") { model.reset() }
            QuietButton(title: "Undo") { model.undo() }
        }
    }
}

struct NothingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            Headline(text: "Nothing to fold")
            Lede(text: "\(model.filesSeen.formatted()) files checked. No duplicates are wasting space here.")
            Spacer().frame(height: 14)
            PrimaryButton(title: "Done") { model.reset() }
        }
    }
}
