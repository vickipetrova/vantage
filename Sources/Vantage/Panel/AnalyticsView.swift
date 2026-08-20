import SwiftUI
import VantageCore

/// App Store engagement: how often people saw the app, and how often they opened its page.
///
/// The one section whose numbers don't come from a sales report. Everything here is per app — an
/// analytics report request is created against one app — so the portfolio figures are sums.
struct AnalyticsView: View {
    @ObservedObject var model: PanelModel

    private static let chartDays = 30

    private var portfolio: [EngagementDay] { model.portfolioEngagement }

    private var trend: TrendData {
        Trend.engagement(days: portfolio, metric: model.engagementMetric,
                         length: Self.chartDays,
                         endingAt: portfolio.last?.date ?? ReportDate.yesterday())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    content
                }
                .padding(Theme.Space.section)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear { model.loadAnalytics() }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.row) {
            Text("Analytics")
                .font(.system(size: 15, weight: .semibold))
            if model.isLoadingAnalytics {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Spacer(minLength: 0)
            Picker("", selection: Binding(
                get: { model.engagementMetric },
                set: { model.select($0) })) {
                ForEach(EngagementMetric.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.card)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasReviewsKey {
            VStack(alignment: .leading, spacing: Theme.Space.row) {
                Text("Analytics needs a key")
                    .font(.system(size: 13, weight: .semibold))
                Text("App Store engagement uses the same key as reviews, and Apple requires an "
                     + "Admin key to start generating a report. Add one in Settings.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings…") { model.onSettings?() }
                    .controlSize(.small)
            }
            .card()
        } else if portfolio.isEmpty {
            waiting
        } else {
            summary
            chartCard
            appRows
            if let error = model.analyticsError {
                WarningRow(text: (error as? AnalyticsError)?.errorDescription
                           ?? "Couldn't refresh analytics.")
            }
            Footnote(text: "Apple finalises a day's analytics two days after it, and keeps report "
                     + "instances for 35 days. Older days here are Vantage's own copy.")
        }
    }

    /// The first-run state, which lasts a day or two and is not a failure.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            Text(model.isLoadingAnalytics ? "Checking with App Store Connect…" : "Nothing yet")
                .font(.system(size: 13, weight: .semibold))
            Text((model.analyticsError as? AnalyticsError)?.errorDescription
                 ?? "Apple generates the first analytics report 24 to 48 hours after Vantage asks "
                 + "for it. Nothing more to do — it will appear on its own.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var summary: some View {
        let impressions = portfolio.reduce(Decimal(0)) { $0 + $1.impressions }
        let pageViews = portfolio.reduce(Decimal(0)) { $0 + $1.pageViews }
        let conversion = impressions > 0 ? pageViews / impressions * 100 : nil

        return HStack(spacing: Theme.Space.row) {
            Stat(label: "Impressions", value: Fmt.downloads(impressions))
            Stat(label: "Page views", value: Fmt.downloads(pageViews))
            // A rate with no denominator is undefined, not zero.
            Stat(label: "Page view rate",
                 value: conversion.map { Fmt.percent($0) } ?? "—")
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            SectionHeader(model.engagementMetric.label)
            if trend.hasData {
                TrendChart(data: trend)
                HStack {
                    Text(Fmt.reportDate(trend.points.first?.date ?? ReportDate.yesterday()))
                    Spacer(minLength: 0)
                    Text(Fmt.reportDate(trend.points.last?.date ?? ReportDate.yesterday()))
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            } else {
                Footnote(text: "No days yet.").frame(height: 40)
            }
        }
        .card()
    }

    private var appRows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            SectionHeader("By app")
            LazyVStack(spacing: 1) {
                ForEach(model.reviewableAppleIDs.filter { model.engagement[$0]?.isEmpty == false },
                        id: \.self) { appleID in
                    let days = model.engagement[appleID] ?? []
                    AppEngagementRow(title: model.titleForApp(appleID),
                                     icon: model.icons[appleID],
                                     impressions: days.reduce(Decimal(0)) { $0 + $1.impressions },
                                     pageViews: days.reduce(Decimal(0)) { $0 + $1.pageViews })
                        .onAppear { model.loadIconIfNeeded(appleID) }
                }
            }
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .card()
    }
}

private struct AppEngagementRow: View {
    let title: String
    let icon: NSImage?
    let impressions: Decimal
    let pageViews: Decimal

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            AppIconView(icon: icon, side: 22)
            Text(title).lineLimit(1)
            Spacer(minLength: Theme.Space.tight)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Fmt.downloads(impressions)) impressions")
                    .monospacedDigit()
                Text("\(Fmt.downloads(pageViews)) page views")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, Theme.Space.row)
        .padding(.vertical, Theme.Space.tight)
    }
}
