import AppKit
import SwiftUI
import VantageCore

/// The window that hosts `SetupView`.
///
/// An ordinary titled window, deliberately not the non-activating `NSPanel` the readings panel
/// uses. That panel exists so Vantage can show a number without becoming frontmost; this is a form
/// with four fields nobody types by hand, so it should take focus like Settings does.
///
/// Not resizable: it holds one step at a time and has no content that benefits from more room.
final class SetupWindow: NSObject, NSWindowDelegate {
    var onCredentialsChanged: (() -> Void)? {
        get { model.onCredentialsChanged } set { model.onCredentialsChanged = newValue }
    }
    var onReviewsKeyChanged: (() -> Void)? {
        get { model.onReviewsKeyChanged } set { model.onReviewsKeyChanged = newValue }
    }
    /// Skip was pressed. The app opens Settings.
    var onSkipped: (() -> Void)?
    var testConnection: ((@escaping (Result<Void, Error>) -> Void) -> Void)? {
        get { model.testConnection } set { model.testConnection = newValue }
    }

    private let model = SetupModel()
    private var window: NSWindow?

    override init() {
        super.init()
        model.onFinished = { [weak self] in self?.close() }
        model.onSkipped = { [weak self] in
            self?.close()
            self?.onSkipped?()
        }
    }

    func show() {
        if window == nil {
            build()
        } else if model.flow.isComplete {
            // Reopened after a finished run — "Run setup again…" is the only route back in, and
            // without this it would redisplay the same Done screen, whose only control is Done,
            // for the rest of the session. A window merely closed mid-flow skips this branch on
            // purpose, so reopening it resumes where the user left off instead of discarding what
            // they typed.
            model.reset()
        }
        // Setup takes focus, like Settings. It's a form, it needs the keyboard, and ⌘V comes from
        // `MainMenu.install()` — without which the fields silently refuse to paste.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Set Up Vantage"
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(model: model))
        self.window = window
    }
}
