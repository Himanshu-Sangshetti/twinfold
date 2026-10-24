import SwiftUI
import TwinfoldCore

/// The idea in motion: two identical files each hold their own block on disk, then the blocks fold into one
/// while both files stay put and point at it. Loops gently.
struct FoldAnimation: View {
    var size = CGSize(width: 400, height: 150)
    @State private var folded: Bool

    init(folded: Bool = false) { _folded = State(initialValue: folded) }

    var body: some View {
        let w = size.width, h = size.height
        let fileY: CGFloat = 28, diskY = h - 34
        let leftX = w * 0.22, rightX = w * 0.78, middle = w * 0.5
        let leftBlock = folded ? middle : leftX
        let rightBlock = folded ? middle : rightX

        ZStack {
            // Links from each file to where its data lives.
            Link(from: CGPoint(x: leftX, y: fileY + 18), to: CGPoint(x: leftBlock, y: diskY - 16))
                .stroke(Color.quiet.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            Link(from: CGPoint(x: rightX, y: fileY + 18), to: CGPoint(x: rightBlock, y: diskY - 16))
                .stroke(Color.quiet.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

            // The disk.
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                .frame(width: w * 0.86, height: 3)
                .position(x: middle, y: diskY + 20)
            Block().position(x: leftBlock, y: diskY)
            Block().opacity(folded ? 0 : 1).position(x: rightBlock, y: diskY)

            // The files never move.
            FileChip(name: "app/torch.dylib").position(x: leftX, y: fileY)
            FileChip(name: "api/torch.dylib").position(x: rightX, y: fileY)

            Text(folded ? "Stored once" : "Stored twice")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(folded ? Color.fold : Color.quiet)
                .contentTransition(.opacity)
                .position(x: middle, y: h - 4)
        }
        .frame(width: w, height: h)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Two identical files, each storing its own copy, fold into one shared copy on disk.")
        .task {
            guard !Look.captured else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.spring(duration: 0.9, bounce: 0.18)) { folded.toggle() }
            }
        }
    }

    private struct Block: View {
        var body: some View {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color.fold, Color.fold.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .frame(width: 58, height: 30)
                .overlay(Text("9 MB").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: Color.fold.opacity(0.3), radius: 6, y: 3)
        }
    }

    private struct FileChip: View {
        let name: String
        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "doc.fill").font(.system(size: 12)).foregroundStyle(Color.quiet)
                Text(name).font(.system(size: 11, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    /// A gentle S-curve between two points; animates as the end point moves.
    private struct Link: Shape {
        var from: CGPoint
        var to: CGPoint

        var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
            get { AnimatablePair(AnimatablePair(from.x, from.y), AnimatablePair(to.x, to.y)) }
            set {
                from = CGPoint(x: newValue.first.first, y: newValue.first.second)
                to = CGPoint(x: newValue.second.first, y: newValue.second.second)
            }
        }

        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: from)
            let midY = (from.y + to.y) / 2
            p.addCurve(to: to, control1: CGPoint(x: from.x, y: midY), control2: CGPoint(x: to.x, y: midY))
            return p
        }
    }
}
