import SwiftUI
import VantageCore

/// The panel's default section: what the v0.1 dropdown showed, as cards you can click.
struct OverviewView: View {
    @ObservedObject var model: PanelModel

    private var overview: OverviewModel {
        OverviewModel.build(days: model.days, rates: model.rates, error: model.error,
                            metrics: model.metrics, displayCurrency: Prefs.displayCurrency,
                            range: model.range)
    }

    var body: some View {
        let overview = self.overview
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                if let message = overview.emptyMessage {
                    EmptyStateView(message: message, checkedAt: overview.checkedAt,
                                   onSettings: model.onSettings)
                } else {
                    RangePicker(model: model)
                    if let headline = overview.headline {
                        HeadlineCard(headline: headline, windows: overview.windows)
                    }
                    chart
                    apps(overview)
                    notes(overview)
                }
            }
            .padding(Theme.Space.section)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Chart

    /// Thirty days, matching the backfill window — the chart can't show more than is cached, and
    /// asking for more would draw a run of gaps that says nothing.
    private static let chartDays = 30

    private var trend: TrendData {
        Trend.series(days: model.days, series: model.trendSeries, length: Self.chartDays,
                     endingAt: model.days.first?.date ?? ReportDate.yesterday(),
                     rates: model.rates, displayCurrency: Prefs.displayCurrency)
    }

    @ViewBuilder
    private var chart: some View {
        let trend = self.trend
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.tight) {
                Text("OVER TIME")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.6)
                Spacer(minLength: 0)
                TrendSeriesPicker(model: model)
            }

            if let unavailable = trend.unavailable {
                Footnote(text: unavailable)
                    .frame(height: 40)
            } else if !trend.hasData {
                Footnote(text: "No days cached yet.")
                    .frame(height: 40)
            } else {
                TrendChart(data: trend, highlightLast: model.range.days)
                HStack {
                    Text(Fmt.reportDate(trend.points.first?.date ?? ReportDate.yesterday()))
                    Spacer(minLength: 0)
                    Text(Fmt.reportDate(trend.points.last?.date ?? ReportDate.yesterday()))
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }
        }
        .card()
    }

    @ViewBuilder
    private func apps(_ overview: OverviewModel) -> some View {
        if !overview.apps.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                SectionHeader("Apps", trailing: AnyView(MetricsPicker(model: model)))
                VStack(spacing: 1) {
                    ForEach(overview.apps) { app in
                        AppRowView(app: app, icon: model.icons[app.appleID]) {
                            model.navigate(to: .appDetail(appleID: app.appleID))
                        }
                        // Fetched on first appearance rather than up front, so a portfolio's worth
                        // of lookups isn't fired for rows nobody scrolls to.
                        .onAppear { model.loadIconIfNeeded(app.appleID) }
                    }
                }
                // Negative inset so the rows' own hover padding lines their text up with the
                // section header above them rather than sitting indented under it.
                .padding(.horizontal, -Theme.Space.row)
            }
        }
    }

    @ViewBuilder
    private func notes(_ overview: OverviewModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            ForEach(overview.warnings, id: \.self) { WarningRow(text: $0) }
            ForEach(overview.footnotes, id: \.self) { Footnote(text: $0) }
        }
    }
}

// MARK: - Range

/// Which slice of the cache everything above the chart refers to.
///
/// A segmented control rather than a menu: three options that are read constantly and switched
/// often want to be one click, not two, and showing all three at once is what makes the current
/// one legible at a glance.
private struct RangePicker: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OverviewRange.allCases, id: \.self) { range in
                let isSelected = model.range == range
                Button {
                    model.select(range)
                } label: {
                    Text(range.shortLabel)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(isSelected ? 0.10 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(range.label)
                .accessibilityLabel(range.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

// MARK: - Headline

private struct HeadlineCard: View {
    let headline: OverviewModel.Headline
    /// The 7- and 30-day totals, alongside rather than below: they're context for the headline
    /// figure, and a full-width card each gave them more weight than yesterday itself.
    let windows: [OverviewModel.WindowTotal]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(alignment: .top, spacing: Theme.Space.row) {
                primary
                Spacer(minLength: Theme.Space.tight)
                VStack(alignment: .trailing, spacing: Theme.Space.row) {
                    Text(headline.dateLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(windows) { WindowDetail(window: $0) }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            notes
        }
        .card()
    }

    private var primary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(headline.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.6)

            Text(headline.money.headline)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(headline.unitsLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .monospacedDigit()

            if let comparison = headline.comparison {
                Text(comparison)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Anything qualifying the figure — a guessed zero, a currency with no rate. Full width, under
    /// both columns, because these are about the card rather than about either side of it.
    @ViewBuilder
    private var notes: some View {
        if headline.assumedZeroNote != nil || !headline.money.notes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let note = headline.assumedZeroNote {
                    Text(note)
                }
                ForEach(headline.money.notes, id: \.self) { Text($0) }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One window's total, sized as a detail rather than as a headline.
private struct WindowDetail: View {
    let window: OverviewModel.WindowTotal

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(window.label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.4)
            Text(window.money.headline)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(window.unitsLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Empty

/// Loading, or a failure with nothing cached to fall back on.
///
/// Hand-rolled rather than `ContentUnavailableView`, which is macOS 14 — and which wouldn't fit
/// anyway, since the useful thing to offer here is the button that fixes it.
private struct EmptyStateView: View {
    let message: String
    let checkedAt: String?
    let onSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let checkedAt {
                Text(checkedAt)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            // Every error whose fix is a credential is one click from the credentials.
            if message.contains("Settings") || message.contains("key") {
                Button("Open Settings…") { onSettings?() }
                    .controlSize(.small)
            }
        }
        .card()
    }
}
