import CryptoKit
import Foundation

/// Twinfold Pro. Everything in the app, the command line tool and the source are free and unlimited; a one-time
/// license key (sold through Dodo Payments) adds Automatic mode.
public enum Store {
    public enum Mode: String, Sendable { case test, live }

    /// Flip to `.live` once the live product exists; `scripts/bundle.sh` warns while this is `.test`.
    public static let mode: Mode = .live

    static let products: [Mode: String] = [
        .test: "pdt_0NqQFyUubmksazGDaYvmQ",
        .live: "pdt_0NqR0VmiWXt8Rxu6048ZS",
    ]

    public static var productID: String { products[mode] ?? "" }
    public static let price = "$12"

    /// `TWINFOLD_STORE_URL` points activation at a local stand-in server (scripts/app-e2e.sh).
    public static var apiBase: URL {
        if let url = ProcessInfo.processInfo.environment["TWINFOLD_STORE_URL"] { return URL(string: url)! }
        return URL(string: mode == .live ? "https://live.dodopayments.com" : "https://test.dodopayments.com")!
    }

    public static var checkoutURL: URL {
        let host = mode == .live ? "checkout.dodopayments.com" : "test.checkout.dodopayments.com"
        return URL(string: "https://\(host)/buy/\(productID)?quantity=1")!
    }

}

public struct License: Codable, Sendable, Equatable {
    public let key: String
    public let instanceID: String
    public let email: String
    public let activatedAt: Date
}

/// Whether this Mac has Pro: its license, if it has one.
public struct Entitlement: Codable, Sendable, Equatable {
    public var license: License?

    public init(license: License? = nil) { self.license = license }

    public var unlocked: Bool { license != nil }

    public static var url: URL { Support.directory.appendingPathComponent("entitlement.json") }

    public static func load(from url: URL = Entitlement.url) -> Entitlement {
        guard let data = try? Data(contentsOf: url) else { return Entitlement() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Entitlement.self, from: data)) ?? Entitlement()
    }

    public func save(to url: URL = Entitlement.url) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
    }

}

public enum ActivationError: LocalizedError, Equatable {
    case notFound, inactive, limitReached, wrongProduct, server(Int), network(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "That key wasn't found. Check it was pasted in full."
        case .inactive: "That key has been turned off, for example after a refund."
        case .limitReached: "That key is already in use on 3 Macs."
        case .wrongProduct: "That key is for a different product."
        case .server(let code): "The license server had a problem (\(code)). Try again in a minute."
        case .network(let text): "Couldn't reach the license server: \(text)"
        }
    }
}

public enum Activation {
    /// Registers this Mac against a license key with Dodo Payments (a public endpoint; no secret in the app).
    public static func activate(key: String, machine: String = Host.current().localizedName ?? "Mac") async throws -> License {
        var request = URLRequest(url: Store.apiBase.appendingPathComponent("licenses/activate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "license_key": key.trimmingCharacters(in: .whitespacesAndNewlines), "name": machine,
        ])
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw ActivationError.network(error.localizedDescription)
        }
        return try parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, key: key)
    }

    static func parse(_ data: Data, status: Int, key: String, now: Date = Date()) throws -> License {
        switch status {
        case 200, 201: break
        case 403: throw ActivationError.inactive
        case 404: throw ActivationError.notFound
        case 422: throw ActivationError.limitReached
        default: throw ActivationError.server(status)
        }
        struct Body: Decodable {
            struct Product: Decodable { let product_id: String }
            struct Customer: Decodable { let email: String }
            let id: String
            let product: Product
            let customer: Customer
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw ActivationError.server(status) }
        guard body.product.product_id == Store.productID else { throw ActivationError.wrongProduct }
        return License(key: key.trimmingCharacters(in: .whitespacesAndNewlines), instanceID: body.id,
                       email: body.customer.email, activatedAt: now)
    }
}

/// Tells the app when a newer Twinfold is out (one small request to GitHub's public releases API, at most once a
/// day). `TWINFOLD_UPDATE_URL` points it at a stand-in (scripts/app-e2e.sh). Nothing is sent but the request.
public enum Updates {
    public static let version = "0.7.1"
    public static let download = URL(string: "https://github.com/Himanshu-Sangshetti/twinfold/releases/latest/download/Twinfold.zip")!
    public static let notes = URL(string: "https://github.com/Himanshu-Sangshetti/twinfold/releases/latest")!

    static var feed: URL {
        URL(string: ProcessInfo.processInfo.environment["TWINFOLD_UPDATE_URL"]
            ?? "https://api.github.com/repos/Himanshu-Sangshetti/twinfold/releases/latest")!
    }

    /// A published version: its number, the app download and the file listing every download's SHA-256.
    public struct Release: Sendable, Equatable {
        public let version: String
        public let zip: URL
        public let checksums: URL
    }

    /// The newer release, or nil when this one is the latest (or the check couldn't run).
    public static func latest() async -> Release? {
        var request = URLRequest(url: feed, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(latest, than: version) else { return nil }
        let assets = (json["assets"] as? [[String: Any]] ?? []).reduce(into: [String: URL]()) { all, asset in
            if let name = asset["name"] as? String, let url = (asset["browser_download_url"] as? String).flatMap(URL.init) {
                all[name] = url
            }
        }
        let fallback = notes.deletingLastPathComponent().appendingPathComponent("download/\(tag)")
        return Release(version: latest,
                       zip: assets["Twinfold-\(latest).zip"] ?? fallback.appendingPathComponent("Twinfold-\(latest).zip"),
                       checksums: assets["checksums.txt"] ?? fallback.appendingPathComponent("checksums.txt"))
    }

    /// The newer version's number, or nil when this one is the latest.
    public static func newer() async -> String? { await latest()?.version }

    public enum InstallError: LocalizedError, Equatable {
        case download(String), checksum, notAnApp, wrongVersion(String), signature, replace(String)
        public var errorDescription: String? {
            switch self {
            case .download(let why): "The download didn't finish (\(why))."
            case .checksum: "The download didn't match the published checksum, so it wasn't installed."
            case .notAnApp: "The download didn't contain Twinfold."
            case .wrongVersion(let v): "The download was version \(v), not the one expected."
            case .signature: "The downloaded app's signature didn't check out, so it wasn't installed."
            case .replace(let why): "Couldn't replace the app (\(why))."
            }
        }
    }

    /// The SHA-256 listed for `file` in a `shasum -a 256` listing (paths may carry a folder).
    public static func checksum(for file: String, in listing: String) -> String? {
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if (name as NSString).lastPathComponent == file { return parts[0].lowercased() }
        }
        return nil
    }

    /// Downloads `release`, checks it against the published SHA-256, its version and signature, then puts it in
    /// place of the app at `appPath` (the old one is moved aside first and put back if anything fails).
    /// Nothing changes unless every check passes.
    public static func install(_ release: Release, replacing appPath: String) async throws {
        func fetch(_ url: URL) async throws -> Data {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError.download("HTTP error") }
                return data
            } catch let e as InstallError { throw e } catch { throw InstallError.download(error.localizedDescription) }
        }
        let zipName = "Twinfold-\(release.version).zip"
        let listing = String(decoding: try await fetch(release.checksums), as: UTF8.self)
        let zip = try await fetch(release.zip)
        let digest = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard let expected = checksum(for: zipName, in: listing), expected == digest else { throw InstallError.checksum }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twinfold-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try zip.write(to: work.appendingPathComponent(zipName))
        guard run("/usr/bin/ditto", "-x", "-k", work.appendingPathComponent(zipName).path, work.appendingPathComponent("x").path)
        else { throw InstallError.notAnApp }
        let app = work.appendingPathComponent("x/Twinfold.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let got = info?["CFBundleShortVersionString"] as? String else { throw InstallError.notAnApp }
        guard got == release.version else { throw InstallError.wrongVersion(got) }
        guard run("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path) else { throw InstallError.signature }

        let target = URL(fileURLWithPath: appPath)
        let aside = target.deletingLastPathComponent().appendingPathComponent(".Twinfold-previous-\(version).app")
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: target, to: aside)
        } catch { throw InstallError.replace(error.localizedDescription) }
        do {
            try FileManager.default.moveItem(at: app, to: target)
        } catch {
            try? FileManager.default.moveItem(at: aside, to: target)
            throw InstallError.replace(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: aside)
    }

    @discardableResult
    static func run(_ tool: String, _ args: String...) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }
}

/// Whether an app at this path will still be there after a restart: in Applications (the Mac's or the user's),
/// and not a temporary App Translocation copy macOS makes for apps opened straight from Downloads.
public enum InstallLocation {
    public static func isStable(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        !path.contains("/AppTranslocation/") && (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/"))
    }
}
