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
