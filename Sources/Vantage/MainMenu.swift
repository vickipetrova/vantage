import AppKit

/// The application menu bar.
///
/// A menu bar app has no windows most of the time, so it's tempting to skip this entirely — and
/// then ⌘V does nothing in the Settings fields. Keyboard shortcuts in AppKit are dispatched by
/// matching them against main-menu items; with no Edit menu there is no `paste:` item, so the
/// keystroke reaches nothing. Nobody types an Issuer ID by hand, so this file is load-bearing.
///
/// The menu only appears while Vantage is the active app, which for an accessory app means while
/// the Settings window is focused.
enum MainMenu {
    static func install() {
        let main = NSMenu()

        // The app menu. Its title is ignored — macOS always shows the process name — but the menu
        // itself must exist for the ones after it to be placed correctly.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Vantage", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Vantage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
