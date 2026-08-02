import ServiceManagement

/// Launch at login, delegated entirely to macOS.
///
/// Deliberately not mirrored into UserDefaults: the system owns this state and the user can revoke
/// it in System Settings › General › Login Items. A local copy would go stale and lie about it.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Registration legitimately fails when the app runs from a temporary or
                // quarantined location — a build straight out of `build/`, typically. Since the
                // getter reads the real status, the checkbox simply doesn't move, which is the
                // honest result rather than a silent lie.
            }
        }
    }
}
