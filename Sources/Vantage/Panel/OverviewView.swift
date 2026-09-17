import SwiftUI
import VantageCore

/// The panel's default section: what the v0.1 dropdown showed, as cards you can click.
struct OverviewView: View {
    @ObservedObject var model: PanelModel

    private var overview: OverviewModel {
        OverviewModel.build(days: model.days, rates: model.rates, error: model.error,
                            metrics: model.metrics, displayCurrency: Prefs.displayCurrency,
                            span: model.span, engagement: model.engagement)
    }

    var body: some View {
        let overview = self.overview
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                if let message = overview.emptyMessage {
                    EmptyStateView(message: message, checkedAt: overview.checkedAt,
                                   onSettings: model.onSettings)
                } else {
                    // Grouped at row spacing: the controls label the card under them, and a full
                    // section gap made them read as a separate block.
                    VStack(alignment: .leading, spacing: Theme.Space.row) {
                        TimeControls(model: model)
                        if let headline = overview.headline {
                            HeadlineCard(headline: headline)
                        }
                    }
                    TrendCard(model: model)
                    if let note = model.engagementState {
                        EngagementNoteCard(note: note, onSettings: model.onSettings)
                    }
                    apps(overview)
                    notes(overview)
                }
            }
            .padding(Theme.Space.section)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func apps(_ overview: OverviewModel) -> some View {
        if !overview.apps.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                SectionHeader("Apps", trailing: AnyView(MetricsPicker(model: model)))
                // Lazy, so the `.onAppear` below really does mean "when this row is scrolled to".
                // A plain VStack instantiates and appears every child immediately, which fired the
                // whole portfolio's icon lookups the moment the panel opened — the opposite of what
                // the comment claimed.
                LazyVStack(spacing: 1) {
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

/// Why the chart has no impressions to draw — the states the Analytics tab used to own.
private struct EngagementNoteCard: View {
    let note: EngagementNote
    let onSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(note.title)
                .font(.system(size: 13, weight: .semibold))
            if !note.body.isEmpty {
                Text(note.body)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if note.offersSettings {
                Button("Open Settings…") { onSettings?() }
                    .controlSize(.small)
            }
        }
        .card()
    }
}
