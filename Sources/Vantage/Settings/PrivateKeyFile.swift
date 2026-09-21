import AppKit

/// Picking and reading an App Store Connect `.p8`.
///
/// Shared by Settings and the setup wizard deliberately: the wizard's picker must fail exactly as
/// informatively as the Settings one, and a second copy is a second copy to forget to fix.
///
/// **Every path out reports something.** Cancelled, unreadable, wrong file. A picker that appears
/// to do nothing is indistinguishable from a broken button, and that was a real bug once.
///
/// The contents are returned and the path is deliberately not: the file can be deleted or moved
/// into a password manager afterwards, and nothing should ever reach for it again. Nothing here
/// logs or prints what it read.
enum PrivateKeyFile {
    enum Outcome {
        case chosen(String)
        /// The user closed the panel. Not a failure, and not worth a message.
        case cancelled
        /// Something to show the user, already written for them.
        case failed(String)
    }

    static func choose() -> Outcome {
        let panel = NSOpenPanel()
        panel.title = "Choose your App Store Connect private key"
        panel.message = "The AuthKey_XXXXXXXXXX.p8 file you downloaded from App Store Connect."
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Deliberately no `allowedContentTypes`: `.p8` has no registered UTI, and constraining the
        // panel is a good way to grey out the one file the user came here to pick.

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            // macOS can refuse a read of ~/Downloads or ~/Desktop. Never silent.
            return .failed("Couldn't read that file. Try moving it somewhere else and choosing "
                           + "again.")
        }
        guard contents.contains("PRIVATE KEY") else {
            return .failed("That file isn't a private key — look for AuthKey_XXXXXXXXXX.p8.")
        }
        return .chosen(contents)
    }
}
