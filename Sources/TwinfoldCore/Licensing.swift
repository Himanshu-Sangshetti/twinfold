import Foundation

/// Twinfold Pro. Everything in the app, the command line tool and the source are free and unlimited; a one-time
/// license key (sold through Dodo Payments) adds Automatic mode.
public enum Store {
    public enum Mode: String, Sendable { case test, live }

    /// Flip to `.live` once the live product exists; `scripts/bundle.sh` warns while this is `.test`.
    public static let mode: Mode = .test

    static let products: [Mode: String] = [
        .test: "pdt_0NqQFyUubmksazGDaYvmQ",
        .live: "",
    ]

    public static var productID: String { products[mode] ?? "" }
    public static let price = "$12"

    public static var apiBase: URL {
        URL(string: mode == .live ? "https://live.dodopayments.com" : "https://test.dodopayments.com")!
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
