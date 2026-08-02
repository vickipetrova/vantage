import Foundation

/// Currency conversion, from the European Central Bank's daily reference rates.
///
/// The ECB directly rather than a JSON re-server: same data, one fewer party in the request path,
/// and it holds the app's whole network surface to two hosts. The request carries nothing — no
/// token, no identifier, no numbers. It's a public XML file, identical for every user on earth.
///
/// Two honest limitations, both surfaced rather than hidden:
///
/// - The ECB publishes about 29 currencies. Apple pays in more than that. Anything it doesn't
///   publish **cannot** be converted, and is reported as an unconverted remainder rather than
///   quietly dropped from a total.
/// - Rates are published on TARGET working days only, so the feed is a day or three stale over a
///   weekend. That's why every converted figure is marked `≈`, and why Apple's own monthly
///   financial reports remain the authority.
public struct FXRates: Codable, Equatable, Sendable {
    /// Units of each currency per 1 EUR, as the ECB publishes them. EUR itself is 1.
    public let perEUR: [String: Decimal]
    /// The date the ECB stamped on the feed — not when Vantage fetched it.
    public let published: String
    public let fetchedAt: Date

    public init(perEUR: [String: Decimal], published: String, fetchedAt: Date) {
        var rates = perEUR
        rates["EUR"] = 1
        self.perEUR = rates
        self.published = published
        self.fetchedAt = fetchedAt
    }

    public func canConvert(_ currency: String) -> Bool {
        perEUR[currency.uppercased()] != nil
    }

    /// Converts one amount, or nil when either side isn't in the feed.
    ///
    /// Via EUR, because that's the only base the ECB publishes. Decimal throughout — the whole
    /// point of carrying Decimal from the TSV is not to hand the money to binary floating point at
    /// the last step.
    public func convert(_ amount: Decimal, from source: String, to target: String) -> Decimal? {
        let from = source.uppercased(), to = target.uppercased()
        if from == to { return amount }
        guard let fromRate = perEUR[from], let toRate = perEUR[to], fromRate != 0 else { return nil }
        return amount / fromRate * toRate
    }

    /// Converts a whole day's per-currency proceeds.
    ///
    /// Returns the converted total *and* whatever couldn't be converted, because a total that
    /// silently omits a currency is exactly the kind of plausible-looking wrong number this app
    /// exists to avoid.
    public func convert(_ proceeds: [String: Decimal],
                        to target: String) -> (converted: Decimal, unconverted: [String: Decimal]) {
        var total: Decimal = 0
        var leftovers: [String: Decimal] = [:]
        for (currency, amount) in proceeds where amount != 0 {
            if let converted = convert(amount, from: currency, to: target) {
                total += converted
            } else {
                leftovers[currency.uppercased(), default: 0] += amount
            }
        }
        return (total, leftovers)
    }

    /// Rates older than this are refetched. Daily rates don't change intraday, and a menu bar app
    /// has no business asking more often than the source publishes.
    public static let maxAge: TimeInterval = 24 * 60 * 60

    public var isStale: Bool { Date().timeIntervalSince(fetchedAt) > Self.maxAge }
}

/// Fetches and caches the ECB feed.
public final class FX {
    public static let endpoint = URL(
        string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    private let cacheURL: URL
    private let session: URLSession

    public init(directory: URL = ReportStore.defaultDirectory) {
        cacheURL = directory.appendingPathComponent("fx-rates.json")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// The cached table, however old. Used to render immediately at launch and to survive a failed
    /// refresh — stale rates beat no numbers, as long as the `≈` is honest about it.
    public func cached() -> FXRates? {
        guard let data = try? Data(contentsOf: cacheURL),
              let rates = try? JSONDecoder().decode(FXRates.self, from: data)
        else { return nil }
        return rates
    }

    /// Fresh rates if the cache has expired, otherwise the cache. Never fails loudly: a failed
    /// refresh returns whatever was cached, and nil only when there has never been a cache.
    public func rates(completion: @escaping (FXRates?) -> Void) {
        if let cached = cached(), !cached.isStale {
            completion(cached)
            return
        }
        session.dataTask(with: FX.endpoint) { [weak self] data, response, _ in
            guard let self else { return }
            guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let parsed = FX.parse(data)
            else {
                completion(self.cached())
                return
            }
            self.store(parsed)
            completion(parsed)
        }.resume()
    }

    private func store(_ rates: FXRates) {
        guard let data = try? JSONEncoder().encode(rates) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Parsing

    /// The feed is `<Cube time='…'><Cube currency='USD' rate='1.0842'/>…`.
    ///
    /// Rates are read as `Decimal(string:)` with a POSIX locale rather than through the XML
    /// parser's number handling: the file writes `1.0842`, and a machine set to a comma-decimal
    /// locale would otherwise read that as ten thousand.
    public static func parse(_ data: Data) -> FXRates? {
        let delegate = ECBParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.rates.isEmpty else { return nil }
        return FXRates(perEUR: delegate.rates, published: delegate.published, fetchedAt: Date())
    }

    private final class ECBParser: NSObject, XMLParserDelegate {
        var rates: [String: Decimal] = [:]
        var published = ""

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            guard element == "Cube" else { return }
            if let time = attributes["time"] { published = time }
            guard let currency = attributes["currency"], let rate = attributes["rate"],
                  let value = Decimal(string: rate, locale: Locale(identifier: "en_US_POSIX")),
                  value > 0
            else { return }
            rates[currency.uppercased()] = value
        }
    }
}
