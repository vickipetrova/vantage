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

// MARK: - Range

/// Which slice of the cache everything above the chart refers to.
///
/// A segmented control rather than a menu: three options that are read constantly and switched
/// often want to be one click, not two, and showing all three at once is what makes the current
/// one legible at a glance.
struct RangePicker: View {
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

struct HeadlineCard: View {
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
struct WindowDetail: View {
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

// MARK: - Chart

/// The trend chart and its series picker. Shared by Overview and App detail so the two can't drift
/// into drawing the same series differently.
struct TrendCard: View {
    @ObservedObject var model: PanelModel
    /// `nil` charts the whole portfolio; an Apple ID charts one app.
    var appleID: String?

    /// Thirty days, matching the backfill window — the chart can't show more than is cached, and
    /// asking for more would draw a run of gaps that says nothing.
    private static let days = 30

    private var trend: TrendData {
        Trend.series(days: model.days, series: model.trendSeries, length: Self.days,
                     endingAt: model.days.first?.date ?? ReportDate.yesterday(),
                     rates: model.rates, displayCurrency: Prefs.displayCurrency,
                     appleID: appleID)
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
}
