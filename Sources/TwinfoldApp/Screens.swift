import SwiftUI
import TwinfoldCore

// MARK: - Look

enum Look {
    /// Screenshots are drawn by the app itself, which can't render Liquid Glass; they get a frosted stand-in.
    static let captured = ProcessInfo.processInfo.environment["TWINFOLD_CAPTURE"] != nil
    static var liquidGlass: Bool {
        if #available(macOS 26, *) { return !captured }
        return false
    }
}

extension View {
    /// Liquid Glass on macOS 26, frosted material before it.
    @ViewBuilder func glass(_ radius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, *), Look.liquidGlass {
            glassEffect(.regular, in: shape)
        } else {
            frosted(shape)
        }
        #else
        frosted(shape)
        #endif
    }

    @ViewBuilder private func frosted(_ shape: RoundedRectangle) -> some View {
        if Look.captured {
            background(Color(nsColor: .windowBackgroundColor).opacity(0.72), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

/// Soft colour behind the glass, so panels have something to refract.
struct Backdrop: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                let w = geo.size.width, h = geo.size.height
                Color(nsColor: .windowBackgroundColor)
                glow(Color.fold.opacity(0.30), at: UnitPoint(x: 0.08, y: 0.05), radius: w * 0.55)
                glow(Kind.python.color.opacity(0.20), at: UnitPoint(x: 0.95, y: 0.95), radius: w * 0.5)
                glow(Kind.images.color.opacity(0.10), at: UnitPoint(x: 0.85, y: 0.0), radius: w * 0.35)
                    .frame(width: w, height: h)
            }
        }
        .ignoresSafeArea()
    }

    private func glow(_ color: Color, at point: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(colors: [color, color.opacity(0)], center: point, startRadius: 0, endRadius: radius)
    }
}

struct PrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), Look.liquidGlass {
            Button(action: action) {
                Text(title).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 10)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.glassProminent)
            .tint(.fold)
            .controlSize(.extraLarge)
            .disabled(disabled)
            .keyboardShortcut(.defaultAction)
        } else {
            capsule
        }
        #else
        capsule
        #endif
    }

    private var capsule: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 26)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Color.fold.opacity(disabled ? 0.4 : 1), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }
}

struct GlassButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        let label = Label { Text(title) } icon: { if let icon { Image(systemName: icon) } }
            .font(.system(size: 13, weight: .medium))
        #if compiler(>=6.2)
        if #available(macOS 26, *), Look.liquidGlass {
            Button(action: action) { label }.buttonStyle(.glass).controlSize(.large)
        } else {
            Button(action: action) { label }.buttonStyle(.bordered).controlSize(.large)
        }
        #else
        Button(action: action) { label }.buttonStyle(.bordered).controlSize(.large)
        #endif
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

/// A centred glass card for the single-purpose screens.
struct Card<Content: View>: View {
    var width: CGFloat = 480
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 16) { content }
            .multilineTextAlignment(.center)
            .padding(36)
            .frame(width: width)
            .glass(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            Backdrop()
            Group {
                switch model.phase {
                case .idle: IdleView()
                case .scanning: ScanningView()
                case .results: ResultsView()
                case .folding: FoldingView()
                case .done: DoneView()
                case .nothing: NothingView()
                case .history: HistoryView()
                }
            }
            .padding(.top, 34)
            TopBar()
        }
        .frame(minWidth: 1080, idealWidth: 1180, minHeight: 680, idealHeight: 780)
        .animation(.smooth(duration: 0.35), value: model.phase)
        .sheet(isPresented: $model.showingAutomatic) { AutomaticSheet() }
    }
}

/// Top right of the window: History and Automatic, always one click away.
struct TopBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            if model.phase != .history {
                GlassButton(title: "History", icon: "clock.arrow.circlepath") { model.showHistory() }
            }
            GlassButton(title: model.settings.automatic == .off ? "Automatic" : "Automatic: \(model.settings.automatic.rawValue.capitalized)",
                        icon: "sparkles") { model.showingAutomatic = true }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
}

// MARK: - Screens

struct IdleView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Card {
            AppIcon().frame(width: 96, height: 96)
            Headline(text: "Get disk space back\nwithout removing any files.")
            Lede(text: "Twinfold finds files that are exactly the same and stores their data once. Every file stays in its folder and keeps working. You see everything before anything changes.")
            HStack(spacing: 10) {
                PrimaryButton(title: "Scan \(model.rootName)") { model.scan() }
                GlassButton(title: "Choose Folders…") { model.chooseFolders() }
            }
            .padding(.top, 6)
            if model.totalSaved > 0 {
                Button { model.showHistory() } label: {
                    Text("Saved \(Format.bytes(model.totalSaved)) on this Mac so far")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.fold)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }
}

struct ScanningView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Card {
            AppIcon().frame(width: 80, height: 80)
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
            Text("Nothing is changed while scanning.")
                .font(.system(size: 13))
                .foregroundStyle(Color.quiet)
        }
    }
}

struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        @Bindable var model = model
        let kinds = model.breakdown?.byKind(model.selected) ?? []
        VStack(spacing: 12) {
            // Summary
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Format.bytes(model.selectedBytes))
                                .font(.system(size: 42, weight: .semibold, design: .rounded))
                                .contentTransition(.numericText())
                            if model.selectedBytes < model.totalBytes {
                                Text("of \(Format.bytes(model.totalBytes)) selected")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.quiet)
                            }
                        }
                        Text("is stored twice on your disk. \(Format.count(model.selected.count, "file is an exact copy", "files are exact copies")) of other files; Twinfold keeps every file and stores the data once.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.quiet)
                            .fixedSize(horizontal: false, vertical: true)
                        Label("Nothing is removed, moved or renamed. Undo any time.", systemImage: "checkmark.shield")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.fold)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        PrimaryButton(title: "Save \(Format.bytes(model.selectedBytes))",
                                      disabled: model.selectedBytes == 0) { confirming = true }
                            .confirmationDialog(
                                "Store \(Format.count(model.selected.count, "duplicate", "duplicates")) only once?",
                                isPresented: $confirming
                            ) {
                                Button("Save \(Format.bytes(model.selectedBytes))") { model.fold() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Every file stays in its folder with its own name, dates and permissions. Each one is compared byte for byte again right before it changes. You can undo this afterwards, from History too.")
                            }
                        HStack(spacing: 6) {
                            if let date = model.scannedAt {
                                Text("Scanned \(date.formatted(.relative(presentation: .named)))")
                                    .foregroundStyle(Color.quiet)
                            }
                            QuietButton(title: "Rescan") { model.scan() }
                        }
                        .font(.system(size: 12))
                    }
                }
                KindBar(kinds: kinds, highlight: model.kindFilter)
                KindLegend(kinds: kinds)
            }
            .padding(22)
            .glass(24)

            // Where, and what exactly
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    HStack {
                        Picker("", selection: $model.tab) {
                            ForEach(AppModel.Tab.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Text(model.kindFilter == nil
                            ? "Untick anything you'd rather leave alone. Twinfold remembers."
                            : "Showing \(model.kindFilter!.rawValue.lowercased()) only. Save still covers everything ticked.")
                            .font(.system(size: 12))
                            .foregroundStyle(model.kindFilter == nil ? Color.quiet : Color.primary)
                        HowItWorksButton()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    switch model.tab {
                    case .folders: FolderList()
                    case .files: FileList()
                    }
                }
                .glass(24)
                DetailPane()
                    .frame(width: 380)
                    .glass(24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 14)
    }
}

struct FoldingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let kinds = model.breakdown?.byKind(model.selected) ?? []
        Card {
            Headline(text: "Storing duplicates once")
            Text("\(model.foldedCount.formatted()) of \(model.foldTotal.formatted()) files")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(Color.quiet)
                .contentTransition(.numericText())
            if kinds.isEmpty {
                ProgressView(value: model.foldTotal > 0 ? Double(model.foldedCount) / Double(model.foldTotal) : 0)
                    .tint(.fold).frame(width: 340)
            } else {
                KindBar(kinds: kinds,
                        drained: model.foldTotal > 0 ? Double(model.foldedCount) / Double(model.foldTotal) : 0)
                    .frame(width: 380)
            }
            Text("Each file is checked byte for byte before it changes. Safe to keep working.")
                .font(.system(size: 13))
                .foregroundStyle(Color.quiet)
        }
    }
}

struct DoneView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Card(width: 520) {
            Text(Format.bytes(model.freedBytes))
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.fold)
            Lede(text: "of disk space back. Every file is still where it was.")
            if model.problems > 0 {
                Text("\(model.problems.formatted()) files changed while we worked, so we left them alone.")
                    .font(.system(size: 13)).foregroundStyle(Color.quiet)
            }
            if let example = model.example {
                VStack(alignment: .leading, spacing: 8) {
                    Text("See for yourself: \((example.keeper as NSString).lastPathComponent)")
                        .font(.system(size: 13, weight: .semibold))
                    ProofSection(group: example)
                    Button("Show all \(example.files.count) copies in Finder") { model.reveal(example.files) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(spacing: 10) {
                GlassButton(title: "Undo") { model.undo() }
                PrimaryButton(title: "Done") { model.reset() }
            }
            .padding(.top, 4)
            Text("Undo gives every file its own copy again. You can also undo it later from History.")
                .font(.system(size: 12))
                .foregroundStyle(Color.quiet)
        }
    }
}

struct NothingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Card {
            Headline(text: "Nothing to save here")
            Lede(text: "\(model.filesSeen.formatted()) files checked. No identical files are taking extra space.")
            PrimaryButton(title: "Done") { model.reset() }
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(model.runs.isEmpty
                        ? "Nothing saved yet."
                        : "\(Format.bytes(model.totalSaved)) saved on this Mac. Undo any run to give its files their own copies again.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.quiet)
                }
                Spacer()
                GlassButton(title: "Back", icon: "chevron.left") {
                    model.phase = model.breakdown == nil ? .idle : .results
                }
            }
            if let message = model.undoMessage {
                Label(message, systemImage: "arrow.uturn.backward.circle")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glass(16)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.runs) { run in
                        HStack(spacing: 14) {
                            Image(systemName: "square.on.square")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.fold)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 14, weight: .medium))
                                Text(Format.count(run.files, "file", "files") + " now share space")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.quiet)
                            }
                            Spacer()
                            Text(Format.bytes(run.bytes))
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            GlassButton(title: "Undo") { model.undo(run) }
                        }
                        .padding(14)
                        .glass(18)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding(28)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pro

struct AutomaticSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(Color.fold)
                Text("Automatic").font(.system(size: 22, weight: .semibold, design: .rounded))
                if model.entitlement.unlocked {
                    Text("Pro").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.fold)
                }
            }
            Text("New projects keep bringing new copies: every `npm install`, every virtualenv, every download. Automatic checks your folders at 3 am, while you sleep, and stores new duplicates once. Folders you've unticked are always left alone, and every run shows up in History, where you can undo it.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            if model.entitlement.unlocked {
                Picker("Run", selection: Binding(get: { model.settings.automatic },
                                                 set: { model.setAutomatic($0) })) {
                    Text("Off").tag(Settings.Frequency.off)
                    Text("Every day").tag(Settings.Frequency.daily)
                    Text("Every week").tag(Settings.Frequency.weekly)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Watches \(model.settings.watched.map { Format.path($0) }.joined(separator: ", ")), leaving \(Format.count(model.settings.leaveAlone.count, "folder", "folders")) alone.")
                    if let last = model.settings.lastAutoRun {
                        Text("Last run \(last.formatted(.relative(presentation: .named))): saved \(Format.bytes(model.settings.lastAutoSaved)).")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.quiet)
                HStack {
                    GlassButton(title: model.autoRunning ? "Running…" : "Run now", icon: "play.fill") {
                        model.runAutomaticNow()
                    }
                    .disabled(model.autoRunning)
                    Spacer()
                    Button("Close") { dismiss() }.controlSize(.large)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Twinfold Pro · \(Store.price) once").font(.system(size: 15, weight: .semibold))
                    Text("Adds Automatic and its menu bar item, on up to 3 Macs. No subscription. Everything else in Twinfold stays free and unlimited.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(16)
                HStack(spacing: 10) {
                    PrimaryButton(title: "Get Pro for \(Store.price)") { model.buy() }
                    Spacer()
                    Button("Not now") { dismiss() }.controlSize(.large)
                }
                Divider()
                Text("Already bought it? Paste the license key from your email.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.quiet)
                HStack {
                    TextField("License key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { model.activate(key) }
                    Button("Activate") { model.activate(key) }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || model.activating)
                    if model.activating { ProgressView().controlSize(.small) }
                }
                if let error = model.activationError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                }
                if Store.mode == .test {
                    Text("Test store: pay with card 4242 4242 4242 4242.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Divider()
            Link(destination: Support.sponsorURL) {
                Label("Just want to say thanks? Support Twinfold", systemImage: "heart")
                    .font(.system(size: 12))
            }
            .foregroundStyle(Color.quiet)
        }
        .padding(26)
        .frame(width: 500)
    }
}

/// Menu bar item while Automatic is on.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Twinfold has saved \(Format.bytes(model.totalSaved))")
        if let last = model.settings.lastAutoRun {
            Text("Last automatic run \(last.formatted(.relative(presentation: .named))): \(Format.bytes(model.settings.lastAutoSaved))")
        }
        Divider()
        Button(model.autoRunning ? "Running…" : "Run Now") { model.runAutomaticNow() }.disabled(model.autoRunning)
        Button("Open Twinfold") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Twinfold") { NSApp.terminate(nil) }
    }
}

extension Support {
    static let sponsorURL = URL(string: "https://github.com/sponsors/Himanshu-Sangshetti")!
}
