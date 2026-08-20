import AppKit

/// The floating panel behind the status item.
///
/// A **non-activating** panel, which is the whole reason this isn't an `NSPopover`. Vantage is an
/// accessory app with no windows of its own, and an `NSPopover` in one can't hold first responder
/// for typing without `NSApp.activate(ignoringOtherApps:)` — which yanks focus away from whatever
/// the user was doing and makes Vantage the frontmost app just to read a number. A panel with
/// `.nonactivatingPanel` takes keyboard input *without* activating the app, which is exactly what
/// the review reply composer needs.
///
/// The cost is that anchoring, click-outside dismissal and Esc are ours to write. That's
/// `PanelController`.
final class PanelWindow: NSPanel {
    /// Called when the panel wants to close itself — Esc, or losing key.
    var onDismiss: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   // .borderless: no title bar, no shadow frame of its own.
                   // .nonactivatingPanel: keyboard without stealing app activation.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        // .statusBar (25) sits just above the menu bar's own level, which is the band a panel
        // belonging to a status item belongs in — above every ordinary window, below the system
        // UI that must never be covered.
        //
        // NOT .popUpMenu (101), which was the first choice and cost an afternoon: the window server
        // stops applying behind-window backdrop filters to windows at that level, so an
        // NSVisualEffectView configured perfectly correctly renders as a flat opaque panel. Every
        // setting reads right in the debugger; only the pixels are wrong.
        level = .statusBar
        // Without this the panel vanishes the moment the user clicks back into their editor, which
        // is precisely when they're reading it.
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        // The visual effect view draws the background; the window itself must not draw one behind
        // it, or the rounded corners sit on a grey square.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Follows the user onto another Space rather than yanking them back to the one it opened
        // on. Not .transient — that hides it on deactivation, which hidesOnDeactivate already
        // covers more precisely.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // An accessory app's panel should never appear in a window menu or a screenshot picker.
        isExcludedFromWindowsMenu = true
        animationBehavior = .utilityWindow
    }

    /// Required for a borderless window to accept keyboard at all — the default is `false` for
    /// anything without a title bar, and without it the reply composer can't be typed into.
    override var canBecomeKey: Bool { true }

    /// Main is for document windows. A panel that becomes main would take the app's menu bar focus
    /// as well, which is more than we want and more than we need.
    override var canBecomeMain: Bool { false }

    /// Esc. AppKit routes it here once nothing in the responder chain has claimed it, so a text
    /// field mid-edit gets first refusal and the panel closes only when Esc means "close".
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}
