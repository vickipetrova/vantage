import SwiftUI
import VantageCore

/// Everything that decides which days the cards below refer to: the range, where it sits in time,
/// and a custom start and end. Shared by Overview and App detail so the two can't drift apart.
///
/// Every date decision is `TimeWindow`'s — these views only show its answers and forward clicks.
struct TimeControls: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            RangePicker(model: model)
            TimeStepper(model: model)
            if model.isEditingRange {
                CustomRangeEditor(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.isEditingRange)
    }
}

// MARK: - Range

/// Which slice of the cache everything below refers to.
///
/// A segmented control rather than a menu: options that are read constantly and switched often
/// want to be one click, not two, and showing them all at once is what makes the current one
/// legible at a glance.
struct RangePicker: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OverviewRange.allCases, id: \.self) { range in
                Segment(title: range.shortLabel, help: range.label,
                        isSelected: model.window.preset == range && !model.isEditingRange) {
                    model.select(range)
                }
            }
            Segment(title: "Custom", help: "Choose a start and end date",
                    isSelected: model.window.preset == nil || model.isEditingRange) {
                model.isEditingRange.toggle()
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private struct Segment: View {
        let title: String
        let help: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
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
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }
}

// MARK: - Stepper

/// `‹        9 Sep – 15 Sep 2026   Latest ›`
///
/// The arrows sit at the very edges, lined up with the segmented control above. Latest is an
/// overlay at the trailing end of the date area rather than a sibling, so appearing doesn't move
/// the arrow or shove the date sideways under the pointer.
///
/// The date is secondary, like the unselected segments: it labels what's below, and the figures
/// are what should draw the eye.
private struct TimeStepper: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let window = model.window
        let newest = model.newestDay
        HStack(spacing: Theme.Space.tight) {
            ArrowButton(symbol: "chevron.left", help: "Earlier",
                        isEnabled: window.canStepBack(oldest: model.oldestDay, newest: newest)) {
                model.step(-1)
            }

            Button {
                model.isEditingRange.toggle()
            } label: {
                Text(window.dateLabel(newest: newest))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose dates")
            .overlay(alignment: .trailing) {
                if !window.isLatest {
                    Button("Latest") { model.returnToLatest() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.trailing, 2)
                        .help("Back to the newest report")
                }
            }

            ArrowButton(symbol: "chevron.right", help: "Later",
                        isEnabled: window.canStepForward(newest: newest)) {
                model.step(1)
            }
        }
    }
}

/// A chevron in the same quiet rounded square as the detail view's back button.
private struct ArrowButton: View {
    let symbol: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0.04))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Custom

/// Start and end, inline under the stepper.
///
/// Inline rather than a popover on purpose: a popover is a separate window, and the panel closes
/// on any click outside its own window — so the first click into a date field would dismiss the
/// panel it belongs to.
///
/// **Neither field carries a date range**, though both obviously could. A `.field` date picker
/// with a maximum validates every keystroke rather than the finished date, and a date is typed one
/// component at a time: with the newest report in September, typing the month of `12/01/2025`
/// proposes December *2026*, which is past the maximum, so AppKit snaps the whole field to the
/// newest day and the rest of the typing lands on a date nobody chose. It is only possible to
/// reach last December by editing the year first — an order nothing on screen tells you about.
/// So the fields take any date, and `TimeWindow.custom` clamps the window to the cached days.
private struct CustomRangeEditor: View {
    @ObservedObject var model: PanelModel
    @State private var from: Date
    @State private var to: Date

    /// Starts from what's on screen, so adjusting one end is one edit rather than two.
    ///
    /// Seeded here rather than in `onAppear`: the row is built fresh every time it opens, and
    /// without a range to clamp it, a bare `Date()` would show today — a day no report covers —
    /// until `onAppear` landed.
    init(model: PanelModel) {
        _model = ObservedObject(wrappedValue: model)
        _from = State(initialValue: model.window.startDate(newest: model.newestDay).calendarDate())
        _to = State(initialValue: model.window.endDate(newest: model.newestDay).calendarDate())
    }

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Text("From")
                .foregroundColor(.secondary)
            DatePicker("From", selection: $from, displayedComponents: .date)
                .labelsHidden()
            Text("to")
                .foregroundColor(.secondary)
            DatePicker("To", selection: $to, displayedComponents: .date)
                .labelsHidden()
            Spacer(minLength: 0)
            Button("Apply") {
                model.selectCustom(from: ReportDate(calendarDate: from),
                                   to: ReportDate(calendarDate: to))
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 11))
        .datePickerStyle(.field)
        .controlSize(.small)
        .padding(.horizontal, Theme.Space.row)
        .padding(.vertical, Theme.Space.tight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}
