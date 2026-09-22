import AppKit
import SwiftUI
import VantageCore

/// The window that hosts `SettingsView`.
///
/// All that's left here is the window itself — the form is SwiftUI now, and its behaviour lives in
/// `SettingsModel`. This is the only place credentials are ever entered. Values go from the form
/// straight into the Keychain; nothing writes them to a log, a preference, or a file, and the
/// `.p8` is never rendered on screen.
final class SettingsWindow: NSObject, NSWindowDelegate {
    /// Called after credentials change, so the app can retry a fetch immediately.
    var onCredentialsChanged: (() -> Void)? {
        get { model.onCredentialsChanged } set { model.onCredentialsChanged = newValue }
    }

    /// Called when a display preference changes — no refetch needed, everything is recomputed from
    /// the cache.
    var onPreferencesChanged: (() -> Void)? {
        get { model.onPreferencesChanged } set { model.onPreferencesChanged = newValue }
    }

    /// Called when the history setting changes, so a wider window starts filling in now rather
    /// than at the next poll.
    var onHistoryChanged: (() -> Void)? {
        get { model.onHistoryChanged } set { model.onHistoryChanged = newValue }
    }

    /// Called when the reviews key or the replies switch changes, so the panel drops a stale state.
    var onReviewsKeyChanged: (() -> Void)? {
        get { model.onReviewsKeyChanged } set { model.onReviewsKeyChanged = newValue }
    }

    /// Reopens the first-run walkthrough.
    var onRunSetup: (() -> Void)? {
        get { model.onRunSetup } set { model.onRunSetup = newValue }
    }

    /// Makes one real request and reports whether it worked. Injected rather than built here so
    /// this window stays a form and knows nothing about App Store Connect.
    var testConnection: ((@escaping (Result<Void, Error>) -> Void) -> Void)? {
        get { model.testConnection } set { model.testConnection = newValue }
    }

    /// Which currencies in the cache nothing can price. Supplied by the app.
    var unpricedCurrencies: (() -> [String])? {
        get { model.unpricedCurrencies } set { model.unpricedCurrencies = newValue }
    }

    private let model = SettingsModel()
    private var window: NSWindow?

    func show() {
        if window == nil { build() }
        // Re-read on every open: the Keychain can change from Keychain Access, or from another
        // copy of the app, while this window is merely closed rather than deallocated.
        model.load()
        // Settings is the one place Vantage deliberately takes focus. It's a form — it needs the
        // keyboard, and ⌘V for values nobody types by hand.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Vantage Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        // Below the tallest content, so the form scrolls rather than clipping on a small display —
        // an earlier fixed 860pt window put "Launch at login" off the bottom of a 900pt screen with
        // no way to reach it.
        window.setContentSize(NSSize(width: 580, height: min(560, (NSScreen.main?.visibleFrame.height ?? 900) - 80)))
        self.window = window
    }
}
