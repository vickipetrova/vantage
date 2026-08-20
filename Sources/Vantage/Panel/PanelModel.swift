import AppKit
import Combine
import SwiftUI
import VantageCore

/// Everything the panel renders, and the only thing its views read from.
///
/// `ObservableObject` rather than `@Observable`: the `Observation` module is macOS 14, and Vantage's
/// floor is 13. The boilerplate is the price of the floor.
///
/// The views are dumb by design — they read these properties and call these closures, and know
/// nothing about App Store Connect, the cache, or the network. Anything that computes a number
/// belongs in `VantageCore`, not here and not in a view.
final class PanelModel: ObservableObject {
    // MARK: - Navigation

    @Published private(set) var route: PanelRoute = .overview

    /// Fired when the route changes so `PanelController` can animate the window to the new size.
    /// The model doesn't own a window and shouldn't; this is the seam.
    var onRouteChange: ((PanelRoute) -> Void)?

    func navigate(to route: PanelRoute) {
        guard route != self.route else { return }
        self.route = route
        onRouteChange?(route)
    }

    // MARK: - Data

    /// Most recent first.
    @Published private(set) var days: [DaySales] = []
    @Published private(set) var rates: FXRates?
    @Published private(set) var error: Error?
    @Published private(set) var hasCredentials = true
    /// Which unit metrics the download figures count. Mirrored from `Prefs` so a toggle re-renders.
    @Published private(set) var metrics: Set<Metric> = Prefs.metrics
    /// Which single series the Overview chart draws. Also mirrored from `Prefs`.
    @Published private(set) var trendSeries: TrendSeries = Prefs.trendSeries
    /// How much of the cache the Overview summarises.
    @Published private(set) var range: OverviewRange = Prefs.overviewRange

    func update(days: [DaySales], rates: FXRates?, error: Error?) {
        self.days = days.sorted { $0.date > $1.date }
        self.rates = rates
        self.error = error
        self.hasCredentials = true
    }

    func showNoCredentials() {
        days = []
        error = SalesError.noCredentials
        hasCredentials = false
    }

    func toggle(_ metric: Metric) {
        Prefs.toggle(metric)
        metrics = Prefs.metrics
        onMetricsChanged?()
    }

    func select(_ range: OverviewRange) {
        guard range != self.range else { return }
        Prefs.overviewRange = range
        self.range = range
    }

    func select(_ series: TrendSeries) {
        guard series != trendSeries else { return }
        Prefs.trendSeries = series
        trendSeries = series
    }

    // MARK: - App icons

    /// Decoded icons, keyed by Apple ID. `NSImage` rather than `Data` so a row doesn't re-decode
    /// the same PNG on every render.
    @Published private(set) var icons: [String: NSImage] = [:]

    private let iconProvider: AppIconProvider = ITunesIconClient()
    /// Apple IDs already asked for, so a scrolling list doesn't fire the same lookup repeatedly —
    /// including for apps that have no icon, where the answer is a permanent nil.
    private var requestedIcons: Set<String> = []

    func loadIconIfNeeded(_ appleID: String) {
        guard icons[appleID] == nil, !requestedIcons.contains(appleID) else { return }
        requestedIcons.insert(appleID)
        iconProvider.icon(for: appleID) { [weak self] data in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { self?.icons[appleID] = image }
        }
    }

    // MARK: - Reviews

    /// Cached reviews, keyed by Apple ID. There is no portfolio-wide endpoint — reviews are per
    /// app — so this is assembled one request at a time.
    @Published private(set) var reviews: [String: [CustomerReview]] = [:]
    @Published private(set) var reviewsError: Error?
    @Published private(set) var isLoadingReviews = false
    /// Mirrored from the Keychain so the empty state can offer the fix rather than an error.
    @Published private(set) var hasReviewsKey = KeychainStore.hasReviewsKey

    private let reviewsProvider: ReviewsProvider = ASCReviewsClient()
    private let reviewStore = ReviewStore()

    /// Every app seen anywhere in the cached window, newest report first.
    ///
    /// The 30-day window rather than yesterday alone: an app that sold nothing yesterday still has
    /// reviews, and a portfolio view that quietly drops it is wrong in the direction that's hardest
    /// to notice.
    var reviewableAppleIDs: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for day in days {
            for app in day.apps where !seen.contains(app.appleID) {
                seen.insert(app.appleID)
                ordered.append(app.appleID)
            }
        }
        return ordered
    }

    /// Every cached review across the portfolio, newest first.
    var allReviews: [CustomerReview] {
        reviews.values.flatMap { $0 }.sorted { $0.createdDate > $1.createdDate }
    }

    func titleForApp(_ appleID: String) -> String {
        for day in days {
            if let app = day.apps.first(where: { $0.appleID == appleID }) { return app.title }
        }
        return appleID
    }

    /// Loads reviews for every app, from cache first and the network only where the cache is stale.
    ///
    /// Called when the Reviews section is opened rather than from the poll timer: a portfolio view
    /// is one request per app, and spending that on a section nobody has looked at is how an hourly
    /// rate limit gets used up by an app sitting idle in the menu bar.
    func loadReviews(force: Bool = false) {
        hasReviewsKey = KeychainStore.hasReviewsKey
        guard hasReviewsKey else {
            reviewsError = ReviewsError.noKey
            return
        }
        guard !isLoadingReviews else { return }

        // Whatever is on disk goes up immediately, stale or not. A blank panel while a fetch runs is
        // worse than text that's an hour old.
        for appleID in reviewableAppleIDs {
            if let cached = reviewStore.load(appleID) { reviews[appleID] = cached }
        }

        let outstanding = reviewableAppleIDs.filter { force || reviewStore.needsFetch($0) }
        guard !outstanding.isEmpty else {
            reviewsError = nil
            return
        }

        isLoadingReviews = true
        reviewsError = nil
        fetchReviews(outstanding, index: 0)
    }

    /// One app at a time, spaced out. Sequential for the same reason `Backfill` is: a burst of
    /// parallel requests is the fastest way to a 429, and the first failure should stop the rest
    /// rather than repeat itself once per app.
    private func fetchReviews(_ appleIDs: [String], index: Int) {
        guard index < appleIDs.count else {
            isLoadingReviews = false
            return
        }
        let appleID = appleIDs[index]
        reviewsProvider.reviews(forApp: appleID, limit: 50) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let reviews):
                    self.reviews[appleID] = reviews
                    self.reviewStore.save(reviews, for: appleID)
                case .failure(let error):
                    // A key that can't read one app can't read any of them, so stop rather than
                    // fail thirty times with the same message.
                    self.reviewsError = error
                    self.isLoadingReviews = false
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.fetchReviews(appleIDs, index: index + 1)
                }
            }
        }
    }

    /// Called when Settings changes a key, so the section stops showing a stale empty state.
    func reviewsKeyChanged() {
        hasReviewsKey = KeychainStore.hasReviewsKey
        if !hasReviewsKey {
            reviews = [:]
            reviewStore.forgetAll()
            reviewsError = ReviewsError.noKey
        } else {
            reviewsError = nil
            loadReviews(force: true)
        }
    }

    // MARK: - Commands

    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onMetricsChanged: (() -> Void)?

    // MARK: - Derived

    /// Formats proceeds with whatever rates are on hand. Every decision inside lives in
    /// `VantageCore.Money` and is covered by `MoneyTests`.
    func money(_ proceeds: [String: Decimal], compact: Bool = false) -> MoneyText {
        Money.text(for: proceeds, rates: rates, displayCurrency: Prefs.displayCurrency,
                   compact: compact)
    }
}
