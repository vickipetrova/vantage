import Foundation

/// Read-only answers about what Vantage has already fetched.
///
/// **This type never touches the Keychain and never opens a socket.** It reads the on-disk cache and
/// nothing else, which is what lets the same queries be exposed to an AI agent without handing it
/// anything it could act with: an agent can reason about the numbers and cannot refresh them,
/// publish anything, or reach App Store Connect at all.
///
/// Everything returned is `Codable`, because the callers are a CLI printing JSON and an MCP server
/// speaking it.
public struct CacheQuery {
    private let reports: ReportStore
    private let reviewStore: ReviewStore
    private let analyticsStore: AnalyticsStore
    private let listings: AppListingStore
    private let fx: FX

    public init(reports: ReportStore = ReportStore(),
                reviews: ReviewStore = ReviewStore(),
                analytics: AnalyticsStore = AnalyticsStore(),
                listings: AppListingStore = AppListingStore(),
                fx: FX = FX()) {
        self.reports = reports
        self.reviewStore = reviews
        self.analyticsStore = analytics
        self.listings = listings
        self.fx = fx
    }

    /// Money, rounded to the cents it will be read as.
    ///
    /// `JSONEncoder` writes a `Decimal` at full precision, so a converted total arrives as
    /// 14.914876209903571 — technically the exact conversion, and noise to anything reading it as
    /// money. Rounded here rather than at each call site so every consumer gets the same figure.
    static func rounded(_ value: Decimal?) -> Decimal? {
        guard let value else { return nil }
        return NSDecimalNumber(decimal: value).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 2, raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false)).decimalValue
    }

    // MARK: - Shared state

    /// Everything cached, newest first. Not a fixed window: the cache keeps days for as long as
    /// the app has been collecting them, and a question about last year deserves last year.
    private var days: [DaySales] {
        AppIdentity.resolve(reports.loadAllCached()).sorted { $0.date > $1.date }
    }

    /// The range pinned to dates, the days inside it, and the span `OverviewModel` totals.
    private func select(_ range: QueryRange, from days: [DaySales])
        -> (resolved: QueryRange.Resolved, window: [DaySales], span: OverviewModel.Span)? {
        guard let newest = days.first?.date, let oldest = days.last?.date else { return nil }
        let resolved = range.resolve(oldest: oldest, newest: newest)
        let window = days.filter { $0.date >= resolved.start && $0.date <= resolved.end }
        let title: String
        switch range {
        case .last(let count): title = count == 1 ? "1 day" : "Last \(count) days"
        case .between: title = Fmt.span(from: resolved.start, to: resolved.end)
        }
        return (resolved, window,
                OverviewModel.Span(title: title, length: resolved.dayCount, end: resolved.end))
    }

    /// Cached rates only — fetching would make this a network tool, which is exactly what it isn't.
    private var rates: FXRates? {
        fx.cached()?.applying(manualRates: Prefs.manualRates)
    }

    // MARK: - Sales

    public struct SalesSnapshot: Codable, Equatable {
        public let range: String
        public let from: String
        public let to: String
        public let displayCurrency: String
        /// Converted, when a rate table covers it. `nil` rather than 0 when it doesn't — a zero
        /// here would be indistinguishable from a range that earned nothing.
        public let proceeds: Decimal?
        public let sales: Decimal?
        public let downloads: Decimal
        public let comparison: String?
        /// Money in currencies nothing can price, left in its own currency rather than dropped.
        public let unconverted: [String: Decimal]
        public let daysCached: Int
        public let daysInRange: Int
    }

    public func sales(range: QueryRange) -> SalesSnapshot? {
        let days = self.days
        guard let (resolved, window, span) = select(range, from: days) else { return nil }

        let model = OverviewModel.build(days: days, rates: rates, error: nil,
                                        metrics: Prefs.metrics,
                                        displayCurrency: Prefs.displayCurrency, span: span)

        var unconverted: [String: Decimal] = [:]
        if let rates {
            var bag: [String: Decimal] = [:]
            for day in window {
                for (code, amount) in day.proceeds { bag[code, default: 0] += amount }
            }
            unconverted = rates.convert(bag.filter { $0.value != 0 },
                                        to: Prefs.displayCurrency).unconverted
                .compactMapValues { Self.rounded($0) }
        }

        return SalesSnapshot(
            range: range.label,
            from: resolved.start.apiString,
            to: resolved.end.apiString,
            displayCurrency: Prefs.displayCurrency,
            proceeds: model.headline?.money.isComparable == true
                ? Self.rounded(model.headline?.money.sortKey) : nil,
            sales: model.headline?.sales?.isComparable == true
                ? Self.rounded(model.headline?.sales?.sortKey) : nil,
            downloads: model.headline?.units ?? 0,
            comparison: model.headline?.comparison,
            unconverted: unconverted,
            daysCached: window.count,
            daysInRange: resolved.dayCount)
    }

    // MARK: - Apps

    public struct AppSnapshot: Codable, Equatable {
        public let appleID: String
        public let title: String
        public let proceeds: Decimal?
        public let downloads: Decimal
        public let averageRating: Decimal?
        public let ratingCount: Int?
    }

    public func apps(range: QueryRange) -> [AppSnapshot] {
        let days = self.days
        guard let (_, _, span) = select(range, from: days) else { return [] }
        let model = OverviewModel.build(days: days, rates: rates, error: nil,
                                        metrics: Prefs.metrics,
                                        displayCurrency: Prefs.displayCurrency, span: span)
        return model.apps.map { app in
            let listing = listings.load(app.appleID)
            return AppSnapshot(appleID: app.appleID, title: app.title,
                               proceeds: app.money.isComparable
                                   ? Self.rounded(app.money.sortKey) : nil,
                               downloads: app.units,
                               averageRating: listing?.averageRating,
                               ratingCount: listing?.ratingCount)
        }
    }

    // MARK: - Reviews

    public struct ReviewSnapshot: Codable, Equatable {
        public let id: String
        public let appleID: String
        public let appTitle: String
        public let rating: Int
        public let title: String
        public let body: String
        public let reviewer: String
        public let territory: String
        public let date: String
        public let response: String?
        public let responseState: String?
    }

    public func reviews(appleID: String? = nil, limit: Int = 50) -> [ReviewSnapshot] {
        let days = self.days
        func title(_ id: String) -> String {
            for day in days {
                if let app = day.apps.first(where: { $0.appleID == id }) { return app.title }
            }
            return id
        }

        let ids: [String] = appleID.map { [$0] } ?? {
            var seen: Set<String> = []
            var ordered: [String] = []
            for day in days {
                for app in day.apps
                where !seen.contains(app.appleID) && app.appleID.allSatisfy(\.isNumber) {
                    seen.insert(app.appleID)
                    ordered.append(app.appleID)
                }
            }
            return ordered
        }()

        let all = ids.flatMap { reviewStore.load($0) ?? [] }
            .sorted { $0.createdDate > $1.createdDate }
            .prefix(limit)

        return all.map { review in
            ReviewSnapshot(
                id: review.id, appleID: review.appleID, appTitle: title(review.appleID),
                rating: review.rating, title: review.title, body: review.body,
                reviewer: review.reviewerNickname, territory: review.territory,
                date: Self.iso.string(from: review.createdDate),
                response: review.response?.body,
                responseState: review.response?.state.rawValue)
        }
    }

    // MARK: - Analytics

    public struct EngagementSnapshot: Codable, Equatable {
        public let date: String
        public let impressions: Decimal
        public let pageViews: Decimal
    }

    public func engagement(appleID: String? = nil) -> [EngagementSnapshot] {
        let ids = appleID.map { [$0] } ?? days.flatMap { $0.apps.map(\.appleID) }
        var collected: [EngagementDay] = []
        for id in Set(ids) where id.allSatisfy(\.isNumber) {
            collected += analyticsStore.load(id) ?? []
        }
        return EngagementMerge.merge(collected).map {
            EngagementSnapshot(date: $0.date.apiString, impressions: $0.impressions,
                               pageViews: $0.pageViews)
        }
    }

    // MARK: - Status

    public struct StatusSnapshot: Codable, Equatable {
        public let headline: String
        public let severity: String
        public let newestReport: String?
        /// How far back a question can usefully reach.
        public let oldestReport: String?
        public let daysCached: Int
        public let displayCurrency: String
        public let ratesPublished: String?
        /// How many apps have reviews on disk. Deliberately **not** whether a key exists: reading
        /// the Keychain from an unsigned binary raises a blocking GUI prompt, and — more to the
        /// point — a tool that promises to hold no credentials has no business asking about one.
        public let appsWithReviewsCached: Int
    }

    public func status() -> StatusSnapshot {
        let days = self.days
        let freshness = Freshness.evaluate(newestCached: days.first?.date,
                                           lastSuccess: Prefs.lastRefreshSuccess, error: nil)
        return StatusSnapshot(
            headline: freshness.headline,
            severity: "\(freshness.severity)",
            newestReport: days.first?.date.apiString,
            oldestReport: days.last?.date.apiString,
            daysCached: days.count,
            displayCurrency: Prefs.displayCurrency,
            ratesPublished: rates?.published,
            appsWithReviewsCached: days
                .flatMap { $0.apps.map(\.appleID) }
                .reduce(into: Set<String>()) { seen, id in
                    if reviewStore.load(id)?.isEmpty == false { seen.insert(id) }
                }
                .count)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
