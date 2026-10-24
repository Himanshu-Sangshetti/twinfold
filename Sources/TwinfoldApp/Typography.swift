import CoreText
import SwiftUI

/// Twinfold's type: Instrument Serif for the big numbers and headlines, the system font for everything you
/// read or click, Geist Mono for file paths. Fonts are bundled (SIL Open Font License) and registered at launch.
enum Typography {
    static func register() {
        let fileManager = FileManager.default
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        // In the .app the fonts sit in Resources/Fonts; in a `swift build` they're in the SwiftPM resource bundle.
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            exe?.appendingPathComponent("Twinfold_TwinfoldApp.bundle/Fonts"),
            exe?.appendingPathComponent("Twinfold_TwinfoldApp.bundle/Contents/Resources/Fonts"),
        ].compactMap { $0 }
        guard let dir = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// The display serif, for numbers and headlines.
    static func display(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size)
    }

    static func mono(_ size: CGFloat) -> Font { .custom("GeistMono-Regular", size: size) }
}
