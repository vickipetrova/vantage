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
/// Currencies with a hard, officially maintained peg to the US dollar.
///
/// The ECB publishes 30 currencies; Apple pays in around 45. For most of the gap there is nothing
/// honest to do — a floating currency has no rate without a source that publishes one. But a few are
/// **fixed by their central bank**, at a rate that is policy rather than a market observation, and
/// for those a hard-coded number is not an approximation: it is the rate.
///
/// Only pegs that are decades old and centrally maintained belong here. A crawling peg, a managed
/// band or anything that moves is a market rate wearing a disguise and must not be added.
///
/// | Currency | Per USD | Pegged since |
/// |---|---|---|
/// | AED | 3.6725 | 1997 |
/// | SAR | 3.75 | 1986 |
/// | QAR | 3.64 | 2001 |
///
/// If a peg is ever broken or revalued, this table becomes silently wrong — which is why it is
/// small, dated, and named in `SECURITY.md` and the README rather than buried. Prefer removing an
/// entry to letting it drift.
public enum FXPeg {
    public static let unitsPerUSD: [String: Decimal] = [
        "AED": Decimal(string: "3.6725")!,
        "SAR": Decimal(string: "3.75")!,
        "QAR": Decimal(string: "3.64")!,
    ]

    public static func isPegged(_ currency: String) -> Bool {
        unitsPerUSD[currency.uppercased()] != nil
    }
}

/// Rough starting rates for currencies nothing publishes and no central bank pegs.
///
/// **These are estimates, not rates.** They exist so that money in a currency the ECB ignores lands
/// in the total as approximately the right amount rather than sitting outside it — a figure that is
/// 2% out beats one that is 5% short and looks complete. They are floating currencies: every number
/// here is drifting from the day it was written.
///
/// Because of that they are used **last**, after a published rate, a central-bank peg, and anything
/// the user typed; anywhere one affects a figure, the panel says the figure rests on an estimate and
/// points at Settings. Correcting one takes ten seconds and makes it exact.
///
/// Sourced from general market levels around **August 2026**, rounded — precision here would be
/// false confidence. Update `asOf` with them, and prefer deleting an entry to letting it rot.
public enum FXSeed {
    /// Roughly when these were true.
    public static let asOf = "August 2026"

    public static let approximateUnitsPerUSD: [String: Decimal] = [
        "COP": 4_100,     // Colombian peso
        "CLP": 950,       // Chilean peso
        "TWD": 32,        // New Taiwan dollar
        "EGP": 49,        // Egyptian pound
        "NGN": 1_550,     // Nigerian naira
        "PKR": 278,       // Pakistani rupee
        "VND": 25_400,    // Vietnamese dong
        "KZT": 480,       // Kazakhstani tenge
        "PEN": Decimal(string: "3.7")!,  // Peruvian sol
        "TZS": 2_700,     // Tanzanian shilling
    ]

    public static func estimate(for currency: String) -> Decimal? {
        approximateUnitsPerUSD[currency.uppercased()]
    }
}

public struct FXRates: Codable, Equatable, Sendable {
    /// Units of each currency per 1 EUR, as the ECB publishes them. EUR itself is 1.
    public let perEUR: [String: Decimal]
    /// The date the ECB stamped on the feed — not when Vantage fetched it.
    public let published: String
    public let fetchedAt: Date

    /// Rates the user typed in, units per US dollar. **Not persisted** with the rate table — these
    /// belong to the user, not to the ECB's file, and are applied by the caller each time.
    public private(set) var manualUnitsPerUSD: [String: Decimal] = [:]

    private enum CodingKeys: String, CodingKey {
        case perEUR, published, fetchedAt
    }

    /// A copy that will also convert the currencies in `manualRates`.
    ///
    /// Applied last, and only where nothing else can price a currency — see `rate(for:)`.
    public func applying(manualRates: [String: Decimal]) -> FXRates {
        var copy = self
        copy.manualUnitsPerUSD = manualRates.filter { $0.value > 0 }
        return copy
    }

    public init(perEUR: [String: Decimal], published: String, fetchedAt: Date) {
        var rates = perEUR
        rates["EUR"] = 1
        self.perEUR = rates
        self.published = published
        self.fetchedAt = fetchedAt
    }

    public func canConvert(_ currency: String) -> Bool {
        rate(for: currency) != nil
    }

    /// Units of `currency` per euro, from the ECB feed or — for a hard-pegged currency the ECB
    /// doesn't publish — derived from its dollar peg and the ECB's own dollar rate.
    ///
    /// Derived rather than stored, so a cache written before the peg table existed still benefits,
    /// and so removing a peg takes effect immediately rather than after the next fetch.
    /// In order: what the ECB published, then a central-bank peg, then whatever the user typed.
    ///
    /// The order is the point. A hand-typed rate is the last resort and can never override a real
    /// one — a currency Vantage can price properly is never converted at a number someone typed
    /// months ago.
    func rate(for currency: String) -> Decimal? {
        let code = currency.uppercased()
        if let published = perEUR[code] { return published }
        // X per EUR = (X per USD) × (USD per EUR).
        guard let usdPerEUR = perEUR["USD"] else { return nil }
        if let peg = FXPeg.unitsPerUSD[code] { return peg * usdPerEUR }
        if let manual = manualUnitsPerUSD[code] { return manual * usdPerEUR }
        // Last, and only because the alternative is leaving real money out of the total entirely.
        if let seed = FXSeed.estimate(for: code) { return seed * usdPerEUR }
        return nil
    }

    /// Which of these currencies were converted at a fixed peg rather than a published rate.
    ///
    /// Surfaced so the panel can say so. The figure is exact, but "exact because a central bank
    /// fixes it" is a different claim from "exact because the ECB published it this morning", and
    /// the difference belongs on screen rather than in a source comment.
    public func peggedCurrencies(in proceeds: [String: Decimal]) -> [String] {
        proceeds.keys
            .map { $0.uppercased() }
            .filter { perEUR[$0] == nil && FXPeg.unitsPerUSD[$0] != nil }
            .sorted()
    }

    /// Whether this currency has no real rate behind it — nothing published, no central-bank peg.
    ///
    /// These are the currencies worth offering a field for. Deliberately **not** `canConvert`,
    /// which is true once a built-in estimate applies — and an estimate is exactly the case where a
    /// user-supplied rate is most worth having.
    public func needsUserRate(_ currency: String) -> Bool {
        let code = currency.uppercased()
        return perEUR[code] == nil && FXPeg.unitsPerUSD[code] == nil
    }

    /// Which of these were converted at a rate the user typed.
    ///
    /// Named separately from the pegs because the claims are different: a peg is a central bank's
    /// number and doesn't drift, a manual rate is one person's and does. The panel says which.
    public func manuallyRatedCurrencies(in proceeds: [String: Decimal]) -> [String] {
        proceeds.keys
            .map { $0.uppercased() }
            .filter { perEUR[$0] == nil && FXPeg.unitsPerUSD[$0] == nil
                && manualUnitsPerUSD[$0] != nil }
            .sorted()
    }

    /// Which of these rest on a built-in estimate rather than a real rate.
    ///
    /// The loudest of the three qualifiers, because it's the only one where the number came from
    /// nobody in particular. A figure that depends on one has to say so.
    public func estimatedCurrencies(in proceeds: [String: Decimal]) -> [String] {
        proceeds.keys
            .map { $0.uppercased() }
            .filter { perEUR[$0] == nil && FXPeg.unitsPerUSD[$0] == nil
                && manualUnitsPerUSD[$0] == nil && FXSeed.estimate(for: $0) != nil }
            .sorted()
    }

    /// Converts one amount, or nil when either side isn't in the feed.
    ///
    /// Via EUR, because that's the only base the ECB publishes. Decimal throughout — the whole
    /// point of carrying Decimal from the TSV is not to hand the money to binary floating point at
    /// the last step.
    public func convert(_ amount: Decimal, from source: String, to target: String) -> Decimal? {
        let from = source.uppercased(), to = target.uppercased()
        if from == to { return amount }
        guard let fromRate = rate(for: from), let toRate = rate(for: to), fromRate != 0
        else { return nil }
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
        // Redirect-refusing for the same reason as the App Store Connect client: two destinations
        // is a promise, and a 302 would quietly make it three.
        session = URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
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
