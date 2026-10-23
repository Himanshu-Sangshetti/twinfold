import Foundation

public enum Format {
    /// "33.2 GB", "812 MB", "4 KB". Decimal units, like Finder.
    public static func bytes(_ value: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        if i == 0 { return "\(value) bytes" }
        return v >= 100 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
    }

    /// Parses "64K", "10MB", "1.5G" or a plain byte count.
    public static func parseSize(_ text: String) -> Int64? {
        let t = text.uppercased().replacingOccurrences(of: "B", with: "")
        let multipliers: [Character: Double] = ["K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12]
        if let last = t.last, let m = multipliers[last], let n = Double(t.dropLast()) { return Int64(n * m) }
        return Int64(t)
    }

    /// Shortens paths under the home folder to ~/...
    public static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
