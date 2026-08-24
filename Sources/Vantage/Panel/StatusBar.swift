import SwiftUI
import VantageCore

/// The strip across the top of every section saying how current the figures are.
///
/// It exists because a failed refresh used to be a grey line at the bottom of the Overview: the
/// numbers stayed on screen looking authoritative, and someone could go three days without noticing
/// that "Can't reach api.appstoreconnect.apple.com" was sitting below the fold. Two things changed
/// — it's at the **top**, in every section rather than one; and it always says when the figures last
/// arrived, so "is this current?" has an answer even when nothing is wrong.
struct StatusBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let freshness = model.freshness
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            summary(freshness)
            // The problem gets its own line at full width. Squeezed onto the summary row it would
            // truncate, and a truncated error is one nobody reads.
            if let problem = freshness.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundColor(freshness.severity == .behind ? .primary : .secondary)
                    // Capped, and not `fixedSize`. An unbounded wrapping label here reports a
                    // minimum height that SwiftUI passes up through NSHostingView, and the panel
                    // window grows to satisfy it — which is how a long error string stretched the
                    // whole panel to full screen height.
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.row)
        .background(background(freshness.severity))
    }

    private func summary(_ freshness: Freshness) -> some View {
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: icon(freshness.severity))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint(freshness.severity))

            Text(freshness.headline)
                .font(.system(size: 11, weight: freshness.severity == .current
                              ? .regular : .semibold))
                .foregroundColor(freshness.severity == .current ? .secondary : .primary)

            if let updated = freshness.lastUpdated {
                Text("· updated \(updated)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.tight)

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            } else {
                // Named when something is wrong, an icon when nothing is. A bare arrow is fine for
                // a routine refresh and useless as the answer to an error.
                Button(freshness.severity == .current ? "" : "Try again") {
                    model.onRefresh?()
                }
                .buttonStyle(.plain)
                .modifier(RefreshLabel(isPlain: freshness.severity == .current))
            }
        }
    }

    private func icon(_ severity: Freshness.Severity) -> String {
        switch severity {
        case .current: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .behind: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ severity: Freshness.Severity) -> Color {
        switch severity {
        case .current: return .secondary
        // Orange, not red, for both: nothing here means the numbers on screen are *wrong*, only
        // that they may be old. Red is for something that needs fixing right now.
        case .warning: return .orange
        case .behind: return .orange
        }
    }

    @ViewBuilder
    private func background(_ severity: Freshness.Severity) -> some View {
        switch severity {
        case .current:
            // Nothing is wrong. A tinted band here would be permanent decoration, and permanent
            // decoration is what makes a warning band invisible when it finally means something.
            Color.clear
        case .warning:
            Color.orange.opacity(0.07)
        case .behind:
            Color.orange.opacity(0.14)
        }
    }
}

/// The refresh control: an icon when things are fine, a labelled button when they aren't.
private struct RefreshLabel: ViewModifier {
    let isPlain: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        Group {
            if isPlain {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                    )
                    .overlay(content.opacity(0.001))
            } else {
                content
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.orange.opacity(isHovering ? 1 : 0.85))
                    )
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("Refresh now")
    }
}
