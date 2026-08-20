import SwiftUI
import VantageCore

/// The panel's frame: a slim icon rail on the leading edge, content beside it.
struct PanelRootView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 0) {
            RailView(model: model)
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The window's NSVisualEffectView provides the background. Anything opaque here would
        // cover it and turn the panel into a plain grey box.
        .background(Color.clear)
    }

    @ViewBuilder
    private var content: some View {
        // Keyed on the route so SwiftUI treats a navigation as a change of view rather than a
        // reconfiguration of the old one — otherwise scroll position and focus leak across
        // sections.
        Group {
            switch model.route {
            case .overview:
                OverviewView(model: model)
            case .appDetail(let appleID):
                PlaceholderView(route: .appDetail(appleID: appleID), model: model)
            case .reviews:
                PlaceholderView(route: .reviews, model: model)
            case .analytics:
                PlaceholderView(route: .analytics, model: model)
            }
        }
        .id(model.route)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.18), value: model.route)
    }
}

// MARK: - Rail

private struct RailView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: Theme.Space.tight) {
            ForEach(PanelRoute.railOrder, id: \.self) { route in
                RailButton(route: route,
                           isSelected: model.route.railSelection == route) {
                    model.navigate(to: route)
                }
            }
            Spacer(minLength: 0)
            RailCommand(symbol: "arrow.clockwise", help: "Refresh Now") { model.onRefresh?() }
            RailCommand(symbol: "gearshape", help: "Settings…") { model.onSettings?() }
        }
        .padding(.vertical, Theme.Space.row)
        .frame(width: Theme.railWidth)
        .frame(maxHeight: .infinity)
    }
}

private struct RailButton: View {
    let route: PanelRoute
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: route.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 30)
                .foregroundColor(isSelected ? Color.accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.14)
                                         : Color.primary.opacity(isHovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(route.label)
        .accessibilityLabel(route.label)
    }
}

/// A rail item that runs a command rather than navigating. Same shape, never selected.
private struct RailCommand: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 36, height: 30)
                .foregroundColor(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Phase 1 placeholder

/// Stands in until each section is built. Carries one text field on purpose: the reply composer in
/// Phase 5 depends on a non-activating panel accepting keyboard input, and that assumption is worth
/// disproving now rather than three phases later.
private struct PlaceholderView: View {
    let route: PanelRoute
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(route.label)
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Space.section)
    }

    private var subtitle: String {
        switch route {
        case .overview:
            return "Built."
        case .appDetail(let appleID):
            return "App \(appleID)."
        case .reviews:
            return "Customer reviews land here in Phase 4."
        case .analytics:
            return "Analytics is the last phase, and optional."
        }
    }
}
