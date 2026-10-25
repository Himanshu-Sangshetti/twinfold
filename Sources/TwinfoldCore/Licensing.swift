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

    /// The newer version's number, or nil when this one is the latest (or the check couldn't run).
    public static func newer() async -> String? {
        var request = URLRequest(url: feed, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String
        else { return nil }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isNewer(latest, than: version) ? latest : nil
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
