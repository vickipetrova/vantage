import Foundation

/// Model output → text the composer may show, or the reason it may not.
///
/// The model's text is untrusted twice over: it's generated, and it was generated from a review a
/// stranger wrote. The link and contact checks are the backstop against a review that talks the
/// model into advertising something. The confirmation sheet is the backstop behind this one.
public enum DraftCleanup {
    /// Refusals are only recognised in English. One in another language reaches the editor, where
    /// it's visible and Undo removes it.
    static let refusalLength = 200

    static let labels = [
        "here's a reply:", "here is a reply:", "here's a response:", "here is a response:",
        "reply:", "response:",
    ]

    static let refusals = [
        "i'm sorry, but i can't", "i am sorry, but i cannot", "i cannot help", "i can't help",
        "i can't assist", "i cannot assist",
    ]

    static let closings: Set<String> = [
        "best", "best regards", "kind regards", "regards", "thanks", "thank you", "cheers",
        "sincerely", "warmly", "all the best",
    ]

    /// Links (including `mailto:`) and phone numbers. The types are constants, so this can't throw.
    private static let detector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    public static func clean(_ raw: String) -> Result<String, DraftError> {
        // Swift treats "\r\n" as one Character, so line splitting needs this first.
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = trimmed(text)
        text = stripWrappingQuotes(text)
        text = stripLeadingLabel(text)
        text = stripWrappingQuotes(text)
        text = trimmed(stripPlaceholderSignOff(text))

        if text.isEmpty { return .failure(.rejected) }
        if text.count < refusalLength, isRefusal(text) { return .failure(.declined) }
        if containsContactDetails(text) || containsPlaceholder(text) { return .failure(.rejected) }
        guard ReplyValidation.check(text).isValid else { return .failure(.rejected) }
        return .success(text)
    }

    // MARK: - Steps

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased, with curly apostrophes straightened, for matching only. Never returned.
    static func folded(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    static func stripWrappingQuotes(_ text: String) -> String {
        for (open, close) in [("\"", "\""), ("“", "”")] {
            guard text.count >= 2, text.hasPrefix(open), text.hasSuffix(close) else { continue }
            let inner = String(text.dropFirst().dropLast())
            // `"Export" is on our list, and so is "dark mode"` starts and ends with a quote but
            // isn't wrapped in one pair.
            guard !inner.contains(open), !inner.contains(close) else { return text }
            return trimmed(inner)
        }
        return text
    }

    static func stripLeadingLabel(_ text: String) -> String {
        let lowered = folded(text)
        for label in labels where lowered.hasPrefix(label) {
            return trimmed(String(text.dropFirst(label.count)))
        }
        return text
    }

    /// "Best,\n[Your Name]" at the end. The instructions forbid a sign-off, and the model adds one
    /// anyway often enough that rejecting it would make Try again the usual path.
    static func stripPlaceholderSignOff(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        dropTrailingBlankLines(&lines)
        guard let last = lines.last, containsPlaceholder(last) else { return text }
        lines.removeLast()
        dropTrailingBlankLines(&lines)
        if let closing = lines.last, isClosing(closing) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func dropTrailingBlankLines(_ lines: inout [String]) {
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
    }

    static func isClosing(_ line: String) -> Bool {
        let word = folded(line)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!-—"))
        return closings.contains(word)
    }

    static func isRefusal(_ text: String) -> Bool {
        let lowered = folded(text)
        return refusals.contains { lowered.hasPrefix($0) }
    }

    static func containsPlaceholder(_ text: String) -> Bool {
        text.range(of: #"\[[^\[\]\n]{1,40}\]"#, options: .regularExpression) != nil
    }

    static func containsContactDetails(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if detector.firstMatch(in: text, options: [], range: range) != nil { return true }
        return text.range(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }
}