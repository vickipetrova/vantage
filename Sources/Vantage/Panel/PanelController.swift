import AppKit
import SwiftUI

/// Opens, closes, positions and resizes the panel.
///
/// Everything `NSPopover` would have done for free, done deliberately: anchoring under the status
/// item, dismissal on an outside click or Esc, and the size animation between compact and expanded
/// routes. See `PanelWindow` for why that trade is the right one.
final class PanelController: NSObject {
    private var window: PanelWindow?
    private var hostingView: NSHostingView<PanelRootView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// The panel's top edge in screen coordinates, held across resizes.
    ///
    /// Resizing a window moves its *origin*, so growing one downward from the menu bar means
    /// recomputing the origin from a fixed top. Without this the panel appears to jump away from
    /// the menu bar and back on every navigation.
    private var topEdge: CGFloat = 0
    private var anchorMidX: CGFloat = 0
    /// When the panel was last closed by a click.
    ///
    /// The status item's own click arrives twice: the local monitor sees mouse-**down** and closes
    /// the panel, then the button's action fires on mouse-**up** and finds it already closed, so it
    /// reopens. The panel flickered and stayed open, and only Esc or a click elsewhere would
    /// dismiss it. `toggle` ignores a reopen that lands within one click of a close.
    private var lastClosedAt: Date?
    private static let reopenSuppression: TimeInterval = 0.25

    private let model: PanelModel

    /// Gap between the menu bar and the panel's top edge, matching what a system popover leaves.
    private static let menuBarGap: CGFloat = 6
    /// Minimum breathing room between the panel and the edge of the screen.
    private static let screenMargin: CGFloat = 8

    init(model: PanelModel) {
        self.model = model
        super.init()
        model.onRouteChange = { [weak self] route in self?.resize(to: route.size) }
    }

    var isOpen: Bool { window?.isVisible == true }

    // MARK: - Opening and closing

    func toggle(relativeTo button: NSStatusBarButton) {
        if isOpen {
            close()
            return
        }
        if let lastClosedAt, Date().timeIntervalSince(lastClosedAt) < Self.reopenSuppression {
            return
        }
        open(relativeTo: button)
    }

    func open(relativeTo button: NSStatusBarButton) {
        let panel = window ?? makeWindow()
        window = panel

        anchor(panel, to: button)
        model.resetTime()
        // Key, but not active: `orderFrontRegardless` plus a non-activating panel means the text
        // fields inside can be typed into while the user's own app stays frontmost.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // A borderless transparent window caches the shadow it computed from its content's alpha,
        // and that cache survives being ordered out and back in at a different size — leaving a
        // shadow tracing the panel's *previous* outline. Cheap to recompute, invisible when right.
        panel.invalidateShadow()
        startMonitoring()

        // Opening the panel *is* opening the app, so analytics refreshes here as well as from the
        // poll timer. Engagement sits on the Overview now, so it is on screen the moment this
        // returns — and a chart nobody looked at for a fortnight was silently losing days it could
        // still have had.
        //
        // Not forced: `AnalyticsStore.maxAge` means a panel opened twenty times in a day costs at
        // most four refreshes, and this path is passive — the user didn't ask for anything.
        model.loadAnalytics()
    }

    func close() {
        stopMonitoring()
        window?.orderOut(nil)
        lastClosedAt = Date()
    }

    /// Esc. Goes back before it closes.
    ///
    /// Somebody two levels in who wants to leave an app's detail shouldn't lose the panel as well.
    /// The route survives a close, so dismissing outright would reopen on the same screen they were
    /// trying to leave.
    func escape() {
        if model.route == .overview {
            close()
        } else {
            model.navigate(to: .overview)
        }
    }

    private func makeWindow() -> PanelWindow {
        let size = model.route.size
        let panel = PanelWindow(contentRect: NSRect(origin: .zero, size: size))
        panel.onDismiss = { [weak self] in self?.escape() }

        let hosting = NSHostingView(rootView: PanelRootView(model: model))
        // The SwiftUI content must not paint a background of its own — it sits on top of the
        // backdrop, so anything opaque here hides it just as effectively as a bad mask.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: size)
        hostingView = hosting

        panel.contentView = makeBackdrop(around: hosting, size: size)
        return panel
    }

    /// The panel's background, which is a different class depending on the OS.
    ///
    /// On macOS 26 the system's own glass — what widgets and menus are drawn with — is available as
    /// `NSGlassEffectView`, and nothing in the older `NSVisualEffectView` material list comes close
    /// to matching it. All nine legacy materials were compared against a widget side by side and
    /// every one of them reads as noticeably more opaque, because they are a different effect
    /// rather than a lighter setting of the same one.
    ///
    /// Below 26 there is no glass to ask for, so the closest legacy material stands in. Vantage's
    /// floor is macOS 13 and that isn't moving for a background.
    private func makeBackdrop(around content: NSView, size: CGSize) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            // `.regular`, not `.clear`. Clear is the widget weight and it is genuinely beautiful,
            // but it passes so much of the desktop through that the figures on top of it stop being
            // readable — which is the one thing this panel exists to do.
            glass.style = .regular
            glass.cornerRadius = Theme.panelCorner
            glass.contentView = content
            glass.autoresizingMask = [.width, .height]
            glass.frame = NSRect(origin: .zero, size: size)
            return glass
        }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        // .active, not .followsWindowActiveState: the panel is deliberately never the active app's
        // key window, and following that state would render it permanently greyed out.
        effect.state = .active
        // Rounded corners via `maskImage`, NOT via `wantsLayer` + `cornerRadius` + `masksToBounds`.
        // Behind-window blur is composited by the window server outside the layer tree, so clipping
        // it with a layer mask silently drops the blur and leaves a flat opaque panel. `maskImage`
        // is the supported way to shape a visual effect view and keeps the material intact.
        effect.maskImage = Self.roundedMask(radius: Theme.panelCorner)
        effect.autoresizingMask = [.width, .height]
        effect.frame = NSRect(origin: .zero, size: size)
        effect.addSubview(content)
        return effect
    }

    /// A resizable rounded-rect mask, nine-part stretched so one small image fits every panel size.
    ///
    /// The cap insets are what make it resizable: the four corners are drawn at their true size and
    /// only the middle is stretched, so the radius stays constant as the panel grows.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Position

    private func anchor(_ panel: PanelWindow, to button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let screen = buttonWindow.screen ?? NSScreen.main
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        anchorMidX = buttonRect.midX
        topEdge = buttonRect.minY - Self.menuBarGap
        panel.setFrame(frame(for: panel.frame.size, on: screen), display: true)
    }

    /// Centred under the status item, clamped so it never hangs off the screen it opened on.
    ///
    /// A status item near the right edge — which is where they all are — would otherwise put half
    /// the panel past the edge of the display.
    private func frame(for size: CGSize, on screen: NSScreen?) -> NSRect {
        var x = anchorMidX - size.width / 2
        var y = topEdge - size.height

        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + Self.screenMargin),
                    visible.maxX - size.width - Self.screenMargin)
            // A panel taller than the space below the menu bar gets pushed up rather than run off
            // the bottom — losing the anchor is better than losing the content.
            y = max(y, visible.minY + Self.screenMargin)
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Animates between the compact and expanded sizes, keeping the top edge pinned.
    private func resize(to size: CGSize) {
        guard let panel = window, panel.isVisible else {
            window?.setContentSize(size)
            return
        }
        guard panel.frame.size != size else { return }

        let target = frame(for: size, on: panel.screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        } completionHandler: {
            panel.invalidateShadow()
        }
    }

    // MARK: - Dismissal

    private func startMonitoring() {
        stopMonitoring()

        // Clicks in *other* apps. The global monitor can only observe, never consume — which is
        // what we want: the click that dismisses the panel should also land where it was aimed.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.close()
        }

        // Clicks inside Vantage's own windows — Settings, say.
        //
        // Esc is deliberately **not** handled here. A local monitor runs before AppKit dispatches
        // to any window, so intercepting key code 53 meant `PanelWindow.cancelOperation` never ran
        // and a text field mid-edit never got first refusal — Esc while writing a reply navigated
        // away instead of ending the edit. It also fired while Settings was focused, because a
        // local monitor is app-wide rather than panel-scoped. The responder chain does this
        // correctly on its own; see `PanelWindow.cancelOperation`.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.window else { return event }
            if event.window !== panel { self.close() }
            return event
        }

        // APPKIT: a display change moves the status item without moving the panel, which is left
        // anchored to a screen that may no longer exist.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenParametersChanged() {
        // Reanchoring would need the status item's button, which this type deliberately doesn't
        // hold. Closing is both simpler and right: the panel is a glance surface, and one that has
        // jumped to a different display is more confusing than one that isn't there.
        close()
    }

    private func stopMonitoring() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { stopMonitoring() }
}
