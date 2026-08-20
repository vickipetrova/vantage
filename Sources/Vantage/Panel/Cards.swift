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
private struct AppIconView: View {
    let icon: NSImage?

    private static let side: CGFloat = 26

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
        .frame(width: Self.side, height: Self.side)
        // iOS artwork arrives as a hard-edged square that the store rounds at display time; macOS
        // artwork arrives with its own shape and transparent corners, so clipping is a no-op there.
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}
