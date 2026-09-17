import SwiftUI
import VantageCore

/// The small, shared pieces every section is built from.
///
/// None of them compute anything — they take strings that `VantageCore` already decided on. That
/// separation is what keeps the numbers testable.

/// A section's title, in the same small-caps-ish weight the old dropdown used for its headers.
struct SectionHeader: View {
    let text: String
    /// Optional trailing control, e.g. the metrics picker.
    var trailing: AnyView?

    init(_ text: String, trailing: AnyView? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.6)
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// Context about the numbers rather than the numbers themselves.
struct Footnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Something went wrong, but not badly enough to hide the figures.
struct WarningRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                // .orange rather than .red: these never mean the numbers on screen are wrong, only
                // that something alongside them didn't work.
                .foregroundColor(.orange)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// One app's row. A button, because it navigates — this is what the v0.1 dropdown could not do.
struct AppRowView: View {
    let app: OverviewModel.AppRow
    /// `nil` while the icon is loading, and permanently for an app that isn't on the store —
    /// TestFlight-only builds and apps removed from sale both look like this.
    let icon: NSImage?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.row) {
                AppIconView(icon: icon)
                Text(app.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Space.tight)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(app.money.headline)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(app.unitsLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    if let impressionsLabel = app.impressionsLabel {
                        Text(impressionsLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .opacity(isHovering ? 1 : 0.35)
            }
            .font(.callout)
            .padding(.horizontal, Theme.Space.row)
            .padding(.vertical, Theme.Space.tight + 1)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(app.title), \(app.money.headline), \(app.unitsLabel)")
    }
}

/// An app's icon, or a neutral stand-in of exactly the same size.
///
/// The placeholder is deliberately not a generic app glyph: a row that shows the wrong icon reads
/// as data, while a row that shows a blank tile reads as a missing image, and the second is the
/// honest one.
struct AppIconView: View {
    let icon: NSImage?
    var side: CGFloat = 26

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .frame(width: side, height: side)
        // iOS artwork arrives as a hard-edged square that the store rounds at display time; macOS
        // artwork arrives with its own shape and transparent corners, so clipping is a no-op there.
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Headline

struct HeadlineCard: View {
    let headline: OverviewModel.Headline

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.6)
                Spacer(minLength: Theme.Space.tight)
                Text(headline.dateLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Side by side, because the comparison people actually make is what customers paid
            // against what reached them — and two figures in a column read as a list, not a pair.
            HStack(alignment: .top, spacing: Theme.Space.section) {
                Figure(value: headline.money.headline, label: "Proceeds", isPrimary: true)
                if let sales = headline.sales {
                    Figure(value: sales.headline, label: "Sales", isPrimary: false)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Spelled out. "89↓" is compact and means nothing until someone tells you what the
                // arrow is; the menu bar has an excuse for shorthand and a card this size doesn't.
                Text("\(Fmt.downloads(headline.units)) \(headline.units == 1 ? "download" : "downloads")")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                if let comparison = headline.comparison {
                    Text(comparison)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let engagement = headline.engagement {
                Text(engagement.line)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let note = headline.engagementNote {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            notes
        }
        .card()
    }

    /// Anything qualifying the figures — a guessed zero, a range that isn't fully cached, money in
    /// a currency nothing can price.
    @ViewBuilder
    private var notes: some View {
        let lines = [headline.coverage, headline.assumedZeroNote].compactMap { $0 }
            + headline.money.notes
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One money figure with its name under it.
private struct Figure: View {
    let value: String
    let label: String
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: isPrimary ? 24 : 20,
                              weight: isPrimary ? .semibold : .regular))
                .foregroundColor(isPrimary ? .primary : .secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
        }
    }
}

// MARK: - Chart

/// The trend chart and its series picker. Shared by Overview and App detail so the two can't drift
/// into drawing the same series differently.
struct TrendCard: View {
    @ObservedObject var model: PanelModel
    /// `nil` charts the whole portfolio; an Apple ID charts one app.
    var appleID: String?

    /// The selected window plus the period before it, ending where the selection ends — see
    /// `TimeWindow.chart`.
    private var trend: TrendData {
        let chart = model.window.chart(newest: model.newestDay)
        return Trend.series(days: model.days, series: model.trendSeries, length: chart.length,
                            endingAt: chart.end, rates: model.rates,
                            displayCurrency: Prefs.displayCurrency, appleID: appleID,
                            engagement: appleID.map { model.engagement[$0] ?? [] }
                                ?? model.portfolioEngagement)
    }

    var body: some View {
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
                Footnote(text: unavailable).frame(height: 40)
            } else if !trend.hasData {
                Footnote(text: "No days cached yet.").frame(height: 40)
            } else {
                TrendChart(data: trend, highlightLast: model.window.length)
                    // Drag or swipe sideways to move through time. The surface only reports whole
                    // days; which days those are is `TimeWindow`'s decision.
                    .overlay(ChartPanSurface(pointCount: trend.points.count) { days in
                        model.pan(byDays: days)
                    })
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
}
