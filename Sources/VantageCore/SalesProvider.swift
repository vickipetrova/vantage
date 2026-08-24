import Foundation

/// One day's sales, in the shape the menu renders.
///
/// Money is `Decimal` throughout and is never collapsed into a single number here: a day routinely
/// spans several proceeds currencies, and choosing which one to show — or what to convert them
/// into — is a display decision made later, with rates attached and an `≈` next to the result.
public struct DaySales: Equatable, Codable, Sendable {
    /// Where the numbers came from. The distinction is load-bearing: an `.observed` day is
    /// immutable and never re-fetched, while an `.assumedZero` day is a guess that Refresh Now is
    /// allowed to overturn. See `docs/REPORT_FORMAT.md`.
    public enum Origin: String, Codable, Sendable {
        /// Parsed from a report Apple actually returned.
        case observed
        /// No report existed well past Apple's publication window, so the day is recorded as zero.
        case assumedZero
    }

    public let date: ReportDate
    public let origin: Origin

    /// Net units of first-time app downloads. Net, and not floored at zero — refund rows carry
    /// negative units, and matching App Store Connect's own figure matters more than never showing
    /// a minus sign.
    public let downloads: Decimal

    /// Developer proceeds, keyed by ISO currency code from the report's Currency of Proceeds
    /// column. Summed as `Units × Developer Proceeds`, which handles refunds correctly on its own.
    public let proceeds: [String: Decimal]

    /// Per-app breakdown, for the dropdown.
    public let apps: [AppSales]

    /// When this day was fetched. Shown as report freshness, not as the report's own date.
    public let fetchedAt: Date

    /// Rows the parser couldn't read at all. Never surfaced as an error — a malformed row costs
    /// one row, not the day — but tracked so a systematic parsing failure is visible rather than
    /// silently shaving numbers.
    public let skippedRows: Int

    /// Net units per product type identifier, exactly as Apple labelled them.
    ///
    /// Kept because "downloads" is a judgement call and this isn't. When Vantage's figure disagrees
    /// with App Store Connect's, the answer is always in here — which codes were counted, which
    /// weren't — and without it the only way to find out is to re-download the report and diff by
    /// hand.
    public let unitsByProductType: [String: Decimal]

    public init(date: ReportDate, origin: Origin, downloads: Decimal,
                proceeds: [String: Decimal], apps: [AppSales],
                fetchedAt: Date, skippedRows: Int = 0,
                unitsByProductType: [String: Decimal] = [:]) {
        self.date = date
        self.origin = origin
        self.downloads = downloads
        self.proceeds = proceeds
        self.apps = apps
        self.fetchedAt = fetchedAt
        self.skippedRows = skippedRows
        self.unitsByProductType = unitsByProductType
    }

    /// Decoded leniently so a cache written by an older build stays valid instead of forcing a
    /// thirty-request refetch every time a field is added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(ReportDate.self, forKey: .date)
        origin = try container.decode(Origin.self, forKey: .origin)
        downloads = try container.decode(Decimal.self, forKey: .downloads)
        proceeds = try container.decode([String: Decimal].self, forKey: .proceeds)
        apps = try container.decode([AppSales].self, forKey: .apps)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        skippedRows = try container.decodeIfPresent(Int.self, forKey: .skippedRows) ?? 0
        unitsByProductType = try container.decodeIfPresent(
            [String: Decimal].self, forKey: .unitsByProductType) ?? [:]
    }

    /// A day Apple published no report for, past the point where it might still arrive.
    public static func zero(on date: ReportDate, fetchedAt: Date) -> DaySales {
        DaySales(date: date, origin: .assumedZero, downloads: 0,
                 proceeds: [:], apps: [], fetchedAt: fetchedAt)
    }
}

/// One app's slice of a day.
public struct AppSales: Equatable, Codable, Sendable {
    /// The Apple Identifier column — the app's Apple ID. Grouping key, because titles are
    /// localized and In-App Purchase rows put the product ID in the Title column instead.
    public let appleID: String
    /// The Title column, for display.
    public let title: String
    public let downloads: Decimal
    public let proceeds: [String: Decimal]

    /// This app's own units per product type, including the ones its In-App Purchases contributed.
    ///
    /// Carried per app for the same reason it's carried per day: the row has to be able to answer
    /// for whichever metrics are switched on. Without it the per-app rows count installs while the
    /// day above them counts something else, and a breakdown that doesn't sum to its own total is
    /// worse than no breakdown.
    public let unitsByProductType: [String: Decimal]

    /// The app's SKU, from the report's own column.
    ///
    /// Carried because an In-App Purchase row names its app by **SKU**, not by Apple Identifier —
    /// so on a day when an app sold no units of its own, its purchases have nothing to resolve
    /// against and group under the raw SKU as a phantom app. Recording the SKU here lets a later
    /// day's report, where the app *did* sell, supply the mapping and fold the phantom back in.
    /// See `AppIdentity`.
    public let sku: String

    public init(appleID: String, title: String, downloads: Decimal,
                proceeds: [String: Decimal], unitsByProductType: [String: Decimal] = [:],
                sku: String = "") {
        self.appleID = appleID
        self.title = title
        self.downloads = downloads
        self.proceeds = proceeds
        self.unitsByProductType = unitsByProductType
        self.sku = sku
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appleID = try container.decode(String.self, forKey: .appleID)
        title = try container.decode(String.self, forKey: .title)
        downloads = try container.decode(Decimal.self, forKey: .downloads)
        proceeds = try container.decode([String: Decimal].self, forKey: .proceeds)
        unitsByProductType = try container.decodeIfPresent(
            [String: Decimal].self, forKey: .unitsByProductType) ?? [:]
        sku = try container.decodeIfPresent(String.self, forKey: .sku) ?? ""
    }
}

/// A source of daily sales figures.
///
/// `ASCClient` is the only implementation in v0.1. The protocol exists so a near-real-time provider
/// — RevenueCat is the obvious one — can be added without the menu learning anything about where
/// numbers come from, exactly as `UsageProvider` does in Headroom.
public protocol SalesProvider {
    var name: String { get }

    /// Fetches one day. `.success(nil)` means Apple has no report for that date *yet* — a real
    /// answer, not a failure, and the distinction the whole scheduler is built on.
    func fetch(_ date: ReportDate, completion: @escaping (Result<DaySales?, Error>) -> Void)
}

/// Everything that can go wrong, in the words the menu will show.
///
/// No case carries a credential, a URL with a vendor number in it, or an underlying Apple error
/// string that might. Error text ends up in the dropdown and in screenshots attached to issues.
public enum SalesError: LocalizedError, Equatable {
    case noCredentials
    /// Apple refused the request. `detail` is Apple's own explanation, already redacted of the
    /// vendor number — without it, a 403 caused by the key's role and a 403 caused by a mistyped
    /// vendor number are the same message, and the user has no way to tell which value to fix.
    case unauthorized(detail: String?)
    case forbidden(detail: String?)
    case rateLimited
    case http(Int, detail: String?)
    case network
    case badReport

    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No App Store Connect key yet — open Settings to add one."
        case .unauthorized:
            // Apple's 401 body is deliberately ignored. It reads "Provide a properly configured
            // and signed bearer token, and make sure that it has not expired…" — boilerplate that
            // names none of the four values the user actually has to check, and that's the only
            // useful thing to say here.
            return "App Store Connect rejected the key. Check the Issuer ID, Key ID, and .p8 file "
                + "— all three have to come from the same key."
        case .forbidden(let detail):
            guard let detail else {
                return "That key can't read sales reports. It needs the Sales and Reports role."
            }
            // Apple's agreement refusal is accurate but doesn't say where to go, and the obvious
            // guess — the key's role — is the wrong place to look. Sales reports need an in-effect
            // Paid Apps Agreement no matter how the key is configured.
            if detail.range(of: "agreement", options: .caseInsensitive) != nil {
                return detail + " Sign it in App Store Connect › Business (Account Holder only)."
            }
            return detail
        case .rateLimited:
            return "App Store Connect is rate limiting. Trying again later."
        case .http(let code, let detail):
            return detail ?? "App Store Connect returned HTTP \(code)."
        case .network:
            return "Can't reach api.appstoreconnect.apple.com."
        case .badReport:
            return "Couldn't read the report Apple returned."
        }
    }
}

/// Apple's `ErrorResponse` body, reduced to something safe to put on screen.
///
/// Apple's `detail` strings are about the request, not the caller — but they can quote a parameter
/// back, and one of those parameters is the vendor number. Anything that reaches the menu can reach
/// a screenshot in a GitHub issue, so the vendor number is redacted before the string escapes this
/// type, and the length is capped so a runaway body can't push the rest of the menu off screen.
public enum ASCErrorBody {
    public static func summary(from data: Data, redacting vendorNumber: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]],
              let first = errors.first
        else { return nil }

        let title = first["title"] as? String
        let detail = first["detail"] as? String
        // Apple's `title` is generic ("The request is forbidden") and `detail` is the useful half
        // ("Invalid vendor number specified"), so prefer detail and fall back.
        guard var message = detail ?? title else { return nil }

        if !vendorNumber.isEmpty {
            message = message.replacingOccurrences(of: vendorNumber, with: "<vendor number>")
        }

        // Apple appends "Learn more about … https://developer.apple.com/…" to several of these.
        // A menu row can't be clicked through to a URL, and a URL that hits the length cap
        // mid-path reads as a broken string rather than as a link.
        if let learnMore = message.range(of: " Learn more", options: .caseInsensitive) {
            message = String(message[..<learnMore.lowerBound])
        }
        if let url = message.range(of: "http", options: .caseInsensitive) {
            message = String(message[..<url.lowerBound])
        }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }

        if message.count > 160 {
            message = String(message.prefix(160)) + "…"
        }
        return message
    }
}
