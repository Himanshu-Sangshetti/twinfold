import AppKit
import TwinfoldCore

/// Where this copy of Twinfold runs from. Opened straight from Downloads, macOS runs it from a temporary copy
/// (App Translocation) whose path is gone after a restart, so the 3 am schedule and the login item may only be
/// set up from Applications.
enum Install {
    static var path: String { Bundle.main.bundlePath }
    static var isApp: Bool { path.hasSuffix(".app") }
    static var inApplications: Bool { InstallLocation.isStable(path) }
    /// Background work (schedule, login item) needs a stable path.
    static var canSchedule: Bool { isApp && inApplications }
    static var needsMove: Bool { isApp && !inApplications }

    /// The real location of a translocated app (usually Downloads), via the Security framework.
    static var originalURL: URL {
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let url = URL(fileURLWithPath: path)
        guard path.contains("/AppTranslocation/"),
              let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL"),
              let original = unsafeBitCast(sym, to: Original.self)(url as CFURL, nil)?.takeRetainedValue()
        else { return url }
        return original as URL
    }

    static func revealForMove() {
        NSWorkspace.shared.activateFileViewerSelecting([originalURL])
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
}
