import SwiftUI
import VantageCore

/// Which units the `↓` figure counts.
///
/// Installs only by default, because that's what the arrow means — but App Store Connect's own
/// dashboard adds in-app purchases to its headline figure, so the ability to reconcile against it
/// has to stay one click away.
///
/// Toggling refetches nothing: every metric is computed from the per-product-type tally already on
/// disk, which is why this can be a menu rather than a settings round trip.
struct MetricsPicker: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Menu {
            ForEach(Metric.displayOrder, id: \.self) { metric in
                Toggle(isOn: binding(for: metric)) {
                    Text("\(metric.label)  (\(Fmt.downloads(units(for: metric))))")
                }
            }
        } label: {
            Label("Metrics", systemImage: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which units the download figure counts")
    }

    private func binding(for metric: Metric) -> Binding<Bool> {
        Binding(get: { model.metrics.contains(metric) },
                set: { _ in model.toggle(metric) })
    }

    /// What this metric alone would count for the day on screen, so the choice can be made against
    /// real numbers rather than guessed at from the label.
    private func units(for metric: Metric) -> Decimal {
        guard let latest = model.days.first else { return 0 }
        return metric.units(in: latest)
    }
}
