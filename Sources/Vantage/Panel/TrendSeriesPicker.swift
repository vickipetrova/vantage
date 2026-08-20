import SwiftUI
import VantageCore

/// Which single series the chart draws.
///
/// Single-select, so it's a list of choices with a checkmark rather than the toggles the metrics
/// picker uses — the shape of the control says which kind of question it is.
struct TrendSeriesPicker: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Menu {
            ForEach(TrendSeries.displayOrder, id: \.self) { series in
                Button {
                    model.select(series)
                } label: {
                    if series == model.trendSeries {
                        Label(series.label, systemImage: "checkmark")
                    } else {
                        Text(series.label)
                    }
                }
            }
        } label: {
            Text(model.trendSeries.label)
                .font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which series the chart draws")
    }
}
